//! Durable, provider-free local journal and replay implementation.
//!
//! The journal accepts only bounded v1 protobuf envelopes. It stores the
//! received bytes plus their wire digest, never a reconstructed protobuf as an
//! integrity substitute. Projections are rebuildable and snapshots are
//! disposable accelerators rather than an authority for new facts.

use crate::{MAXIMUM_ENVELOPE_BYTES, SCHEMA_MAJOR, v1};
use prost::Message;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, backup::Backup, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    path::Path,
    time::Duration,
};

const MAXIMUM_REPLAY_PAGE: u32 = 500;
const PROJECTION_SCHEMA_VERSION: u32 = 1;

#[derive(Debug)]
pub enum JournalError {
    Database(rusqlite::Error),
    Protocol(&'static str),
    ProtocolDetail(String),
    ReadOnly,
    Integrity(String),
    Snapshot(String),
}

impl fmt::Display for JournalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => write!(formatter, "database: {error}"),
            Self::Protocol(code) => formatter.write_str(code),
            Self::ProtocolDetail(code) => formatter.write_str(code),
            Self::ReadOnly => formatter.write_str("safe_read_only"),
            Self::Integrity(code) => write!(formatter, "integrity: {code}"),
            Self::Snapshot(code) => write!(formatter, "snapshot: {code}"),
        }
    }
}

impl std::error::Error for JournalError {}

impl From<rusqlite::Error> for JournalError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Database(value)
    }
}

pub type Result<T> = std::result::Result<T, JournalError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppendResult {
    pub store_position: u64,
    pub stream_sequence: u64,
    pub duplicate: bool,
    pub event: v1::EventEnvelope,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplayBasis {
    Events,
    ResyncRequired,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayPage {
    pub basis: ReplayBasis,
    pub snapshot: Option<Snapshot>,
    pub events: Vec<v1::EventEnvelope>,
    pub next_cursor: v1::ReplayCursor,
    pub high_water_mark: u64,
    pub has_more: bool,
    pub gap_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub id: String,
    pub selector_id: String,
    pub high_water_mark: u64,
    pub checksum: Vec<u8>,
    pub state: Vec<u8>,
    pub projection_schema_version: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThreadProjection {
    pub stream_id: String,
    pub task_state: String,
    pub attention: String,
    pub pending_approval_ids: BTreeSet<String>,
    pub latest_sequence: u64,
    pub unsupported_event_count: u64,
}

/// A selected project's Thread and Inbox views are intentionally derived from
/// the same per-thread projections.  There is no separately mutable Inbox
/// authority to drift after a restart.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectProjection {
    pub project_id: String,
    pub threads: BTreeMap<String, ThreadProjection>,
    pub attention_thread_ids: BTreeMap<String, Vec<String>>,
    pub latest_store_position: u64,
}

impl ThreadProjection {
    fn empty(stream_id: String) -> Self {
        Self {
            stream_id,
            task_state: "not_started".into(),
            attention: "none".into(),
            pending_approval_ids: BTreeSet::new(),
            latest_sequence: 0,
            unsupported_event_count: 0,
        }
    }

    fn apply(&mut self, event: &v1::EventEnvelope) -> Result<()> {
        if event.stream_id != self.stream_id {
            return Err(JournalError::Integrity("projection_stream_mismatch".into()));
        }
        if event.stream_sequence <= self.latest_sequence {
            return Err(JournalError::Integrity(
                "projection_sequence_not_increasing".into(),
            ));
        }

        match event.kind.as_str() {
            "task.queued" => self.task_state = "queued".into(),
            "run.starting" => self.task_state = "starting".into(),
            "run.started" => self.task_state = "running".into(),
            "approval.requested" => {
                self.pending_approval_ids.insert(approval_identity(event));
                self.task_state = "waiting_for_user".into();
            }
            "approval.approved" | "approval.rejected" | "approval.expired" => {
                self.pending_approval_ids.remove(&approval_identity(event));
                self.task_state = if self.pending_approval_ids.is_empty() {
                    "running".into()
                } else {
                    "waiting_for_user".into()
                };
            }
            "approval.stale" => self.task_state = "waiting_for_user".into(),
            "run.provider_completed"
                if matches!(
                    self.task_state.as_str(),
                    "accepted" | "cancelled" | "failed" | "interrupted"
                ) =>
            {
                self.unsupported_event_count += 1
            }
            "run.provider_completed" => self.task_state = "completed".into(),
            "review.accepted" => self.task_state = "accepted".into(),
            "review.rejected" => self.task_state = "completed".into(),
            "run.failed" => self.task_state = "failed".into(),
            "run.cancelled" => self.task_state = "cancelled".into(),
            "run.interrupted" => self.task_state = "interrupted".into(),
            "provider.native_event_observed" => self.unsupported_event_count += 1,
            "command.admitted"
            | "queue.enqueued"
            | "queue.edited"
            | "queue.removed"
            | "queue.revision_conflict"
            | "notification.receipt_recorded"
            | "policy.denied"
            | "run.reconciliation_required" => {}
            _ => return Err(JournalError::Protocol("unknown_event_kind")),
        }
        self.latest_sequence = event.stream_sequence;
        self.attention = match self.task_state.as_str() {
            "queued" => "queued",
            "starting" | "running" => "running",
            "waiting_for_user" => "needs_response",
            "completed" => "needs_review",
            "failed" => "failed",
            "interrupted" => "interrupted",
            _ => "none",
        }
        .into();
        Ok(())
    }
}

/// SQLite-backed authority. The cursor key is supplied by the qualified host;
/// it is deliberately not persisted in SQLite or a fixture.
pub struct Journal {
    connection: Connection,
    cursor_key: Vec<u8>,
    read_only: bool,
}

impl Journal {
    pub fn open(path: impl AsRef<Path>, cursor_key: &[u8]) -> Result<Self> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection, cursor_key, false)
    }

    pub fn open_in_memory(cursor_key: &[u8]) -> Result<Self> {
        Self::from_connection(Connection::open_in_memory()?, cursor_key, false)
    }

    pub fn open_read_only(path: impl AsRef<Path>, cursor_key: &[u8]) -> Result<Self> {
        let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        Self::from_connection(connection, cursor_key, true)
    }

    fn from_connection(
        mut connection: Connection,
        cursor_key: &[u8],
        read_only: bool,
    ) -> Result<Self> {
        if cursor_key.len() < 16 {
            return Err(JournalError::Protocol("cursor_key_too_short"));
        }
        if !read_only {
            connection.pragma_update(None, "journal_mode", "WAL")?;
            connection.pragma_update(None, "foreign_keys", "ON")?;
            connection.pragma_update(None, "synchronous", "NORMAL")?;
            migrate(&mut connection)?;
        }
        Ok(Self {
            connection,
            cursor_key: cursor_key.to_vec(),
            read_only,
        })
    }

    pub fn admit_command(&mut self, command: &v1::CommandEnvelope) -> Result<v1::CommandOutcome> {
        self.require_writable()?;
        validate_command(command)?;
        let wire = command.encode_to_vec();
        let command_digest = digest(&wire);
        let transaction = self.connection.transaction()?;

        if let Some((existing_id, existing_digest, outcome)) = transaction
            .query_row(
                "SELECT command_id, wire_digest, outcome FROM commands WHERE idempotency_key = ?1",
                [&command.idempotency_key],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Vec<u8>>(1)?,
                        row.get::<_, Vec<u8>>(2)?,
                    ))
                },
            )
            .optional()?
        {
            if existing_id == command.command_id && existing_digest == command_digest {
                return decode_outcome(&outcome);
            }
            return Err(JournalError::Integrity("idempotency_key_reused".into()));
        }

        if let Some(existing_digest) = transaction
            .query_row(
                "SELECT wire_digest FROM commands WHERE command_id = ?1",
                [&command.command_id],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()?
        {
            if existing_digest == command_digest {
                let outcome = transaction.query_row(
                    "SELECT outcome FROM commands WHERE command_id = ?1",
                    [&command.command_id],
                    |row| row.get::<_, Vec<u8>>(0),
                )?;
                return decode_outcome(&outcome);
            }
            return Err(JournalError::Integrity("command_id_reused".into()));
        }

        let outcome = v1::CommandOutcome {
            command_id: command.command_id.clone(),
            disposition: v1::CommandDisposition::Accepted as i32,
            reason_code: "accepted".into(),
            store_position: next_store_position(&transaction)?,
            receipt_id: format!("receipt:{}", command.command_id),
        };
        let outcome_wire = outcome.encode_to_vec();
        transaction.execute(
            "INSERT INTO commands (command_id, idempotency_key, wire, wire_digest, outcome, outcome_digest, admitted_position) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![command.command_id, command.idempotency_key, wire, command_digest, outcome_wire, digest(&outcome.encode_to_vec()), sql_u64(outcome.store_position)?],
        )?;
        transaction.commit()?;
        Ok(outcome)
    }

    /// Appends a new local event. The authority assigns global and per-stream
    /// ordering before persisting the exact encoded envelope bytes.
    pub fn append_event(&mut self, mut event: v1::EventEnvelope) -> Result<AppendResult> {
        self.require_writable()?;
        validate_event_shape(&event)?;
        let transaction = self.connection.transaction()?;
        if let Some((wire, store_position, stream_sequence)) = transaction
            .query_row(
                "SELECT wire, store_position, stream_sequence FROM events WHERE event_id = ?1",
                [&event.event_id],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?
        {
            let store_position = db_u64(store_position)?;
            let stream_sequence = db_u64(stream_sequence)?;
            let existing = v1::EventEnvelope::decode(wire.as_slice())
                .map_err(|_| JournalError::Integrity("stored_event_malformed".into()))?;
            if equivalent_unpositioned_event(&existing, &event) {
                return Ok(AppendResult {
                    store_position,
                    stream_sequence,
                    duplicate: true,
                    event: existing,
                });
            }
            return Err(JournalError::Integrity("event_id_reused".into()));
        }

        let expected_sequence = next_stream_sequence(&transaction, &event.stream_id)?;
        if event.stream_sequence != 0 && event.stream_sequence != expected_sequence {
            return Err(JournalError::Integrity("stream_sequence_mismatch".into()));
        }
        event.stream_sequence = expected_sequence;
        let expected_position = next_store_position(&transaction)?;
        if event.store_position != 0 && event.store_position != expected_position {
            return Err(JournalError::Integrity("store_position_mismatch".into()));
        }
        event.store_position = expected_position;
        let wire = event.encode_to_vec();
        insert_event(&transaction, &event, &wire)?;
        transaction.commit()?;
        Ok(AppendResult {
            store_position: expected_position,
            stream_sequence: expected_sequence,
            duplicate: false,
            event,
        })
    }

    /// Persists a protocol envelope received at the host boundary verbatim.
    pub fn append_received_wire(&mut self, wire: &[u8]) -> Result<AppendResult> {
        self.require_writable()?;
        if wire.len() > MAXIMUM_ENVELOPE_BYTES {
            return Err(JournalError::Protocol("envelope_too_large"));
        }
        let event = v1::EventEnvelope::decode(wire)
            .map_err(|_| JournalError::Protocol("malformed_event_envelope"))?;
        validate_event_shape(&event)?;
        if event.store_position == 0 || event.stream_sequence == 0 {
            return Err(JournalError::Protocol("received_event_missing_order"));
        }
        let transaction = self.connection.transaction()?;
        if let Some((stored_wire, store_position, stream_sequence)) = transaction
            .query_row(
                "SELECT wire, store_position, stream_sequence FROM events WHERE event_id = ?1",
                [&event.event_id],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?
        {
            let store_position = db_u64(store_position)?;
            let stream_sequence = db_u64(stream_sequence)?;
            if stored_wire == wire {
                return Ok(AppendResult {
                    store_position,
                    stream_sequence,
                    duplicate: true,
                    event,
                });
            }
            return Err(JournalError::Integrity("event_id_reused".into()));
        }
        if event.stream_sequence != next_stream_sequence(&transaction, &event.stream_id)?
            || event.store_position != next_store_position(&transaction)?
        {
            return Err(JournalError::Integrity(
                "received_event_order_mismatch".into(),
            ));
        }
        insert_event(&transaction, &event, wire)?;
        transaction.commit()?;
        Ok(AppendResult {
            store_position: event.store_position,
            stream_sequence: event.stream_sequence,
            duplicate: false,
            event,
        })
    }

    /// Deterministic fault-injection seam for recovery tests. The error is
    /// returned before commit, so SQLite drops the transaction exactly as a
    /// process crash would at this storage boundary.
    pub fn inject_crash_before_event_commit_for_test(
        &mut self,
        mut event: v1::EventEnvelope,
    ) -> Result<()> {
        self.require_writable()?;
        validate_event_shape(&event)?;
        let transaction = self.connection.transaction()?;
        event.stream_sequence = next_stream_sequence(&transaction, &event.stream_id)?;
        event.store_position = next_store_position(&transaction)?;
        let wire = event.encode_to_vec();
        insert_event(&transaction, &event, &wire)?;
        Err(JournalError::Protocol("injected_crash_before_event_commit"))
    }

    pub fn replay(
        &self,
        selector_id: &str,
        cursor: Option<&v1::ReplayCursor>,
        page_size: u32,
    ) -> Result<ReplayPage> {
        let stream_id = selector_stream(selector_id)?;
        let high_water_mark = max_position_for_stream(&self.connection, stream_id)?;
        let retention_horizon = retention_horizon(&self.connection, selector_id)?;
        let after = match cursor {
            Some(cursor) => {
                validate_cursor(cursor, selector_id, &self.cursor_key)?;
                cursor.after_store_position
            }
            None => 0,
        };

        if after < retention_horizon {
            let snapshot = self.load_latest_snapshot(selector_id).ok();
            return Ok(ReplayPage {
                basis: ReplayBasis::ResyncRequired,
                snapshot,
                events: Vec::new(),
                next_cursor: self.make_cursor(
                    selector_id,
                    retention_horizon,
                    high_water_mark,
                    retention_horizon,
                ),
                high_water_mark,
                has_more: false,
                gap_reason: Some("retention_gap".into()),
            });
        }

        let bounded_page_size = page_size.clamp(1, MAXIMUM_REPLAY_PAGE) as usize;
        let mut statement = self.connection.prepare(
            "SELECT wire FROM events WHERE stream_id = ?1 AND store_position > ?2 ORDER BY store_position ASC LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![stream_id, sql_u64(after)?, (bounded_page_size + 1) as i64],
            |row| row.get::<_, Vec<u8>>(0),
        )?;
        let mut events = Vec::new();
        for row in rows {
            let wire = row?;
            events.push(
                v1::EventEnvelope::decode(wire.as_slice())
                    .map_err(|_| JournalError::Integrity("stored_event_malformed".into()))?,
            );
        }
        let has_more = events.len() > bounded_page_size;
        if has_more {
            events.pop();
        }
        let cursor_position = events.last().map_or(after, |event| event.store_position);
        Ok(ReplayPage {
            basis: ReplayBasis::Events,
            snapshot: None,
            events,
            next_cursor: self.make_cursor(
                selector_id,
                cursor_position,
                high_water_mark,
                retention_horizon,
            ),
            high_water_mark,
            has_more,
            gap_reason: None,
        })
    }

    pub fn rebuild_thread_projection(&self, selector_id: &str) -> Result<ThreadProjection> {
        let stream_id = selector_stream(selector_id)?.to_owned();
        let mut projection = ThreadProjection::empty(stream_id.clone());
        let mut statement = self
            .connection
            .prepare("SELECT wire FROM events WHERE stream_id = ?1 ORDER BY store_position ASC")?;
        let events = statement.query_map([stream_id], |row| row.get::<_, Vec<u8>>(0))?;
        for wire in events {
            let event = v1::EventEnvelope::decode(wire?.as_slice())
                .map_err(|_| JournalError::Integrity("stored_event_malformed".into()))?;
            projection.apply(&event)?;
        }
        Ok(projection)
    }

    /// Rebuilds a selected project's canonical thread state and its Inbox
    /// grouping in one pass over the journal. Project streams have the
    /// explicit `thread:project:<project-id>:` prefix; arbitrary SQL selectors
    /// are never accepted from a client.
    pub fn rebuild_project_projection(&self, selector_id: &str) -> Result<ProjectProjection> {
        let project_id = selector_project(selector_id)?.to_owned();
        let stream_prefix = format!("thread:project:{project_id}:");
        let mut projection = ProjectProjection {
            project_id,
            threads: BTreeMap::new(),
            attention_thread_ids: BTreeMap::new(),
            latest_store_position: 0,
        };
        let mut statement = self.connection.prepare(
            "SELECT wire FROM events WHERE stream_id LIKE ?1 ORDER BY store_position ASC",
        )?;
        let events = statement.query_map([format!("{stream_prefix}%")], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        for wire in events {
            let event = v1::EventEnvelope::decode(wire?.as_slice())
                .map_err(|_| JournalError::Integrity("stored_event_malformed".into()))?;
            let thread = projection
                .threads
                .entry(event.stream_id.clone())
                .or_insert_with(|| ThreadProjection::empty(event.stream_id.clone()));
            thread.apply(&event)?;
            projection.latest_store_position = event.store_position;
        }
        for (thread_id, thread) in &projection.threads {
            if thread.attention != "none" {
                projection
                    .attention_thread_ids
                    .entry(thread.attention.clone())
                    .or_default()
                    .push(thread_id.clone());
            }
        }
        Ok(projection)
    }

    pub fn create_snapshot(&mut self, selector_id: &str) -> Result<Snapshot> {
        self.require_writable()?;
        let projection = self.rebuild_thread_projection(selector_id)?;
        let state = serde_json::to_vec(&projection)
            .map_err(|_| JournalError::Snapshot("encode_failed".into()))?;
        let high_water_mark =
            max_position_for_stream(&self.connection, selector_stream(selector_id)?)?;
        let snapshot = Snapshot {
            id: format!(
                "snapshot:{}:{}",
                hex_digest(selector_id.as_bytes()),
                high_water_mark
            ),
            selector_id: selector_id.to_owned(),
            high_water_mark,
            checksum: digest(&state),
            state,
            projection_schema_version: PROJECTION_SCHEMA_VERSION,
        };
        self.connection.execute(
            "INSERT OR REPLACE INTO snapshots (snapshot_id, selector_id, high_water_mark, checksum, projection_schema_version, state) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![snapshot.id, snapshot.selector_id, sql_u64(snapshot.high_water_mark)?, snapshot.checksum, snapshot.projection_schema_version as i64, snapshot.state],
        )?;
        Ok(snapshot)
    }

    pub fn load_latest_snapshot(&self, selector_id: &str) -> Result<Snapshot> {
        let snapshot = self.connection.query_row(
            "SELECT snapshot_id, selector_id, high_water_mark, checksum, projection_schema_version, state FROM snapshots WHERE selector_id = ?1 ORDER BY high_water_mark DESC LIMIT 1",
            [selector_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?, row.get::<_, Vec<u8>>(3)?, row.get::<_, i64>(4)?, row.get::<_, Vec<u8>>(5)?)),
        ).optional()?.ok_or_else(|| JournalError::Snapshot("not_found".into()))?;
        let snapshot = Snapshot {
            id: snapshot.0,
            selector_id: snapshot.1,
            high_water_mark: db_u64(snapshot.2)?,
            checksum: snapshot.3,
            projection_schema_version: u32::try_from(snapshot.4)
                .map_err(|_| JournalError::Snapshot("invalid_schema_version".into()))?,
            state: snapshot.5,
        };
        if snapshot.projection_schema_version != PROJECTION_SCHEMA_VERSION {
            return Err(JournalError::Snapshot("schema_incompatible".into()));
        }
        if digest(&snapshot.state) != snapshot.checksum {
            return Err(JournalError::Snapshot("checksum_mismatch".into()));
        }
        let projection: ThreadProjection = serde_json::from_slice(&snapshot.state)
            .map_err(|_| JournalError::Snapshot("decode_failed".into()))?;
        if projection.stream_id != selector_stream(selector_id)? {
            return Err(JournalError::Snapshot("selector_mismatch".into()));
        }
        Ok(snapshot)
    }

    pub fn set_retention_horizon(&mut self, selector_id: &str, store_position: u64) -> Result<()> {
        self.require_writable()?;
        selector_stream(selector_id)?;
        self.connection.execute(
            "INSERT INTO retention_horizons (selector_id, store_position) VALUES (?1, ?2) ON CONFLICT(selector_id) DO UPDATE SET store_position = excluded.store_position",
            params![selector_id, sql_u64(store_position)?],
        )?;
        Ok(())
    }

    /// Test/recovery hook: corrupts a snapshot only after the test has created
    /// it. Normal production code never calls this method.
    pub fn corrupt_snapshot_for_test(&mut self, snapshot_id: &str) -> Result<()> {
        self.require_writable()?;
        self.connection.execute(
            "UPDATE snapshots SET state = X'00' WHERE snapshot_id = ?1",
            [snapshot_id],
        )?;
        Ok(())
    }

    pub fn backup_to(&self, destination: impl AsRef<Path>) -> Result<()> {
        let mut target = Connection::open(destination)?;
        let backup = Backup::new(&self.connection, &mut target)?;
        backup.run_to_completion(64, Duration::from_millis(1), None)?;
        Ok(())
    }

    pub fn integrity_check(&self) -> Result<()> {
        let result: String = self
            .connection
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
        if result == "ok" {
            Ok(())
        } else {
            Err(JournalError::Integrity(result))
        }
    }

    /// Fixture reports are a bounded, checksummed replay cache for the Phase 1
    /// fake adapter. The event journal remains the source of state; this cache
    /// prevents a service reconnect from re-executing a completed deterministic
    /// scenario merely to recreate its UI summary.
    pub fn load_fixture_report(&self, fixture_id: &str) -> Result<Option<Vec<u8>>> {
        let Some((report, checksum)) = self
            .connection
            .query_row(
                "SELECT report, checksum FROM fixture_reports WHERE fixture_id = ?1",
                [fixture_id],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?)),
            )
            .optional()?
        else {
            return Ok(None);
        };
        if report.len() > MAXIMUM_ENVELOPE_BYTES || digest(&report) != checksum {
            return Err(JournalError::Integrity("fixture_report_corrupt".into()));
        }
        Ok(Some(report))
    }

    pub fn save_fixture_report(&mut self, fixture_id: &str, report: &[u8]) -> Result<()> {
        self.require_writable()?;
        if !is_fixture_id(fixture_id) || report.is_empty() || report.len() > MAXIMUM_ENVELOPE_BYTES
        {
            return Err(JournalError::Protocol("invalid_fixture_report"));
        }
        self.connection.execute(
            "INSERT INTO fixture_reports (fixture_id, report, checksum) VALUES (?1, ?2, ?3) ON CONFLICT(fixture_id) DO UPDATE SET report = excluded.report, checksum = excluded.checksum",
            params![fixture_id, report, digest(report)],
        )?;
        Ok(())
    }

    fn make_cursor(
        &self,
        selector_id: &str,
        after: u64,
        high_water_mark: u64,
        retention_horizon: u64,
    ) -> v1::ReplayCursor {
        let mut cursor = v1::ReplayCursor {
            selector_id: selector_id.to_owned(),
            after_store_position: after,
            high_water_mark,
            retention_horizon,
            integrity_tag: Vec::new(),
        };
        cursor.integrity_tag = cursor_tag(&cursor, &self.cursor_key);
        cursor
    }

    fn require_writable(&self) -> Result<()> {
        if self.read_only {
            Err(JournalError::ReadOnly)
        } else {
            Ok(())
        }
    }
}

fn migrate(connection: &mut Connection) -> Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY);
         CREATE TABLE IF NOT EXISTS commands (
           command_id TEXT PRIMARY KEY,
           idempotency_key TEXT NOT NULL UNIQUE,
           wire BLOB NOT NULL,
           wire_digest BLOB NOT NULL,
           outcome BLOB NOT NULL,
           outcome_digest BLOB NOT NULL,
           admitted_position INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS events (
           event_id TEXT PRIMARY KEY,
           store_position INTEGER NOT NULL UNIQUE,
           stream_id TEXT NOT NULL,
           stream_sequence INTEGER NOT NULL,
           occurred_at_unix_millis INTEGER NOT NULL,
           kind TEXT NOT NULL,
           wire BLOB NOT NULL,
           wire_digest BLOB NOT NULL,
           raw_evidence_digest TEXT,
           UNIQUE(stream_id, stream_sequence)
         );
         CREATE INDEX IF NOT EXISTS events_stream_position ON events(stream_id, store_position);
         CREATE TABLE IF NOT EXISTS snapshots (
           snapshot_id TEXT PRIMARY KEY,
           selector_id TEXT NOT NULL,
           high_water_mark INTEGER NOT NULL,
           checksum BLOB NOT NULL,
           projection_schema_version INTEGER NOT NULL,
           state BLOB NOT NULL
         );
         CREATE INDEX IF NOT EXISTS snapshots_selector_high_water ON snapshots(selector_id, high_water_mark DESC);
         CREATE TABLE IF NOT EXISTS retention_horizons (
           selector_id TEXT PRIMARY KEY,
           store_position INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS fixture_reports (
           fixture_id TEXT PRIMARY KEY,
           report BLOB NOT NULL,
           checksum BLOB NOT NULL
         );
         INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
         INSERT OR IGNORE INTO schema_migrations(version) VALUES (2);",
    )?;
    Ok(())
}

fn validate_command(command: &v1::CommandEnvelope) -> Result<()> {
    if command.encode_to_vec().len() > MAXIMUM_ENVELOPE_BYTES {
        return Err(JournalError::Protocol("envelope_too_large"));
    }
    if command.schema_version.as_ref().map(|version| version.major) != Some(SCHEMA_MAJOR) {
        return Err(JournalError::Protocol("unsupported_schema_major"));
    }
    if command.command_id.is_empty()
        || command.idempotency_key.is_empty()
        || command.kind.is_empty()
    {
        return Err(JournalError::Protocol("invalid_command_identity"));
    }
    if command.kind.len() > 128 || command.actor_id.len() > 256 {
        return Err(JournalError::Protocol("command_field_too_large"));
    }
    Ok(())
}

fn validate_event_shape(event: &v1::EventEnvelope) -> Result<()> {
    if event.encode_to_vec().len() > MAXIMUM_ENVELOPE_BYTES {
        return Err(JournalError::Protocol("envelope_too_large"));
    }
    if event.schema_version.as_ref().map(|version| version.major) != Some(SCHEMA_MAJOR) {
        return Err(JournalError::Protocol("unsupported_schema_major"));
    }
    if event.event_id.is_empty() || event.stream_id.is_empty() || event.kind.is_empty() {
        return Err(JournalError::Protocol("invalid_event_identity"));
    }
    if event.kind.len() > 128 || event.stream_id.len() > 256 {
        return Err(JournalError::Protocol("event_field_too_large"));
    }
    Ok(())
}

fn insert_event(
    transaction: &Transaction<'_>,
    event: &v1::EventEnvelope,
    wire: &[u8],
) -> Result<()> {
    transaction.execute(
        "INSERT INTO events (event_id, store_position, stream_id, stream_sequence, occurred_at_unix_millis, kind, wire, wire_digest, raw_evidence_digest) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![event.event_id, sql_u64(event.store_position)?, event.stream_id, sql_u64(event.stream_sequence)?, event.occurred_at_unix_millis, event.kind, wire, digest(wire), event.provenance.as_ref().map(|provenance| provenance.raw_evidence_digest.clone()).filter(|digest| !digest.is_empty())],
    )?;
    Ok(())
}

fn next_store_position(transaction: &Transaction<'_>) -> Result<u64> {
    db_u64(transaction.query_row(
        "SELECT COALESCE(MAX(store_position), 0) + 1 FROM events",
        [],
        |row| row.get::<_, i64>(0),
    )?)
}

fn next_stream_sequence(transaction: &Transaction<'_>, stream_id: &str) -> Result<u64> {
    db_u64(transaction.query_row(
        "SELECT COALESCE(MAX(stream_sequence), 0) + 1 FROM events WHERE stream_id = ?1",
        [stream_id],
        |row| row.get::<_, i64>(0),
    )?)
}

fn max_position_for_stream(connection: &Connection, stream_id: &str) -> Result<u64> {
    db_u64(connection.query_row(
        "SELECT COALESCE(MAX(store_position), 0) FROM events WHERE stream_id = ?1",
        [stream_id],
        |row| row.get::<_, i64>(0),
    )?)
}

fn retention_horizon(connection: &Connection, selector_id: &str) -> Result<u64> {
    let horizon = connection
        .query_row(
            "SELECT store_position FROM retention_horizons WHERE selector_id = ?1",
            [selector_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0);
    db_u64(horizon)
}

fn selector_stream(selector_id: &str) -> Result<&str> {
    selector_id
        .strip_prefix("thread:")
        .filter(|stream| !stream.is_empty())
        .ok_or(JournalError::Protocol("unauthorized_selector"))
}

fn selector_project(selector_id: &str) -> Result<&str> {
    let project = selector_id
        .strip_prefix("project:")
        .filter(|project| !project.is_empty() && project.len() <= 128);
    match project {
        Some(project)
            if project
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-') =>
        {
            Ok(project)
        }
        _ => Err(JournalError::Protocol("unauthorized_selector")),
    }
}

fn is_fixture_id(value: &str) -> bool {
    value.len() == 4
        && value.starts_with("F-")
        && value.as_bytes()[2].is_ascii_digit()
        && value.as_bytes()[3].is_ascii_digit()
}

fn approval_identity(event: &v1::EventEnvelope) -> String {
    if event.causation_id.is_empty() {
        event.event_id.clone()
    } else {
        event.causation_id.clone()
    }
}

fn equivalent_unpositioned_event(
    existing: &v1::EventEnvelope,
    incoming: &v1::EventEnvelope,
) -> bool {
    existing.event_id == incoming.event_id
        && existing.stream_id == incoming.stream_id
        && existing.occurred_at_unix_millis == incoming.occurred_at_unix_millis
        && existing.kind == incoming.kind
        && existing.payload == incoming.payload
        && existing.provenance == incoming.provenance
        && existing.causation_id == incoming.causation_id
        && existing.correlation_id == incoming.correlation_id
}

fn validate_cursor(cursor: &v1::ReplayCursor, selector_id: &str, key: &[u8]) -> Result<()> {
    if cursor.selector_id != selector_id || cursor.integrity_tag != cursor_tag(cursor, key) {
        return Err(JournalError::Protocol("invalid_cursor"));
    }
    Ok(())
}

fn cursor_tag(cursor: &v1::ReplayCursor, key: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.replay.cursor.v1\0");
    hasher.update(key);
    hasher.update(cursor.selector_id.as_bytes());
    hasher.update(cursor.after_store_position.to_be_bytes());
    hasher.update(cursor.high_water_mark.to_be_bytes());
    hasher.update(cursor.retention_horizon.to_be_bytes());
    hasher.finalize().to_vec()
}

fn decode_outcome(wire: &[u8]) -> Result<v1::CommandOutcome> {
    v1::CommandOutcome::decode(wire)
        .map_err(|_| JournalError::Integrity("stored_command_outcome_malformed".into()))
}

fn digest(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

fn hex_digest(bytes: &[u8]) -> String {
    hex::encode(digest(bytes))
}

fn sql_u64(value: u64) -> Result<i64> {
    i64::try_from(value).map_err(|_| JournalError::Protocol("integer_out_of_range"))
}

fn db_u64(value: i64) -> Result<u64> {
    u64::try_from(value).map_err(|_| JournalError::Integrity("negative_database_position".into()))
}
