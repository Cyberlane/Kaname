use crate::{
    LinkError, Result,
    model::{
        DeviceSummary, InviteArtifact, LinkMessage, MAXIMUM_CLOCK_SKEW_MILLIS,
        MAXIMUM_INVITE_LIFETIME_SECONDS, MAXIMUM_PAGE_SIZE, MINIMUM_INVITE_LIFETIME_SECONDS,
        MessageReceipt, RpcOperation, RpcRequest, RpcResponse, RpcResult, SCHEMA_VERSION,
        SpaceSummary, now_unix_millis, validate_gateway_url, validate_identifier, validate_name,
        validate_schema, validate_text,
    },
    noise::{
        StaticKeypair, encode_bytes, generate_invite_secret, generate_static_keypair,
        key_fingerprint, sha256_hex, verification_code,
    },
    private_store::{open_private_database, table_has_column},
    secret_store::{SharedSecretStore, production_secret_store, state_secret_reference},
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const DATABASE_FILENAME: &str = "kaname-link-gateway.sqlite3";

pub struct ActiveInvite {
    pub invite_id: String,
    pub space_id: String,
    pub secret: Vec<u8>,
    pub secret_reference: String,
    pub expires_at_unix_millis: i64,
}

#[derive(Debug, Clone)]
pub struct GatewayDevice {
    pub device_id: String,
    pub display_name: String,
    pub space_id: String,
    pub state: String,
    pub static_public: Vec<u8>,
}

impl GatewayDevice {
    pub(crate) fn require_approved_session(&self) -> Result<()> {
        match self.state.as_str() {
            "approved" => Ok(()),
            "revoked" => Err(LinkError::DeviceRevoked),
            _ => Err(LinkError::Forbidden("device_not_approved")),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatus {
    pub schema_version: u32,
    pub host_key_fingerprint: String,
    pub space_count: u64,
    pub pending_device_count: u64,
    pub approved_device_count: u64,
    pub message_count: u64,
}

pub struct GatewayStore {
    connection: Connection,
    state_root: PathBuf,
    secrets: SharedSecretStore,
}

impl GatewayStore {
    pub fn open(state_root: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_secret_store(state_root, production_secret_store()?)
    }

    pub fn open_with_secret_store(
        state_root: impl AsRef<Path>,
        secrets: SharedSecretStore,
    ) -> Result<Self> {
        let (connection, database_path) =
            open_private_database(state_root.as_ref(), DATABASE_FILENAME)?;
        let state_root = database_path
            .parent()
            .ok_or(LinkError::Invalid("invalid_state_root"))?
            .to_owned();
        let mut store = Self {
            connection,
            state_root,
            secrets,
        };
        store.reject_insecure_legacy_schema()?;
        store.migrate()?;
        store.ensure_host_keypair()?;
        store.purge_inactive_invite_secrets(now_unix_millis())?;
        Ok(store)
    }

    fn reject_insecure_legacy_schema(&self) -> Result<()> {
        if table_has_column(&self.connection, "gateway_identity", "static_private")?
            || table_has_column(&self.connection, "invites", "invite_secret")?
        {
            return Err(LinkError::Conflict("insecure_legacy_database"));
        }
        Ok(())
    }

    fn migrate(&self) -> Result<()> {
        self.connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS gateway_identity (
                 singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                 static_private_reference TEXT NOT NULL UNIQUE,
                 static_public BLOB NOT NULL CHECK (length(static_public) = 32),
                 created_at_unix_millis INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS spaces (
                 space_id TEXT PRIMARY KEY,
                 name TEXT NOT NULL,
                 created_at_unix_millis INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS invites (
                 invite_id TEXT PRIMARY KEY,
                 space_id TEXT NOT NULL REFERENCES spaces(space_id),
                 secret_reference TEXT UNIQUE,
                 secret_digest TEXT NOT NULL,
                 gateway_url TEXT NOT NULL,
                 created_at_unix_millis INTEGER NOT NULL,
                 expires_at_unix_millis INTEGER NOT NULL,
                 consumed_at_unix_millis INTEGER
             );
             CREATE TABLE IF NOT EXISTS devices (
                 device_id TEXT PRIMARY KEY,
                 enrollment_id TEXT NOT NULL UNIQUE,
                 display_name TEXT NOT NULL,
                 space_id TEXT NOT NULL REFERENCES spaces(space_id),
                 static_public BLOB NOT NULL UNIQUE CHECK (length(static_public) = 32),
                 state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'revoked')),
                 created_at_unix_millis INTEGER NOT NULL,
                 approved_at_unix_millis INTEGER,
                 revoked_at_unix_millis INTEGER
             );
             CREATE TABLE IF NOT EXISTS messages (
                 position INTEGER PRIMARY KEY AUTOINCREMENT,
                 message_id TEXT NOT NULL UNIQUE,
                 space_id TEXT NOT NULL REFERENCES spaces(space_id),
                 sender_kind TEXT NOT NULL CHECK (sender_kind IN ('host', 'device')),
                 sender_device_id TEXT,
                 text TEXT NOT NULL,
                 text_digest TEXT NOT NULL,
                 queued_at_unix_millis INTEGER NOT NULL,
                 host_received_at_unix_millis INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS messages_space_position
                 ON messages(space_id, position);
             CREATE TABLE IF NOT EXISTS rpc_requests (
                 device_id TEXT NOT NULL REFERENCES devices(device_id),
                 request_id TEXT NOT NULL,
                 request_digest TEXT NOT NULL,
                 response_json BLOB NOT NULL,
                 created_at_unix_millis INTEGER NOT NULL,
                 PRIMARY KEY(device_id, request_id)
             );",
        )?;
        Ok(())
    }

    fn ensure_host_keypair(&mut self) -> Result<()> {
        if self
            .connection
            .query_row(
                "SELECT 1 FROM gateway_identity WHERE singleton = 1",
                [],
                |_| Ok(()),
            )
            .optional()?
            .is_some()
        {
            self.host_keypair()?;
            return Ok(());
        }
        let pair = generate_static_keypair()?;
        let reference = state_secret_reference(&self.state_root, "gateway", "host-static-v1")?;
        self.secrets.put(&reference, &pair.private)?;
        let insert_result = self.connection.execute(
            "INSERT INTO gateway_identity(
                 singleton, static_private_reference, static_public, created_at_unix_millis
             ) VALUES (1, ?1, ?2, ?3)",
            params![reference, pair.public, now_unix_millis()],
        );
        if let Err(error) = insert_result {
            self.secrets.delete(&reference)?;
            return Err(error.into());
        }
        Ok(())
    }

    pub fn host_keypair(&self) -> Result<StaticKeypair> {
        let (reference, public) = self.connection.query_row(
            "SELECT static_private_reference, static_public
               FROM gateway_identity WHERE singleton = 1",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
        )?;
        let private = self.secrets.get(&reference)?;
        if private.len() != 32 || public.len() != 32 {
            return Err(LinkError::Conflict("stored_host_key_invalid"));
        }
        Ok(StaticKeypair { private, public })
    }

    pub fn status(&self) -> Result<GatewayStatus> {
        let keypair = self.host_keypair()?;
        Ok(GatewayStatus {
            schema_version: SCHEMA_VERSION,
            host_key_fingerprint: key_fingerprint(&keypair.public)?,
            space_count: count(&self.connection, "SELECT COUNT(*) FROM spaces")?,
            pending_device_count: count(
                &self.connection,
                "SELECT COUNT(*) FROM devices WHERE state = 'pending'",
            )?,
            approved_device_count: count(
                &self.connection,
                "SELECT COUNT(*) FROM devices WHERE state = 'approved'",
            )?,
            message_count: count(&self.connection, "SELECT COUNT(*) FROM messages")?,
        })
    }

    pub fn create_invite(
        &mut self,
        space_id: &str,
        space_name: &str,
        gateway_url: &str,
        lifetime_seconds: u64,
    ) -> Result<InviteArtifact> {
        validate_identifier(space_id, "invalid_space_id")?;
        validate_name(space_name, "invalid_space_name")?;
        validate_gateway_url(gateway_url)?;
        if !(MINIMUM_INVITE_LIFETIME_SECONDS..=MAXIMUM_INVITE_LIFETIME_SECONDS)
            .contains(&lifetime_seconds)
        {
            return Err(LinkError::Invalid("invalid_invite_lifetime"));
        }
        let now = now_unix_millis();
        let lifetime_millis: i64 = lifetime_seconds
            .checked_mul(1_000)
            .and_then(|value| value.try_into().ok())
            .ok_or(LinkError::Invalid("invalid_invite_lifetime"))?;
        let expires_at = now
            .checked_add(lifetime_millis)
            .ok_or(LinkError::Invalid("invalid_invite_lifetime"))?;
        let invite_id = format!("invite-{}", Uuid::new_v4());
        let secret = generate_invite_secret()?;
        let secret_digest = sha256_hex(&secret);
        let secret_reference =
            state_secret_reference(&self.state_root, "gateway", &format!("invite-{invite_id}"))?;
        let host = self.host_keypair()?;
        self.secrets.put(&secret_reference, &secret)?;
        let database_result = (|| -> Result<()> {
            let transaction = self
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)?;
            if let Some(existing_name) = transaction
                .query_row(
                    "SELECT name FROM spaces WHERE space_id = ?1",
                    [space_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
            {
                if existing_name != space_name {
                    return Err(LinkError::Conflict("space_name_mismatch"));
                }
            } else {
                transaction.execute(
                    "INSERT INTO spaces(space_id, name, created_at_unix_millis)
                     VALUES (?1, ?2, ?3)",
                    params![space_id, space_name, now],
                )?;
            }
            transaction.execute(
                "INSERT INTO invites(
                     invite_id, space_id, secret_reference, secret_digest, gateway_url,
                     created_at_unix_millis, expires_at_unix_millis
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    invite_id,
                    space_id,
                    secret_reference,
                    secret_digest,
                    gateway_url,
                    now,
                    expires_at
                ],
            )?;
            transaction.commit()?;
            Ok(())
        })();
        if let Err(error) = database_result {
            self.secrets.delete(&secret_reference)?;
            return Err(error);
        }
        Ok(InviteArtifact {
            schema_version: SCHEMA_VERSION,
            invite_id,
            space_id: space_id.to_owned(),
            space_name: space_name.to_owned(),
            gateway_url: gateway_url.to_owned(),
            host_static_public_key: encode_bytes(&host.public),
            invite_secret: encode_bytes(&secret),
            expires_at_unix_millis: expires_at,
        })
    }

    pub fn active_invite(&mut self, invite_id: &str, now: i64) -> Result<ActiveInvite> {
        validate_identifier(invite_id, "invalid_invite_id")?;
        let record = self
            .connection
            .query_row(
                "SELECT space_id, secret_reference, secret_digest,
                        expires_at_unix_millis, consumed_at_unix_millis
                   FROM invites WHERE invite_id = ?1",
                [invite_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                    ))
                },
            )
            .optional()?
            .ok_or(LinkError::NotFound("invite_unavailable"))?;
        let (space_id, secret_reference, secret_digest, expires_at, consumed_at) = record;
        if consumed_at.is_some() {
            return Err(LinkError::Forbidden("invite_unavailable"));
        }
        let secret_reference =
            secret_reference.ok_or(LinkError::Forbidden("invite_unavailable"))?;
        if expires_at <= now {
            self.secrets.delete(&secret_reference)?;
            self.connection.execute(
                "UPDATE invites SET secret_reference = NULL
                  WHERE invite_id = ?1 AND consumed_at_unix_millis IS NULL",
                [invite_id],
            )?;
            return Err(LinkError::Forbidden("invite_unavailable"));
        }
        let secret = self.secrets.get(&secret_reference)?;
        if secret.len() != 32 || sha256_hex(&secret) != secret_digest {
            return Err(LinkError::Conflict("stored_invite_secret_invalid"));
        }
        Ok(ActiveInvite {
            invite_id: invite_id.to_owned(),
            space_id,
            secret,
            secret_reference,
            expires_at_unix_millis: expires_at,
        })
    }

    pub fn admit_pending_device(
        &mut self,
        invite: &ActiveInvite,
        payload: &crate::model::EnrollmentPayload,
        static_public: &[u8],
        now: i64,
    ) -> Result<()> {
        validate_schema(payload.schema_version)?;
        validate_identifier(&payload.enrollment_id, "invalid_enrollment_id")?;
        validate_identifier(&payload.device_id, "invalid_device_id")?;
        validate_name(&payload.display_name, "invalid_display_name")?;
        validate_identifier(&payload.space_id, "invalid_space_id")?;
        if payload.space_id != invite.space_id
            || static_public.len() != 32
            || payload.created_at_unix_millis <= 0
            || (payload.created_at_unix_millis - now).abs() > MAXIMUM_CLOCK_SKEW_MILLIS
        {
            return Err(LinkError::Invalid("invalid_enrollment"));
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let updated = transaction.execute(
            "UPDATE invites
                SET consumed_at_unix_millis = ?1
              WHERE invite_id = ?2
                AND space_id = ?3
                AND consumed_at_unix_millis IS NULL
                AND expires_at_unix_millis > ?1
                AND secret_digest = ?4",
            params![
                now,
                invite.invite_id,
                invite.space_id,
                sha256_hex(&invite.secret)
            ],
        )?;
        if updated != 1 {
            return Err(LinkError::Conflict("invite_unavailable"));
        }
        transaction.execute(
            "INSERT INTO devices(
                 device_id, enrollment_id, display_name, space_id, static_public,
                 state, created_at_unix_millis
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6)",
            params![
                payload.device_id,
                payload.enrollment_id,
                payload.display_name,
                payload.space_id,
                static_public,
                now
            ],
        )?;
        transaction.commit()?;
        self.secrets.delete(&invite.secret_reference)?;
        self.connection.execute(
            "UPDATE invites SET secret_reference = NULL
              WHERE invite_id = ?1 AND consumed_at_unix_millis IS NOT NULL",
            [&invite.invite_id],
        )?;
        Ok(())
    }

    fn purge_inactive_invite_secrets(&mut self, now: i64) -> Result<()> {
        let expired = {
            let mut statement = self.connection.prepare(
                "SELECT invite_id, secret_reference FROM invites
                  WHERE (consumed_at_unix_millis IS NOT NULL
                         OR expires_at_unix_millis <= ?1)
                    AND secret_reference IS NOT NULL",
            )?;
            statement
                .query_map([now], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for (invite_id, reference) in expired {
            self.secrets.delete(&reference)?;
            self.connection.execute(
                "UPDATE invites SET secret_reference = NULL WHERE invite_id = ?1",
                [invite_id],
            )?;
        }
        Ok(())
    }

    pub fn device_for_static(&self, static_public: &[u8]) -> Result<GatewayDevice> {
        self.connection
            .query_row(
                "SELECT device_id, display_name, space_id, state, static_public
                   FROM devices WHERE static_public = ?1",
                [static_public],
                |row| {
                    Ok(GatewayDevice {
                        device_id: row.get(0)?,
                        display_name: row.get(1)?,
                        space_id: row.get(2)?,
                        state: row.get(3)?,
                        static_public: row.get(4)?,
                    })
                },
            )
            .optional()?
            .ok_or(LinkError::Forbidden("device_not_approved"))
    }

    pub fn handle_rpc(
        &mut self,
        device: &GatewayDevice,
        request: &RpcRequest,
        now: i64,
    ) -> Result<RpcResponse> {
        validate_schema(request.schema_version)?;
        validate_identifier(&request.request_id, "invalid_request_id")?;
        validate_identifier(&request.device_id, "invalid_device_id")?;
        validate_identifier(&request.space_id, "invalid_space_id")?;
        device.require_approved_session()?;
        if request.device_id != device.device_id || request.space_id != device.space_id {
            return Err(LinkError::Forbidden("space_scope_mismatch"));
        }
        validate_rpc_operation(&request.operation)?;
        let request_wire = serde_json::to_vec(request)?;
        let request_digest = sha256_hex(&request_wire);
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some((stored_digest, response_wire)) = transaction
            .query_row(
                "SELECT request_digest, response_json FROM rpc_requests
                  WHERE device_id = ?1 AND request_id = ?2",
                params![device.device_id, request.request_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
            )
            .optional()?
        {
            if stored_digest != request_digest {
                return Err(LinkError::Conflict("request_id_reused"));
            }
            return Ok(serde_json::from_slice(&response_wire)?);
        }
        if request.issued_at_unix_millis <= 0
            || (request.issued_at_unix_millis - now).abs() > MAXIMUM_CLOCK_SKEW_MILLIS
        {
            return Err(LinkError::Invalid("request_expired"));
        }
        let result = process_rpc(&transaction, device, request, now)?;
        let response = RpcResponse {
            schema_version: SCHEMA_VERSION,
            request_id: request.request_id.clone(),
            result,
        };
        let response_wire = serde_json::to_vec(&response)?;
        transaction.execute(
            "INSERT INTO rpc_requests(
                 device_id, request_id, request_digest, response_json, created_at_unix_millis
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                device.device_id,
                request.request_id,
                request_digest,
                response_wire,
                now
            ],
        )?;
        transaction.commit()?;
        Ok(response)
    }

    pub fn spaces(&self) -> Result<Vec<SpaceSummary>> {
        let mut statement = self.connection.prepare(
            "SELECT s.space_id, s.name,
                    (SELECT COUNT(*) FROM devices d WHERE d.space_id = s.space_id),
                    (SELECT COUNT(*) FROM messages m WHERE m.space_id = s.space_id)
               FROM spaces s ORDER BY s.created_at_unix_millis, s.space_id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(SpaceSummary {
                space_id: row.get(0)?,
                name: row.get(1)?,
                device_count: row.get::<_, i64>(2)?.try_into().unwrap_or(0),
                message_count: row.get::<_, i64>(3)?.try_into().unwrap_or(0),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn pending_devices(&self, space_id: Option<&str>) -> Result<Vec<DeviceSummary>> {
        if let Some(space_id) = space_id {
            validate_identifier(space_id, "invalid_space_id")?;
        }
        let mut statement = self.connection.prepare(
            "SELECT device_id, display_name, space_id, state, static_public,
                    created_at_unix_millis, approved_at_unix_millis, revoked_at_unix_millis
               FROM devices
              WHERE state = 'pending' AND (?1 IS NULL OR space_id = ?1)
              ORDER BY created_at_unix_millis, device_id",
        )?;
        let rows = statement.query_map([space_id], device_summary_from_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn approve_device(&mut self, device_id: &str) -> Result<DeviceSummary> {
        self.transition_device(device_id, "approved")
    }

    pub fn revoke_device(&mut self, device_id: &str) -> Result<DeviceSummary> {
        self.transition_device(device_id, "revoked")
    }

    fn transition_device(&mut self, device_id: &str, target: &str) -> Result<DeviceSummary> {
        validate_identifier(device_id, "invalid_device_id")?;
        let now = now_unix_millis();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = transaction
            .query_row(
                "SELECT state FROM devices WHERE device_id = ?1",
                [device_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or(LinkError::NotFound("device_not_found"))?;
        match target {
            "approved" if current == "pending" => {
                transaction.execute(
                    "UPDATE devices SET state = 'approved', approved_at_unix_millis = ?1
                      WHERE device_id = ?2",
                    params![now, device_id],
                )?;
            }
            "approved" if current == "approved" => {}
            "revoked" if current != "revoked" => {
                transaction.execute(
                    "UPDATE devices SET state = 'revoked', revoked_at_unix_millis = ?1
                      WHERE device_id = ?2",
                    params![now, device_id],
                )?;
            }
            "revoked" => {}
            _ => return Err(LinkError::Conflict("device_state_conflict")),
        }
        let summary = transaction.query_row(
            "SELECT device_id, display_name, space_id, state, static_public,
                    created_at_unix_millis, approved_at_unix_millis, revoked_at_unix_millis
               FROM devices WHERE device_id = ?1",
            [device_id],
            device_summary_from_row,
        )?;
        transaction.commit()?;
        Ok(summary)
    }

    pub fn inbox(
        &self,
        space_id: &str,
        after_position: u64,
        limit: u32,
    ) -> Result<Vec<LinkMessage>> {
        validate_identifier(space_id, "invalid_space_id")?;
        validate_page(limit)?;
        let mut statement = self.connection.prepare(
            "SELECT position, message_id, space_id, text,
                    queued_at_unix_millis, host_received_at_unix_millis
               FROM messages
              WHERE space_id = ?1 AND sender_kind = 'device' AND position > ?2
              ORDER BY position LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![space_id, as_i64(after_position)?, i64::from(limit)],
            |row| message_from_row(row, "collaborator"),
        )?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn send_host_text(
        &mut self,
        space_id: &str,
        message_id: &str,
        text: &str,
    ) -> Result<MessageReceipt> {
        validate_identifier(space_id, "invalid_space_id")?;
        validate_identifier(message_id, "invalid_message_id")?;
        validate_text(text)?;
        let now = now_unix_millis();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let exists = transaction
            .query_row(
                "SELECT 1 FROM spaces WHERE space_id = ?1",
                [space_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !exists {
            return Err(LinkError::NotFound("space_not_found"));
        }
        let receipt = insert_message(
            &transaction,
            space_id,
            message_id,
            "host",
            None,
            text,
            now,
            now,
        )?;
        transaction.commit()?;
        Ok(receipt)
    }
}

fn process_rpc(
    transaction: &Transaction<'_>,
    device: &GatewayDevice,
    request: &RpcRequest,
    now: i64,
) -> Result<RpcResult> {
    match &request.operation {
        RpcOperation::SendText {
            message_id,
            text,
            queued_at_unix_millis,
        } => Ok(RpcResult::SendText {
            receipt: insert_message(
                transaction,
                &device.space_id,
                message_id,
                "device",
                Some(&device.device_id),
                text,
                *queued_at_unix_millis,
                now,
            )?,
        }),
        RpcOperation::Sync {
            after_position,
            limit,
        } => {
            let mut statement = transaction.prepare(
                "SELECT position, message_id, space_id, sender_kind, text,
                        queued_at_unix_millis, host_received_at_unix_millis
                   FROM messages
                  WHERE space_id = ?1 AND position > ?2
                  ORDER BY position LIMIT ?3",
            )?;
            let rows = statement.query_map(
                params![device.space_id, as_i64(*after_position)?, i64::from(*limit)],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                    ))
                },
            )?;
            let all = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            let next_position = all
                .last()
                .map(|row| row.0.try_into().unwrap_or(*after_position))
                .unwrap_or(*after_position);
            let messages = all
                .into_iter()
                .filter(|row| row.3 == "host")
                .map(|row| LinkMessage {
                    position: row.0.try_into().unwrap_or(0),
                    message_id: row.1,
                    space_id: row.2,
                    sender: "host".to_owned(),
                    text: row.4,
                    queued_at_unix_millis: row.5,
                    host_received_at_unix_millis: row.6,
                })
                .collect();
            Ok(RpcResult::Sync {
                messages,
                next_position,
            })
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn insert_message(
    transaction: &Transaction<'_>,
    space_id: &str,
    message_id: &str,
    sender_kind: &str,
    sender_device_id: Option<&str>,
    text: &str,
    queued_at: i64,
    host_received_at: i64,
) -> Result<MessageReceipt> {
    let digest = sha256_hex(text.as_bytes());
    if let Some((
        stored_space,
        stored_sender,
        stored_device,
        stored_digest,
        stored_queued,
        stored_received,
        position,
    )) = transaction
        .query_row(
            "SELECT space_id, sender_kind, sender_device_id, text_digest,
                    queued_at_unix_millis, host_received_at_unix_millis, position
               FROM messages WHERE message_id = ?1",
            [message_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        )
        .optional()?
    {
        if stored_space != space_id
            || stored_sender != sender_kind
            || stored_device.as_deref() != sender_device_id
            || stored_digest != digest
            || stored_queued != queued_at
        {
            return Err(LinkError::Conflict("message_id_reused"));
        }
        return Ok(MessageReceipt {
            message_id: message_id.to_owned(),
            state: "hostReceived".to_owned(),
            queued_at_unix_millis: stored_queued,
            host_received_at_unix_millis: Some(stored_received),
            position: Some(
                position
                    .try_into()
                    .map_err(|_| LinkError::Conflict("invalid_position"))?,
            ),
            duplicate: true,
        });
    }
    transaction.execute(
        "INSERT INTO messages(
             message_id, space_id, sender_kind, sender_device_id, text, text_digest,
             queued_at_unix_millis, host_received_at_unix_millis
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            message_id,
            space_id,
            sender_kind,
            sender_device_id,
            text,
            digest,
            queued_at,
            host_received_at
        ],
    )?;
    let position: u64 = transaction
        .last_insert_rowid()
        .try_into()
        .map_err(|_| LinkError::Conflict("invalid_position"))?;
    Ok(MessageReceipt {
        message_id: message_id.to_owned(),
        state: "hostReceived".to_owned(),
        queued_at_unix_millis: queued_at,
        host_received_at_unix_millis: Some(host_received_at),
        position: Some(position),
        duplicate: false,
    })
}

fn validate_rpc_operation(operation: &RpcOperation) -> Result<()> {
    match operation {
        RpcOperation::SendText {
            message_id,
            text,
            queued_at_unix_millis,
        } => {
            validate_identifier(message_id, "invalid_message_id")?;
            validate_text(text)?;
            if *queued_at_unix_millis <= 0 {
                return Err(LinkError::Invalid("invalid_queued_time"));
            }
        }
        RpcOperation::Sync { limit, .. } => validate_page(*limit)?,
    }
    Ok(())
}

fn validate_page(limit: u32) -> Result<()> {
    if limit == 0 || limit > MAXIMUM_PAGE_SIZE {
        return Err(LinkError::Invalid("invalid_page_size"));
    }
    Ok(())
}

fn as_i64(value: u64) -> Result<i64> {
    value
        .try_into()
        .map_err(|_| LinkError::Invalid("invalid_cursor"))
}

fn count(connection: &Connection, query: &str) -> Result<u64> {
    let value = connection.query_row(query, [], |row| row.get::<_, i64>(0))?;
    value
        .try_into()
        .map_err(|_| LinkError::Conflict("invalid_count"))
}

fn device_summary_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceSummary> {
    let static_public = row.get::<_, Vec<u8>>(4)?;
    let verification_code = verification_code(&static_public).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Blob, Box::new(error))
    })?;
    Ok(DeviceSummary {
        device_id: row.get(0)?,
        display_name: row.get(1)?,
        space_id: row.get(2)?,
        state: row.get(3)?,
        verification_code,
        created_at_unix_millis: row.get(5)?,
        approved_at_unix_millis: row.get(6)?,
        revoked_at_unix_millis: row.get(7)?,
    })
}

fn message_from_row(row: &rusqlite::Row<'_>, sender: &str) -> rusqlite::Result<LinkMessage> {
    Ok(LinkMessage {
        position: row.get::<_, i64>(0)?.try_into().unwrap_or(0),
        message_id: row.get(1)?,
        space_id: row.get(2)?,
        sender: sender.to_owned(),
        text: row.get(3)?,
        queued_at_unix_millis: row.get(4)?,
        host_received_at_unix_millis: row.get(5)?,
    })
}
