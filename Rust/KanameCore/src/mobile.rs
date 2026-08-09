//! Durable mobile enrollment and authenticated-envelope replay authority.
//!
//! Cryptographic opening is owned by the signed Apple host using CryptoKit.
//! Only after authenticated HPKE succeeds may that host submit the exact
//! received envelope bytes here. This module then enforces enrollment state,
//! active key generation, expiry, sender ordering, hash-chain continuity,
//! duplicate identity, revocation, and restart-safe reconciliation.

use crate::{
    MAXIMUM_ENVELOPE_BYTES, SCHEMA_MAJOR,
    journal::{Journal, JournalError, Result},
    v1,
};
use prost::Message;
use rusqlite::{OptionalExtension, params};
use sha2::{Digest, Sha256};

const MAXIMUM_SYNC_ENVELOPE_BYTES: usize = MAXIMUM_ENVELOPE_BYTES + 8 * 1024;
const MAXIMUM_HEADER_BYTES: usize = 4 * 1024;
const MAXIMUM_CLOCK_SKEW_MILLIS: i64 = 5 * 60 * 1_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    pub identity: v1::DevicePublicIdentity,
    pub state: v1::DeviceEnrollmentState,
    pub enrolled_at_unix_millis: i64,
    pub revoked_at_unix_millis: Option<i64>,
    pub last_sender_sequence: u64,
    pub last_envelope_digest: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnrollmentAdmission {
    Pending,
    Duplicate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnrollmentDecisionResult {
    pub state: v1::DeviceEnrollmentState,
    pub duplicate: bool,
    pub device: Option<DeviceRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncAdmission {
    Accepted {
        sender_sequence: u64,
        envelope_digest: Vec<u8>,
    },
    Duplicate {
        sender_sequence: u64,
        envelope_digest: Vec<u8>,
    },
    ResyncRequired {
        expected_sender_sequence: u64,
    },
}

impl Journal {
    pub fn propose_mobile_device(
        &mut self,
        challenge: &v1::DeviceEnrollmentChallenge,
        now_unix_millis: i64,
    ) -> Result<EnrollmentAdmission> {
        self.require_writable()?;
        validate_enrollment_challenge(challenge, now_unix_millis)?;
        let identity = challenge
            .proposed_device
            .as_ref()
            .ok_or(JournalError::Protocol("missing_device_identity"))?;
        let challenge_wire = challenge.encode_to_vec();
        let challenge_digest = digest(&challenge_wire);
        if let Some((existing_wire, state)) = self
            .connection
            .query_row(
                "SELECT challenge_wire, state FROM device_enrollments WHERE enrollment_id = ?1",
                [&challenge.enrollment_id],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i32>(1)?)),
            )
            .optional()?
        {
            if existing_wire == challenge_wire && state == v1::DeviceEnrollmentState::Pending as i32
            {
                return Ok(EnrollmentAdmission::Duplicate);
            }
            return Err(JournalError::Integrity("enrollment_id_reused".into()));
        }
        if self.device(&identity.device_id)?.is_some() {
            return Err(JournalError::Protocol("device_already_enrolled"));
        }
        let pending_for_device = self.connection.query_row(
            "SELECT COUNT(*) FROM device_enrollments WHERE device_id = ?1 AND state = ?2",
            params![
                identity.device_id,
                v1::DeviceEnrollmentState::Pending as i32
            ],
            |row| row.get::<_, i64>(0),
        )?;
        if pending_for_device != 0 {
            return Err(JournalError::Protocol("device_enrollment_pending"));
        }
        self.connection.execute(
            "INSERT INTO device_enrollments (enrollment_id, device_id, state, challenge_wire, challenge_digest, expires_at_unix_millis) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                challenge.enrollment_id,
                identity.device_id,
                v1::DeviceEnrollmentState::Pending as i32,
                challenge_wire,
                challenge_digest,
                challenge.expires_at_unix_millis,
            ],
        )?;
        Ok(EnrollmentAdmission::Pending)
    }

    pub fn decide_mobile_device(
        &mut self,
        decision: &v1::DeviceEnrollmentDecision,
        now_unix_millis: i64,
    ) -> Result<EnrollmentDecisionResult> {
        self.require_writable()?;
        validate_enrollment_decision(decision, now_unix_millis)?;
        let decision_wire = decision.encode_to_vec();
        let decision_digest = digest(&decision_wire);
        let Some((state, challenge_wire, expires_at, existing_decision)) = self
            .connection
            .query_row(
                "SELECT state, challenge_wire, expires_at_unix_millis, decision_wire FROM device_enrollments WHERE enrollment_id = ?1",
                [&decision.enrollment_id],
                |row| {
                    Ok((
                        row.get::<_, i32>(0)?,
                        row.get::<_, Vec<u8>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<Vec<u8>>>(3)?,
                    ))
                },
            )
            .optional()?
        else {
            return Err(JournalError::Protocol("enrollment_not_found"));
        };
        if let Some(existing_decision) = existing_decision {
            if existing_decision != decision_wire || state != decision.state {
                return Err(JournalError::Integrity("enrollment_decision_reused".into()));
            }
            let resolved_state = enrollment_state(state)?;
            let challenge = decode_challenge(&challenge_wire)?;
            let device = if resolved_state == v1::DeviceEnrollmentState::Active {
                let device_id = &challenge
                    .proposed_device
                    .as_ref()
                    .ok_or_else(|| {
                        JournalError::Integrity("stored_enrollment_missing_device".into())
                    })?
                    .device_id;
                self.device(device_id)?
            } else {
                None
            };
            return Ok(EnrollmentDecisionResult {
                state: resolved_state,
                duplicate: true,
                device,
            });
        }
        if state != v1::DeviceEnrollmentState::Pending as i32 {
            return Err(JournalError::Protocol("enrollment_not_pending"));
        }
        if expires_at <= now_unix_millis || decision.decided_at_unix_millis > now_unix_millis {
            return Err(JournalError::Protocol("enrollment_expired_or_future"));
        }

        let challenge = decode_challenge(&challenge_wire)?;
        let identity = challenge
            .proposed_device
            .ok_or_else(|| JournalError::Integrity("stored_enrollment_missing_device".into()))?;
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "UPDATE device_enrollments SET state = ?2, decision_wire = ?3, decision_digest = ?4, decided_at_unix_millis = ?5 WHERE enrollment_id = ?1 AND state = ?6",
            params![
                decision.enrollment_id,
                decision.state,
                decision_wire,
                decision_digest,
                decision.decided_at_unix_millis,
                v1::DeviceEnrollmentState::Pending as i32,
            ],
        )?;
        let resolved_state = enrollment_state(decision.state)?;
        if resolved_state == v1::DeviceEnrollmentState::Active {
            let identity_wire = identity.encode_to_vec();
            transaction.execute(
                "INSERT INTO mobile_devices (device_id, key_id, key_generation, state, identity_wire, identity_digest, enrolled_at_unix_millis) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    identity.device_id,
                    identity.key_id,
                    sql_u64(identity.key_generation)?,
                    resolved_state as i32,
                    identity_wire,
                    digest(&identity.encode_to_vec()),
                    decision.decided_at_unix_millis,
                ],
            )?;
        }
        transaction.commit()?;
        let device = if resolved_state == v1::DeviceEnrollmentState::Active {
            self.device(&identity.device_id)?
        } else {
            None
        };
        Ok(EnrollmentDecisionResult {
            state: resolved_state,
            duplicate: false,
            device,
        })
    }

    pub fn device(&self, device_id: &str) -> Result<Option<DeviceRecord>> {
        let row = self
            .connection
            .query_row(
                "SELECT identity_wire, state, enrolled_at_unix_millis, revoked_at_unix_millis, last_sender_sequence, last_envelope_digest FROM mobile_devices WHERE device_id = ?1",
                [device_id],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, i32>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, Vec<u8>>(5)?,
                    ))
                },
            )
            .optional()?;
        let Some((identity_wire, state, enrolled_at, revoked_at, sequence, envelope_digest)) = row
        else {
            return Ok(None);
        };
        let identity = v1::DevicePublicIdentity::decode(identity_wire.as_slice())
            .map_err(|_| JournalError::Integrity("stored_device_identity_malformed".into()))?;
        Ok(Some(DeviceRecord {
            identity,
            state: enrollment_state(state)?,
            enrolled_at_unix_millis: enrolled_at,
            revoked_at_unix_millis: revoked_at,
            last_sender_sequence: db_u64(sequence)?,
            last_envelope_digest: envelope_digest,
        }))
    }

    pub fn rotate_mobile_device_key(
        &mut self,
        rotation: &v1::DeviceKeyRotation,
        now_unix_millis: i64,
    ) -> Result<DeviceRecord> {
        self.require_writable()?;
        let next = rotation
            .next_identity
            .as_ref()
            .ok_or(JournalError::Protocol("missing_device_identity"))?;
        validate_device_identity(next, now_unix_millis)?;
        if !valid_identifier(&rotation.device_id)
            || !valid_identifier(&rotation.previous_key_id)
            || rotation.device_id != next.device_id
            || rotation.transcript_digest.len() != 32
            || rotation.rotated_at_unix_millis <= 0
            || rotation.rotated_at_unix_millis > now_unix_millis
        {
            return Err(JournalError::Protocol("invalid_device_key_rotation"));
        }
        let current = self
            .device(&rotation.device_id)?
            .ok_or(JournalError::Protocol("device_not_found"))?;
        if current.state != v1::DeviceEnrollmentState::Active {
            return Err(JournalError::Protocol("device_not_active"));
        }
        if current.identity.key_id == next.key_id
            && current.identity.encode_to_vec() == next.encode_to_vec()
        {
            return Ok(current);
        }
        if current.identity.key_id != rotation.previous_key_id
            || next.key_generation != current.identity.key_generation + 1
            || next.created_at_unix_millis > rotation.rotated_at_unix_millis
        {
            return Err(JournalError::Protocol("device_key_rotation_conflict"));
        }
        let current_wire = current.identity.encode_to_vec();
        let next_wire = next.encode_to_vec();
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO mobile_device_key_history (device_id, key_id, key_generation, identity_wire, retired_at_unix_millis) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                current.identity.device_id,
                current.identity.key_id,
                sql_u64(current.identity.key_generation)?,
                current_wire,
                rotation.rotated_at_unix_millis,
            ],
        )?;
        transaction.execute(
            "UPDATE mobile_devices SET key_id = ?2, key_generation = ?3, identity_wire = ?4, identity_digest = ?5, last_sender_sequence = 0, last_envelope_digest = X'' WHERE device_id = ?1 AND state = ?6",
            params![
                next.device_id,
                next.key_id,
                sql_u64(next.key_generation)?,
                next_wire,
                digest(&next.encode_to_vec()),
                v1::DeviceEnrollmentState::Active as i32,
            ],
        )?;
        transaction.commit()?;
        self.device(&rotation.device_id)?
            .ok_or_else(|| JournalError::Integrity("rotated_device_missing".into()))
    }

    pub fn revoke_mobile_device(
        &mut self,
        revocation: &v1::DeviceRevocation,
        now_unix_millis: i64,
    ) -> Result<DeviceRecord> {
        self.require_writable()?;
        if !valid_identifier(&revocation.device_id)
            || !valid_identifier(&revocation.key_id)
            || revocation.reason_code.is_empty()
            || revocation.reason_code.len() > 128
            || revocation.revoked_at_unix_millis <= 0
            || revocation.revoked_at_unix_millis > now_unix_millis
        {
            return Err(JournalError::Protocol("invalid_device_revocation"));
        }
        let current = self
            .device(&revocation.device_id)?
            .ok_or(JournalError::Protocol("device_not_found"))?;
        if current.identity.key_id != revocation.key_id {
            return Err(JournalError::Protocol("device_key_mismatch"));
        }
        if current.state == v1::DeviceEnrollmentState::Revoked {
            return Ok(current);
        }
        if current.state != v1::DeviceEnrollmentState::Active {
            return Err(JournalError::Protocol("device_not_active"));
        }
        self.connection.execute(
            "UPDATE mobile_devices SET state = ?2, revoked_at_unix_millis = ?3 WHERE device_id = ?1 AND state = ?4",
            params![
                revocation.device_id,
                v1::DeviceEnrollmentState::Revoked as i32,
                revocation.revoked_at_unix_millis,
                v1::DeviceEnrollmentState::Active as i32,
            ],
        )?;
        self.device(&revocation.device_id)?
            .ok_or_else(|| JournalError::Integrity("revoked_device_missing".into()))
    }

    /// Records exact envelope bytes only after the signed Apple host has
    /// authenticated and opened HPKE and verified the plaintext digest.
    pub fn record_authenticated_mobile_sync_wire(
        &mut self,
        envelope_wire: &[u8],
        expected_recipient_device_id: &str,
        expected_recipient_key_id: &str,
        now_unix_millis: i64,
    ) -> Result<SyncAdmission> {
        self.require_writable()?;
        if envelope_wire.is_empty() || envelope_wire.len() > MAXIMUM_SYNC_ENVELOPE_BYTES {
            return Err(JournalError::Protocol("invalid_sync_envelope_size"));
        }
        let envelope = v1::EncryptedSyncEnvelope::decode(envelope_wire)
            .map_err(|_| JournalError::Protocol("malformed_sync_envelope"))?;
        if envelope.authenticated_header.is_empty()
            || envelope.authenticated_header.len() > MAXIMUM_HEADER_BYTES
            || envelope.encapsulated_key.is_empty()
            || envelope.ciphertext.is_empty()
        {
            return Err(JournalError::Protocol("invalid_sync_envelope"));
        }
        let header = v1::SyncAuthenticatedHeader::decode(envelope.authenticated_header.as_slice())
            .map_err(|_| JournalError::Protocol("malformed_sync_header"))?;
        validate_sync_header(&header, now_unix_millis)?;
        if header.recipient_device_id != expected_recipient_device_id
            || header.recipient_key_id != expected_recipient_key_id
        {
            return Err(JournalError::Protocol("sync_recipient_mismatch"));
        }
        let device = self
            .device(&header.sender_device_id)?
            .ok_or(JournalError::Protocol("sender_device_not_found"))?;
        if device.state != v1::DeviceEnrollmentState::Active {
            return Err(JournalError::Protocol("sender_device_not_active"));
        }
        if device.identity.key_id != header.sender_key_id
            || device.identity.expires_at_unix_millis <= now_unix_millis
        {
            return Err(JournalError::Protocol("sender_key_not_active"));
        }

        let envelope_digest = digest(envelope_wire);
        if let Some((stored_wire, stored_sequence, stored_digest)) = self
            .connection
            .query_row(
                "SELECT envelope_wire, sender_sequence, envelope_digest FROM mobile_sync_envelopes WHERE envelope_id = ?1",
                [&header.envelope_id],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Vec<u8>>(2)?,
                    ))
                },
            )
            .optional()?
        {
            if stored_wire == envelope_wire && stored_digest == envelope_digest {
                return Ok(SyncAdmission::Duplicate {
                    sender_sequence: db_u64(stored_sequence)?,
                    envelope_digest,
                });
            }
            return Err(JournalError::Integrity("sync_envelope_id_reused".into()));
        }

        let expected_sequence = device.last_sender_sequence + 1;
        if header.sender_sequence > expected_sequence {
            return Ok(SyncAdmission::ResyncRequired {
                expected_sender_sequence: expected_sequence,
            });
        }
        if header.sender_sequence < expected_sequence {
            return Err(JournalError::Protocol("sync_replay_detected"));
        }
        if header.sender_sequence == 1 {
            if !header.previous_envelope_digest.is_empty() {
                return Err(JournalError::Protocol("sync_chain_mismatch"));
            }
        } else if header.previous_envelope_digest != device.last_envelope_digest {
            return Err(JournalError::Protocol("sync_chain_mismatch"));
        }

        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO mobile_sync_envelopes (envelope_id, sender_device_id, sender_key_id, sender_sequence, authenticated_header_wire, envelope_wire, envelope_digest, received_at_unix_millis) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                header.envelope_id,
                header.sender_device_id,
                header.sender_key_id,
                sql_u64(header.sender_sequence)?,
                envelope.authenticated_header,
                envelope_wire,
                envelope_digest,
                now_unix_millis,
            ],
        )?;
        transaction.execute(
            "UPDATE mobile_devices SET last_sender_sequence = ?2, last_envelope_digest = ?3 WHERE device_id = ?1 AND key_id = ?4 AND state = ?5",
            params![
                header.sender_device_id,
                sql_u64(header.sender_sequence)?,
                envelope_digest,
                header.sender_key_id,
                v1::DeviceEnrollmentState::Active as i32,
            ],
        )?;
        transaction.commit()?;
        Ok(SyncAdmission::Accepted {
            sender_sequence: header.sender_sequence,
            envelope_digest,
        })
    }
}

fn validate_enrollment_challenge(
    challenge: &v1::DeviceEnrollmentChallenge,
    now_unix_millis: i64,
) -> Result<()> {
    let identity = challenge
        .proposed_device
        .as_ref()
        .ok_or(JournalError::Protocol("missing_device_identity"))?;
    validate_device_identity(identity, now_unix_millis)?;
    if challenge
        .schema_version
        .as_ref()
        .map(|version| version.major)
        != Some(SCHEMA_MAJOR)
        || !valid_identifier(&challenge.enrollment_id)
        || challenge.mac_nonce.len() != 32
        || challenge.confirmation_digest.len() != 32
        || challenge.expires_at_unix_millis <= now_unix_millis
        || challenge.expires_at_unix_millis > identity.expires_at_unix_millis
    {
        return Err(JournalError::Protocol("invalid_enrollment_challenge"));
    }
    Ok(())
}

fn validate_enrollment_decision(
    decision: &v1::DeviceEnrollmentDecision,
    now_unix_millis: i64,
) -> Result<()> {
    let state = enrollment_state(decision.state)?;
    if !matches!(
        state,
        v1::DeviceEnrollmentState::Active | v1::DeviceEnrollmentState::Rejected
    ) || !valid_identifier(&decision.enrollment_id)
        || !valid_identifier(&decision.mac_device_id)
        || decision.transcript_digest.len() != 32
        || decision.decided_at_unix_millis <= 0
        || decision.decided_at_unix_millis > now_unix_millis
    {
        return Err(JournalError::Protocol("invalid_enrollment_decision"));
    }
    Ok(())
}

fn validate_device_identity(
    identity: &v1::DevicePublicIdentity,
    now_unix_millis: i64,
) -> Result<()> {
    if !valid_identifier(&identity.device_id)
        || !valid_identifier(&identity.key_id)
        || identity.display_name.is_empty()
        || identity.display_name.len() > 128
        || !matches!(identity.platform.as_str(), "ios" | "macos")
        || identity.hpke_public_key.len() != 32
        || identity.key_generation == 0
        || identity.created_at_unix_millis <= 0
        || identity.created_at_unix_millis > now_unix_millis
        || identity.expires_at_unix_millis <= now_unix_millis
    {
        return Err(JournalError::Protocol("invalid_device_identity"));
    }
    Ok(())
}

fn validate_sync_header(header: &v1::SyncAuthenticatedHeader, now_unix_millis: i64) -> Result<()> {
    if header.schema_version.as_ref().map(|version| version.major) != Some(SCHEMA_MAJOR)
        || !valid_identifier(&header.envelope_id)
        || !valid_identifier(&header.sender_device_id)
        || !valid_identifier(&header.sender_key_id)
        || !valid_identifier(&header.recipient_device_id)
        || !valid_identifier(&header.recipient_key_id)
        || header.sender_device_id == header.recipient_device_id
        || header.sender_sequence == 0
        || header.sent_at_unix_millis <= 0
        || header.sent_at_unix_millis > now_unix_millis + MAXIMUM_CLOCK_SKEW_MILLIS
        || header.expires_at_unix_millis <= now_unix_millis
        || header.expires_at_unix_millis <= header.sent_at_unix_millis
        || header.payload_kind.is_empty()
        || header.payload_kind.len() > 128
        || header.plaintext_digest.len() != 32
        || header.content_type != "application/x-protobuf"
    {
        return Err(JournalError::Protocol("invalid_sync_header"));
    }
    Ok(())
}

fn decode_challenge(wire: &[u8]) -> Result<v1::DeviceEnrollmentChallenge> {
    v1::DeviceEnrollmentChallenge::decode(wire)
        .map_err(|_| JournalError::Integrity("stored_enrollment_malformed".into()))
}

fn enrollment_state(value: i32) -> Result<v1::DeviceEnrollmentState> {
    v1::DeviceEnrollmentState::try_from(value)
        .map_err(|_| JournalError::Integrity("invalid_device_state".into()))
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b':'))
}

fn digest(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

fn sql_u64(value: u64) -> Result<i64> {
    i64::try_from(value).map_err(|_| JournalError::Protocol("integer_out_of_range"))
}

fn db_u64(value: i64) -> Result<u64> {
    u64::try_from(value).map_err(|_| JournalError::Integrity("negative_database_position".into()))
}
