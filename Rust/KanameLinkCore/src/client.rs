use crate::{
    LinkError, Result,
    model::{
        EnrollmentHttpRequest, EnrollmentPayload, EnrollmentReply, InviteArtifact, LinkMessage,
        MAXIMUM_HTTP_RESPONSE_BYTES, MAXIMUM_NOISE_MESSAGE_BYTES, MAXIMUM_PAGE_SIZE,
        MAXIMUM_SYNC_PAGE_SIZE, MessageReceipt, NoiseHttpRequest, NoiseHttpResponse, RpcOperation,
        RpcRequest, RpcResponse, RpcResult, SCHEMA_VERSION, now_unix_millis, validate_gateway_url,
        validate_identifier, validate_name, validate_schema, validate_text,
    },
    noise::{
        decode_bytes, encode_bytes, enrollment_initiator, generate_static_keypair, key_fingerprint,
        read_handshake_message, session_initiator, verification_code, write_handshake_message,
    },
    private_store::{open_private_database, table_has_column},
    secret_store::{SharedSecretStore, production_secret_store, state_secret_reference},
};
use reqwest::blocking::Client as HttpClient;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;

const DATABASE_FILENAME: &str = "kaname-link-client.sqlite3";
const MAXIMUM_SNAPSHOT_MESSAGES_PER_DIRECTION: i64 = 6;

struct ClientIdentity {
    device_id: String,
    display_name: String,
    space_id: String,
    space_name: String,
    gateway_url: String,
    host_static_public: Vec<u8>,
    client_static_public: Vec<u8>,
    client_static_private: Option<Vec<u8>>,
    state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClientSnapshot {
    pub schema_version: u32,
    pub enrolled: bool,
    pub device_id: Option<String>,
    pub display_name: Option<String>,
    pub space_id: Option<String>,
    pub space_name: Option<String>,
    pub gateway_url: Option<String>,
    pub enrollment_state: Option<String>,
    pub verification_code: Option<String>,
    pub queued_messages: Vec<MessageReceipt>,
    pub received_messages: Vec<LinkMessage>,
    pub timeline_messages: Vec<ClientTimelineMessage>,
    pub last_sync_position: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClientTimelineMessage {
    pub message_id: String,
    pub sender: String,
    pub text: String,
    pub sent_at_unix_millis: i64,
    pub receipt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EnrollmentResult {
    pub device_id: String,
    pub space_id: String,
    pub state: String,
    pub host_key_fingerprint: String,
    pub verification_code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SendResult {
    pub receipt: MessageReceipt,
    pub connected: bool,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SyncResult {
    pub connected: bool,
    pub delivered_receipts: Vec<MessageReceipt>,
    pub last_error: Option<String>,
    pub snapshot: ClientSnapshot,
}

pub struct LinkClient {
    connection: Connection,
    http: HttpClient,
    state_root: PathBuf,
    secrets: SharedSecretStore,
}

impl LinkClient {
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
        let client = Self {
            connection,
            http: HttpClient::builder()
                .timeout(Duration::from_secs(10))
                .https_only(false)
                .build()
                .map_err(|error| LinkError::Transport(error.to_string()))?,
            state_root,
            secrets,
        };
        client.reject_insecure_legacy_schema()?;
        client.migrate()?;
        client.identity()?;
        Ok(client)
    }

    fn reject_insecure_legacy_schema(&self) -> Result<()> {
        if table_has_column(&self.connection, "client_identity", "client_static_private")? {
            return Err(LinkError::Conflict("insecure_legacy_database"));
        }
        Ok(())
    }

    fn migrate(&self) -> Result<()> {
        self.connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS client_identity (
                 singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                 enrollment_id TEXT NOT NULL,
                 device_id TEXT NOT NULL,
                 display_name TEXT NOT NULL,
                 space_id TEXT NOT NULL,
                 space_name TEXT NOT NULL,
                 gateway_url TEXT NOT NULL,
                 host_static_public BLOB NOT NULL CHECK (length(host_static_public) = 32),
                 client_static_private_reference TEXT NOT NULL UNIQUE,
                 client_static_public BLOB NOT NULL CHECK (length(client_static_public) = 32),
                 state TEXT NOT NULL CHECK (state IN ('pending', 'approved', 'revoked')),
                 enrolled_at_unix_millis INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS client_state (
                 singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                 last_sync_position INTEGER NOT NULL
             );
             INSERT OR IGNORE INTO client_state(singleton, last_sync_position) VALUES (1, 0);
             CREATE TABLE IF NOT EXISTS outbox (
                 message_id TEXT PRIMARY KEY,
                 request_id TEXT NOT NULL UNIQUE,
                 request_issued_at_unix_millis INTEGER NOT NULL,
                 text TEXT NOT NULL,
                 text_digest TEXT NOT NULL,
                 queued_at_unix_millis INTEGER NOT NULL,
                 state TEXT NOT NULL CHECK (state IN ('queued', 'hostReceived')),
                 host_received_at_unix_millis INTEGER,
                 host_position INTEGER
             );
             CREATE TABLE IF NOT EXISTS inbox (
                 position INTEGER PRIMARY KEY,
                 message_id TEXT NOT NULL UNIQUE,
                 sender TEXT NOT NULL CHECK (sender = 'host'),
                 text TEXT NOT NULL,
                 queued_at_unix_millis INTEGER NOT NULL,
                 host_received_at_unix_millis INTEGER NOT NULL
             );",
        )?;
        Ok(())
    }

    pub fn enroll(
        &mut self,
        invite: &InviteArtifact,
        display_name: &str,
    ) -> Result<EnrollmentResult> {
        validate_schema(invite.schema_version)?;
        validate_identifier(&invite.invite_id, "invalid_invite_id")?;
        validate_identifier(&invite.space_id, "invalid_space_id")?;
        validate_name(&invite.space_name, "invalid_space_name")?;
        validate_name(display_name, "invalid_display_name")?;
        validate_gateway_url(&invite.gateway_url)?;
        if invite.expires_at_unix_millis <= now_unix_millis() {
            return Err(LinkError::Forbidden("invite_expired"));
        }
        if self.identity()?.is_some() {
            return Err(LinkError::Conflict("client_already_enrolled"));
        }
        let host_public = decode_bytes(
            &invite.host_static_public_key,
            32,
            "invalid_host_static_key",
        )?;
        let invite_secret = decode_bytes(&invite.invite_secret, 32, "invalid_invite_secret")?;
        let client_keys = generate_static_keypair()?;
        let now = now_unix_millis();
        let enrollment_id = format!("enrollment-{}", Uuid::new_v4());
        let device_id = format!("device-{}", Uuid::new_v4());
        let private_reference = state_secret_reference(
            &self.state_root,
            "client",
            &format!("device-{device_id}-static-v1"),
        )?;
        self.secrets.put(&private_reference, &client_keys.private)?;
        let result = (|| -> Result<EnrollmentResult> {
            let payload = EnrollmentPayload {
                schema_version: SCHEMA_VERSION,
                enrollment_id: enrollment_id.clone(),
                device_id: device_id.clone(),
                display_name: display_name.to_owned(),
                space_id: invite.space_id.clone(),
                created_at_unix_millis: now,
            };
            let mut noise =
                enrollment_initiator(&client_keys.private, &host_public, &invite_secret)?;
            let first = write_handshake_message(&mut noise, &serde_json::to_vec(&payload)?)?;
            let response = self.post_json::<_, NoiseHttpResponse>(
                &invite.gateway_url,
                "/v1/enroll",
                &EnrollmentHttpRequest {
                    schema_version: SCHEMA_VERSION,
                    invite_id: invite.invite_id.clone(),
                    noise_message: encode_bytes(&first),
                },
                "enrollment_rejected",
            )?;
            validate_schema(response.schema_version)?;
            let second = decode_bytes(
                &response.noise_message,
                MAXIMUM_NOISE_MESSAGE_BYTES,
                "invalid_noise_response",
            )?;
            let reply_wire = read_handshake_message(&mut noise, &second)?;
            let reply: EnrollmentReply = serde_json::from_slice(&reply_wire)?;
            validate_schema(reply.schema_version)?;
            let fingerprint = key_fingerprint(&host_public)?;
            let device_verification_code = verification_code(&client_keys.public)?;
            if reply.enrollment_id != enrollment_id
                || reply.device_id != device_id
                || reply.state != "pending"
                || reply.host_key_fingerprint != fingerprint
                || reply.verification_code != device_verification_code
            {
                return Err(LinkError::Conflict("enrollment_response_mismatch"));
            }
            self.connection.execute(
                "INSERT INTO client_identity(
                     singleton, enrollment_id, device_id, display_name, space_id, space_name,
                     gateway_url, host_static_public, client_static_private_reference,
                     client_static_public, state, enrolled_at_unix_millis
                 ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'pending', ?10)",
                params![
                    enrollment_id,
                    device_id,
                    display_name,
                    invite.space_id,
                    invite.space_name,
                    invite.gateway_url,
                    host_public,
                    private_reference,
                    client_keys.public,
                    now
                ],
            )?;
            Ok(EnrollmentResult {
                device_id: device_id.clone(),
                space_id: invite.space_id.clone(),
                state: "pending".to_owned(),
                host_key_fingerprint: fingerprint,
                verification_code: device_verification_code,
            })
        })();
        if result.is_err() {
            self.secrets.delete(&private_reference)?;
        }
        result
    }

    pub fn send_text(
        &mut self,
        text: &str,
        proposed_message_id: Option<&str>,
    ) -> Result<SendResult> {
        validate_text(text)?;
        let message_id = proposed_message_id
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| format!("message-{}", Uuid::new_v4()));
        validate_identifier(&message_id, "invalid_message_id")?;
        let queued_at = now_unix_millis();
        let request_id = format!("request-{}", Uuid::new_v4());
        let digest = crate::noise::sha256_hex(text.as_bytes());
        if let Some((stored_digest, stored_queued)) = self
            .connection
            .query_row(
                "SELECT text_digest, queued_at_unix_millis FROM outbox WHERE message_id = ?1",
                [&message_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
        {
            if stored_digest != digest {
                return Err(LinkError::Conflict("message_id_reused"));
            }
            let receipt = self.outbox_receipt(&message_id)?;
            return Ok(SendResult {
                connected: receipt.state == "hostReceived",
                last_error: None,
                receipt: MessageReceipt {
                    queued_at_unix_millis: stored_queued,
                    duplicate: true,
                    ..receipt
                },
            });
        }
        self.identity()?
            .ok_or(LinkError::Forbidden("client_not_enrolled"))?;
        self.connection.execute(
            "INSERT INTO outbox(
                 message_id, request_id, request_issued_at_unix_millis, text, text_digest,
                 queued_at_unix_millis, state
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'queued')",
            params![message_id, request_id, queued_at, text, digest, queued_at],
        )?;
        let (delivered, error) = self.flush_outbox(100)?;
        let mut receipt = self.outbox_receipt(&message_id)?;
        receipt.duplicate = false;
        Ok(SendResult {
            connected: receipt.state == "hostReceived",
            last_error: error.map(|value| value.code().to_owned()),
            receipt: delivered
                .into_iter()
                .find(|value| value.message_id == message_id)
                .unwrap_or(receipt),
        })
    }

    pub fn sync(&mut self) -> Result<SyncResult> {
        let (delivered, flush_error) = self.flush_outbox(100)?;
        let mut last_error = flush_error.map(|value| value.code().to_owned());
        let mut connected = last_error.is_none();
        if connected {
            let identity = self
                .identity()?
                .ok_or(LinkError::Forbidden("client_not_enrolled"))?;
            let after_position = self.last_sync_position()?;
            let request = RpcRequest {
                schema_version: SCHEMA_VERSION,
                request_id: format!("request-{}", Uuid::new_v4()),
                device_id: identity.device_id.clone(),
                space_id: identity.space_id.clone(),
                issued_at_unix_millis: now_unix_millis(),
                operation: RpcOperation::Sync {
                    after_position,
                    limit: MAXIMUM_SYNC_PAGE_SIZE,
                },
            };
            match self.rpc_roundtrip(&identity, &request) {
                Ok(RpcResponse {
                    result:
                        RpcResult::Sync {
                            messages,
                            next_position,
                        },
                    ..
                }) => {
                    self.record_sync(&messages, next_position)?;
                    self.mark_approved()?;
                }
                Ok(_) => return Err(LinkError::Conflict("rpc_response_mismatch")),
                Err(error) => {
                    connected = false;
                    last_error = Some(error.code().to_owned());
                    if matches!(error, LinkError::Forbidden(_)) {
                        self.mark_authorization_failure()?;
                    }
                }
            }
        }
        Ok(SyncResult {
            connected,
            delivered_receipts: delivered,
            last_error,
            snapshot: self.snapshot()?,
        })
    }

    pub fn snapshot(&self) -> Result<ClientSnapshot> {
        let identity = self.identity()?;
        let mut outbox_statement = self.connection.prepare(
            "SELECT message_id, state, queued_at_unix_millis,
                    host_received_at_unix_millis, host_position
               FROM outbox
              ORDER BY CASE state WHEN 'queued' THEN 0 ELSE 1 END,
                       queued_at_unix_millis DESC, message_id
              LIMIT ?1",
        )?;
        let queued_messages = outbox_statement
            .query_map([i64::from(MAXIMUM_PAGE_SIZE)], |row| {
                Ok(MessageReceipt {
                    message_id: row.get(0)?,
                    state: row.get(1)?,
                    queued_at_unix_millis: row.get(2)?,
                    host_received_at_unix_millis: row.get(3)?,
                    position: row
                        .get::<_, Option<i64>>(4)?
                        .and_then(|value| value.try_into().ok()),
                    duplicate: false,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut sent_statement = self.connection.prepare(
            "SELECT message_id, text, queued_at_unix_millis, state
               FROM outbox ORDER BY queued_at_unix_millis DESC, message_id LIMIT ?1",
        )?;
        let sent_messages = sent_statement
            .query_map([MAXIMUM_SNAPSHOT_MESSAGES_PER_DIRECTION], |row| {
                Ok(ClientTimelineMessage {
                    message_id: row.get(0)?,
                    sender: "collaborator".to_owned(),
                    text: row.get(1)?,
                    sent_at_unix_millis: row.get(2)?,
                    receipt: row.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let space_id = identity.as_ref().map(|value| value.space_id.clone());
        let mut inbox_statement = self.connection.prepare(
            "SELECT position, message_id, sender, text,
                    queued_at_unix_millis, host_received_at_unix_millis
               FROM inbox ORDER BY position DESC LIMIT ?1",
        )?;
        let received_messages = inbox_statement
            .query_map([MAXIMUM_SNAPSHOT_MESSAGES_PER_DIRECTION], |row| {
                Ok(LinkMessage {
                    position: row.get::<_, i64>(0)?.try_into().unwrap_or(0),
                    message_id: row.get(1)?,
                    space_id: space_id.clone().unwrap_or_default(),
                    sender: row.get(2)?,
                    text: row.get(3)?,
                    queued_at_unix_millis: row.get(4)?,
                    host_received_at_unix_millis: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut timeline_messages = sent_messages;
        timeline_messages.extend(
            received_messages
                .iter()
                .map(|message| ClientTimelineMessage {
                    message_id: message.message_id.clone(),
                    sender: "host".to_owned(),
                    text: message.text.clone(),
                    sent_at_unix_millis: message.host_received_at_unix_millis,
                    receipt: "hostPublished".to_owned(),
                }),
        );
        timeline_messages.sort_by(|left, right| {
            left.sent_at_unix_millis
                .cmp(&right.sent_at_unix_millis)
                .then_with(|| left.message_id.cmp(&right.message_id))
        });
        Ok(ClientSnapshot {
            schema_version: SCHEMA_VERSION,
            enrolled: identity.is_some(),
            device_id: identity.as_ref().map(|value| value.device_id.clone()),
            display_name: identity.as_ref().map(|value| value.display_name.clone()),
            space_id,
            space_name: identity.as_ref().map(|value| value.space_name.clone()),
            gateway_url: identity.as_ref().map(|value| value.gateway_url.clone()),
            enrollment_state: identity.as_ref().map(|value| value.state.clone()),
            verification_code: identity
                .as_ref()
                .map(|value| verification_code(&value.client_static_public))
                .transpose()?,
            queued_messages,
            received_messages,
            timeline_messages,
            last_sync_position: self.last_sync_position()?,
        })
    }

    fn flush_outbox(&mut self, limit: u32) -> Result<(Vec<MessageReceipt>, Option<LinkError>)> {
        let identity = self
            .identity()?
            .ok_or(LinkError::Forbidden("client_not_enrolled"))?;
        let queued = {
            let mut statement = self.connection.prepare(
                "SELECT message_id, request_id, request_issued_at_unix_millis,
                        text, queued_at_unix_millis
                   FROM outbox WHERE state = 'queued'
                   ORDER BY queued_at_unix_millis, message_id LIMIT ?1",
            )?;
            statement
                .query_map([i64::from(limit)], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut receipts = Vec::new();
        for (message_id, request_id, request_issued_at, text, queued_at) in queued {
            let request = RpcRequest {
                schema_version: SCHEMA_VERSION,
                request_id,
                device_id: identity.device_id.clone(),
                space_id: identity.space_id.clone(),
                issued_at_unix_millis: request_issued_at,
                operation: RpcOperation::SendText {
                    message_id: message_id.clone(),
                    text,
                    queued_at_unix_millis: queued_at,
                },
            };
            let response = match self.rpc_roundtrip(&identity, &request) {
                Ok(response) => response,
                Err(error) => {
                    if matches!(error, LinkError::Forbidden(_)) {
                        self.mark_authorization_failure()?;
                    }
                    return Ok((receipts, Some(error)));
                }
            };
            let RpcResult::SendText { receipt } = response.result else {
                return Err(LinkError::Conflict("rpc_response_mismatch"));
            };
            if receipt.message_id != message_id
                || receipt.state != "hostReceived"
                || receipt.queued_at_unix_millis != queued_at
                || receipt.host_received_at_unix_millis.is_none()
                || receipt.position.is_none()
            {
                return Err(LinkError::Conflict("receipt_mismatch"));
            }
            self.connection.execute(
                "UPDATE outbox
                    SET state = 'hostReceived', host_received_at_unix_millis = ?1,
                        host_position = ?2
                  WHERE message_id = ?3 AND state = 'queued'",
                params![
                    receipt.host_received_at_unix_millis,
                    receipt.position.and_then(|value| i64::try_from(value).ok()),
                    message_id
                ],
            )?;
            self.mark_approved()?;
            receipts.push(receipt);
        }
        Ok((receipts, None))
    }

    fn rpc_roundtrip(
        &self,
        identity: &ClientIdentity,
        request: &RpcRequest,
    ) -> Result<RpcResponse> {
        let client_private = identity
            .client_static_private
            .as_deref()
            .ok_or(LinkError::Forbidden("client_key_unavailable"))?;
        let mut noise = session_initiator(client_private, &identity.host_static_public)?;
        let first = write_handshake_message(&mut noise, &serde_json::to_vec(request)?)?;
        let response = self.post_json::<_, NoiseHttpResponse>(
            &identity.gateway_url,
            "/v1/rpc",
            &NoiseHttpRequest {
                schema_version: SCHEMA_VERSION,
                noise_message: encode_bytes(&first),
            },
            "session_rejected",
        )?;
        validate_schema(response.schema_version)?;
        let second = decode_bytes(
            &response.noise_message,
            MAXIMUM_NOISE_MESSAGE_BYTES,
            "invalid_noise_response",
        )?;
        let response_wire = read_handshake_message(&mut noise, &second)?;
        let decoded: RpcResponse = serde_json::from_slice(&response_wire)?;
        validate_schema(decoded.schema_version)?;
        if decoded.request_id != request.request_id {
            return Err(LinkError::Conflict("rpc_response_mismatch"));
        }
        Ok(decoded)
    }

    fn post_json<Request: Serialize, Response: for<'de> Deserialize<'de>>(
        &self,
        gateway_url: &str,
        path: &str,
        request: &Request,
        rejection_code: &'static str,
    ) -> Result<Response> {
        let url = format!("{}{}", gateway_url.trim_end_matches('/'), path);
        let response = self
            .http
            .post(url)
            .json(request)
            .send()
            .map_err(|error| LinkError::Transport(error.to_string()))?;
        if !response.status().is_success() {
            return if matches!(
                response.status(),
                reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN
            ) {
                Err(LinkError::Forbidden(rejection_code))
            } else if response.status().is_server_error() {
                Err(LinkError::Unavailable("gateway_unavailable"))
            } else {
                Err(LinkError::Invalid(rejection_code))
            };
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAXIMUM_HTTP_RESPONSE_BYTES as u64)
        {
            return Err(LinkError::Invalid("gateway_response_too_large"));
        }
        let mut body = Vec::new();
        response
            .take((MAXIMUM_HTTP_RESPONSE_BYTES + 1) as u64)
            .read_to_end(&mut body)
            .map_err(|error| LinkError::Transport(error.to_string()))?;
        if body.len() > MAXIMUM_HTTP_RESPONSE_BYTES {
            return Err(LinkError::Invalid("gateway_response_too_large"));
        }
        serde_json::from_slice(&body).map_err(LinkError::from)
    }

    fn identity(&self) -> Result<Option<ClientIdentity>> {
        let record = self
            .connection
            .query_row(
                "SELECT device_id, display_name, space_id, space_name, gateway_url,
                        host_static_public, client_static_private_reference,
                        client_static_public, state
                   FROM client_identity WHERE singleton = 1",
                [],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Vec<u8>>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, Vec<u8>>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                },
            )
            .optional()?;
        let Some((
            device_id,
            display_name,
            space_id,
            space_name,
            gateway_url,
            host_static_public,
            client_static_private_reference,
            client_static_public,
            state,
        )) = record
        else {
            return Ok(None);
        };
        let client_static_private = if state == "revoked" {
            None
        } else {
            let secret = self.secrets.get(&client_static_private_reference)?;
            if secret.len() != 32 {
                return Err(LinkError::Conflict("stored_client_key_invalid"));
            }
            Some(secret)
        };
        Ok(Some(ClientIdentity {
            device_id,
            display_name,
            space_id,
            space_name,
            gateway_url,
            host_static_public,
            client_static_public,
            client_static_private,
            state,
        }))
    }

    fn mark_approved(&self) -> Result<()> {
        self.connection.execute(
            "UPDATE client_identity SET state = 'approved'
              WHERE singleton = 1 AND state = 'pending'",
            [],
        )?;
        Ok(())
    }

    fn mark_authorization_failure(&self) -> Result<()> {
        let reference = self
            .connection
            .query_row(
                "SELECT client_static_private_reference FROM client_identity
                  WHERE singleton = 1 AND state = 'approved'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(reference) = reference else {
            return Ok(());
        };
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            "UPDATE client_identity SET state = 'revoked'
              WHERE singleton = 1 AND state = 'approved'",
            [],
        )?;
        self.secrets.delete(&reference)?;
        transaction.commit()?;
        Ok(())
    }

    fn outbox_receipt(&self, message_id: &str) -> Result<MessageReceipt> {
        Ok(self.connection.query_row(
            "SELECT message_id, state, queued_at_unix_millis,
                    host_received_at_unix_millis, host_position
               FROM outbox WHERE message_id = ?1",
            [message_id],
            |row| {
                Ok(MessageReceipt {
                    message_id: row.get(0)?,
                    state: row.get(1)?,
                    queued_at_unix_millis: row.get(2)?,
                    host_received_at_unix_millis: row.get(3)?,
                    position: row
                        .get::<_, Option<i64>>(4)?
                        .and_then(|value| value.try_into().ok()),
                    duplicate: false,
                })
            },
        )?)
    }

    fn last_sync_position(&self) -> Result<u64> {
        let value = self.connection.query_row(
            "SELECT last_sync_position FROM client_state WHERE singleton = 1",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        value
            .try_into()
            .map_err(|_| LinkError::Conflict("invalid_cursor"))
    }

    fn record_sync(&mut self, messages: &[LinkMessage], next_position: u64) -> Result<()> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        for message in messages {
            if message.sender != "host" {
                return Err(LinkError::Conflict("invalid_sender"));
            }
            validate_identifier(&message.message_id, "invalid_message_id")?;
            validate_text(&message.text)?;
            transaction.execute(
                "INSERT INTO inbox(
                     position, message_id, sender, text,
                     queued_at_unix_millis, host_received_at_unix_millis
                 ) VALUES (?1, ?2, 'host', ?3, ?4, ?5)
                 ON CONFLICT(position) DO NOTHING",
                params![
                    i64::try_from(message.position)
                        .map_err(|_| LinkError::Invalid("invalid_position"))?,
                    message.message_id,
                    message.text,
                    message.queued_at_unix_millis,
                    message.host_received_at_unix_millis
                ],
            )?;
        }
        transaction.execute(
            "UPDATE client_state SET last_sync_position = ?1 WHERE singleton = 1",
            [i64::try_from(next_position).map_err(|_| LinkError::Invalid("invalid_cursor"))?],
        )?;
        transaction.commit()?;
        Ok(())
    }
}
