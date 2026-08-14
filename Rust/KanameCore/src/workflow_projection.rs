//! Disposable SQLite projection for durable workflow-run history.
//!
//! The journal remains authoritative. This database can be discarded and
//! rebuilt from global journal order without executing a node or dereferencing
//! a value. It stores only immutable revision identity, lifecycle/timing state,
//! and bounded value references already admitted by the runtime contract.

use crate::{
    journal::{Journal, JournalError},
    v1,
    workflow_library::{PrivatePathKind, prepare_database_path, protect_private_path},
    workflow_runtime::{self, WorkflowRuntimeEvent},
};
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    fmt, fs,
    path::{Path, PathBuf},
    time::Duration,
};

const PROJECTION_SCHEMA_VERSION: i64 = 4;
const DEFAULT_BATCH_SIZE: u32 = 250;

const INITIAL_SCHEMA: &str = r#"
CREATE TABLE workflow_projection_meta (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    high_water_mark INTEGER NOT NULL CHECK (high_water_mark >= 0),
    state_digest TEXT NOT NULL CHECK (length(state_digest) = 64)
) STRICT;

CREATE TABLE workflow_values (
    value_id TEXT PRIMARY KEY CHECK (length(value_id) BETWEEN 1 AND 128),
    content_type TEXT NOT NULL CHECK (length(content_type) BETWEEN 1 AND 128),
    byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
    sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
    inline_canonical_json BLOB,
    storage_reference_id TEXT,
    storage_handle_id TEXT,
    storage_scope TEXT,
    storage_logical_key TEXT,
    storage_version_id TEXT,
    storage_revision INTEGER,
    storage_previous_version_id TEXT,
    storage_source_version_id TEXT,
    storage_result TEXT,
    CHECK ((inline_canonical_json IS NULL) <> (storage_reference_id IS NULL))
) STRICT;

CREATE TABLE workflow_runs (
    run_id TEXT PRIMARY KEY,
    run_token_id TEXT NOT NULL UNIQUE,
    request_command_id TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    status TEXT NOT NULL CHECK (status IN ('running', 'cancelling', 'succeeded', 'failed', 'cancelled')),
    outcome TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    final_emission_ids_json TEXT NOT NULL DEFAULT '[]',
    cancellation_command_id TEXT,
    cancellation_reason_code TEXT,
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    first_store_position INTEGER NOT NULL CHECK (first_store_position > 0),
    last_store_position INTEGER NOT NULL CHECK (last_store_position >= first_store_position)
) STRICT;

CREATE INDEX workflow_runs_revision_time
    ON workflow_runs(workflow_id, revision_id, created_at_unix_millis DESC, run_id);

CREATE TABLE workflow_attempts (
    attempt_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    outcome TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    emission_ids_json TEXT NOT NULL DEFAULT '[]',
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL CHECK (started_store_position > 0),
    settled_store_position INTEGER,
    UNIQUE(run_id, execution_token_id, node_id, attempt_number)
) STRICT;

CREATE INDEX workflow_attempts_run_node
    ON workflow_attempts(run_id, node_id, attempt_number, attempt_id);

CREATE TABLE workflow_node_states (
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    latest_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    latest_attempt_number INTEGER NOT NULL CHECK (latest_attempt_number > 0),
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    last_store_position INTEGER NOT NULL CHECK (last_store_position > 0),
    PRIMARY KEY(run_id, node_id)
) STRICT;

CREATE TABLE workflow_emissions (
    emission_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    port_id TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    event_id TEXT NOT NULL UNIQUE,
    emitted_at_unix_millis INTEGER NOT NULL CHECK (emitted_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;

CREATE INDEX workflow_emissions_attempt
    ON workflow_emissions(run_id, attempt_id, store_position);

CREATE TABLE workflow_edge_checkpoints (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    edge_id TEXT NOT NULL,
    emission_id TEXT NOT NULL REFERENCES workflow_emissions(emission_id) ON DELETE CASCADE,
    target_node_id TEXT NOT NULL,
    target_port_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('admitted', 'skipped')),
    checkpointed_at_unix_millis INTEGER NOT NULL CHECK (checkpointed_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, edge_id, emission_id, target_node_id, target_port_id)
) STRICT;

CREATE INDEX workflow_edge_checkpoints_run_edge
    ON workflow_edge_checkpoints(run_id, edge_id, store_position);

CREATE TABLE workflow_match_traces (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    input_value_id TEXT NOT NULL,
    evaluated_case_ids_json TEXT NOT NULL,
    matched_case_ids_json TEXT NOT NULL,
    emitted_port_ids_json TEXT NOT NULL,
    trace_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    recorded_at_unix_millis INTEGER NOT NULL CHECK (recorded_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;

CREATE INDEX workflow_match_traces_attempt
    ON workflow_match_traces(run_id, attempt_id, store_position);

CREATE TABLE workflow_execution_tokens (
    execution_token_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    parent_execution_token_id TEXT,
    fork_node_id TEXT,
    branch_id TEXT,
    branch_port_id TEXT,
    join_node_id TEXT,
    source_emission_id TEXT,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed', 'cancelled', 'forked', 'joined')),
    outcome TEXT,
    terminal_node_id TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    final_emission_ids_json TEXT NOT NULL DEFAULT '[]',
    created_event_id TEXT NOT NULL UNIQUE,
    settled_event_id TEXT UNIQUE,
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    created_store_position INTEGER NOT NULL UNIQUE CHECK (created_store_position > 0),
    settled_store_position INTEGER UNIQUE,
    UNIQUE(run_id, fork_node_id, branch_id)
) STRICT;

CREATE INDEX workflow_execution_tokens_run_position
    ON workflow_execution_tokens(run_id, created_store_position, execution_token_id);

CREATE TABLE workflow_join_evaluations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    join_node_id TEXT NOT NULL,
    fork_node_id TEXT NOT NULL,
    resumed_execution_token_id TEXT NOT NULL,
    policy TEXT NOT NULL CHECK (policy IN ('all', 'any', 'quorum')),
    threshold INTEGER NOT NULL CHECK (threshold > 0),
    decision TEXT NOT NULL CHECK (decision IN ('succeeded', 'failed')),
    expected_execution_token_ids_json TEXT NOT NULL,
    arrived_execution_token_ids_json TEXT NOT NULL,
    failed_execution_token_ids_json TEXT NOT NULL,
    pending_execution_token_ids_json TEXT NOT NULL,
    cancel_remaining INTEGER NOT NULL CHECK (cancel_remaining IN (0, 1)),
    error_code TEXT,
    evaluated_at_unix_millis INTEGER NOT NULL CHECK (evaluated_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, fork_node_id, join_node_id),
    UNIQUE(run_id, resumed_execution_token_id)
) STRICT;

CREATE INDEX workflow_join_evaluations_run_position
    ON workflow_join_evaluations(run_id, store_position, event_id);

CREATE TABLE workflow_projected_events (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    stream_sequence INTEGER NOT NULL CHECK (stream_sequence > 0),
    occurred_at_unix_millis INTEGER NOT NULL CHECK (occurred_at_unix_millis >= 0)
) STRICT;

CREATE INDEX workflow_projected_events_run_position
    ON workflow_projected_events(run_id, store_position);
"#;

const PROJECTION_MIGRATION_2: &str = r#"
ALTER TABLE workflow_values ADD COLUMN storage_handle_id TEXT;
ALTER TABLE workflow_values ADD COLUMN storage_scope TEXT;
ALTER TABLE workflow_values ADD COLUMN storage_logical_key TEXT;
ALTER TABLE workflow_values ADD COLUMN storage_version_id TEXT;
ALTER TABLE workflow_values ADD COLUMN storage_revision INTEGER;
ALTER TABLE workflow_values ADD COLUMN storage_previous_version_id TEXT;
ALTER TABLE workflow_values ADD COLUMN storage_result TEXT;
"#;

const PROJECTION_MIGRATION_3: &str = r#"
ALTER TABLE workflow_values ADD COLUMN storage_source_version_id TEXT;
"#;

const PROJECTION_MIGRATION_4: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_execution_tokens (
    execution_token_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    parent_execution_token_id TEXT,
    fork_node_id TEXT,
    branch_id TEXT,
    branch_port_id TEXT,
    join_node_id TEXT,
    source_emission_id TEXT,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed', 'cancelled', 'forked', 'joined')),
    outcome TEXT,
    terminal_node_id TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    final_emission_ids_json TEXT NOT NULL DEFAULT '[]',
    created_event_id TEXT NOT NULL UNIQUE,
    settled_event_id TEXT UNIQUE,
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    created_store_position INTEGER NOT NULL UNIQUE CHECK (created_store_position > 0),
    settled_store_position INTEGER UNIQUE,
    UNIQUE(run_id, fork_node_id, branch_id)
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_execution_tokens_run_position
    ON workflow_execution_tokens(run_id, created_store_position, execution_token_id);

CREATE TABLE IF NOT EXISTS workflow_join_evaluations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    join_node_id TEXT NOT NULL,
    fork_node_id TEXT NOT NULL,
    resumed_execution_token_id TEXT NOT NULL,
    policy TEXT NOT NULL CHECK (policy IN ('all', 'any', 'quorum')),
    threshold INTEGER NOT NULL CHECK (threshold > 0),
    decision TEXT NOT NULL CHECK (decision IN ('succeeded', 'failed')),
    expected_execution_token_ids_json TEXT NOT NULL,
    arrived_execution_token_ids_json TEXT NOT NULL,
    failed_execution_token_ids_json TEXT NOT NULL,
    pending_execution_token_ids_json TEXT NOT NULL,
    cancel_remaining INTEGER NOT NULL CHECK (cancel_remaining IN (0, 1)),
    error_code TEXT,
    evaluated_at_unix_millis INTEGER NOT NULL CHECK (evaluated_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, fork_node_id, join_node_id),
    UNIQUE(run_id, resumed_execution_token_id)
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_join_evaluations_run_position
    ON workflow_join_evaluations(run_id, store_position, event_id);
"#;

// Projection v3 constrained attempts by run and node only. Tokenized fan-out
// permits the same node to execute once per branch token, so an actual v3
// projection is discarded and replayed from the authoritative journal with
// the widened key. No journal or retained workflow data is deleted.
const PROJECTION_MIGRATION_4_RESET: &str = r#"
DELETE FROM workflow_projected_events;
DELETE FROM workflow_match_traces;
DELETE FROM workflow_edge_checkpoints;
DELETE FROM workflow_emissions;
DELETE FROM workflow_node_states;
DELETE FROM workflow_attempts;
DELETE FROM workflow_runs;
DELETE FROM workflow_values;
UPDATE workflow_projection_meta SET high_water_mark = 0 WHERE singleton = 1;

DROP TABLE workflow_match_traces;
DROP TABLE workflow_edge_checkpoints;
DROP TABLE workflow_emissions;
DROP TABLE workflow_node_states;
DROP TABLE workflow_attempts;

CREATE TABLE workflow_attempts (
    attempt_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    outcome TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    emission_ids_json TEXT NOT NULL DEFAULT '[]',
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL CHECK (started_store_position > 0),
    settled_store_position INTEGER,
    UNIQUE(run_id, execution_token_id, node_id, attempt_number)
) STRICT;
CREATE INDEX workflow_attempts_run_node
    ON workflow_attempts(run_id, node_id, attempt_number, attempt_id);

CREATE TABLE workflow_node_states (
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    node_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    latest_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    latest_attempt_number INTEGER NOT NULL CHECK (latest_attempt_number > 0),
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    last_store_position INTEGER NOT NULL CHECK (last_store_position > 0),
    PRIMARY KEY(run_id, node_id)
) STRICT;

CREATE TABLE workflow_emissions (
    emission_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    port_id TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    event_id TEXT NOT NULL UNIQUE,
    emitted_at_unix_millis INTEGER NOT NULL CHECK (emitted_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;
CREATE INDEX workflow_emissions_attempt
    ON workflow_emissions(run_id, attempt_id, store_position);

CREATE TABLE workflow_edge_checkpoints (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    edge_id TEXT NOT NULL,
    emission_id TEXT NOT NULL REFERENCES workflow_emissions(emission_id) ON DELETE CASCADE,
    target_node_id TEXT NOT NULL,
    target_port_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('admitted', 'skipped')),
    checkpointed_at_unix_millis INTEGER NOT NULL CHECK (checkpointed_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, edge_id, emission_id, target_node_id, target_port_id)
) STRICT;
CREATE INDEX workflow_edge_checkpoints_run_edge
    ON workflow_edge_checkpoints(run_id, edge_id, store_position);

CREATE TABLE workflow_match_traces (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    input_value_id TEXT NOT NULL,
    evaluated_case_ids_json TEXT NOT NULL,
    matched_case_ids_json TEXT NOT NULL,
    emitted_port_ids_json TEXT NOT NULL,
    trace_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    recorded_at_unix_millis INTEGER NOT NULL CHECK (recorded_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;
CREATE INDEX workflow_match_traces_attempt
    ON workflow_match_traces(run_id, attempt_id, store_position);
"#;

#[derive(Debug)]
pub enum WorkflowProjectionError {
    Database(rusqlite::Error),
    Journal(JournalError),
    Setup(String),
    UnsupportedNewerSchema { found: i64, supported: i64 },
    Integrity(String),
    Lifecycle(String),
    InjectedInterruption,
}

impl fmt::Display for WorkflowProjectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => write!(formatter, "workflow projection database: {error}"),
            Self::Journal(error) => write!(formatter, "workflow projection journal: {error}"),
            Self::Setup(error) => write!(formatter, "workflow projection setup: {error}"),
            Self::UnsupportedNewerSchema { found, supported } => write!(
                formatter,
                "workflow projection schema newer: found {found}, supported {supported}"
            ),
            Self::Integrity(code) => write!(formatter, "workflow projection integrity: {code}"),
            Self::Lifecycle(code) => write!(formatter, "workflow projection lifecycle: {code}"),
            Self::InjectedInterruption => formatter.write_str("workflow projection interrupted"),
        }
    }
}

impl std::error::Error for WorkflowProjectionError {}

impl From<rusqlite::Error> for WorkflowProjectionError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Database(value)
    }
}

impl From<JournalError> for WorkflowProjectionError {
    fn from(value: JournalError) -> Self {
        Self::Journal(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowProjectionError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowProjectionProgress {
    pub previous_high_water_mark: u64,
    pub high_water_mark: u64,
    pub journal_high_water_mark: u64,
    pub scanned_event_count: usize,
    pub projected_event_count: usize,
    pub has_more: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowProjectionFault {
    AfterScannedEvent(usize),
}

#[derive(Serialize)]
struct CanonicalProjectionState {
    schema_version: i64,
    high_water_mark: u64,
    tables: Vec<CanonicalTable>,
}

#[derive(Serialize)]
struct CanonicalTable {
    name: &'static str,
    rows: Vec<Vec<Option<String>>>,
}

pub struct WorkflowRunProjection {
    connection: Connection,
}

impl WorkflowRunProjection {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        prepare_database_path(path)
            .map_err(|error| WorkflowProjectionError::Setup(error.to_string()))?;
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
        )?;
        protect_private_path(path, PrivatePathKind::File)
            .map_err(|error| WorkflowProjectionError::Setup(error.to_string()))?;
        Self::initialize(connection)
    }

    /// Opens a disposable projection, quarantining only a corrupt supported
    /// projection before rebuilding it from the authoritative journal. A
    /// newer schema or unsafe path is never replaced.
    pub fn open_or_rebuild(path: impl AsRef<Path>, journal: &Journal) -> Result<(Self, bool)> {
        let path = path.as_ref();
        match Self::open(path) {
            Ok(mut projection) => {
                let rebuilt = projection.verify_or_rebuild(journal)?;
                Ok((projection, rebuilt))
            }
            Err(WorkflowProjectionError::Database(_) | WorkflowProjectionError::Integrity(_)) => {
                quarantine_projection_files(path)?;
                let mut projection = Self::open(path)?;
                projection.catch_up(journal)?;
                Ok((projection, true))
            }
            Err(error) => Err(error),
        }
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::initialize(Connection::open_in_memory()?)
    }

    fn initialize(mut connection: Connection) -> Result<Self> {
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "trusted_schema", "OFF")?;
        quick_check(&connection)?;
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found > PROJECTION_SCHEMA_VERSION {
            return Err(WorkflowProjectionError::UnsupportedNewerSchema {
                found,
                supported: PROJECTION_SCHEMA_VERSION,
            });
        }
        if found == 0 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(INITIAL_SCHEMA)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            transaction.execute(
                "INSERT INTO workflow_projection_meta(singleton, high_water_mark, state_digest) VALUES (1, 0, ?1)",
                ["0".repeat(64)],
            )?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        if found == 1 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_2)?;
            transaction.pragma_update(None, "user_version", 2)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 2 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_3)?;
            transaction.pragma_update(None, "user_version", 3)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 3 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if !table_has_column(&transaction, "workflow_attempts", "execution_token_id")? {
                transaction.execute_batch(PROJECTION_MIGRATION_4_RESET)?;
            }
            for table in [
                "workflow_attempts",
                "workflow_emissions",
                "workflow_edge_checkpoints",
                "workflow_match_traces",
            ] {
                if !table_has_column(&transaction, table, "execution_token_id")? {
                    transaction.execute_batch(&format!(
                        "ALTER TABLE {table} ADD COLUMN execution_token_id TEXT NOT NULL DEFAULT '';"
                    ))?;
                }
            }
            transaction.execute_batch(PROJECTION_MIGRATION_4)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        let projection = Self { connection };
        projection.integrity_check()?;
        Ok(projection)
    }

    pub fn high_water_mark(&self) -> Result<u64> {
        let value: i64 = self.connection.query_row(
            "SELECT high_water_mark FROM workflow_projection_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        u64::try_from(value)
            .map_err(|_| WorkflowProjectionError::Integrity("negative_high_water_mark".into()))
    }

    pub fn integrity_check(&self) -> Result<()> {
        quick_check(&self.connection)?;
        let violation = self
            .connection
            .query_row("PRAGMA foreign_key_check", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;
        if violation.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "foreign_key_violation".into(),
            ));
        }
        let incomplete_settled_token_graph = self
            .connection
            .query_row(
                "SELECT 1
                 FROM workflow_runs r
                 LEFT JOIN workflow_execution_tokens t ON t.run_id = r.run_id
                 LEFT JOIN workflow_emissions e ON e.emission_id = t.source_emission_id
                 LEFT JOIN workflow_join_evaluations j ON j.run_id = r.run_id
                 LEFT JOIN workflow_execution_tokens resumed
                   ON resumed.execution_token_id = j.resumed_execution_token_id
                 WHERE r.status IN ('succeeded', 'failed', 'cancelled')
                   AND ((t.source_emission_id IS NOT NULL AND e.emission_id IS NULL)
                     OR (j.event_id IS NOT NULL AND resumed.execution_token_id IS NULL)
                     OR t.status = 'active')
                 LIMIT 1",
                [],
                |_| Ok(()),
            )
            .optional()?;
        if incomplete_settled_token_graph.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "settled_execution_token_graph_incomplete".into(),
            ));
        }
        let stored: String = self.connection.query_row(
            "SELECT state_digest FROM workflow_projection_meta WHERE singleton = 1",
            [],
            |row| row.get(0),
        )?;
        let actual = hex::encode(Sha256::digest(canonical_state_bytes(&self.connection)?));
        if stored != actual {
            return Err(WorkflowProjectionError::Integrity(
                "state_digest_mismatch".into(),
            ));
        }
        Ok(())
    }

    pub fn canonical_snapshot(&self) -> Result<Vec<u8>> {
        self.integrity_check()?;
        canonical_state_bytes(&self.connection)
    }

    pub fn catch_up(&mut self, journal: &Journal) -> Result<WorkflowProjectionProgress> {
        let mut total_scanned = 0;
        let mut total_projected = 0;
        let initial = self.high_water_mark()?;
        loop {
            let progress = self.catch_up_batch(journal, DEFAULT_BATCH_SIZE)?;
            total_scanned += progress.scanned_event_count;
            total_projected += progress.projected_event_count;
            if !progress.has_more {
                return Ok(WorkflowProjectionProgress {
                    previous_high_water_mark: initial,
                    high_water_mark: progress.high_water_mark,
                    journal_high_water_mark: progress.journal_high_water_mark,
                    scanned_event_count: total_scanned,
                    projected_event_count: total_projected,
                    has_more: false,
                });
            }
        }
    }

    pub fn catch_up_batch(
        &mut self,
        journal: &Journal,
        page_size: u32,
    ) -> Result<WorkflowProjectionProgress> {
        self.catch_up_batch_with_fault(journal, page_size, None)
    }

    #[doc(hidden)]
    pub fn catch_up_batch_with_fault_for_test(
        &mut self,
        journal: &Journal,
        page_size: u32,
        fault: WorkflowProjectionFault,
    ) -> Result<WorkflowProjectionProgress> {
        self.catch_up_batch_with_fault(journal, page_size, Some(fault))
    }

    fn catch_up_batch_with_fault(
        &mut self,
        journal: &Journal,
        page_size: u32,
        fault: Option<WorkflowProjectionFault>,
    ) -> Result<WorkflowProjectionProgress> {
        self.integrity_check()?;
        let previous = self.high_water_mark()?;
        let page = journal.event_page_after(previous, page_size)?;
        if previous > page.high_water_mark {
            return Err(WorkflowProjectionError::Integrity(
                "checkpoint_ahead_of_journal".into(),
            ));
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut projected = 0;
        for (index, event) in page.events.iter().enumerate() {
            if apply_event(&transaction, event)? {
                projected += 1;
            }
            if fault == Some(WorkflowProjectionFault::AfterScannedEvent(index + 1)) {
                return Err(WorkflowProjectionError::InjectedInterruption);
            }
        }
        transaction.execute(
            "UPDATE workflow_projection_meta SET high_water_mark = ?1 WHERE singleton = 1",
            [sql_u64(page.next_store_position)?],
        )?;
        refresh_state_digest(&transaction)?;
        transaction.commit()?;
        Ok(WorkflowProjectionProgress {
            previous_high_water_mark: previous,
            high_water_mark: page.next_store_position,
            journal_high_water_mark: page.high_water_mark,
            scanned_event_count: page.events.len(),
            projected_event_count: projected,
            has_more: page.has_more,
        })
    }

    pub fn rebuild_from_zero(&mut self, journal: &Journal) -> Result<WorkflowProjectionProgress> {
        self.rebuild_without_verification()?;
        self.catch_up(journal)
    }

    pub fn verify_or_rebuild(&mut self, journal: &Journal) -> Result<bool> {
        let journal_high_water = journal.event_page_after(0, 1)?.high_water_mark;
        let healthy = self.integrity_check().is_ok()
            && self
                .high_water_mark()
                .is_ok_and(|checkpoint| checkpoint <= journal_high_water);
        if healthy {
            self.catch_up(journal)?;
            return Ok(false);
        }
        self.rebuild_without_verification()?;
        self.catch_up(journal)?;
        Ok(true)
    }

    fn rebuild_without_verification(&mut self) -> Result<()> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute_batch(
            "DELETE FROM workflow_projected_events;
             DELETE FROM workflow_join_evaluations;
             DELETE FROM workflow_execution_tokens;
             DELETE FROM workflow_match_traces;
             DELETE FROM workflow_edge_checkpoints;
             DELETE FROM workflow_emissions;
             DELETE FROM workflow_node_states;
             DELETE FROM workflow_attempts;
             DELETE FROM workflow_runs;
             DELETE FROM workflow_values;
             UPDATE workflow_projection_meta SET high_water_mark = 0 WHERE singleton = 1;",
        )?;
        refresh_state_digest(&transaction)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn row_count(&self, table: &'static str) -> Result<u64> {
        let sql = match table {
            "runs" => "SELECT COUNT(*) FROM workflow_runs",
            "attempts" => "SELECT COUNT(*) FROM workflow_attempts",
            "nodes" => "SELECT COUNT(*) FROM workflow_node_states",
            "emissions" => "SELECT COUNT(*) FROM workflow_emissions",
            "edges" => "SELECT COUNT(*) FROM workflow_edge_checkpoints",
            "matches" => "SELECT COUNT(*) FROM workflow_match_traces",
            "tokens" => "SELECT COUNT(*) FROM workflow_execution_tokens",
            "joins" => "SELECT COUNT(*) FROM workflow_join_evaluations",
            "events" => "SELECT COUNT(*) FROM workflow_projected_events",
            "values" => "SELECT COUNT(*) FROM workflow_values",
            _ => return Err(WorkflowProjectionError::Integrity("unknown_table".into())),
        };
        let count: i64 = self.connection.query_row(sql, [], |row| row.get(0))?;
        u64::try_from(count)
            .map_err(|_| WorkflowProjectionError::Integrity("negative_row_count".into()))
    }

    /// Returns a bounded, read-only view of durable run evidence. The caller
    /// selects identities only; storage paths remain owned by the local core.
    pub fn inspect_runs(
        &self,
        workflow_id: Option<&str>,
        run_id: Option<&str>,
        limit: u32,
    ) -> Result<Vec<v1::WorkflowProjectedRun>> {
        self.integrity_check()?;
        if limit == 0 || limit > 100 {
            return Err(WorkflowProjectionError::Integrity(
                "inspection_limit_out_of_bounds".into(),
            ));
        }
        let mut run_ids = Vec::new();
        match (
            workflow_id.filter(|value| !value.is_empty()),
            run_id.filter(|value| !value.is_empty()),
        ) {
            (_, Some(run_id)) => {
                let found = self
                    .connection
                    .query_row(
                        "SELECT run_id FROM workflow_runs WHERE run_id = ?1",
                        [run_id],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                run_ids.extend(found);
            }
            (Some(workflow_id), None) => {
                let mut statement = self.connection.prepare(
                    "SELECT run_id FROM workflow_runs WHERE workflow_id = ?1
                     ORDER BY created_at_unix_millis DESC, first_store_position DESC, run_id
                     LIMIT ?2",
                )?;
                let rows = statement.query_map(params![workflow_id, i64::from(limit)], |row| {
                    row.get::<_, String>(0)
                })?;
                run_ids = rows.collect::<std::result::Result<_, _>>()?;
            }
            (None, None) => {
                let mut statement = self.connection.prepare(
                    "SELECT run_id FROM workflow_runs
                     ORDER BY created_at_unix_millis DESC, first_store_position DESC, run_id
                     LIMIT ?1",
                )?;
                let rows =
                    statement.query_map([i64::from(limit)], |row| row.get::<_, String>(0))?;
                run_ids = rows.collect::<std::result::Result<_, _>>()?;
            }
        }
        run_ids
            .iter()
            .map(|run_id| self.inspect_run(run_id))
            .collect()
    }

    fn inspect_run(&self, run_id: &str) -> Result<v1::WorkflowProjectedRun> {
        type RunRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            Option<String>,
            Option<String>,
            i64,
            Option<i64>,
            i64,
            i64,
        );
        let row: RunRow = self.connection.query_row(
            "SELECT run_id, run_token_id, request_command_id, workflow_id, revision_id,
                    package_digest, status, outcome, error_code, error_value_id,
                    final_emission_ids_json, cancellation_command_id, cancellation_reason_code,
                    created_at_unix_millis, settled_at_unix_millis,
                    first_store_position, last_store_position
             FROM workflow_runs WHERE run_id = ?1",
            [run_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                    row.get(14)?,
                    row.get(15)?,
                    row.get(16)?,
                ))
            },
        )?;
        Ok(v1::WorkflowProjectedRun {
            run_id: row.0,
            run_token_id: row.1,
            request_command_id: row.2,
            workflow_id: row.3,
            revision_id: row.4,
            package_digest: row.5,
            status: row.6,
            outcome: row.7.unwrap_or_default(),
            error_code: row.8.unwrap_or_default(),
            error: self.inspect_optional_value(row.9.as_deref())?,
            final_emission_ids: decode_string_list(&row.10)?,
            cancellation_command_id: row.11.unwrap_or_default(),
            cancellation_reason_code: row.12.unwrap_or_default(),
            created_at_unix_millis: row.13,
            settled_at_unix_millis: row.14.unwrap_or_default(),
            first_store_position: projected_u64(row.15)?,
            last_store_position: projected_u64(row.16)?,
            attempts: self.inspect_attempts(run_id)?,
            nodes: self.inspect_nodes(run_id)?,
            emissions: self.inspect_emissions(run_id)?,
            edges: self.inspect_edges(run_id)?,
            match_traces: self.inspect_match_traces(run_id)?,
            events: self.inspect_events(run_id)?,
            execution_tokens: self.inspect_execution_tokens(run_id)?,
            joins: self.inspect_joins(run_id)?,
        })
    }

    fn inspect_attempts(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedAttempt>> {
        let mut statement = self.connection.prepare(
            "SELECT attempt_id, node_id, attempt_number, status, outcome, error_code,
                    error_value_id, emission_ids_json, started_at_unix_millis,
                    settled_at_unix_millis, started_store_position, settled_store_position,
                    execution_token_id
             FROM workflow_attempts WHERE run_id = ?1
             ORDER BY started_store_position, attempt_id",
        )?;
        type AttemptRow = (
            String,
            String,
            i64,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            i64,
            Option<i64>,
            i64,
            Option<i64>,
            String,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<AttemptRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
                row.get(10)?,
                row.get(11)?,
                row.get(12)?,
            ))
        })?;
        let rows = rows.collect::<std::result::Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedAttempt {
                    attempt_id: row.0,
                    node_id: row.1,
                    attempt_number: projected_u32(row.2)?,
                    status: row.3,
                    outcome: row.4.unwrap_or_default(),
                    error_code: row.5.unwrap_or_default(),
                    error: self.inspect_optional_value(row.6.as_deref())?,
                    emission_ids: decode_string_list(&row.7)?,
                    started_at_unix_millis: row.8,
                    settled_at_unix_millis: row.9.unwrap_or_default(),
                    started_store_position: projected_u64(row.10)?,
                    settled_store_position: row
                        .11
                        .map(projected_u64)
                        .transpose()?
                        .unwrap_or_default(),
                    execution_token_id: row.12,
                })
            })
            .collect()
    }

    fn inspect_nodes(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedNodeState>> {
        let mut statement = self.connection.prepare(
            "SELECT node_id, status, latest_attempt_id, latest_attempt_number,
                    started_at_unix_millis, settled_at_unix_millis, last_store_position
             FROM workflow_node_states WHERE run_id = ?1 ORDER BY last_store_position, node_id",
        )?;
        type NodeRow = (String, String, String, i64, i64, Option<i64>, i64);
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<NodeRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedNodeState {
                    node_id: row.0,
                    status: row.1,
                    latest_attempt_id: row.2,
                    latest_attempt_number: projected_u32(row.3)?,
                    started_at_unix_millis: row.4,
                    settled_at_unix_millis: row.5.unwrap_or_default(),
                    last_store_position: projected_u64(row.6)?,
                })
            })
            .collect()
    }

    fn inspect_emissions(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedEmission>> {
        let mut statement = self.connection.prepare(
            "SELECT emission_id, attempt_id, node_id, port_id, value_id, event_id,
                    emitted_at_unix_millis, store_position, execution_token_id
             FROM workflow_emissions WHERE run_id = ?1 ORDER BY store_position, emission_id",
        )?;
        type EmissionRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
            String,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<EmissionRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedEmission {
                    emission_id: row.0,
                    attempt_id: row.1,
                    node_id: row.2,
                    port_id: row.3,
                    value: Some(self.inspect_value(&row.4)?),
                    event_id: row.5,
                    emitted_at_unix_millis: row.6,
                    store_position: projected_u64(row.7)?,
                    execution_token_id: row.8,
                })
            })
            .collect()
    }

    fn inspect_edges(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedEdgeCheckpoint>> {
        let mut statement = self.connection.prepare(
            "SELECT event_id, edge_id, emission_id, target_node_id, target_port_id, state,
                    checkpointed_at_unix_millis, store_position, execution_token_id
             FROM workflow_edge_checkpoints WHERE run_id = ?1 ORDER BY store_position, event_id",
        )?;
        type EdgeRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
            String,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<EdgeRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedEdgeCheckpoint {
                    event_id: row.0,
                    edge_id: row.1,
                    emission_id: row.2,
                    target_node_id: row.3,
                    target_port_id: row.4,
                    state: row.5,
                    checkpointed_at_unix_millis: row.6,
                    store_position: projected_u64(row.7)?,
                    execution_token_id: row.8,
                })
            })
            .collect()
    }

    fn inspect_execution_tokens(
        &self,
        run_id: &str,
    ) -> Result<Vec<v1::WorkflowProjectedExecutionToken>> {
        let mut statement = self.connection.prepare(
            "SELECT execution_token_id, parent_execution_token_id, fork_node_id, branch_id,
                    branch_port_id, join_node_id, source_emission_id, status, outcome,
                    terminal_node_id, error_code, error_value_id, final_emission_ids_json,
                    created_store_position, settled_store_position
             FROM workflow_execution_tokens WHERE run_id = ?1
             ORDER BY created_store_position, execution_token_id",
        )?;
        type TokenRow = (
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            i64,
            Option<i64>,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<TokenRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
                row.get(10)?,
                row.get(11)?,
                row.get(12)?,
                row.get(13)?,
                row.get(14)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedExecutionToken {
                    execution_token_id: row.0,
                    parent_execution_token_id: row.1.unwrap_or_default(),
                    fork_node_id: row.2.unwrap_or_default(),
                    branch_id: row.3.unwrap_or_default(),
                    branch_port_id: row.4.unwrap_or_default(),
                    join_node_id: row.5.unwrap_or_default(),
                    source_emission_id: row.6.unwrap_or_default(),
                    status: row.7,
                    outcome: row.8.unwrap_or_default(),
                    terminal_node_id: row.9.unwrap_or_default(),
                    error_code: row.10.unwrap_or_default(),
                    error: self.inspect_optional_value(row.11.as_deref())?,
                    final_emission_ids: decode_string_list(&row.12)?,
                    created_store_position: projected_u64(row.13)?,
                    settled_store_position: row
                        .14
                        .map(projected_u64)
                        .transpose()?
                        .unwrap_or_default(),
                })
            })
            .collect()
    }

    fn inspect_joins(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedJoinEvaluation>> {
        let mut statement = self.connection.prepare(
            "SELECT join_node_id, fork_node_id, resumed_execution_token_id, policy, threshold,
                    decision, expected_execution_token_ids_json, arrived_execution_token_ids_json,
                    failed_execution_token_ids_json, pending_execution_token_ids_json,
                    cancel_remaining, error_code, store_position
             FROM workflow_join_evaluations WHERE run_id = ?1 ORDER BY store_position, event_id",
        )?;
        type JoinRow = (
            String,
            String,
            String,
            String,
            i64,
            String,
            String,
            String,
            String,
            String,
            bool,
            Option<String>,
            i64,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<JoinRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
                row.get(10)?,
                row.get(11)?,
                row.get(12)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedJoinEvaluation {
                    join_node_id: row.0,
                    fork_node_id: row.1,
                    resumed_execution_token_id: row.2,
                    policy: row.3,
                    threshold: projected_u32(row.4)?,
                    decision: row.5,
                    expected_execution_token_ids: decode_string_list(&row.6)?,
                    arrived_execution_token_ids: decode_string_list(&row.7)?,
                    failed_execution_token_ids: decode_string_list(&row.8)?,
                    pending_execution_token_ids: decode_string_list(&row.9)?,
                    cancel_remaining: row.10,
                    error_code: row.11.unwrap_or_default(),
                    store_position: projected_u64(row.12)?,
                })
            })
            .collect()
    }

    fn inspect_match_traces(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedMatchTrace>> {
        let mut statement = self.connection.prepare(
            "SELECT event_id, attempt_id, node_id, input_value_id, evaluated_case_ids_json,
                    matched_case_ids_json, emitted_port_ids_json, trace_value_id,
                    recorded_at_unix_millis, store_position
             FROM workflow_match_traces WHERE run_id = ?1 ORDER BY store_position, event_id",
        )?;
        type MatchRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<MatchRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedMatchTrace {
                    event_id: row.0,
                    attempt_id: row.1,
                    node_id: row.2,
                    input_value_id: row.3,
                    evaluated_case_ids: decode_string_list(&row.4)?,
                    matched_case_ids: decode_string_list(&row.5)?,
                    emitted_port_ids: decode_string_list(&row.6)?,
                    trace: Some(self.inspect_value(&row.7)?),
                    recorded_at_unix_millis: row.8,
                    store_position: projected_u64(row.9)?,
                })
            })
            .collect()
    }

    fn inspect_events(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedEventReference>> {
        let mut statement = self.connection.prepare(
            "SELECT event_id, kind, store_position, stream_sequence, occurred_at_unix_millis
             FROM workflow_projected_events WHERE run_id = ?1 ORDER BY store_position, event_id",
        )?;
        type EventRow = (String, String, i64, i64, i64);
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<EventRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedEventReference {
                    event_id: row.0,
                    kind: row.1,
                    store_position: projected_u64(row.2)?,
                    stream_sequence: projected_u64(row.3)?,
                    occurred_at_unix_millis: row.4,
                })
            })
            .collect()
    }

    fn inspect_optional_value(
        &self,
        value_id: Option<&str>,
    ) -> Result<Option<v1::WorkflowProjectedValue>> {
        value_id
            .map(|value_id| self.inspect_value(value_id))
            .transpose()
    }

    fn inspect_value(&self, value_id: &str) -> Result<v1::WorkflowProjectedValue> {
        type ValueRow = (
            String,
            String,
            i64,
            String,
            Option<Vec<u8>>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i64>,
            Option<String>,
            Option<String>,
            Option<String>,
        );
        let row: ValueRow = self.connection.query_row(
            "SELECT value_id, content_type, byte_count, sha256, inline_canonical_json,
                    storage_reference_id, storage_handle_id, storage_scope,
                    storage_logical_key, storage_version_id, storage_revision,
                    storage_previous_version_id, storage_source_version_id, storage_result
             FROM workflow_values WHERE value_id = ?1",
            [value_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                ))
            },
        )?;
        let availability = if row.4.is_some() {
            "inline"
        } else if row.6.is_some() {
            "scoped_handle"
        } else {
            "storage_unavailable"
        };
        let byte_count = projected_u64(row.2)?;
        let storage_revision = row.10.map(projected_u64).transpose()?.unwrap_or_default();
        let storage = row.6.map(|handle_id| v1::WorkflowStorageValueMetadata {
            handle_id,
            scope: row.7.unwrap_or_default(),
            logical_key: row.8.unwrap_or_default(),
            version_id: row.9.unwrap_or_default(),
            revision: storage_revision,
            previous_version_id: row.11.unwrap_or_default(),
            byte_count,
            result: row.13.unwrap_or_default(),
            source_version_id: row.12.unwrap_or_default(),
        });
        Ok(v1::WorkflowProjectedValue {
            value_id: row.0,
            content_type: row.1,
            byte_count,
            sha256: row.3,
            inline_canonical_json: row.4.unwrap_or_default(),
            storage_reference_id: row.5.unwrap_or_default(),
            availability: availability.into(),
            storage,
        })
    }

    #[doc(hidden)]
    pub fn corrupt_first_run_for_test(&self) -> Result<()> {
        self.connection.execute(
            "UPDATE workflow_runs SET workflow_id = workflow_id || '-corrupt'
             WHERE run_id = (SELECT run_id FROM workflow_runs ORDER BY run_id LIMIT 1)",
            [],
        )?;
        Ok(())
    }

    #[doc(hidden)]
    pub fn rewind_checkpoint_for_test(&mut self, high_water_mark: u64) -> Result<()> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction.execute(
            "UPDATE workflow_projection_meta SET high_water_mark = ?1 WHERE singleton = 1",
            [sql_u64(high_water_mark)?],
        )?;
        refresh_state_digest(&transaction)?;
        transaction.commit()?;
        Ok(())
    }
}

fn decode_string_list(value: &str) -> Result<Vec<String>> {
    serde_json::from_str(value)
        .map_err(|_| WorkflowProjectionError::Integrity("string_list_decode_failed".into()))
}

fn projected_u64(value: i64) -> Result<u64> {
    u64::try_from(value)
        .map_err(|_| WorkflowProjectionError::Integrity("negative_projection_integer".into()))
}

fn projected_u32(value: i64) -> Result<u32> {
    u32::try_from(value)
        .map_err(|_| WorkflowProjectionError::Integrity("projection_integer_out_of_bounds".into()))
}

fn apply_event(transaction: &Transaction<'_>, event: &v1::EventEnvelope) -> Result<bool> {
    if !workflow_runtime::is_workflow_runtime_kind(&event.kind) {
        return Ok(false);
    }
    if let Some((position, kind)) = transaction
        .query_row(
            "SELECT store_position, kind FROM workflow_projected_events WHERE event_id = ?1",
            [&event.event_id],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
    {
        if position == sql_u64(event.store_position)? && kind == event.kind {
            return Ok(false);
        }
        return lifecycle("projected_event_identity_reused");
    }

    let runtime = workflow_runtime::decode_workflow_event(event)
        .map_err(|_| WorkflowProjectionError::Lifecycle("runtime_event_invalid".into()))?;
    let run_id = runtime.run_id().to_owned();
    match runtime {
        WorkflowRuntimeEvent::RunTokenCreated(payload) => {
            if run_exists(transaction, &payload.run_id)? {
                return lifecycle("run_identity_reused");
            }
            transaction.execute(
                "INSERT INTO workflow_runs
                 (run_id, run_token_id, request_command_id, workflow_id, revision_id, package_digest,
                  status, created_at_unix_millis, first_store_position, last_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7, ?8, ?8)",
                params![
                    payload.run_id,
                    payload.run_token_id,
                    payload.request_command_id,
                    payload.workflow_id,
                    payload.revision_id,
                    payload.package_digest,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
        }
        WorkflowRuntimeEvent::ExecutionTokenCreated(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            if !payload.parent_execution_token_id.is_empty() {
                let parent_run: Option<String> = transaction
                    .query_row(
                        "SELECT run_id FROM workflow_execution_tokens WHERE execution_token_id = ?1",
                        [&payload.parent_execution_token_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if parent_run.as_deref() != Some(payload.run_id.as_str()) {
                    return lifecycle("execution_token_parent_missing");
                }
            }
            transaction.execute(
                "INSERT INTO workflow_execution_tokens
                 (execution_token_id, run_id, run_token_id, parent_execution_token_id,
                  fork_node_id, branch_id, branch_port_id, join_node_id, source_emission_id,
                  status, created_event_id, created_at_unix_millis, created_store_position)
                 VALUES (?1, ?2, ?3, NULLIF(?4, ''), NULLIF(?5, ''), NULLIF(?6, ''),
                         NULLIF(?7, ''), NULLIF(?8, ''), NULLIF(?9, ''), 'active', ?10, ?11, ?12)",
                params![
                    payload.execution_token_id,
                    payload.run_id,
                    payload.run_token_id,
                    payload.parent_execution_token_id,
                    payload.fork_node_id,
                    payload.branch_id,
                    payload.branch_port_id,
                    payload.join_node_id,
                    payload.source_emission_id,
                    event.event_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::ExecutionTokenSettled(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let status: Option<String> = transaction
                .query_row(
                    "SELECT status FROM workflow_execution_tokens
                     WHERE execution_token_id = ?1 AND run_id = ?2 AND run_token_id = ?3",
                    params![
                        payload.execution_token_id,
                        payload.run_id,
                        payload.run_token_id
                    ],
                    |row| row.get(0),
                )
                .optional()?;
            if status.as_deref() != Some("active") {
                return lifecycle("execution_token_not_active");
            }
            let outcome = v1::WorkflowExecutionTokenOutcome::try_from(payload.outcome)
                .map_err(|_| WorkflowProjectionError::Lifecycle("token_outcome_invalid".into()))?;
            let status = match outcome {
                v1::WorkflowExecutionTokenOutcome::Completed => "completed",
                v1::WorkflowExecutionTokenOutcome::Failed => "failed",
                v1::WorkflowExecutionTokenOutcome::Cancelled => "cancelled",
                v1::WorkflowExecutionTokenOutcome::Forked => "forked",
                v1::WorkflowExecutionTokenOutcome::Joined => "joined",
                v1::WorkflowExecutionTokenOutcome::Unspecified => {
                    return lifecycle("token_outcome_invalid");
                }
            };
            let error_value_id = insert_optional_value(transaction, payload.error.as_ref())?;
            transaction.execute(
                "UPDATE workflow_execution_tokens SET status = ?1, outcome = ?1,
                   terminal_node_id = NULLIF(?2, ''), join_node_id = COALESCE(NULLIF(?3, ''), join_node_id),
                   error_code = NULLIF(?4, ''), error_value_id = ?5, final_emission_ids_json = ?6,
                   settled_event_id = ?7, settled_at_unix_millis = ?8, settled_store_position = ?9
                 WHERE execution_token_id = ?10",
                params![
                    status,
                    payload.terminal_node_id,
                    payload.join_node_id,
                    payload.error_code,
                    error_value_id,
                    string_list_json(&payload.final_emission_ids)?,
                    event.event_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.execution_token_id,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::JoinEvaluated(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            for token_id in &payload.expected_execution_token_ids {
                let token: Option<(String, Option<String>, Option<String>)> = transaction
                    .query_row(
                        "SELECT run_id, fork_node_id, join_node_id FROM workflow_execution_tokens
                         WHERE execution_token_id = ?1",
                        [token_id],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .optional()?;
                if token
                    .as_ref()
                    .is_none_or(|(run_id, fork_node_id, join_node_id)| {
                        run_id != &payload.run_id
                            || fork_node_id.as_deref() != Some(payload.fork_node_id.as_str())
                            || join_node_id.as_deref() != Some(payload.join_node_id.as_str())
                    })
                {
                    return lifecycle("join_expected_token_mismatch");
                }
            }
            let decision = match v1::WorkflowJoinDecision::try_from(payload.decision) {
                Ok(v1::WorkflowJoinDecision::Succeeded) => "succeeded",
                Ok(v1::WorkflowJoinDecision::Failed) => "failed",
                _ => return lifecycle("join_decision_invalid"),
            };
            transaction.execute(
                "INSERT INTO workflow_join_evaluations
                 (event_id, run_id, join_node_id, fork_node_id, resumed_execution_token_id,
                  policy, threshold, decision, expected_execution_token_ids_json,
                  arrived_execution_token_ids_json, failed_execution_token_ids_json,
                  pending_execution_token_ids_json, cancel_remaining, error_code,
                  evaluated_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         NULLIF(?14, ''), ?15, ?16)",
                params![
                    event.event_id,
                    payload.run_id,
                    payload.join_node_id,
                    payload.fork_node_id,
                    payload.resumed_execution_token_id,
                    payload.policy,
                    payload.threshold,
                    decision,
                    string_list_json(&payload.expected_execution_token_ids)?,
                    string_list_json(&payload.arrived_execution_token_ids)?,
                    string_list_json(&payload.failed_execution_token_ids)?,
                    string_list_json(&payload.pending_execution_token_ids)?,
                    payload.cancel_remaining,
                    payload.error_code,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::AttemptStarted(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            require_execution_token(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.execution_token_id,
                true,
            )?;
            let running_node: Option<String> = transaction
                .query_row(
                    "SELECT status FROM workflow_node_states WHERE run_id = ?1 AND node_id = ?2",
                    params![payload.run_id, payload.node_id],
                    |row| row.get(0),
                )
                .optional()?;
            if running_node.as_deref() == Some("running") {
                return lifecycle("node_attempt_overlap");
            }
            transaction.execute(
                "INSERT INTO workflow_attempts
                 (attempt_id, run_id, run_token_id, execution_token_id, node_id, attempt_number, status,
                  started_at_unix_millis, started_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7, ?8)",
                params![
                    payload.attempt_id,
                    payload.run_id,
                    payload.run_token_id,
                    payload.execution_token_id,
                    payload.node_id,
                    payload.attempt_number,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            transaction.execute(
                "INSERT INTO workflow_node_states
                 (run_id, node_id, status, latest_attempt_id, latest_attempt_number,
                  started_at_unix_millis, last_store_position)
                 VALUES (?1, ?2, 'running', ?3, ?4, ?5, ?6)
                 ON CONFLICT(run_id, node_id) DO UPDATE SET
                   status = 'running', latest_attempt_id = excluded.latest_attempt_id,
                   latest_attempt_number = excluded.latest_attempt_number,
                   started_at_unix_millis = excluded.started_at_unix_millis,
                   settled_at_unix_millis = NULL, last_store_position = excluded.last_store_position",
                params![
                    payload.run_id,
                    payload.node_id,
                    payload.attempt_id,
                    payload.attempt_number,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::PortEmitted(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let value = payload.value.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("emission_value_missing".into())
            })?;
            insert_value(transaction, value)?;
            transaction.execute(
                "INSERT INTO workflow_emissions
                 (emission_id, run_id, attempt_id, execution_token_id, node_id, port_id, value_id, event_id,
                  emitted_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    payload.emission_id,
                    payload.run_id,
                    payload.attempt_id,
                    payload.execution_token_id,
                    payload.node_id,
                    payload.port_id,
                    value.value_id,
                    event.event_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::EdgeCheckpointed(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            require_execution_token(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.execution_token_id,
                true,
            )?;
            let emission_run: Option<String> = transaction
                .query_row(
                    "SELECT run_id FROM workflow_emissions WHERE emission_id = ?1",
                    [&payload.emission_id],
                    |row| row.get(0),
                )
                .optional()?;
            if emission_run.as_deref() != Some(payload.run_id.as_str()) {
                return lifecycle("edge_emission_missing");
            }
            let state = match v1::WorkflowEdgeCheckpointState::try_from(payload.state) {
                Ok(v1::WorkflowEdgeCheckpointState::Admitted) => "admitted",
                Ok(v1::WorkflowEdgeCheckpointState::Skipped) => "skipped",
                _ => return lifecycle("edge_state_invalid"),
            };
            transaction.execute(
                "INSERT INTO workflow_edge_checkpoints
                 (event_id, run_id, execution_token_id, edge_id, emission_id, target_node_id, target_port_id,
                  state, checkpointed_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    event.event_id,
                    payload.run_id,
                    payload.execution_token_id,
                    payload.edge_id,
                    payload.emission_id,
                    payload.target_node_id,
                    payload.target_port_id,
                    state,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::MatchTraceRecorded(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let trace = payload
                .trace
                .as_ref()
                .ok_or_else(|| WorkflowProjectionError::Lifecycle("match_trace_missing".into()))?;
            insert_value(transaction, trace)?;
            transaction.execute(
                "INSERT INTO workflow_match_traces
                 (event_id, run_id, attempt_id, execution_token_id, node_id, input_value_id,
                  evaluated_case_ids_json, matched_case_ids_json, emitted_port_ids_json,
                  trace_value_id, recorded_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    event.event_id,
                    payload.run_id,
                    payload.attempt_id,
                    payload.execution_token_id,
                    payload.node_id,
                    payload.input_value_id,
                    string_list_json(&payload.evaluated_case_ids)?,
                    string_list_json(&payload.matched_case_ids)?,
                    string_list_json(&payload.emitted_port_ids)?,
                    trace.value_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::AttemptSettled(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                Some(payload.attempt_number),
                Some(&payload.execution_token_id),
            )?;
            let actual_emissions = emission_ids_for_attempt(transaction, &payload.attempt_id)?;
            if actual_emissions != payload.emission_ids {
                return lifecycle("attempt_emission_set_mismatch");
            }
            let (status, outcome) = settled_outcome(payload.outcome, OutcomeDomain::Attempt)?;
            let error_value_id = insert_optional_value(transaction, payload.error.as_ref())?;
            transaction.execute(
                "UPDATE workflow_attempts SET
                   status = ?1, outcome = ?2, error_code = NULLIF(?3, ''), error_value_id = ?4,
                   emission_ids_json = ?5, settled_at_unix_millis = ?6, settled_store_position = ?7
                 WHERE attempt_id = ?8",
                params![
                    status,
                    outcome,
                    payload.error_code,
                    error_value_id,
                    string_list_json(&payload.emission_ids)?,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.attempt_id,
                ],
            )?;
            transaction.execute(
                "UPDATE workflow_node_states SET status = ?1, settled_at_unix_millis = ?2,
                 last_store_position = ?3 WHERE run_id = ?4 AND node_id = ?5
                 AND latest_attempt_id = ?6",
                params![
                    status,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.run_id,
                    payload.node_id,
                    payload.attempt_id,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::RunCancellationRequested(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            transaction.execute(
                "UPDATE workflow_runs SET status = 'cancelling', cancellation_command_id = ?1,
                 cancellation_reason_code = ?2, last_store_position = ?3 WHERE run_id = ?4",
                params![
                    payload.cancel_command_id,
                    payload.reason_code,
                    sql_u64(event.store_position)?,
                    payload.run_id,
                ],
            )?;
        }
        WorkflowRuntimeEvent::RunSettled(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let running_attempts: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM workflow_attempts WHERE run_id = ?1 AND status = 'running'",
                [&payload.run_id],
                |row| row.get(0),
            )?;
            if running_attempts != 0 {
                return lifecycle("run_has_active_attempts");
            }
            let token_count: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM workflow_execution_tokens WHERE run_id = ?1",
                [&payload.run_id],
                |row| row.get(0),
            )?;
            let active_tokens: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM workflow_execution_tokens
                 WHERE run_id = ?1 AND status = 'active'",
                [&payload.run_id],
                |row| row.get(0),
            )?;
            if token_count != 0 && active_tokens != 0 {
                return lifecycle("run_has_active_execution_tokens");
            }
            for emission_id in &payload.final_emission_ids {
                let emission_run: Option<String> = transaction
                    .query_row(
                        "SELECT run_id FROM workflow_emissions WHERE emission_id = ?1",
                        [emission_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if emission_run.as_deref() != Some(payload.run_id.as_str()) {
                    return lifecycle("final_emission_missing");
                }
            }
            let (status, outcome) = settled_outcome(payload.outcome, OutcomeDomain::Run)?;
            let error_value_id = insert_optional_value(transaction, payload.error.as_ref())?;
            transaction.execute(
                "UPDATE workflow_runs SET status = ?1, outcome = ?2, error_code = NULLIF(?3, ''),
                 error_value_id = ?4, final_emission_ids_json = ?5,
                 settled_at_unix_millis = ?6, last_store_position = ?7 WHERE run_id = ?8",
                params![
                    status,
                    outcome,
                    payload.error_code,
                    error_value_id,
                    string_list_json(&payload.final_emission_ids)?,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.run_id,
                ],
            )?;
        }
    }
    transaction.execute(
        "INSERT INTO workflow_projected_events
         (event_id, run_id, kind, store_position, stream_sequence, occurred_at_unix_millis)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            event.event_id,
            run_id,
            event.kind,
            sql_u64(event.store_position)?,
            sql_u64(event.stream_sequence)?,
            event.occurred_at_unix_millis,
        ],
    )?;
    Ok(true)
}

fn run_exists(transaction: &Transaction<'_>, run_id: &str) -> Result<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM workflow_runs WHERE run_id = ?1",
            [run_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn require_active_run(transaction: &Transaction<'_>, run_id: &str, token_id: &str) -> Result<()> {
    let row: Option<(String, String)> = transaction
        .query_row(
            "SELECT run_token_id, status FROM workflow_runs WHERE run_id = ?1",
            [run_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    match row {
        Some((stored_token, status))
            if stored_token == token_id && matches!(status.as_str(), "running" | "cancelling") =>
        {
            Ok(())
        }
        Some((stored_token, _)) if stored_token != token_id => lifecycle("run_token_mismatch"),
        Some(_) => lifecycle("run_already_settled"),
        None => lifecycle("run_token_missing"),
    }
}

fn require_execution_token(
    transaction: &Transaction<'_>,
    run_id: &str,
    run_token_id: &str,
    execution_token_id: &str,
    require_active: bool,
) -> Result<()> {
    if execution_token_id.is_empty() {
        let token_count: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM workflow_execution_tokens WHERE run_id = ?1",
            [run_id],
            |row| row.get(0),
        )?;
        return if token_count == 0 {
            Ok(())
        } else {
            lifecycle("execution_token_missing")
        };
    }
    let row: Option<(String, String, String)> = transaction
        .query_row(
            "SELECT run_id, run_token_id, status FROM workflow_execution_tokens
             WHERE execution_token_id = ?1",
            [execution_token_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    match row {
        Some((stored_run, stored_run_token, status))
            if stored_run == run_id
                && stored_run_token == run_token_id
                && (!require_active || status == "active") =>
        {
            Ok(())
        }
        Some(_) => lifecycle("execution_token_mismatch"),
        None => lifecycle("execution_token_missing"),
    }
}

fn require_active_attempt(
    transaction: &Transaction<'_>,
    run_id: &str,
    token_id: &str,
    attempt_id: &str,
    node_id: &str,
    attempt_number: Option<u32>,
    execution_token_id: Option<&str>,
) -> Result<()> {
    require_active_run(transaction, run_id, token_id)?;
    let row: Option<(String, String, String, i64, String, String)> = transaction
        .query_row(
            "SELECT run_id, run_token_id, node_id, attempt_number, status, execution_token_id
             FROM workflow_attempts WHERE attempt_id = ?1",
            [attempt_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .optional()?;
    let Some((
        stored_run,
        stored_token,
        stored_node,
        stored_number,
        status,
        stored_execution_token,
    )) = row
    else {
        return lifecycle("attempt_missing");
    };
    if stored_run != run_id
        || stored_token != token_id
        || stored_node != node_id
        || execution_token_id.is_some_and(|value| value != stored_execution_token)
    {
        return lifecycle("attempt_identity_mismatch");
    }
    if attempt_number.is_some_and(|number| i64::from(number) != stored_number) {
        return lifecycle("attempt_number_mismatch");
    }
    if status != "running" {
        return lifecycle("attempt_already_settled");
    }
    Ok(())
}

fn touch_run(transaction: &Transaction<'_>, run_id: &str, store_position: u64) -> Result<()> {
    transaction.execute(
        "UPDATE workflow_runs SET last_store_position = ?1 WHERE run_id = ?2",
        params![sql_u64(store_position)?, run_id],
    )?;
    Ok(())
}

fn insert_value(transaction: &Transaction<'_>, value: &v1::WorkflowValueReference) -> Result<()> {
    let inline =
        (!value.inline_canonical_json.is_empty()).then_some(value.inline_canonical_json.as_slice());
    let storage =
        (!value.storage_reference_id.is_empty()).then_some(value.storage_reference_id.as_str());
    let metadata = value.storage.as_ref();
    transaction.execute(
        "INSERT OR IGNORE INTO workflow_values
         (value_id, content_type, byte_count, sha256, inline_canonical_json, storage_reference_id,
          storage_handle_id, storage_scope, storage_logical_key, storage_version_id,
          storage_revision, storage_previous_version_id, storage_source_version_id, storage_result)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            value.value_id,
            value.content_type,
            sql_u64(value.byte_count)?,
            value.sha256,
            inline,
            storage,
            metadata.map(|value| value.handle_id.as_str()),
            metadata.map(|value| value.scope.as_str()),
            metadata.map(|value| value.logical_key.as_str()),
            metadata.map(|value| value.version_id.as_str()),
            metadata.map(|value| sql_u64(value.revision)).transpose()?,
            metadata.and_then(|value| (!value.previous_version_id.is_empty())
                .then_some(value.previous_version_id.as_str())),
            metadata.and_then(|value| (!value.source_version_id.is_empty())
                .then_some(value.source_version_id.as_str())),
            metadata.map(|value| value.result.as_str()),
        ],
    )?;
    type StoredValue = (
        String,
        i64,
        String,
        Option<Vec<u8>>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<String>,
    );
    let stored: StoredValue = transaction.query_row(
        "SELECT content_type, byte_count, sha256, inline_canonical_json, storage_reference_id,
                storage_handle_id, storage_scope, storage_logical_key, storage_version_id,
                storage_revision, storage_previous_version_id, storage_source_version_id,
                storage_result
         FROM workflow_values WHERE value_id = ?1",
        [&value.value_id],
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
                row.get(10)?,
                row.get(11)?,
                row.get(12)?,
            ))
        },
    )?;
    if stored.0 != value.content_type
        || stored.1 != sql_u64(value.byte_count)?
        || stored.2 != value.sha256
        || stored.3.as_deref() != inline
        || stored.4.as_deref() != storage
        || stored.5.as_deref() != metadata.map(|value| value.handle_id.as_str())
        || stored.6.as_deref() != metadata.map(|value| value.scope.as_str())
        || stored.7.as_deref() != metadata.map(|value| value.logical_key.as_str())
        || stored.8.as_deref() != metadata.map(|value| value.version_id.as_str())
        || stored.9 != metadata.map(|value| sql_u64(value.revision)).transpose()?
        || stored.10.as_deref()
            != metadata.and_then(|value| {
                (!value.previous_version_id.is_empty())
                    .then_some(value.previous_version_id.as_str())
            })
        || stored.11.as_deref()
            != metadata.and_then(|value| {
                (!value.source_version_id.is_empty()).then_some(value.source_version_id.as_str())
            })
        || stored.12.as_deref() != metadata.map(|value| value.result.as_str())
    {
        return lifecycle("value_identity_reused");
    }
    Ok(())
}

fn insert_optional_value(
    transaction: &Transaction<'_>,
    value: Option<&v1::WorkflowValueReference>,
) -> Result<Option<String>> {
    value
        .map(|value| {
            insert_value(transaction, value)?;
            Ok(value.value_id.clone())
        })
        .transpose()
}

fn emission_ids_for_attempt(
    transaction: &Transaction<'_>,
    attempt_id: &str,
) -> Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT emission_id FROM workflow_emissions WHERE attempt_id = ?1 ORDER BY store_position",
    )?;
    let rows = statement.query_map([attempt_id], |row| row.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

enum OutcomeDomain {
    Attempt,
    Run,
}

fn settled_outcome(value: i32, domain: OutcomeDomain) -> Result<(&'static str, &'static str)> {
    let label = match domain {
        OutcomeDomain::Attempt => match v1::WorkflowAttemptOutcome::try_from(value) {
            Ok(v1::WorkflowAttemptOutcome::Succeeded) => "succeeded",
            Ok(v1::WorkflowAttemptOutcome::Failed) => "failed",
            Ok(v1::WorkflowAttemptOutcome::Cancelled) => "cancelled",
            _ => return lifecycle("attempt_outcome_invalid"),
        },
        OutcomeDomain::Run => match v1::WorkflowRunOutcome::try_from(value) {
            Ok(v1::WorkflowRunOutcome::Succeeded) => "succeeded",
            Ok(v1::WorkflowRunOutcome::Failed) => "failed",
            Ok(v1::WorkflowRunOutcome::Cancelled) => "cancelled",
            _ => return lifecycle("run_outcome_invalid"),
        },
    };
    Ok((label, label))
}

fn string_list_json(values: &[String]) -> Result<String> {
    serde_json::to_string(values)
        .map_err(|_| WorkflowProjectionError::Integrity("string_list_encode_failed".into()))
}

fn lifecycle<T>(code: &'static str) -> Result<T> {
    Err(WorkflowProjectionError::Lifecycle(code.into()))
}

fn quick_check(connection: &Connection) -> Result<()> {
    let status: String = connection.pragma_query_value(None, "quick_check", |row| row.get(0))?;
    if status != "ok" {
        return Err(WorkflowProjectionError::Integrity(
            "sqlite_quick_check".into(),
        ));
    }
    Ok(())
}

fn table_has_column(connection: &Connection, table: &str, expected_column: &str) -> Result<bool> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
    for column in columns {
        if column? == expected_column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn refresh_state_digest(connection: &Connection) -> Result<()> {
    let bytes = canonical_state_bytes(connection)?;
    let digest = hex::encode(Sha256::digest(bytes));
    connection.execute(
        "UPDATE workflow_projection_meta SET state_digest = ?1 WHERE singleton = 1",
        [digest],
    )?;
    Ok(())
}

fn canonical_state_bytes(connection: &Connection) -> Result<Vec<u8>> {
    let high_water: i64 = connection.query_row(
        "SELECT high_water_mark FROM workflow_projection_meta WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let state = CanonicalProjectionState {
        schema_version: PROJECTION_SCHEMA_VERSION,
        high_water_mark: u64::try_from(high_water)
            .map_err(|_| WorkflowProjectionError::Integrity("negative_high_water_mark".into()))?,
        tables: vec![
            table_rows(
                connection,
                "values",
                "SELECT value_id, content_type, byte_count, sha256, inline_canonical_json, storage_reference_id, storage_handle_id, storage_scope, storage_logical_key, storage_version_id, storage_revision, storage_previous_version_id, storage_source_version_id, storage_result FROM workflow_values ORDER BY value_id",
                14,
            )?,
            table_rows(
                connection,
                "runs",
                "SELECT run_id, run_token_id, request_command_id, workflow_id, revision_id, package_digest, status, outcome, error_code, error_value_id, final_emission_ids_json, cancellation_command_id, cancellation_reason_code, created_at_unix_millis, settled_at_unix_millis, first_store_position, last_store_position FROM workflow_runs ORDER BY run_id",
                17,
            )?,
            table_rows(
                connection,
                "attempts",
                "SELECT attempt_id, run_id, run_token_id, execution_token_id, node_id, attempt_number, status, outcome, error_code, error_value_id, emission_ids_json, started_at_unix_millis, settled_at_unix_millis, started_store_position, settled_store_position FROM workflow_attempts ORDER BY run_id, execution_token_id, node_id, attempt_number, attempt_id",
                15,
            )?,
            table_rows(
                connection,
                "nodes",
                "SELECT run_id, node_id, status, latest_attempt_id, latest_attempt_number, started_at_unix_millis, settled_at_unix_millis, last_store_position FROM workflow_node_states ORDER BY run_id, node_id",
                8,
            )?,
            table_rows(
                connection,
                "emissions",
                "SELECT emission_id, run_id, attempt_id, execution_token_id, node_id, port_id, value_id, event_id, emitted_at_unix_millis, store_position FROM workflow_emissions ORDER BY run_id, store_position, emission_id",
                10,
            )?,
            table_rows(
                connection,
                "edges",
                "SELECT event_id, run_id, execution_token_id, edge_id, emission_id, target_node_id, target_port_id, state, checkpointed_at_unix_millis, store_position FROM workflow_edge_checkpoints ORDER BY run_id, store_position, event_id",
                10,
            )?,
            table_rows(
                connection,
                "matches",
                "SELECT event_id, run_id, attempt_id, execution_token_id, node_id, input_value_id, evaluated_case_ids_json, matched_case_ids_json, emitted_port_ids_json, trace_value_id, recorded_at_unix_millis, store_position FROM workflow_match_traces ORDER BY run_id, store_position, event_id",
                12,
            )?,
            table_rows(
                connection,
                "tokens",
                "SELECT execution_token_id, run_id, run_token_id, parent_execution_token_id, fork_node_id, branch_id, branch_port_id, join_node_id, source_emission_id, status, outcome, terminal_node_id, error_code, error_value_id, final_emission_ids_json, created_event_id, settled_event_id, created_at_unix_millis, settled_at_unix_millis, created_store_position, settled_store_position FROM workflow_execution_tokens ORDER BY run_id, created_store_position, execution_token_id",
                21,
            )?,
            table_rows(
                connection,
                "joins",
                "SELECT event_id, run_id, join_node_id, fork_node_id, resumed_execution_token_id, policy, threshold, decision, expected_execution_token_ids_json, arrived_execution_token_ids_json, failed_execution_token_ids_json, pending_execution_token_ids_json, cancel_remaining, error_code, evaluated_at_unix_millis, store_position FROM workflow_join_evaluations ORDER BY run_id, store_position, event_id",
                16,
            )?,
            table_rows(
                connection,
                "events",
                "SELECT event_id, run_id, kind, store_position, stream_sequence, occurred_at_unix_millis FROM workflow_projected_events ORDER BY store_position, event_id",
                6,
            )?,
        ],
    };
    serde_json::to_vec(&state)
        .map_err(|_| WorkflowProjectionError::Integrity("state_encode_failed".into()))
}

fn table_rows(
    connection: &Connection,
    name: &'static str,
    sql: &'static str,
    column_count: usize,
) -> Result<CanonicalTable> {
    use rusqlite::types::{Type, ValueRef};
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map([], |row| {
        let mut values = Vec::with_capacity(column_count);
        for index in 0..column_count {
            let value = match row.get_ref(index)? {
                ValueRef::Null => None,
                ValueRef::Integer(value) => Some(value.to_string()),
                ValueRef::Real(value) => Some(value.to_string()),
                ValueRef::Text(value) => Some(
                    std::str::from_utf8(value)
                        .map_err(|error| {
                            rusqlite::Error::FromSqlConversionFailure(
                                index,
                                Type::Text,
                                Box::new(error),
                            )
                        })?
                        .to_owned(),
                ),
                ValueRef::Blob(value) => Some(hex::encode(value)),
            };
            values.push(value);
        }
        Ok(values)
    })?;
    Ok(CanonicalTable {
        name,
        rows: rows.collect::<std::result::Result<_, _>>()?,
    })
}

fn sql_u64(value: u64) -> Result<i64> {
    i64::try_from(value).map_err(|_| WorkflowProjectionError::Integrity("integer_overflow".into()))
}

fn quarantine_projection_files(path: &Path) -> Result<PathBuf> {
    prepare_database_path(path)
        .map_err(|error| WorkflowProjectionError::Setup(error.to_string()))?;
    if !path.exists() {
        return Err(WorkflowProjectionError::Integrity(
            "corrupt_projection_missing".into(),
        ));
    }
    let file_name = path
        .file_name()
        .ok_or_else(|| WorkflowProjectionError::Setup("database_name_missing".into()))?;
    for sequence in 1..=100 {
        let mut quarantine_name = OsString::from(file_name);
        quarantine_name.push(format!(".corrupt-{sequence:02}"));
        let quarantine_path = path.with_file_name(quarantine_name);
        if quarantine_path.exists() {
            continue;
        }
        fs::rename(path, &quarantine_path)
            .map_err(|error| WorkflowProjectionError::Setup(error.to_string()))?;
        for suffix in ["-wal", "-shm"] {
            let source = sidecar_path(path, suffix)?;
            if source.exists() {
                let target = sidecar_path(&quarantine_path, suffix)?;
                fs::rename(source, target)
                    .map_err(|error| WorkflowProjectionError::Setup(error.to_string()))?;
            }
        }
        return Ok(quarantine_path);
    }
    Err(WorkflowProjectionError::Integrity(
        "projection_quarantine_exhausted".into(),
    ))
}

fn sidecar_path(path: &Path, suffix: &str) -> Result<PathBuf> {
    let file_name = path
        .file_name()
        .ok_or_else(|| WorkflowProjectionError::Setup("database_name_missing".into()))?;
    let mut sidecar_name = OsString::from(file_name);
    sidecar_name.push(suffix);
    Ok(path.with_file_name(sidecar_name))
}
