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
    workflow_retention::WorkflowRunRetentionPolicy,
    workflow_runtime::{self, WorkflowRuntimeEvent},
};
use prost::Message;
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    fmt, fs,
    path::{Path, PathBuf},
    time::Duration,
};

const PROJECTION_SCHEMA_VERSION: i64 = 13;
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
    retention_mode TEXT NOT NULL DEFAULT 'duration'
        CHECK (retention_mode IN ('duration', 'delete-after-success', 'forever')),
    retention_days INTEGER NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 0 AND 3650),
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
    iteration_node_id TEXT,
    iteration_index INTEGER,
    iteration_count INTEGER,
    resume_node_id TEXT,
    resume_reason TEXT,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed', 'cancelled', 'forked', 'joined', 'iterated')),
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
    UNIQUE(run_id, fork_node_id, branch_id),
    UNIQUE(run_id, iteration_node_id, iteration_index, parent_execution_token_id)
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

CREATE TABLE workflow_iterations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    iteration_node_id TEXT NOT NULL,
    parent_execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    input_value_id TEXT NOT NULL,
    input_sha256 TEXT NOT NULL CHECK (length(input_sha256) = 64),
    item_count INTEGER NOT NULL CHECK (item_count BETWEEN 0 AND 256),
    maximum_items INTEGER NOT NULL CHECK (maximum_items BETWEEN 1 AND 256),
    maximum_concurrency INTEGER NOT NULL CHECK (maximum_concurrency BETWEEN 1 AND 64),
    failure_policy TEXT NOT NULL CHECK (failure_policy IN ('fail-fast', 'collect')),
    decision TEXT CHECK (decision IN ('succeeded', 'failed')),
    resumed_execution_token_id TEXT,
    expected_execution_token_ids_json TEXT,
    succeeded_execution_token_ids_json TEXT,
    failed_execution_token_ids_json TEXT,
    pending_execution_token_ids_json TEXT,
    error_code TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    planned_at_unix_millis INTEGER NOT NULL CHECK (planned_at_unix_millis >= 0),
    evaluated_at_unix_millis INTEGER,
    planned_store_position INTEGER NOT NULL UNIQUE CHECK (planned_store_position > 0),
    evaluated_store_position INTEGER UNIQUE,
    UNIQUE(run_id, iteration_node_id, parent_execution_token_id)
) STRICT;
CREATE INDEX workflow_iterations_run_position
    ON workflow_iterations(run_id, planned_store_position, event_id);

CREATE TABLE workflow_retry_evaluations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    retry_node_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    failed_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    target_node_id TEXT NOT NULL,
    error_code TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('scheduled', 'exhausted', 'not-retryable', 'unknown-outcome')),
    next_attempt_number INTEGER NOT NULL CHECK (next_attempt_number > 1),
    maximum_attempts INTEGER NOT NULL CHECK (maximum_attempts BETWEEN 1 AND 100),
    delay_milliseconds INTEGER NOT NULL CHECK (delay_milliseconds >= 0),
    eligible_at_unix_millis INTEGER,
    retry_input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    evaluated_at_unix_millis INTEGER NOT NULL CHECK (evaluated_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;
CREATE INDEX workflow_retry_evaluations_run_position
    ON workflow_retry_evaluations(run_id, store_position, event_id);

CREATE TABLE workflow_wait_signals (
    signal_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    signal_command_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('event', 'reply')),
    owner_kind TEXT NOT NULL CHECK (owner_kind IN ('case', 'installation', 'workflow')),
    owner_id TEXT NOT NULL,
    correlation_json TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    recorded_at_unix_millis INTEGER NOT NULL CHECK (recorded_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, signal_id)
) STRICT;
CREATE INDEX workflow_wait_signals_run_position
    ON workflow_wait_signals(run_id, store_position, signal_id);

CREATE TABLE workflow_waits (
    subscription_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    wait_node_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    kind TEXT NOT NULL CHECK (kind IN ('timer', 'event', 'reply')),
    owner_kind TEXT NOT NULL CHECK (owner_kind IN ('case', 'installation', 'workflow')),
    owner_id TEXT NOT NULL,
    correlation_json TEXT NOT NULL,
    input_value_id TEXT NOT NULL,
    input_sha256 TEXT NOT NULL CHECK (length(input_sha256) = 64),
    status TEXT NOT NULL CHECK (status IN ('waiting', 'resumed', 'expired', 'cancelled')),
    decision TEXT CHECK (decision IN ('resumed', 'expired', 'cancelled')),
    resolving_signal_id TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    reason_code TEXT,
    expires_at_unix_millis INTEGER NOT NULL CHECK (expires_at_unix_millis > 0),
    subscribed_store_position INTEGER NOT NULL UNIQUE CHECK (subscribed_store_position > 0),
    resolved_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX workflow_waits_run_position
    ON workflow_waits(run_id, subscribed_store_position, subscription_id);

CREATE TABLE workflow_cases (
    installation_id TEXT NOT NULL,
    case_id TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    first_episode_id TEXT NOT NULL,
    last_episode_id TEXT NOT NULL,
    episode_count INTEGER NOT NULL CHECK (episode_count > 0),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= created_at_unix_millis),
    first_store_position INTEGER NOT NULL UNIQUE CHECK (first_store_position > 0),
    last_store_position INTEGER NOT NULL CHECK (last_store_position >= first_store_position),
    PRIMARY KEY(installation_id, case_id)
) STRICT;

CREATE TABLE workflow_episodes (
    episode_id TEXT PRIMARY KEY,
    installation_id TEXT NOT NULL,
    case_id TEXT NOT NULL,
    run_id TEXT NOT NULL UNIQUE REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    kind TEXT NOT NULL CHECK (kind IN ('initial', 'delivery', 'correction', 'redelivery')),
    prior_episode_id TEXT,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    trigger_kind TEXT NOT NULL,
    trigger_event_id TEXT,
    compiled_context_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    source_episode_ids_json TEXT NOT NULL,
    source_event_ids_json TEXT NOT NULL,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    UNIQUE(installation_id, case_id, ordinal),
    FOREIGN KEY(installation_id, case_id) REFERENCES workflow_cases(installation_id, case_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX workflow_episodes_case_ordinal
    ON workflow_episodes(installation_id, case_id, ordinal, episode_id);

CREATE TABLE workflow_episode_inputs (
    episode_id TEXT NOT NULL REFERENCES workflow_episodes(episode_id) ON DELETE CASCADE,
    port_id TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY(episode_id, port_id),
    UNIQUE(episode_id, ordinal)
) STRICT;

CREATE TABLE workflow_subflows (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    child_run_id TEXT NOT NULL UNIQUE,
    child_command_id TEXT NOT NULL,
    child_workflow_id TEXT NOT NULL,
    child_revision_id TEXT NOT NULL,
    child_package_id TEXT NOT NULL,
    child_package_digest TEXT NOT NULL CHECK (length(child_package_digest) = 64),
    entrypoint TEXT NOT NULL,
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('called', 'settled')),
    outcome TEXT CHECK (outcome IN ('succeeded', 'failed', 'cancelled')),
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    child_final_emission_ids_json TEXT,
    called_at_unix_millis INTEGER NOT NULL CHECK (called_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    called_store_position INTEGER NOT NULL UNIQUE CHECK (called_store_position > 0),
    settled_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX workflow_subflows_run_position
    ON workflow_subflows(run_id, called_store_position, invocation_id);

CREATE TABLE workflow_capability_attempts (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    capability_id TEXT NOT NULL,
    version TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    configuration_contract_digest TEXT NOT NULL CHECK (length(configuration_contract_digest) = 64),
    input_schema_digest TEXT NOT NULL CHECK (length(input_schema_digest) = 64),
    output_schema_digest TEXT NOT NULL CHECK (length(output_schema_digest) = 64),
    output_schema_ref TEXT NOT NULL,
    configuration_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    artifact_inputs_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'settled')),
    outcome TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    artifact_outputs_json TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    logs_json TEXT,
    timeout_milliseconds INTEGER NOT NULL CHECK (timeout_milliseconds > 0),
    deadline_unix_millis INTEGER NOT NULL CHECK (deadline_unix_millis >= 0),
    elapsed_milliseconds INTEGER,
    receipt_id TEXT,
    provider_run_reference TEXT,
    idempotency_key TEXT,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    settled_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX workflow_capability_attempts_run_position
    ON workflow_capability_attempts(run_id, started_store_position, invocation_id);

CREATE TABLE workflow_llm_attempts (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    settings_wire BLOB NOT NULL,
    context_digest TEXT NOT NULL CHECK (length(context_digest) = 64),
    context_groups_json TEXT NOT NULL,
    messages_json TEXT NOT NULL,
    prior_episode_ids_json TEXT NOT NULL,
    attachments_json TEXT NOT NULL,
    compilation_report_wire BLOB NOT NULL,
    output_schema_ref TEXT NOT NULL,
    output_schema_digest TEXT NOT NULL CHECK (length(output_schema_digest) = 64),
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('running', 'settled')),
    outcome TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    timeout_milliseconds INTEGER NOT NULL CHECK (timeout_milliseconds > 0),
    deadline_unix_millis INTEGER NOT NULL CHECK (deadline_unix_millis >= 0),
    elapsed_milliseconds INTEGER,
    receipt_id TEXT,
    provider_run_reference TEXT,
    idempotency_key TEXT,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    settled_store_position INTEGER UNIQUE,
    tool_definitions_json TEXT NOT NULL,
    tool_calls_json TEXT,
    response_messages_json TEXT,
    usage_wire BLOB,
    validation_wire BLOB,
    provider_receipt_wire BLOB
) STRICT;
CREATE INDEX workflow_llm_attempts_run_position
    ON workflow_llm_attempts(run_id, started_store_position, invocation_id);

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

CREATE TABLE workflow_run_purge_receipts (
    run_id TEXT PRIMARY KEY,
    purge_event_id TEXT NOT NULL UNIQUE,
    purge_command_id TEXT NOT NULL UNIQUE,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    mode TEXT NOT NULL CHECK (mode IN ('manual', 'automatic')),
    preview_evidence_digest TEXT NOT NULL CHECK (length(preview_evidence_digest) = 64),
    source_first_store_position INTEGER NOT NULL CHECK (source_first_store_position > 0),
    source_last_store_position INTEGER NOT NULL CHECK (source_last_store_position >= source_first_store_position),
    source_event_count INTEGER NOT NULL CHECK (source_event_count > 0),
    affected_attempt_count INTEGER NOT NULL CHECK (affected_attempt_count >= 0),
    affected_value_count INTEGER NOT NULL CHECK (affected_value_count >= 0),
    affected_file_handle_count INTEGER NOT NULL CHECK (affected_file_handle_count >= 0),
    retained_promoted_handle_ids_json TEXT NOT NULL,
    affected_value_bytes INTEGER NOT NULL CHECK (affected_value_bytes >= 0),
    installation_id TEXT NOT NULL,
    historical_revision_retained INTEGER NOT NULL CHECK (historical_revision_retained = 1),
    purged_at_unix_millis INTEGER NOT NULL CHECK (purged_at_unix_millis >= 0),
    purge_store_position INTEGER NOT NULL UNIQUE CHECK (purge_store_position > source_last_store_position)
) STRICT;
"#;

const PROJECTION_MIGRATION_13: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_run_purge_receipts (
    run_id TEXT PRIMARY KEY,
    purge_event_id TEXT NOT NULL UNIQUE,
    purge_command_id TEXT NOT NULL UNIQUE,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    mode TEXT NOT NULL CHECK (mode IN ('manual', 'automatic')),
    preview_evidence_digest TEXT NOT NULL CHECK (length(preview_evidence_digest) = 64),
    source_first_store_position INTEGER NOT NULL CHECK (source_first_store_position > 0),
    source_last_store_position INTEGER NOT NULL CHECK (source_last_store_position >= source_first_store_position),
    source_event_count INTEGER NOT NULL CHECK (source_event_count > 0),
    affected_attempt_count INTEGER NOT NULL CHECK (affected_attempt_count >= 0),
    affected_value_count INTEGER NOT NULL CHECK (affected_value_count >= 0),
    affected_file_handle_count INTEGER NOT NULL CHECK (affected_file_handle_count >= 0),
    retained_promoted_handle_ids_json TEXT NOT NULL,
    affected_value_bytes INTEGER NOT NULL CHECK (affected_value_bytes >= 0),
    installation_id TEXT NOT NULL,
    historical_revision_retained INTEGER NOT NULL CHECK (historical_revision_retained = 1),
    purged_at_unix_millis INTEGER NOT NULL CHECK (purged_at_unix_millis >= 0),
    purge_store_position INTEGER NOT NULL UNIQUE CHECK (purge_store_position > source_last_store_position)
) STRICT;
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

// v5 adds iteration/retry projections and widens token lineage. Projection
// rows are disposable, so v4 is reset and replayed rather than mutated into a
// partially constrained hybrid. The authoritative journal is untouched.
const PROJECTION_MIGRATION_5_RESET: &str = r#"
DROP TABLE IF EXISTS workflow_retry_evaluations;
DROP TABLE IF EXISTS workflow_iterations;
DELETE FROM workflow_projected_events;
DELETE FROM workflow_match_traces;
DELETE FROM workflow_edge_checkpoints;
DELETE FROM workflow_emissions;
DELETE FROM workflow_node_states;
DELETE FROM workflow_attempts;
DELETE FROM workflow_join_evaluations;
DELETE FROM workflow_execution_tokens;
DELETE FROM workflow_runs;
DELETE FROM workflow_values;
UPDATE workflow_projection_meta SET high_water_mark = 0 WHERE singleton = 1;

DROP TABLE workflow_execution_tokens;
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
    iteration_node_id TEXT,
    iteration_index INTEGER,
    iteration_count INTEGER,
    resume_node_id TEXT,
    resume_reason TEXT,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed', 'cancelled', 'forked', 'joined', 'iterated')),
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
    UNIQUE(run_id, fork_node_id, branch_id),
    UNIQUE(run_id, iteration_node_id, iteration_index, parent_execution_token_id)
) STRICT;
CREATE INDEX workflow_execution_tokens_run_position
    ON workflow_execution_tokens(run_id, created_store_position, execution_token_id);

CREATE TABLE workflow_iterations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    iteration_node_id TEXT NOT NULL,
    parent_execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    input_value_id TEXT NOT NULL,
    input_sha256 TEXT NOT NULL CHECK (length(input_sha256) = 64),
    item_count INTEGER NOT NULL CHECK (item_count BETWEEN 0 AND 256),
    maximum_items INTEGER NOT NULL CHECK (maximum_items BETWEEN 1 AND 256),
    maximum_concurrency INTEGER NOT NULL CHECK (maximum_concurrency BETWEEN 1 AND 64),
    failure_policy TEXT NOT NULL CHECK (failure_policy IN ('fail-fast', 'collect')),
    decision TEXT CHECK (decision IN ('succeeded', 'failed')),
    resumed_execution_token_id TEXT,
    expected_execution_token_ids_json TEXT,
    succeeded_execution_token_ids_json TEXT,
    failed_execution_token_ids_json TEXT,
    pending_execution_token_ids_json TEXT,
    error_code TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    planned_at_unix_millis INTEGER NOT NULL CHECK (planned_at_unix_millis >= 0),
    evaluated_at_unix_millis INTEGER,
    planned_store_position INTEGER NOT NULL UNIQUE CHECK (planned_store_position > 0),
    evaluated_store_position INTEGER UNIQUE,
    UNIQUE(run_id, iteration_node_id, parent_execution_token_id)
) STRICT;
CREATE INDEX workflow_iterations_run_position
    ON workflow_iterations(run_id, planned_store_position, event_id);

CREATE TABLE workflow_retry_evaluations (
    event_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    retry_node_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    failed_attempt_id TEXT NOT NULL REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    target_node_id TEXT NOT NULL,
    error_code TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('scheduled', 'exhausted', 'not-retryable', 'unknown-outcome')),
    next_attempt_number INTEGER NOT NULL CHECK (next_attempt_number > 1),
    maximum_attempts INTEGER NOT NULL CHECK (maximum_attempts BETWEEN 1 AND 100),
    delay_milliseconds INTEGER NOT NULL CHECK (delay_milliseconds >= 0),
    eligible_at_unix_millis INTEGER,
    retry_input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    evaluated_at_unix_millis INTEGER NOT NULL CHECK (evaluated_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0)
) STRICT;
CREATE INDEX workflow_retry_evaluations_run_position
    ON workflow_retry_evaluations(run_id, store_position, event_id);
"#;

const PROJECTION_MIGRATION_6: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_wait_signals (
    signal_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    signal_command_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('event', 'reply')),
    owner_kind TEXT NOT NULL CHECK (owner_kind IN ('case', 'installation', 'workflow')),
    owner_id TEXT NOT NULL,
    correlation_json TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    recorded_at_unix_millis INTEGER NOT NULL CHECK (recorded_at_unix_millis >= 0),
    store_position INTEGER NOT NULL UNIQUE CHECK (store_position > 0),
    UNIQUE(run_id, signal_id)
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_wait_signals_run_position
    ON workflow_wait_signals(run_id, store_position, signal_id);

CREATE TABLE IF NOT EXISTS workflow_waits (
    subscription_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    wait_node_id TEXT NOT NULL,
    execution_token_id TEXT NOT NULL,
    controller_attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    kind TEXT NOT NULL CHECK (kind IN ('timer', 'event', 'reply')),
    owner_kind TEXT NOT NULL CHECK (owner_kind IN ('case', 'installation', 'workflow')),
    owner_id TEXT NOT NULL,
    correlation_json TEXT NOT NULL,
    input_value_id TEXT NOT NULL,
    input_sha256 TEXT NOT NULL CHECK (length(input_sha256) = 64),
    status TEXT NOT NULL CHECK (status IN ('waiting', 'resumed', 'expired', 'cancelled')),
    decision TEXT CHECK (decision IN ('resumed', 'expired', 'cancelled')),
    resolving_signal_id TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    reason_code TEXT,
    expires_at_unix_millis INTEGER NOT NULL CHECK (expires_at_unix_millis > 0),
    subscribed_store_position INTEGER NOT NULL UNIQUE CHECK (subscribed_store_position > 0),
    resolved_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_waits_run_position
    ON workflow_waits(run_id, subscribed_store_position, subscription_id);
"#;

const PROJECTION_MIGRATION_7: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_cases (
    installation_id TEXT NOT NULL,
    case_id TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    first_episode_id TEXT NOT NULL,
    last_episode_id TEXT NOT NULL,
    episode_count INTEGER NOT NULL CHECK (episode_count > 0),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= created_at_unix_millis),
    first_store_position INTEGER NOT NULL UNIQUE CHECK (first_store_position > 0),
    last_store_position INTEGER NOT NULL CHECK (last_store_position >= first_store_position),
    PRIMARY KEY(installation_id, case_id)
) STRICT;
CREATE TABLE IF NOT EXISTS workflow_episodes (
    episode_id TEXT PRIMARY KEY,
    installation_id TEXT NOT NULL,
    case_id TEXT NOT NULL,
    run_id TEXT NOT NULL UNIQUE REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    run_token_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal > 0),
    kind TEXT NOT NULL CHECK (kind IN ('initial', 'delivery', 'correction', 'redelivery')),
    prior_episode_id TEXT,
    workflow_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    trigger_kind TEXT NOT NULL,
    trigger_event_id TEXT,
    compiled_context_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    source_episode_ids_json TEXT NOT NULL,
    source_event_ids_json TEXT NOT NULL,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    UNIQUE(installation_id, case_id, ordinal),
    FOREIGN KEY(installation_id, case_id) REFERENCES workflow_cases(installation_id, case_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_episodes_case_ordinal
    ON workflow_episodes(installation_id, case_id, ordinal, episode_id);
CREATE TABLE IF NOT EXISTS workflow_episode_inputs (
    episode_id TEXT NOT NULL REFERENCES workflow_episodes(episode_id) ON DELETE CASCADE,
    port_id TEXT NOT NULL,
    value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY(episode_id, port_id),
    UNIQUE(episode_id, ordinal)
) STRICT;
"#;

const PROJECTION_MIGRATION_8: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_subflows (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    child_run_id TEXT NOT NULL UNIQUE,
    child_command_id TEXT NOT NULL,
    child_workflow_id TEXT NOT NULL,
    child_revision_id TEXT NOT NULL,
    child_package_id TEXT NOT NULL,
    child_package_digest TEXT NOT NULL CHECK (length(child_package_digest) = 64),
    entrypoint TEXT NOT NULL,
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('called', 'settled')),
    outcome TEXT CHECK (outcome IN ('succeeded', 'failed', 'cancelled')),
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    child_final_emission_ids_json TEXT,
    called_at_unix_millis INTEGER NOT NULL CHECK (called_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    called_store_position INTEGER NOT NULL UNIQUE CHECK (called_store_position > 0),
    settled_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_subflows_run_position
    ON workflow_subflows(run_id, called_store_position, invocation_id);
"#;

const PROJECTION_MIGRATION_9: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_capability_attempts (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    capability_id TEXT NOT NULL,
    version TEXT NOT NULL,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    configuration_contract_digest TEXT NOT NULL CHECK (length(configuration_contract_digest) = 64),
    input_schema_digest TEXT NOT NULL CHECK (length(input_schema_digest) = 64),
    output_schema_digest TEXT NOT NULL CHECK (length(output_schema_digest) = 64),
    output_schema_ref TEXT NOT NULL,
    configuration_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    artifact_inputs_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('running', 'settled')),
    outcome TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    artifact_outputs_json TEXT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    logs_json TEXT,
    timeout_milliseconds INTEGER NOT NULL CHECK (timeout_milliseconds > 0),
    deadline_unix_millis INTEGER NOT NULL CHECK (deadline_unix_millis >= 0),
    elapsed_milliseconds INTEGER,
    receipt_id TEXT,
    provider_run_reference TEXT,
    idempotency_key TEXT,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    settled_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_capability_attempts_run_position
    ON workflow_capability_attempts(run_id, started_store_position, invocation_id);
"#;

const PROJECTION_MIGRATION_10: &str = r#"
CREATE TABLE IF NOT EXISTS workflow_llm_attempts (
    invocation_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES workflow_runs(run_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES workflow_attempts(attempt_id) ON DELETE CASCADE,
    execution_token_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    settings_wire BLOB NOT NULL,
    context_digest TEXT NOT NULL CHECK (length(context_digest) = 64),
    context_groups_json TEXT NOT NULL,
    messages_json TEXT NOT NULL,
    prior_episode_ids_json TEXT NOT NULL,
    attachments_json TEXT NOT NULL,
    compilation_report_wire BLOB NOT NULL,
    output_schema_ref TEXT NOT NULL,
    output_schema_digest TEXT NOT NULL CHECK (length(output_schema_digest) = 64),
    input_value_id TEXT NOT NULL REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    status TEXT NOT NULL CHECK (status IN ('running', 'settled')),
    outcome TEXT,
    output_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    error_code TEXT,
    error_value_id TEXT REFERENCES workflow_values(value_id) ON DELETE RESTRICT,
    timeout_milliseconds INTEGER NOT NULL CHECK (timeout_milliseconds > 0),
    deadline_unix_millis INTEGER NOT NULL CHECK (deadline_unix_millis >= 0),
    elapsed_milliseconds INTEGER,
    receipt_id TEXT,
    provider_run_reference TEXT,
    idempotency_key TEXT,
    started_at_unix_millis INTEGER NOT NULL CHECK (started_at_unix_millis >= 0),
    settled_at_unix_millis INTEGER,
    started_store_position INTEGER NOT NULL UNIQUE CHECK (started_store_position > 0),
    settled_store_position INTEGER UNIQUE
) STRICT;
CREATE INDEX IF NOT EXISTS workflow_llm_attempts_run_position
    ON workflow_llm_attempts(run_id, started_store_position, invocation_id);
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

#[derive(Deserialize, Serialize)]
struct CapabilityArtifactRecord {
    handle_id: String,
    role: String,
    value_id: String,
}

#[derive(Deserialize, Serialize)]
struct CapabilityLogRecord {
    sequence: u32,
    level: String,
    message: String,
    offset_milliseconds: u64,
}

#[derive(Deserialize, Serialize)]
struct LlmContextGroupRecord {
    group_id: String,
    kind: String,
    title: String,
    provenance: String,
    content_value_id: String,
    original_byte_count: u64,
    retained_byte_count: u64,
    redaction_count: u32,
    truncated: bool,
    source_episode_ids: Vec<String>,
}

#[derive(Deserialize, Serialize)]
struct LlmMessageRecord {
    message_id: String,
    sequence: u32,
    role: String,
    context_group_id: String,
    summary: String,
    content_value_id: String,
    estimated_tokens: u64,
    redaction_count: u32,
    truncated: bool,
}

#[derive(Deserialize, Serialize)]
struct LlmToolDefinitionRecord {
    tool_id: String,
    version: String,
    package_digest: String,
    description: String,
    input_schema_ref: String,
    input_schema_digest: String,
    output_schema_ref: String,
    output_schema_digest: String,
}

#[derive(Deserialize, Serialize)]
struct LlmToolCallRecord {
    call_id: String,
    sequence: u32,
    tool_id: String,
    status: String,
    input_value_id: String,
    output_value_id: Option<String>,
    error_code: String,
    error_value_id: Option<String>,
    duration_milliseconds: u64,
}

#[derive(Deserialize, Serialize)]
struct LlmResponseMessageRecord {
    message_id: String,
    sequence: u32,
    role: String,
    kind: String,
    summary: String,
    content_value_id: String,
    tool_call_id: String,
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
            transaction.pragma_update(None, "user_version", 4)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 4 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_5_RESET)?;
            transaction.pragma_update(None, "user_version", 5)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 5 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_6)?;
            transaction.execute_batch(PROJECTION_MIGRATION_7)?;
            transaction.execute_batch(PROJECTION_MIGRATION_8)?;
            transaction.execute_batch(PROJECTION_MIGRATION_9)?;
            transaction.execute_batch(PROJECTION_MIGRATION_10)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 6 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_7)?;
            transaction.execute_batch(PROJECTION_MIGRATION_8)?;
            transaction.execute_batch(PROJECTION_MIGRATION_9)?;
            transaction.execute_batch(PROJECTION_MIGRATION_10)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 7 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_8)?;
            transaction.execute_batch(PROJECTION_MIGRATION_9)?;
            transaction.execute_batch(PROJECTION_MIGRATION_10)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 8 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_9)?;
            transaction.execute_batch(PROJECTION_MIGRATION_10)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 9 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_10)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 10 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            apply_projection_migration_11(&transaction)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 11 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            apply_projection_migration_12(&transaction)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
            transaction.pragma_update(None, "user_version", PROJECTION_SCHEMA_VERSION)?;
            refresh_state_digest(&transaction)?;
            transaction.commit()?;
        }
        let found: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if found == 12 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(PROJECTION_MIGRATION_13)?;
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
                 LEFT JOIN workflow_iterations i ON i.run_id = r.run_id
                 LEFT JOIN workflow_execution_tokens iteration_resumed
                   ON iteration_resumed.execution_token_id = i.resumed_execution_token_id
                 LEFT JOIN workflow_waits w ON w.run_id = r.run_id
                 WHERE r.status IN ('succeeded', 'failed', 'cancelled')
                   AND ((t.source_emission_id IS NOT NULL AND e.emission_id IS NULL)
                     OR (j.event_id IS NOT NULL AND resumed.execution_token_id IS NULL)
                     OR (i.event_id IS NOT NULL AND i.decision IS NULL)
                     OR (i.event_id IS NOT NULL AND i.decision IS NOT NULL
                         AND iteration_resumed.execution_token_id IS NULL)
                     OR t.status = 'active'
                     OR w.status = 'waiting')
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
        let invalid_case_chain = self
            .connection
            .query_row(
                "SELECT 1 FROM workflow_cases c
                 WHERE c.episode_count != (
                     SELECT COUNT(*) FROM workflow_episodes e
                     WHERE e.installation_id = c.installation_id AND e.case_id = c.case_id)
                    OR c.first_episode_id != (
                     SELECT e.episode_id FROM workflow_episodes e
                     WHERE e.installation_id = c.installation_id AND e.case_id = c.case_id
                     ORDER BY e.ordinal LIMIT 1)
                    OR c.last_episode_id != (
                     SELECT e.episode_id FROM workflow_episodes e
                     WHERE e.installation_id = c.installation_id AND e.case_id = c.case_id
                     ORDER BY e.ordinal DESC LIMIT 1)
                    OR EXISTS (
                     SELECT 1 FROM workflow_episodes e
                     WHERE e.installation_id = c.installation_id AND e.case_id = c.case_id
                       AND ((e.ordinal = 1 AND (e.kind != 'initial' OR e.prior_episode_id IS NOT NULL))
                         OR (e.ordinal > 1 AND e.prior_episode_id != (
                           SELECT p.episode_id FROM workflow_episodes p
                           WHERE p.installation_id = e.installation_id AND p.case_id = e.case_id
                             AND p.ordinal = e.ordinal - 1)))
                    )
                 LIMIT 1",
                [],
                |_| Ok(()),
            )
            .optional()?;
        if invalid_case_chain.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "case_episode_chain_invalid".into(),
            ));
        }
        let invalid_subflow = self
            .connection
            .query_row(
                "SELECT 1 FROM workflow_subflows s
                 JOIN workflow_runs parent ON parent.run_id = s.run_id
                 LEFT JOIN workflow_runs child ON child.run_id = s.child_run_id
                 WHERE (s.status = 'called' AND parent.status != 'running')
                    OR (s.status = 'settled' AND (
                        child.run_id IS NULL
                        OR child.status = 'running'
                        OR child.workflow_id != s.child_workflow_id
                        OR child.revision_id != s.child_revision_id
                        OR child.package_digest != s.child_package_digest
                        OR child.outcome != s.outcome
                        OR s.settled_store_position IS NULL))
                 LIMIT 1",
                [],
                |_| Ok(()),
            )
            .optional()?;
        if invalid_subflow.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "subflow_projection_invalid".into(),
            ));
        }
        let invalid_capability = self
            .connection
            .query_row(
                "SELECT 1 FROM workflow_capability_attempts c
                 JOIN workflow_runs r ON r.run_id = c.run_id
                 JOIN workflow_attempts a ON a.attempt_id = c.attempt_id
                 WHERE c.node_id != a.node_id
                    OR c.execution_token_id != a.execution_token_id
                    OR (c.status = 'running' AND (a.status != 'running' OR r.status != 'running'))
                    OR (c.status = 'settled' AND (
                        c.outcome IS NULL
                        OR c.settled_store_position IS NULL
                        OR c.elapsed_milliseconds IS NULL
                        OR c.idempotency_key != c.invocation_id))
                 LIMIT 1",
                [],
                |_| Ok(()),
            )
            .optional()?;
        if invalid_capability.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "capability_projection_invalid".into(),
            ));
        }
        let invalid_llm = self
            .connection
            .query_row(
                "SELECT 1 FROM workflow_llm_attempts l
                 JOIN workflow_runs r ON r.run_id = l.run_id
                 JOIN workflow_attempts a ON a.attempt_id = l.attempt_id
                 WHERE l.node_id != a.node_id
                    OR l.execution_token_id != a.execution_token_id
                    OR (l.status = 'running' AND (a.status != 'running' OR r.status != 'running'))
                    OR (l.status = 'settled' AND (
                        l.outcome IS NULL
                        OR l.settled_store_position IS NULL
                        OR l.elapsed_milliseconds IS NULL
                        OR l.idempotency_key != l.invocation_id))
                 LIMIT 1",
                [],
                |_| Ok(()),
            )
            .optional()?;
        if invalid_llm.is_some() {
            return Err(WorkflowProjectionError::Integrity(
                "llm_projection_invalid".into(),
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
            "DELETE FROM workflow_run_purge_receipts;
             DELETE FROM workflow_projected_events;
             DELETE FROM workflow_llm_attempts;
             DELETE FROM workflow_capability_attempts;
             DELETE FROM workflow_subflows;
             DELETE FROM workflow_episode_inputs;
             DELETE FROM workflow_episodes;
             DELETE FROM workflow_cases;
             DELETE FROM workflow_waits;
             DELETE FROM workflow_wait_signals;
             DELETE FROM workflow_retry_evaluations;
             DELETE FROM workflow_iterations;
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
            "iterations" => "SELECT COUNT(*) FROM workflow_iterations",
            "retries" => "SELECT COUNT(*) FROM workflow_retry_evaluations",
            "waits" => "SELECT COUNT(*) FROM workflow_waits",
            "wait_signals" => "SELECT COUNT(*) FROM workflow_wait_signals",
            "cases" => "SELECT COUNT(*) FROM workflow_cases",
            "episodes" => "SELECT COUNT(*) FROM workflow_episodes",
            "episode_inputs" => "SELECT COUNT(*) FROM workflow_episode_inputs",
            "subflows" => "SELECT COUNT(*) FROM workflow_subflows",
            "capability_attempts" => "SELECT COUNT(*) FROM workflow_capability_attempts",
            "llm_attempts" => "SELECT COUNT(*) FROM workflow_llm_attempts",
            "events" => "SELECT COUNT(*) FROM workflow_projected_events",
            "purge_receipts" => "SELECT COUNT(*) FROM workflow_run_purge_receipts",
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
        self.inspect_runs_as_of(workflow_id, run_id, limit, 0)
    }

    pub fn inspect_runs_as_of(
        &self,
        workflow_id: Option<&str>,
        run_id: Option<&str>,
        limit: u32,
        as_of_unix_millis: i64,
    ) -> Result<Vec<v1::WorkflowProjectedRun>> {
        self.integrity_check()?;
        if as_of_unix_millis < 0 {
            return Err(WorkflowProjectionError::Integrity(
                "inspection_time_out_of_bounds".into(),
            ));
        }
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
                        "SELECT run_id FROM workflow_runs r WHERE run_id = ?1
                         AND NOT EXISTS (
                           SELECT 1 FROM workflow_run_purge_receipts p WHERE p.run_id = r.run_id
                         )",
                        [run_id],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                run_ids.extend(found);
            }
            (Some(workflow_id), None) => {
                let mut statement = self.connection.prepare(
                    "SELECT run_id FROM workflow_runs r WHERE workflow_id = ?1
                       AND NOT EXISTS (
                         SELECT 1 FROM workflow_run_purge_receipts p WHERE p.run_id = r.run_id
                       )
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
                    "SELECT run_id FROM workflow_runs r
                     WHERE NOT EXISTS (
                       SELECT 1 FROM workflow_run_purge_receipts p WHERE p.run_id = r.run_id
                     )
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
            .map(|run_id| self.inspect_run(run_id, as_of_unix_millis))
            .collect()
    }

    pub fn purge_tombstone(
        &self,
        run_id: &str,
    ) -> Result<Option<(String, u64, v1::WorkflowRunPurged)>> {
        self.integrity_check()?;
        type TombstoneRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            i64,
            i64,
            i64,
            String,
            i64,
            String,
            i64,
            i64,
        );
        let row: Option<TombstoneRow> = self
            .connection
            .query_row(
                "SELECT purge_event_id, purge_command_id, workflow_id, revision_id,
                        package_digest, mode, source_first_store_position,
                        source_last_store_position, source_event_count, affected_attempt_count,
                        affected_value_count, affected_file_handle_count,
                        retained_promoted_handle_ids_json, affected_value_bytes,
                        installation_id, historical_revision_retained, purge_store_position
                 FROM workflow_run_purge_receipts WHERE run_id = ?1",
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
            )
            .optional()?;
        row.map(|row| {
            let mode = match row.5.as_str() {
                "manual" => v1::WorkflowRunPurgeMode::Manual,
                "automatic" => v1::WorkflowRunPurgeMode::Automatic,
                _ => return Err(WorkflowProjectionError::Integrity("purge_mode".into())),
            };
            let preview_evidence_digest: String = self.connection.query_row(
                "SELECT preview_evidence_digest FROM workflow_run_purge_receipts WHERE run_id = ?1",
                [run_id],
                |row| row.get(0),
            )?;
            Ok((
                row.0,
                projected_u64(row.16)?,
                v1::WorkflowRunPurged {
                    run_id: run_id.to_owned(),
                    purge_command_id: row.1,
                    workflow_id: row.2,
                    revision_id: row.3,
                    package_digest: row.4,
                    mode: mode as i32,
                    preview_evidence_digest,
                    source_first_store_position: projected_u64(row.6)?,
                    source_last_store_position: projected_u64(row.7)?,
                    source_event_count: projected_u64(row.8)?,
                    affected_attempt_count: projected_u64(row.9)?,
                    affected_value_count: projected_u64(row.10)?,
                    affected_file_handle_count: projected_u64(row.11)?,
                    retained_promoted_handle_ids: decode_string_list(&row.12)?,
                    affected_value_bytes: projected_u64(row.13)?,
                    installation_id: row.14,
                    historical_revision_retained: row.15 == 1,
                },
            ))
        })
        .transpose()
    }

    fn inspect_run(
        &self,
        run_id: &str,
        as_of_unix_millis: i64,
    ) -> Result<v1::WorkflowProjectedRun> {
        type RunRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
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
                    package_digest, retention_mode, retention_days, status, outcome, error_code, error_value_id,
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
                    row.get(17)?,
                    row.get(18)?,
                ))
            },
        )?;
        let mut projected = v1::WorkflowProjectedRun {
            run_id: row.0,
            run_token_id: row.1,
            request_command_id: row.2,
            workflow_id: row.3,
            revision_id: row.4,
            package_digest: row.5,
            status: row.8,
            outcome: row.9.unwrap_or_default(),
            error_code: row.10.unwrap_or_default(),
            error: self.inspect_optional_value(row.11.as_deref())?,
            final_emission_ids: decode_string_list(&row.12)?,
            cancellation_command_id: row.13.unwrap_or_default(),
            cancellation_reason_code: row.14.unwrap_or_default(),
            created_at_unix_millis: row.15,
            settled_at_unix_millis: row.16.unwrap_or_default(),
            first_store_position: projected_u64(row.17)?,
            last_store_position: projected_u64(row.18)?,
            attempts: self.inspect_attempts(run_id)?,
            nodes: self.inspect_nodes(run_id)?,
            emissions: self.inspect_emissions(run_id)?,
            edges: self.inspect_edges(run_id)?,
            match_traces: self.inspect_match_traces(run_id)?,
            events: self.inspect_events(run_id)?,
            execution_tokens: self.inspect_execution_tokens(run_id)?,
            joins: self.inspect_joins(run_id)?,
            iterations: self.inspect_iterations(run_id)?,
            retries: self.inspect_retries(run_id)?,
            waits: self.inspect_waits(run_id)?,
            wait_signals: self.inspect_wait_signals(run_id)?,
            episode: self.inspect_episode(run_id)?,
            subflows: self.inspect_subflows(run_id)?,
            capability_attempts: self.inspect_capability_attempts(run_id)?,
            llm_attempts: self.inspect_llm_attempts(run_id)?,
            retention_policy: Some(projected_retention_policy(&row.6, row.7)?),
            purge_preview: None,
        };
        projected.purge_preview = Some(projected_purge_preview(&projected, as_of_unix_millis)?);
        Ok(projected)
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
                    created_store_position, settled_store_position, iteration_node_id,
                    iteration_index, iteration_count, resume_node_id, resume_reason
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
            Option<String>,
            Option<i64>,
            Option<i64>,
            Option<String>,
            Option<String>,
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
                row.get(15)?,
                row.get(16)?,
                row.get(17)?,
                row.get(18)?,
                row.get(19)?,
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
                    iteration_node_id: row.15.unwrap_or_default(),
                    iteration_index: row.16.map(projected_u32).transpose()?.unwrap_or_default(),
                    iteration_count: row.17.map(projected_u32).transpose()?.unwrap_or_default(),
                    resume_node_id: row.18.unwrap_or_default(),
                    resume_reason: row.19.unwrap_or_default(),
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

    fn inspect_iterations(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedIteration>> {
        let mut statement = self.connection.prepare(
            "SELECT iteration_node_id, parent_execution_token_id, controller_attempt_id,
                    input_value_id, input_sha256, item_count, maximum_items,
                    maximum_concurrency, failure_policy, decision,
                    resumed_execution_token_id, expected_execution_token_ids_json,
                    succeeded_execution_token_ids_json, failed_execution_token_ids_json,
                    pending_execution_token_ids_json, error_code, output_value_id,
                    planned_store_position, evaluated_store_position
             FROM workflow_iterations WHERE run_id = ?1
             ORDER BY planned_store_position, event_id",
        )?;
        type IterationRow = (
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
            Option<i64>,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<IterationRow> {
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
                row.get(17)?,
                row.get(18)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedIteration {
                    iteration_node_id: row.0,
                    parent_execution_token_id: row.1,
                    controller_attempt_id: row.2,
                    input_value_id: row.3,
                    input_sha256: row.4,
                    item_count: projected_u32(row.5)?,
                    maximum_items: projected_u32(row.6)?,
                    maximum_concurrency: projected_u32(row.7)?,
                    failure_policy: row.8,
                    decision: row.9.unwrap_or_default(),
                    resumed_execution_token_id: row.10.unwrap_or_default(),
                    expected_execution_token_ids: decode_optional_string_list(row.11.as_deref())?,
                    succeeded_execution_token_ids: decode_optional_string_list(row.12.as_deref())?,
                    failed_execution_token_ids: decode_optional_string_list(row.13.as_deref())?,
                    pending_execution_token_ids: decode_optional_string_list(row.14.as_deref())?,
                    error_code: row.15.unwrap_or_default(),
                    output: self.inspect_optional_value(row.16.as_deref())?,
                    planned_store_position: projected_u64(row.17)?,
                    evaluated_store_position: row
                        .18
                        .map(projected_u64)
                        .transpose()?
                        .unwrap_or_default(),
                })
            })
            .collect()
    }

    fn inspect_retries(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedRetryEvaluation>> {
        let mut statement = self.connection.prepare(
            "SELECT retry_node_id, execution_token_id, controller_attempt_id,
                    failed_attempt_id, target_node_id, error_code, decision,
                    next_attempt_number, maximum_attempts, delay_milliseconds,
                    eligible_at_unix_millis, retry_input_value_id, error_value_id,
                    store_position
             FROM workflow_retry_evaluations WHERE run_id = ?1
             ORDER BY store_position, event_id",
        )?;
        type RetryRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            Option<i64>,
            String,
            String,
            i64,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<RetryRow> {
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
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedRetryEvaluation {
                    retry_node_id: row.0,
                    execution_token_id: row.1,
                    controller_attempt_id: row.2,
                    failed_attempt_id: row.3,
                    target_node_id: row.4,
                    error_code: row.5,
                    decision: row.6,
                    next_attempt_number: projected_u32(row.7)?,
                    maximum_attempts: projected_u32(row.8)?,
                    delay_milliseconds: projected_u64(row.9)?,
                    eligible_at_unix_millis: row.10.unwrap_or_default(),
                    retry_input: Some(self.inspect_value(&row.11)?),
                    error: Some(self.inspect_value(&row.12)?),
                    store_position: projected_u64(row.13)?,
                })
            })
            .collect()
    }

    fn inspect_waits(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedWait>> {
        let mut statement = self.connection.prepare(
            "SELECT subscription_id, wait_node_id, execution_token_id, controller_attempt_id,
                    workflow_id, revision_id, package_digest, kind, owner_kind, owner_id,
                    correlation_json, input_value_id, input_sha256, status, decision,
                    resolving_signal_id, output_value_id, reason_code, expires_at_unix_millis,
                    subscribed_store_position, resolved_store_position
             FROM workflow_waits WHERE run_id = ?1
             ORDER BY subscribed_store_position, subscription_id",
        )?;
        type WaitRow = (
            String,
            String,
            String,
            String,
            String,
            String,
            String,
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
            Option<String>,
            i64,
            i64,
            Option<i64>,
        );
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<WaitRow> {
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
                row.get(17)?,
                row.get(18)?,
                row.get(19)?,
                row.get(20)?,
            ))
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|row| {
                Ok(v1::WorkflowProjectedWait {
                    subscription_id: row.0,
                    wait_node_id: row.1,
                    execution_token_id: row.2,
                    controller_attempt_id: row.3,
                    workflow_id: row.4,
                    revision_id: row.5,
                    package_digest: row.6,
                    kind: row.7,
                    owner_kind: row.8,
                    owner_id: row.9,
                    correlation: decode_wait_correlation(&row.10)?,
                    input_value_id: row.11,
                    input_sha256: row.12,
                    status: row.13,
                    decision: row.14.unwrap_or_default(),
                    resolving_signal_id: row.15.unwrap_or_default(),
                    output: self.inspect_optional_value(row.16.as_deref())?,
                    reason_code: row.17.unwrap_or_default(),
                    expires_at_unix_millis: row.18,
                    subscribed_store_position: projected_u64(row.19)?,
                    resolved_store_position: row
                        .20
                        .map(projected_u64)
                        .transpose()?
                        .unwrap_or_default(),
                })
            })
            .collect()
    }

    fn inspect_wait_signals(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedWaitSignal>> {
        let mut statement = self.connection.prepare(
            "SELECT signal_id, signal_command_id, kind, owner_kind, owner_id,
                    correlation_json, value_id, recorded_at_unix_millis, store_position
             FROM workflow_wait_signals WHERE run_id = ?1 ORDER BY store_position, signal_id",
        )?;
        type SignalRow = (
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
        let rows = statement.query_map([run_id], |row| -> rusqlite::Result<SignalRow> {
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
                Ok(v1::WorkflowProjectedWaitSignal {
                    signal_id: row.0,
                    signal_command_id: row.1,
                    kind: row.2,
                    owner_kind: row.3,
                    owner_id: row.4,
                    correlation: decode_wait_correlation(&row.5)?,
                    value: Some(self.inspect_value(&row.6)?),
                    recorded_at_unix_millis: row.7,
                    store_position: projected_u64(row.8)?,
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

    fn inspect_episode(&self, run_id: &str) -> Result<Option<v1::WorkflowProjectedCaseEpisode>> {
        type EpisodeRow = (
            String,
            String,
            String,
            i64,
            String,
            Option<String>,
            String,
            Option<String>,
            String,
            String,
            String,
            i64,
        );
        let row: Option<EpisodeRow> = self
            .connection
            .query_row(
                "SELECT installation_id, case_id, episode_id, ordinal, kind, prior_episode_id,
                        trigger_kind, trigger_event_id, compiled_context_value_id,
                        source_episode_ids_json, source_event_ids_json, started_store_position
                 FROM workflow_episodes WHERE run_id = ?1",
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
                    ))
                },
            )
            .optional()?;
        let Some(row) = row else {
            return Ok(None);
        };
        let mut statement = self.connection.prepare(
            "SELECT port_id, value_id FROM workflow_episode_inputs
             WHERE episode_id = ?1 ORDER BY ordinal",
        )?;
        let inputs = statement
            .query_map([&row.2], |input| {
                Ok((input.get::<_, String>(0)?, input.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|(port_id, value_id)| {
                Ok(v1::WorkflowProjectedInputBinding {
                    port_id,
                    value: Some(self.inspect_value(&value_id)?),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Some(v1::WorkflowProjectedCaseEpisode {
            installation_id: row.0,
            case_id: row.1,
            episode_id: row.2,
            ordinal: projected_u32(row.3)?,
            kind: row.4,
            prior_episode_id: row.5.unwrap_or_default(),
            trigger_kind: row.6,
            trigger_event_id: row.7.unwrap_or_default(),
            inputs,
            compiled_context: Some(self.inspect_value(&row.8)?),
            source_episode_ids: decode_string_list(&row.9)?,
            source_event_ids: decode_string_list(&row.10)?,
            started_store_position: projected_u64(row.11)?,
        }))
    }

    fn inspect_subflows(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedSubflow>> {
        type SubflowRow = (
            String,
            String,
            String,
            String,
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
            Option<String>,
            Option<String>,
            Option<String>,
            String,
            i64,
            Option<i64>,
            i64,
            Option<i64>,
        );
        let mut statement = self.connection.prepare(
            "SELECT invocation_id, attempt_id, execution_token_id, node_id, child_run_id,
                    child_workflow_id, child_revision_id, child_package_id, child_package_digest,
                    entrypoint, input_value_id, status, outcome, output_value_id, error_code,
                    error_value_id, child_final_emission_ids_json, child_command_id,
                    called_at_unix_millis, settled_at_unix_millis, called_store_position,
                    settled_store_position
             FROM workflow_subflows WHERE run_id = ?1
             ORDER BY called_store_position, invocation_id",
        )?;
        let rows = statement.query_map([run_id], |row| {
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
                row.get(17)?,
                row.get(18)?,
                row.get(19)?,
                row.get(20)?,
                row.get(21)?,
            ))
        })?;
        rows.map(|row| {
            let row: SubflowRow = row?;
            Ok(v1::WorkflowProjectedSubflow {
                invocation_id: row.0,
                attempt_id: row.1,
                execution_token_id: row.2,
                node_id: row.3,
                child_run_id: row.4,
                child_workflow_id: row.5,
                child_revision_id: row.6,
                child_package_id: row.7,
                child_package_digest: row.8,
                entrypoint: row.9,
                input: Some(self.inspect_value(&row.10)?),
                status: row.11.unwrap_or_default(),
                outcome: row.12.unwrap_or_default(),
                output: self.inspect_optional_value(row.13.as_deref())?,
                error_code: row.14.unwrap_or_default(),
                error: self.inspect_optional_value(row.15.as_deref())?,
                child_final_emission_ids: decode_optional_string_list(row.16.as_deref())?,
                child_command_id: row.17,
                called_at_unix_millis: row.18,
                settled_at_unix_millis: row.19.unwrap_or_default(),
                called_store_position: projected_u64(row.20)?,
                settled_store_position: row.21.map(projected_u64).transpose()?.unwrap_or_default(),
            })
        })
        .collect()
    }

    fn inspect_capability_attempts(
        &self,
        run_id: &str,
    ) -> Result<Vec<v1::WorkflowProjectedCapabilityAttempt>> {
        struct CapabilityRow {
            invocation_id: String,
            attempt_id: String,
            execution_token_id: String,
            node_id: String,
            capability_id: String,
            version: String,
            package_digest: String,
            configuration_contract_digest: String,
            input_schema_digest: String,
            output_schema_digest: String,
            output_schema_ref: String,
            configuration_value_id: String,
            input_value_id: String,
            artifact_inputs_json: String,
            status: String,
            outcome: Option<String>,
            output_value_id: Option<String>,
            artifact_outputs_json: Option<String>,
            error_code: Option<String>,
            error_value_id: Option<String>,
            logs_json: Option<String>,
            timeout_milliseconds: i64,
            deadline_unix_millis: i64,
            elapsed_milliseconds: Option<i64>,
            receipt_id: Option<String>,
            provider_run_reference: Option<String>,
            idempotency_key: Option<String>,
            started_at_unix_millis: i64,
            settled_at_unix_millis: Option<i64>,
            started_store_position: i64,
            settled_store_position: Option<i64>,
        }
        let mut statement = self.connection.prepare(
            "SELECT invocation_id, attempt_id, execution_token_id, node_id, capability_id,
                    version, package_digest, configuration_contract_digest, input_schema_digest,
                    output_schema_digest, output_schema_ref, configuration_value_id, input_value_id,
                    artifact_inputs_json, status, outcome, output_value_id, artifact_outputs_json,
                    error_code, error_value_id, logs_json, timeout_milliseconds,
                    deadline_unix_millis, elapsed_milliseconds, receipt_id,
                    provider_run_reference, idempotency_key, started_at_unix_millis,
                    settled_at_unix_millis, started_store_position, settled_store_position
             FROM workflow_capability_attempts WHERE run_id = ?1
             ORDER BY started_store_position, invocation_id",
        )?;
        let rows = statement.query_map([run_id], |row| {
            Ok(CapabilityRow {
                invocation_id: row.get(0)?,
                attempt_id: row.get(1)?,
                execution_token_id: row.get(2)?,
                node_id: row.get(3)?,
                capability_id: row.get(4)?,
                version: row.get(5)?,
                package_digest: row.get(6)?,
                configuration_contract_digest: row.get(7)?,
                input_schema_digest: row.get(8)?,
                output_schema_digest: row.get(9)?,
                output_schema_ref: row.get(10)?,
                configuration_value_id: row.get(11)?,
                input_value_id: row.get(12)?,
                artifact_inputs_json: row.get(13)?,
                status: row.get(14)?,
                outcome: row.get(15)?,
                output_value_id: row.get(16)?,
                artifact_outputs_json: row.get(17)?,
                error_code: row.get(18)?,
                error_value_id: row.get(19)?,
                logs_json: row.get(20)?,
                timeout_milliseconds: row.get(21)?,
                deadline_unix_millis: row.get(22)?,
                elapsed_milliseconds: row.get(23)?,
                receipt_id: row.get(24)?,
                provider_run_reference: row.get(25)?,
                idempotency_key: row.get(26)?,
                started_at_unix_millis: row.get(27)?,
                settled_at_unix_millis: row.get(28)?,
                started_store_position: row.get(29)?,
                settled_store_position: row.get(30)?,
            })
        })?;
        rows.map(|row| {
            let row = row?;
            Ok(v1::WorkflowProjectedCapabilityAttempt {
                invocation_id: row.invocation_id,
                attempt_id: row.attempt_id,
                execution_token_id: row.execution_token_id,
                node_id: row.node_id,
                capability_id: row.capability_id,
                version: row.version,
                package_digest: row.package_digest,
                configuration_contract_digest: row.configuration_contract_digest,
                input_schema_digest: row.input_schema_digest,
                output_schema_digest: row.output_schema_digest,
                output_schema_ref: row.output_schema_ref,
                configuration: Some(self.inspect_value(&row.configuration_value_id)?),
                input: Some(self.inspect_value(&row.input_value_id)?),
                artifact_inputs: self.inspect_capability_artifacts(&row.artifact_inputs_json)?,
                status: row.status,
                outcome: row.outcome.unwrap_or_default(),
                output: self.inspect_optional_value(row.output_value_id.as_deref())?,
                artifact_outputs: row
                    .artifact_outputs_json
                    .as_deref()
                    .map(|value| self.inspect_capability_artifacts(value))
                    .transpose()?
                    .unwrap_or_default(),
                error_code: row.error_code.unwrap_or_default(),
                error: self.inspect_optional_value(row.error_value_id.as_deref())?,
                logs: decode_capability_logs(row.logs_json.as_deref())?,
                timeout_milliseconds: projected_u64(row.timeout_milliseconds)?,
                deadline_unix_millis: row.deadline_unix_millis,
                elapsed_milliseconds: row
                    .elapsed_milliseconds
                    .map(projected_u64)
                    .transpose()?
                    .unwrap_or_default(),
                receipt_id: row.receipt_id.unwrap_or_default(),
                provider_run_reference: row.provider_run_reference.unwrap_or_default(),
                idempotency_key: row.idempotency_key.unwrap_or_default(),
                started_at_unix_millis: row.started_at_unix_millis,
                settled_at_unix_millis: row.settled_at_unix_millis.unwrap_or_default(),
                started_store_position: projected_u64(row.started_store_position)?,
                settled_store_position: row
                    .settled_store_position
                    .map(projected_u64)
                    .transpose()?
                    .unwrap_or_default(),
            })
        })
        .collect()
    }

    fn inspect_capability_artifacts(
        &self,
        value: &str,
    ) -> Result<Vec<v1::WorkflowProjectedCapabilityArtifactHandle>> {
        let records: Vec<CapabilityArtifactRecord> = serde_json::from_str(value).map_err(|_| {
            WorkflowProjectionError::Integrity("capability_artifacts_decode".into())
        })?;
        records
            .into_iter()
            .map(|record| {
                Ok(v1::WorkflowProjectedCapabilityArtifactHandle {
                    handle_id: record.handle_id,
                    role: record.role,
                    value: Some(self.inspect_value(&record.value_id)?),
                })
            })
            .collect()
    }

    fn inspect_llm_attempts(&self, run_id: &str) -> Result<Vec<v1::WorkflowProjectedLlmAttempt>> {
        type LlmRow = (
            String,
            String,
            String,
            String,
            Vec<u8>,
            String,
            String,
            String,
            String,
            String,
            Vec<u8>,
            String,
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
            i64,
            Option<i64>,
            Option<String>,
            Option<String>,
            Option<String>,
            i64,
            Option<i64>,
            i64,
            Option<i64>,
            String,
            Option<String>,
            Option<String>,
            Option<Vec<u8>>,
            Option<Vec<u8>>,
            Option<Vec<u8>>,
        );
        let mut statement = self.connection.prepare(
            "SELECT invocation_id, attempt_id, execution_token_id, node_id, settings_wire,
                    context_digest, context_groups_json, messages_json, prior_episode_ids_json,
                    attachments_json, compilation_report_wire, output_schema_ref,
                    output_schema_digest, input_value_id, status, outcome, output_value_id,
                    error_code, error_value_id, timeout_milliseconds, deadline_unix_millis,
                    elapsed_milliseconds, receipt_id, provider_run_reference, idempotency_key,
                    started_at_unix_millis, settled_at_unix_millis, started_store_position,
                    settled_store_position, tool_definitions_json, tool_calls_json,
                    response_messages_json, usage_wire, validation_wire, provider_receipt_wire
             FROM workflow_llm_attempts WHERE run_id = ?1
             ORDER BY started_store_position, invocation_id",
        )?;
        let rows = statement.query_map([run_id], |row| {
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
                row.get(17)?,
                row.get(18)?,
                row.get(19)?,
                row.get(20)?,
                row.get(21)?,
                row.get(22)?,
                row.get(23)?,
                row.get(24)?,
                row.get(25)?,
                row.get(26)?,
                row.get(27)?,
                row.get(28)?,
                row.get(29)?,
                row.get(30)?,
                row.get(31)?,
                row.get(32)?,
                row.get(33)?,
                row.get(34)?,
            ))
        })?;
        rows.map(|row| {
            let row: LlmRow = row?;
            let settings = v1::WorkflowLlmModelSettings::decode(row.4.as_slice())
                .map_err(|_| WorkflowProjectionError::Integrity("llm_settings_decode".into()))?;
            let report =
                v1::WorkflowLlmCompilationReport::decode(row.10.as_slice()).map_err(|_| {
                    WorkflowProjectionError::Integrity("llm_compilation_report_decode".into())
                })?;
            Ok(v1::WorkflowProjectedLlmAttempt {
                invocation_id: row.0,
                attempt_id: row.1,
                execution_token_id: row.2,
                node_id: row.3,
                settings: Some(settings),
                context_digest: row.5,
                context_groups: self.inspect_llm_context_groups(&row.6)?,
                messages: self.inspect_llm_messages(&row.7)?,
                prior_episode_ids: decode_string_list(&row.8)?,
                attachments: self.inspect_capability_artifacts(&row.9)?,
                compilation_report: Some(report),
                output_schema_ref: row.11,
                output_schema_digest: row.12,
                input: Some(self.inspect_value(&row.13)?),
                status: row.14,
                outcome: row.15.unwrap_or_default(),
                output: self.inspect_optional_value(row.16.as_deref())?,
                error_code: row.17.unwrap_or_default(),
                error: self.inspect_optional_value(row.18.as_deref())?,
                timeout_milliseconds: projected_u64(row.19)?,
                deadline_unix_millis: row.20,
                elapsed_milliseconds: row.21.map(projected_u64).transpose()?.unwrap_or_default(),
                receipt_id: row.22.unwrap_or_default(),
                provider_run_reference: row.23.unwrap_or_default(),
                idempotency_key: row.24.unwrap_or_default(),
                started_at_unix_millis: row.25,
                settled_at_unix_millis: row.26.unwrap_or_default(),
                started_store_position: projected_u64(row.27)?,
                settled_store_position: row.28.map(projected_u64).transpose()?.unwrap_or_default(),
                tool_definitions: decode_llm_tool_definitions(&row.29)?,
                tool_calls: self.inspect_llm_tool_calls(row.30.as_deref().unwrap_or("[]"))?,
                response_messages: self
                    .inspect_llm_response_messages(row.31.as_deref().unwrap_or("[]"))?,
                usage: decode_optional_message(row.32.as_deref(), "llm_usage_decode")?,
                validation: decode_optional_message(row.33.as_deref(), "llm_validation_decode")?,
                provider_receipt: decode_optional_message(
                    row.34.as_deref(),
                    "llm_provider_receipt_decode",
                )?,
            })
        })
        .collect()
    }

    fn inspect_llm_context_groups(
        &self,
        value: &str,
    ) -> Result<Vec<v1::WorkflowProjectedLlmContextGroup>> {
        let records: Vec<LlmContextGroupRecord> = serde_json::from_str(value)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_context_groups_decode".into()))?;
        records
            .into_iter()
            .map(|record| {
                Ok(v1::WorkflowProjectedLlmContextGroup {
                    group_id: record.group_id,
                    kind: record.kind,
                    title: record.title,
                    provenance: record.provenance,
                    content: Some(self.inspect_value(&record.content_value_id)?),
                    original_byte_count: record.original_byte_count,
                    retained_byte_count: record.retained_byte_count,
                    redaction_count: record.redaction_count,
                    truncated: record.truncated,
                    source_episode_ids: record.source_episode_ids,
                })
            })
            .collect()
    }

    fn inspect_llm_messages(&self, value: &str) -> Result<Vec<v1::WorkflowProjectedLlmMessage>> {
        let records: Vec<LlmMessageRecord> = serde_json::from_str(value)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_messages_decode".into()))?;
        records
            .into_iter()
            .map(|record| {
                Ok(v1::WorkflowProjectedLlmMessage {
                    message_id: record.message_id,
                    sequence: record.sequence,
                    role: record.role,
                    context_group_id: record.context_group_id,
                    summary: record.summary,
                    content: Some(self.inspect_value(&record.content_value_id)?),
                    estimated_tokens: record.estimated_tokens,
                    redaction_count: record.redaction_count,
                    truncated: record.truncated,
                })
            })
            .collect()
    }

    fn inspect_llm_tool_calls(&self, value: &str) -> Result<Vec<v1::WorkflowProjectedLlmToolCall>> {
        let records: Vec<LlmToolCallRecord> = serde_json::from_str(value)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_tool_calls_decode".into()))?;
        records
            .into_iter()
            .map(|record| {
                Ok(v1::WorkflowProjectedLlmToolCall {
                    call_id: record.call_id,
                    sequence: record.sequence,
                    tool_id: record.tool_id,
                    status: record.status,
                    input: Some(self.inspect_value(&record.input_value_id)?),
                    output: self.inspect_optional_value(record.output_value_id.as_deref())?,
                    error_code: record.error_code,
                    error: self.inspect_optional_value(record.error_value_id.as_deref())?,
                    duration_milliseconds: record.duration_milliseconds,
                })
            })
            .collect()
    }

    fn inspect_llm_response_messages(
        &self,
        value: &str,
    ) -> Result<Vec<v1::WorkflowProjectedLlmResponseMessage>> {
        let records: Vec<LlmResponseMessageRecord> = serde_json::from_str(value).map_err(|_| {
            WorkflowProjectionError::Integrity("llm_response_messages_decode".into())
        })?;
        records
            .into_iter()
            .map(|record| {
                Ok(v1::WorkflowProjectedLlmResponseMessage {
                    message_id: record.message_id,
                    sequence: record.sequence,
                    role: record.role,
                    kind: record.kind,
                    summary: record.summary,
                    content: Some(self.inspect_value(&record.content_value_id)?),
                    tool_call_id: record.tool_call_id,
                })
            })
            .collect()
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

fn projected_retention_policy(mode: &str, days: i64) -> Result<v1::WorkflowRunRetentionPolicy> {
    let days = projected_u32(days)?;
    let policy = match mode {
        "duration" if (1..=3_650).contains(&days) => WorkflowRunRetentionPolicy::Duration { days },
        "delete-after-success" if days == 0 => WorkflowRunRetentionPolicy::DeleteAfterSuccess,
        "forever" if days == 0 => WorkflowRunRetentionPolicy::Forever,
        _ => {
            return Err(WorkflowProjectionError::Integrity(
                "run_retention_policy".into(),
            ));
        }
    };
    Ok(policy.as_proto())
}

fn projected_purge_preview(
    run: &v1::WorkflowProjectedRun,
    as_of_unix_millis: i64,
) -> Result<v1::WorkflowRunPurgePreview> {
    let policy = WorkflowRunRetentionPolicy::from_proto(run.retention_policy.as_ref())
        .map_err(|_| WorkflowProjectionError::Integrity("run_retention_policy".into()))?;
    let outcome = match run.outcome.as_str() {
        "succeeded" => Some(v1::WorkflowRunOutcome::Succeeded),
        "failed" => Some(v1::WorkflowRunOutcome::Failed),
        "cancelled" => Some(v1::WorkflowRunOutcome::Cancelled),
        "" => None,
        _ => {
            return Err(WorkflowProjectionError::Integrity(
                "run_retention_outcome".into(),
            ));
        }
    };
    let protection = crate::workflow_retention::WorkflowRunProtectionState {
        settled: matches!(run.status.as_str(), "succeeded" | "failed" | "cancelled"),
        waiting: run.waits.iter().any(|wait| wait.status == "waiting"),
        // V2 effect approvals do not yet have a workflow-runtime projection.
        // Their runs remain unsettled, which is independently protected.
        approval_pending: false,
        unknown_outcome: run
            .retries
            .iter()
            .any(|retry| retry.decision == "unknown-outcome"),
    };
    // A case episode participates in an immutable cross-run context chain.
    // Run-only deletion cannot rewrite or gap that chain, so it remains
    // protected until a case-wide tombstone contract exists.
    let protected_reason = if run.episode.is_some() {
        "case_episode"
    } else {
        protection.protected_reason().unwrap_or_default()
    };
    let automatic_eligible_at = policy
        .automatic_eligible_at(
            outcome,
            (run.settled_at_unix_millis > 0).then_some(run.settled_at_unix_millis),
        )
        .unwrap_or_default();

    let mut values = BTreeMap::<String, v1::WorkflowProjectedValue>::new();
    let mut remember = |value: Option<&v1::WorkflowProjectedValue>| {
        if let Some(value) = value {
            values
                .entry(value.value_id.clone())
                .or_insert_with(|| value.clone());
        }
    };
    remember(run.error.as_ref());
    for attempt in &run.attempts {
        remember(attempt.error.as_ref());
    }
    for emission in &run.emissions {
        remember(emission.value.as_ref());
    }
    for trace in &run.match_traces {
        remember(trace.trace.as_ref());
    }
    for token in &run.execution_tokens {
        remember(token.error.as_ref());
    }
    for iteration in &run.iterations {
        remember(iteration.output.as_ref());
    }
    for retry in &run.retries {
        remember(retry.retry_input.as_ref());
        remember(retry.error.as_ref());
    }
    for wait in &run.waits {
        remember(wait.output.as_ref());
    }
    for signal in &run.wait_signals {
        remember(signal.value.as_ref());
    }
    if let Some(episode) = run.episode.as_ref() {
        remember(episode.compiled_context.as_ref());
        for input in &episode.inputs {
            remember(input.value.as_ref());
        }
    }
    for subflow in &run.subflows {
        remember(subflow.input.as_ref());
        remember(subflow.output.as_ref());
        remember(subflow.error.as_ref());
    }
    for capability in &run.capability_attempts {
        remember(capability.configuration.as_ref());
        remember(capability.input.as_ref());
        remember(capability.output.as_ref());
        remember(capability.error.as_ref());
        for artifact in capability
            .artifact_inputs
            .iter()
            .chain(&capability.artifact_outputs)
        {
            remember(artifact.value.as_ref());
        }
    }
    for llm in &run.llm_attempts {
        remember(llm.input.as_ref());
        remember(llm.output.as_ref());
        remember(llm.error.as_ref());
        for group in &llm.context_groups {
            remember(group.content.as_ref());
        }
        for message in &llm.messages {
            remember(message.content.as_ref());
        }
        for attachment in &llm.attachments {
            remember(attachment.value.as_ref());
        }
        for call in &llm.tool_calls {
            remember(call.input.as_ref());
            remember(call.output.as_ref());
            remember(call.error.as_ref());
        }
        for message in &llm.response_messages {
            remember(message.content.as_ref());
        }
    }

    let mut affected_value_ids = Vec::new();
    let mut affected_file_handle_ids = Vec::new();
    let mut retained_promoted_handle_ids = Vec::new();
    let mut affected_value_bytes = 0_u64;
    for value in values.values() {
        let promoted = value.storage.as_ref().is_some_and(|storage| {
            matches!(storage.scope.as_str(), "case" | "workflow")
                && !storage.source_version_id.is_empty()
        });
        if promoted {
            if let Some(storage) = value.storage.as_ref() {
                retained_promoted_handle_ids.push(storage.handle_id.clone());
            }
            continue;
        }
        affected_value_ids.push(value.value_id.clone());
        affected_value_bytes = affected_value_bytes
            .checked_add(value.byte_count)
            .ok_or_else(|| WorkflowProjectionError::Integrity("run_purge_byte_count".into()))?;
        if let Some(storage) = value.storage.as_ref()
            && storage.scope == "job"
        {
            affected_file_handle_ids.push(storage.handle_id.clone());
        }
    }
    affected_file_handle_ids.sort();
    affected_file_handle_ids.dedup();
    retained_promoted_handle_ids.sort();
    retained_promoted_handle_ids.dedup();
    let affected_attempt_ids = run
        .attempts
        .iter()
        .map(|attempt| attempt.attempt_id.clone())
        .collect::<Vec<_>>();
    let evidence = serde_json::json!({
        "runId": run.run_id,
        "status": run.status,
        "outcome": run.outcome,
        "policy": policy,
        "protectedReason": protected_reason,
        "attemptIds": affected_attempt_ids,
        "valueIds": affected_value_ids,
        "fileHandleIds": affected_file_handle_ids,
        "retainedPromotedHandleIds": retained_promoted_handle_ids,
        "affectedValueBytes": affected_value_bytes,
    });
    let evidence_bytes = serde_json_canonicalizer::to_vec(&evidence)
        .map_err(|_| WorkflowProjectionError::Integrity("run_purge_evidence".into()))?;
    let manual_eligible = protected_reason.is_empty();
    Ok(v1::WorkflowRunPurgePreview {
        manual_eligible,
        automatic_eligible: manual_eligible
            && automatic_eligible_at > 0
            && as_of_unix_millis >= automatic_eligible_at,
        protected_reason: protected_reason.into(),
        automatic_eligible_at_unix_millis: automatic_eligible_at,
        affected_attempt_ids,
        affected_value_ids,
        affected_file_handle_ids,
        retained_promoted_handle_ids,
        affected_value_bytes,
        evidence_digest: hex::encode(Sha256::digest(evidence_bytes)),
    })
}

fn decode_optional_string_list(value: Option<&str>) -> Result<Vec<String>> {
    value
        .map(decode_string_list)
        .transpose()
        .map(Option::unwrap_or_default)
}

fn decode_capability_logs(value: Option<&str>) -> Result<Vec<v1::WorkflowCapabilityLogEntry>> {
    let records: Vec<CapabilityLogRecord> = value
        .map(serde_json::from_str)
        .transpose()
        .map_err(|_| WorkflowProjectionError::Integrity("capability_logs_decode".into()))?
        .unwrap_or_default();
    Ok(records
        .into_iter()
        .map(|record| v1::WorkflowCapabilityLogEntry {
            sequence: record.sequence,
            level: record.level,
            message: record.message,
            offset_milliseconds: record.offset_milliseconds,
        })
        .collect())
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
    if event.kind == workflow_runtime::WORKFLOW_RUN_PURGED_KIND
        && let Some((run_id, position)) = transaction
            .query_row(
                "SELECT run_id, purge_store_position FROM workflow_run_purge_receipts
                 WHERE purge_event_id = ?1",
                [&event.event_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
    {
        if run_id == event.correlation_id && position == sql_u64(event.store_position)? {
            return Ok(false);
        }
        return lifecycle("purge_event_identity_reused");
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
        WorkflowRuntimeEvent::CaseEpisodeStarted(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let pins: (String, String, String) = transaction.query_row(
                "SELECT workflow_id, revision_id, package_digest FROM workflow_runs WHERE run_id = ?1",
                [&payload.run_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
            if pins
                != (
                    payload.workflow_id.clone(),
                    payload.revision_id.clone(),
                    payload.package_digest.clone(),
                )
            {
                return lifecycle("episode_run_pin_mismatch");
            }
            let existing_case: Option<(String, String, i64)> = transaction
                .query_row(
                    "SELECT workflow_id, last_episode_id, episode_count FROM workflow_cases
                     WHERE installation_id = ?1 AND case_id = ?2",
                    params![payload.installation_id, payload.case_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            match existing_case {
                None => {
                    if payload.ordinal != 1
                        || payload.kind != "initial"
                        || !payload.prior_episode_id.is_empty()
                        || !payload.source_episode_ids.is_empty()
                    {
                        return lifecycle("case_initial_episode_contract");
                    }
                    transaction.execute(
                        "INSERT INTO workflow_cases
                         (installation_id, case_id, workflow_id, first_episode_id, last_episode_id,
                          episode_count, created_at_unix_millis, updated_at_unix_millis,
                          first_store_position, last_store_position)
                         VALUES (?1, ?2, ?3, ?4, ?4, 1, ?5, ?5, ?6, ?6)",
                        params![
                            payload.installation_id,
                            payload.case_id,
                            payload.workflow_id,
                            payload.episode_id,
                            event.occurred_at_unix_millis,
                            sql_u64(event.store_position)?,
                        ],
                    )?;
                }
                Some((workflow_id, last_episode_id, episode_count)) => {
                    if workflow_id != payload.workflow_id
                        || payload.ordinal != projected_u32(episode_count)? + 1
                        || payload.prior_episode_id != last_episode_id
                    {
                        return lifecycle("case_episode_chain");
                    }
                    let mut statement = transaction.prepare(
                        "SELECT episode_id FROM workflow_episodes
                         WHERE installation_id = ?1 AND case_id = ?2 ORDER BY ordinal",
                    )?;
                    let sources = statement
                        .query_map(params![payload.installation_id, payload.case_id], |row| {
                            row.get::<_, String>(0)
                        })?
                        .collect::<std::result::Result<Vec<_>, _>>()?;
                    if sources != payload.source_episode_ids {
                        return lifecycle("case_episode_sources");
                    }
                    transaction.execute(
                        "UPDATE workflow_cases SET last_episode_id = ?1, episode_count = ?2,
                         updated_at_unix_millis = ?3, last_store_position = ?4
                         WHERE installation_id = ?5 AND case_id = ?6",
                        params![
                            payload.episode_id,
                            i64::from(payload.ordinal),
                            event.occurred_at_unix_millis,
                            sql_u64(event.store_position)?,
                            payload.installation_id,
                            payload.case_id,
                        ],
                    )?;
                }
            }
            let context = payload.compiled_context.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("episode_context_missing".into())
            })?;
            insert_value(transaction, context)?;
            transaction.execute(
                "INSERT INTO workflow_episodes
                 (episode_id, installation_id, case_id, run_id, run_token_id, ordinal, kind,
                  prior_episode_id, workflow_id, revision_id, package_digest, trigger_kind,
                  trigger_event_id, compiled_context_value_id, source_episode_ids_json,
                  source_event_ids_json, started_at_unix_millis, started_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULLIF(?8, ''), ?9, ?10, ?11, ?12,
                         NULLIF(?13, ''), ?14, ?15, ?16, ?17, ?18)",
                params![
                    payload.episode_id,
                    payload.installation_id,
                    payload.case_id,
                    payload.run_id,
                    payload.run_token_id,
                    i64::from(payload.ordinal),
                    payload.kind,
                    payload.prior_episode_id,
                    payload.workflow_id,
                    payload.revision_id,
                    payload.package_digest,
                    payload.trigger_kind,
                    payload.trigger_event_id,
                    context.value_id,
                    string_list_json(&payload.source_episode_ids)?,
                    string_list_json(&payload.source_event_ids)?,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            for (ordinal, input) in payload.inputs.iter().enumerate() {
                let value = input.value.as_ref().ok_or_else(|| {
                    WorkflowProjectionError::Lifecycle("episode_input_missing".into())
                })?;
                insert_value(transaction, value)?;
                transaction.execute(
                    "INSERT INTO workflow_episode_inputs(episode_id, port_id, value_id, ordinal)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![
                        payload.episode_id,
                        input.port_id,
                        value.value_id,
                        ordinal as i64,
                    ],
                )?;
            }
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::SubflowCalled(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let input = payload.input.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("subflow_input_missing".into())
            })?;
            insert_value(transaction, input)?;
            transaction.execute(
                "INSERT INTO workflow_subflows
                 (invocation_id, run_id, attempt_id, execution_token_id, node_id, child_run_id,
                  child_command_id, child_workflow_id, child_revision_id, child_package_id,
                  child_package_digest, entrypoint, input_value_id, status, called_at_unix_millis,
                  called_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         'called', ?14, ?15)",
                params![
                    payload.invocation_id,
                    payload.run_id,
                    payload.attempt_id,
                    payload.execution_token_id,
                    payload.node_id,
                    payload.child_run_id,
                    payload.child_command_id,
                    payload.child_workflow_id,
                    payload.child_revision_id,
                    payload.child_package_id,
                    payload.child_package_digest,
                    payload.entrypoint,
                    input.value_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::SubflowSettled(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let called: Option<(String, String, String, String, String)> = transaction
                .query_row(
                    "SELECT child_run_id, child_workflow_id, child_revision_id,
                            child_package_digest, status
                     FROM workflow_subflows WHERE invocation_id = ?1 AND run_id = ?2",
                    params![payload.invocation_id, payload.run_id],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                        ))
                    },
                )
                .optional()?;
            let Some((child_run_id, child_workflow_id, child_revision_id, child_digest, status)) =
                called
            else {
                return lifecycle("subflow_call_missing");
            };
            if status != "called" || child_run_id != payload.child_run_id {
                return lifecycle("subflow_settled_mismatch");
            }
            let child: Option<(String, String, String, String, Option<String>, String)> =
                transaction
                    .query_row(
                        "SELECT workflow_id, revision_id, package_digest, status, outcome,
                            final_emission_ids_json
                     FROM workflow_runs WHERE run_id = ?1",
                        [&payload.child_run_id],
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
                workflow_id,
                revision_id,
                package_digest,
                child_status,
                child_outcome,
                child_final_ids,
            )) = child
            else {
                return lifecycle("subflow_child_run_missing");
            };
            let (outcome, _) = settled_outcome(payload.outcome, OutcomeDomain::Run)?;
            if workflow_id != child_workflow_id
                || revision_id != child_revision_id
                || package_digest != child_digest
                || child_status == "running"
                || child_outcome.as_deref() != Some(outcome)
                || child_final_ids != string_list_json(&payload.child_final_emission_ids)?
            {
                return lifecycle("subflow_child_run_mismatch");
            }
            let output_id = insert_optional_value(transaction, payload.output.as_ref())?;
            let error_id = insert_optional_value(transaction, payload.error.as_ref())?;
            transaction.execute(
                "UPDATE workflow_subflows
                 SET status = 'settled', outcome = ?1, output_value_id = ?2, error_code = NULLIF(?3, ''),
                     error_value_id = ?4, child_final_emission_ids_json = ?5,
                     settled_at_unix_millis = ?6, settled_store_position = ?7
                 WHERE invocation_id = ?8",
                params![
                    outcome,
                    output_id,
                    payload.error_code,
                    error_id,
                    string_list_json(&payload.child_final_emission_ids)?,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.invocation_id,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::RunTokenCreated(payload) => {
            if run_exists(transaction, &payload.run_id)?
                || purge_receipt_exists(transaction, &payload.run_id)?
            {
                return lifecycle("run_identity_reused");
            }
            let retention = WorkflowRunRetentionPolicy::from_proto(
                payload.retention_policy.as_ref(),
            )
            .map_err(|_| WorkflowProjectionError::Lifecycle("run_retention_policy".into()))?;
            let (retention_mode, retention_days) = match retention {
                WorkflowRunRetentionPolicy::Duration { days } => ("duration", days),
                WorkflowRunRetentionPolicy::DeleteAfterSuccess => ("delete-after-success", 0),
                WorkflowRunRetentionPolicy::Forever => ("forever", 0),
            };
            transaction.execute(
                "INSERT INTO workflow_runs
                 (run_id, run_token_id, request_command_id, workflow_id, revision_id, package_digest,
                  retention_mode, retention_days, status, created_at_unix_millis,
                  first_store_position, last_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'running', ?9, ?10, ?10)",
                params![
                    payload.run_id,
                    payload.run_token_id,
                    payload.request_command_id,
                    payload.workflow_id,
                    payload.revision_id,
                    payload.package_digest,
                    retention_mode,
                    i64::from(retention_days),
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
                  iteration_node_id, iteration_index, iteration_count, resume_node_id, resume_reason,
                  status, created_event_id, created_at_unix_millis, created_store_position)
                 VALUES (?1, ?2, ?3, NULLIF(?4, ''), NULLIF(?5, ''), NULLIF(?6, ''),
                         NULLIF(?7, ''), NULLIF(?8, ''), NULLIF(?9, ''), NULLIF(?10, ''),
                         ?11, ?12, NULLIF(?13, ''), NULLIF(?14, ''), 'active', ?15, ?16, ?17)",
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
                    payload.iteration_node_id,
                    (payload.iteration_count != 0).then_some(payload.iteration_index),
                    (payload.iteration_count != 0).then_some(payload.iteration_count),
                    payload.resume_node_id,
                    payload.resume_reason,
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
                v1::WorkflowExecutionTokenOutcome::Iterated => "iterated",
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
        WorkflowRuntimeEvent::IterationPlanned(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.controller_attempt_id,
                &payload.iteration_node_id,
                None,
                Some(&payload.parent_execution_token_id),
            )?;
            transaction.execute(
                "INSERT INTO workflow_iterations
                 (event_id, run_id, iteration_node_id, parent_execution_token_id,
                  controller_attempt_id, input_value_id, input_sha256, item_count,
                  maximum_items, maximum_concurrency, failure_policy,
                  planned_at_unix_millis, planned_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    event.event_id,
                    payload.run_id,
                    payload.iteration_node_id,
                    payload.parent_execution_token_id,
                    payload.controller_attempt_id,
                    payload.input_value_id,
                    payload.input_sha256,
                    payload.item_count,
                    payload.maximum_items,
                    payload.maximum_concurrency,
                    payload.failure_policy,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::IterationEvaluated(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let decision = match v1::WorkflowIterationDecision::try_from(payload.decision) {
                Ok(v1::WorkflowIterationDecision::Succeeded) => "succeeded",
                Ok(v1::WorkflowIterationDecision::Failed) => "failed",
                _ => return lifecycle("iteration_decision_invalid"),
            };
            let output = payload.output.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("iteration_output_missing".into())
            })?;
            insert_value(transaction, output)?;
            let updated = transaction.execute(
                "UPDATE workflow_iterations SET decision = ?1, resumed_execution_token_id = ?2,
                   expected_execution_token_ids_json = ?3,
                   succeeded_execution_token_ids_json = ?4,
                   failed_execution_token_ids_json = ?5,
                   pending_execution_token_ids_json = ?6,
                   error_code = NULLIF(?7, ''), output_value_id = ?8,
                   evaluated_at_unix_millis = ?9, evaluated_store_position = ?10
                 WHERE run_id = ?11 AND iteration_node_id = ?12
                   AND parent_execution_token_id = ?13 AND decision IS NULL",
                params![
                    decision,
                    payload.resumed_execution_token_id,
                    string_list_json(&payload.expected_execution_token_ids)?,
                    string_list_json(&payload.succeeded_execution_token_ids)?,
                    string_list_json(&payload.failed_execution_token_ids)?,
                    string_list_json(&payload.pending_execution_token_ids)?,
                    payload.error_code,
                    output.value_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.run_id,
                    payload.iteration_node_id,
                    payload.parent_execution_token_id,
                ],
            )?;
            if updated != 1 {
                return lifecycle("iteration_plan_not_active");
            }
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::RetryEvaluated(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.controller_attempt_id,
                &payload.retry_node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let decision = match v1::WorkflowRetryDecision::try_from(payload.decision) {
                Ok(v1::WorkflowRetryDecision::Scheduled) => "scheduled",
                Ok(v1::WorkflowRetryDecision::Exhausted) => "exhausted",
                Ok(v1::WorkflowRetryDecision::NotRetryable) => "not-retryable",
                Ok(v1::WorkflowRetryDecision::UnknownOutcome) => "unknown-outcome",
                _ => return lifecycle("retry_decision_invalid"),
            };
            let retry_input = payload
                .retry_input
                .as_ref()
                .ok_or_else(|| WorkflowProjectionError::Lifecycle("retry_input_missing".into()))?;
            let error = payload
                .error
                .as_ref()
                .ok_or_else(|| WorkflowProjectionError::Lifecycle("retry_error_missing".into()))?;
            insert_value(transaction, retry_input)?;
            insert_value(transaction, error)?;
            transaction.execute(
                "INSERT INTO workflow_retry_evaluations
                 (event_id, run_id, retry_node_id, execution_token_id, controller_attempt_id,
                  failed_attempt_id, target_node_id, error_code, decision, next_attempt_number,
                  maximum_attempts, delay_milliseconds, eligible_at_unix_millis,
                  retry_input_value_id, error_value_id, evaluated_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, ?16, ?17)",
                params![
                    event.event_id,
                    payload.run_id,
                    payload.retry_node_id,
                    payload.execution_token_id,
                    payload.controller_attempt_id,
                    payload.failed_attempt_id,
                    payload.target_node_id,
                    payload.error_code,
                    decision,
                    payload.next_attempt_number,
                    payload.maximum_attempts,
                    sql_u64(payload.delay_milliseconds)?,
                    (payload.eligible_at_unix_millis != 0)
                        .then_some(payload.eligible_at_unix_millis),
                    retry_input.value_id,
                    error.value_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::WaitSignalRecorded(payload) => {
            let value = payload.value.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("wait_signal_value_missing".into())
            })?;
            insert_value(transaction, value)?;
            transaction.execute(
                "INSERT INTO workflow_wait_signals
                 (signal_id, run_id, signal_command_id, kind, owner_kind, owner_id,
                  correlation_json, value_id, recorded_at_unix_millis, store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    payload.signal_id,
                    payload.run_id,
                    payload.signal_command_id,
                    payload.kind,
                    payload.owner_kind,
                    payload.owner_id,
                    wait_correlation_json(&payload.correlation)?,
                    value.value_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            if run_exists(transaction, &payload.run_id)? {
                touch_run(transaction, &payload.run_id, event.store_position)?;
            }
        }
        WorkflowRuntimeEvent::WaitSubscribed(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.controller_attempt_id,
                &payload.wait_node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let pins: (String, String, String) = transaction.query_row(
                "SELECT workflow_id, revision_id, package_digest FROM workflow_runs WHERE run_id = ?1",
                [&payload.run_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )?;
            if pins
                != (
                    payload.workflow_id.clone(),
                    payload.revision_id.clone(),
                    payload.package_digest.clone(),
                )
            {
                return lifecycle("wait_revision_pin_mismatch");
            }
            transaction.execute(
                "INSERT INTO workflow_waits
                 (subscription_id, run_id, run_token_id, wait_node_id, execution_token_id,
                  controller_attempt_id, workflow_id, revision_id, package_digest, kind,
                  owner_kind, owner_id, correlation_json, input_value_id, input_sha256,
                  status, expires_at_unix_millis, subscribed_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, 'waiting', ?16, ?17)",
                params![
                    payload.subscription_id,
                    payload.run_id,
                    payload.run_token_id,
                    payload.wait_node_id,
                    payload.execution_token_id,
                    payload.controller_attempt_id,
                    payload.workflow_id,
                    payload.revision_id,
                    payload.package_digest,
                    payload.kind,
                    payload.owner_kind,
                    payload.owner_id,
                    wait_correlation_json(&payload.correlation)?,
                    payload.input_value_id,
                    payload.input_sha256,
                    payload.expires_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::WaitResolved(payload) => {
            require_active_run(transaction, &payload.run_id, &payload.run_token_id)?;
            let wait: Option<(String, String)> = transaction
                .query_row(
                    "SELECT status, kind FROM workflow_waits
                     WHERE subscription_id = ?1 AND run_id = ?2 AND run_token_id = ?3",
                    params![
                        payload.subscription_id,
                        payload.run_id,
                        payload.run_token_id
                    ],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let Some((status, kind)) = wait else {
                return lifecycle("wait_subscription_missing");
            };
            if status != "waiting" {
                return lifecycle("wait_not_active");
            }
            let decision = match v1::WorkflowWaitDecision::try_from(payload.decision) {
                Ok(v1::WorkflowWaitDecision::Resumed) => "resumed",
                Ok(v1::WorkflowWaitDecision::Expired) => "expired",
                Ok(v1::WorkflowWaitDecision::Cancelled) => "cancelled",
                _ => return lifecycle("wait_decision_invalid"),
            };
            if decision == "resumed" && kind != "timer" {
                let signal_run: Option<String> = transaction
                    .query_row(
                        "SELECT run_id FROM workflow_wait_signals WHERE signal_id = ?1",
                        [&payload.signal_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                if signal_run.as_deref() != Some(payload.run_id.as_str()) {
                    return lifecycle("wait_resolving_signal_missing");
                }
            }
            let output_value_id = insert_optional_value(transaction, payload.output.as_ref())?;
            let updated = transaction.execute(
                "UPDATE workflow_waits SET status = ?1, decision = ?1,
                   resolving_signal_id = NULLIF(?2, ''), output_value_id = ?3,
                   reason_code = NULLIF(?4, ''), resolved_store_position = ?5
                 WHERE subscription_id = ?6 AND status = 'waiting'",
                params![
                    decision,
                    payload.signal_id,
                    output_value_id,
                    payload.reason_code,
                    sql_u64(event.store_position)?,
                    payload.subscription_id,
                ],
            )?;
            if updated != 1 {
                return lifecycle("wait_not_active");
            }
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
        WorkflowRuntimeEvent::CapabilityAttemptStarted(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let configuration = payload.configuration.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("capability_configuration_value_missing".into())
            })?;
            let input = payload.input.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("capability_input_value_missing".into())
            })?;
            insert_value(transaction, configuration)?;
            insert_value(transaction, input)?;
            let artifact_inputs = capability_artifacts_json(transaction, &payload.artifact_inputs)?;
            transaction.execute(
                "INSERT INTO workflow_capability_attempts
                 (invocation_id, run_id, attempt_id, execution_token_id, node_id, capability_id,
                  version, package_digest, configuration_contract_digest, input_schema_digest,
                  output_schema_digest, output_schema_ref, configuration_value_id, input_value_id,
                  artifact_inputs_json, status, timeout_milliseconds, deadline_unix_millis,
                  started_at_unix_millis, started_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                         ?15, 'running', ?16, ?17, ?18, ?19)",
                params![
                    payload.invocation_id,
                    payload.run_id,
                    payload.attempt_id,
                    payload.execution_token_id,
                    payload.node_id,
                    payload.capability_id,
                    payload.version,
                    payload.package_digest,
                    payload.configuration_contract_digest,
                    payload.input_schema_digest,
                    payload.output_schema_digest,
                    payload.output_schema_ref,
                    configuration.value_id,
                    input.value_id,
                    artifact_inputs,
                    sql_u64(payload.timeout_milliseconds)?,
                    payload.deadline_unix_millis,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::CapabilityAttemptSettled(payload) => {
            let current: Option<(String, String, String)> = transaction
                .query_row(
                    "SELECT run_id, attempt_id, status FROM workflow_capability_attempts
                     WHERE invocation_id = ?1",
                    [&payload.invocation_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            if current.as_ref().is_none_or(|(run_id, attempt_id, status)| {
                run_id != &payload.run_id
                    || attempt_id != &payload.attempt_id
                    || status != "running"
            }) {
                return lifecycle("capability_attempt_not_active");
            }
            let output_value_id = insert_optional_value(transaction, payload.output.as_ref())?;
            let error_value_id = insert_optional_value(transaction, payload.error.as_ref())?;
            let artifact_outputs =
                capability_artifacts_json(transaction, &payload.artifact_outputs)?;
            let logs = capability_logs_json(&payload.logs)?;
            transaction.execute(
                "UPDATE workflow_capability_attempts SET
                   status = 'settled', outcome = ?1, output_value_id = ?2,
                   artifact_outputs_json = ?3, error_code = NULLIF(?4, ''),
                   error_value_id = ?5, logs_json = ?6, elapsed_milliseconds = ?7,
                   receipt_id = NULLIF(?8, ''), provider_run_reference = NULLIF(?9, ''),
                   idempotency_key = ?10, settled_at_unix_millis = ?11,
                   settled_store_position = ?12
                 WHERE invocation_id = ?13",
                params![
                    capability_outcome_name(payload.outcome)?,
                    output_value_id,
                    artifact_outputs,
                    payload.error_code,
                    error_value_id,
                    logs,
                    sql_u64(payload.elapsed_milliseconds)?,
                    payload.receipt_id,
                    payload.provider_run_reference,
                    payload.idempotency_key,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    payload.invocation_id,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::LlmAttemptStarted(payload) => {
            require_active_attempt(
                transaction,
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                None,
                Some(&payload.execution_token_id),
            )?;
            let settings = payload
                .settings
                .as_ref()
                .ok_or_else(|| WorkflowProjectionError::Lifecycle("llm_settings_missing".into()))?;
            let report = payload.compilation_report.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("llm_compilation_report_missing".into())
            })?;
            let input = payload.input.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("llm_input_value_missing".into())
            })?;
            insert_value(transaction, input)?;
            let context_groups = llm_context_groups_json(transaction, &payload.context_groups)?;
            let messages = llm_messages_json(transaction, &payload.messages)?;
            let attachments = capability_artifacts_json(transaction, &payload.attachments)?;
            let tool_definitions = llm_tool_definitions_json(&payload.tool_definitions)?;
            transaction.execute(
                "INSERT INTO workflow_llm_attempts
                 (invocation_id, run_id, attempt_id, execution_token_id, node_id, settings_wire,
                  context_digest, context_groups_json, messages_json, prior_episode_ids_json,
                  attachments_json, compilation_report_wire, output_schema_ref,
                  output_schema_digest, input_value_id, status, timeout_milliseconds,
                  deadline_unix_millis, started_at_unix_millis, started_store_position,
                  tool_definitions_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         ?14, ?15, 'running', ?16, ?17, ?18, ?19, ?20)",
                params![
                    payload.invocation_id,
                    payload.run_id,
                    payload.attempt_id,
                    payload.execution_token_id,
                    payload.node_id,
                    settings.encode_to_vec(),
                    payload.context_digest,
                    context_groups,
                    messages,
                    string_list_json(&payload.prior_episode_ids)?,
                    attachments,
                    report.encode_to_vec(),
                    payload.output_schema_ref,
                    payload.output_schema_digest,
                    input.value_id,
                    sql_u64(payload.timeout_milliseconds)?,
                    payload.deadline_unix_millis,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    tool_definitions,
                ],
            )?;
            touch_run(transaction, &payload.run_id, event.store_position)?;
        }
        WorkflowRuntimeEvent::LlmAttemptSettled(payload) => {
            let current: Option<(String, String, String)> = transaction
                .query_row(
                    "SELECT run_id, attempt_id, status FROM workflow_llm_attempts
                     WHERE invocation_id = ?1",
                    [&payload.invocation_id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            if current.as_ref().is_none_or(|(run_id, attempt_id, status)| {
                run_id != &payload.run_id
                    || attempt_id != &payload.attempt_id
                    || status != "running"
            }) {
                return lifecycle("llm_attempt_not_active");
            }
            let output_value_id = insert_optional_value(transaction, payload.output.as_ref())?;
            let error_value_id = insert_optional_value(transaction, payload.error.as_ref())?;
            let tool_calls = llm_tool_calls_json(transaction, &payload.tool_calls)?;
            let response_messages =
                llm_response_messages_json(transaction, &payload.response_messages)?;
            transaction.execute(
                "UPDATE workflow_llm_attempts SET
                   status = 'settled', outcome = ?1, output_value_id = ?2,
                   error_code = NULLIF(?3, ''), error_value_id = ?4,
                   elapsed_milliseconds = ?5, receipt_id = NULLIF(?6, ''),
                   provider_run_reference = NULLIF(?7, ''), idempotency_key = ?8,
                   settled_at_unix_millis = ?9, settled_store_position = ?10,
                   tool_calls_json = ?11, response_messages_json = ?12,
                   usage_wire = ?13, validation_wire = ?14, provider_receipt_wire = ?15
                 WHERE invocation_id = ?16",
                params![
                    llm_outcome_name(payload.outcome)?,
                    output_value_id,
                    payload.error_code,
                    error_value_id,
                    sql_u64(payload.elapsed_milliseconds)?,
                    payload.receipt_id,
                    payload.provider_run_reference,
                    payload.idempotency_key,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                    tool_calls,
                    response_messages,
                    payload.usage.as_ref().map(Message::encode_to_vec),
                    payload.validation.as_ref().map(Message::encode_to_vec),
                    payload
                        .provider_receipt
                        .as_ref()
                        .map(Message::encode_to_vec),
                    payload.invocation_id,
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
        WorkflowRuntimeEvent::RunPurged(payload) => {
            let mode = match v1::WorkflowRunPurgeMode::try_from(payload.mode) {
                Ok(v1::WorkflowRunPurgeMode::Manual) => "manual",
                Ok(v1::WorkflowRunPurgeMode::Automatic) => "automatic",
                _ => return lifecycle("purge_mode_invalid"),
            };
            let existing: Option<(String, String, String, i64, i64, String)> = transaction
                .query_row(
                    "SELECT workflow_id, revision_id, package_digest, first_store_position,
                            last_store_position, status
                     FROM workflow_runs WHERE run_id = ?1",
                    [&payload.run_id],
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
            if let Some((workflow_id, revision_id, package_digest, first, last, status)) = existing
            {
                let event_count: i64 = transaction.query_row(
                    "SELECT COUNT(*) FROM workflow_projected_events WHERE run_id = ?1",
                    [&payload.run_id],
                    |row| row.get(0),
                )?;
                if workflow_id != payload.workflow_id
                    || revision_id != payload.revision_id
                    || package_digest != payload.package_digest
                    || first != sql_u64(payload.source_first_store_position)?
                    || last != sql_u64(payload.source_last_store_position)?
                    || event_count != sql_u64(payload.source_event_count)?
                    || matches!(status.as_str(), "running" | "cancelling")
                {
                    return lifecycle("purge_source_mismatch");
                }
                delete_projected_run(transaction, &payload.run_id)?;
            }
            transaction.execute(
                "INSERT INTO workflow_run_purge_receipts
                 (run_id, purge_event_id, purge_command_id, workflow_id, revision_id,
                  package_digest, mode, preview_evidence_digest, source_first_store_position,
                  source_last_store_position, source_event_count, affected_attempt_count,
                  affected_value_count, affected_file_handle_count,
                  retained_promoted_handle_ids_json, affected_value_bytes, installation_id,
                  historical_revision_retained, purged_at_unix_millis, purge_store_position)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                         ?14, ?15, ?16, ?17, 1, ?18, ?19)",
                params![
                    payload.run_id,
                    event.event_id,
                    payload.purge_command_id,
                    payload.workflow_id,
                    payload.revision_id,
                    payload.package_digest,
                    mode,
                    payload.preview_evidence_digest,
                    sql_u64(payload.source_first_store_position)?,
                    sql_u64(payload.source_last_store_position)?,
                    sql_u64(payload.source_event_count)?,
                    sql_u64(payload.affected_attempt_count)?,
                    sql_u64(payload.affected_value_count)?,
                    sql_u64(payload.affected_file_handle_count)?,
                    string_list_json(&payload.retained_promoted_handle_ids)?,
                    sql_u64(payload.affected_value_bytes)?,
                    payload.installation_id,
                    event.occurred_at_unix_millis,
                    sql_u64(event.store_position)?,
                ],
            )?;
        }
    }
    if run_exists(transaction, &run_id)? {
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
    }
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

fn purge_receipt_exists(transaction: &Transaction<'_>, run_id: &str) -> Result<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM workflow_run_purge_receipts WHERE run_id = ?1",
            [run_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn delete_projected_run(transaction: &Transaction<'_>, run_id: &str) -> Result<()> {
    let case: Option<(String, String)> = transaction
        .query_row(
            "SELECT installation_id, case_id FROM workflow_episodes WHERE run_id = ?1",
            [run_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((installation_id, case_id)) = case.as_ref() {
        let episode_count: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM workflow_episodes
             WHERE installation_id = ?1 AND case_id = ?2",
            params![installation_id, case_id],
            |row| row.get(0),
        )?;
        // Purging one member out of an immutable multi-episode chain would
        // either rewrite later provenance or leave a misleading gap. Preserve
        // the chain until a case-wide tombstone contract exists.
        if episode_count > 1 {
            return lifecycle("purge_case_chain_protected");
        }
    }
    let deleted = transaction.execute("DELETE FROM workflow_runs WHERE run_id = ?1", [run_id])?;
    if deleted != 1 {
        return lifecycle("purge_run_missing");
    }
    if let Some((installation_id, case_id)) = case {
        transaction.execute(
            "DELETE FROM workflow_cases WHERE installation_id = ?1 AND case_id = ?2",
            params![installation_id, case_id],
        )?;
    }
    prune_unreferenced_values(transaction)
}

fn prune_unreferenced_values(transaction: &Transaction<'_>) -> Result<()> {
    let retained = retained_value_ids(transaction)?;
    let value_ids = {
        let mut statement = transaction.prepare("SELECT value_id FROM workflow_values")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()?
    };
    for value_id in value_ids {
        if retained.contains(&value_id) {
            continue;
        }
        match transaction.execute(
            "DELETE FROM workflow_values WHERE value_id = ?1",
            [&value_id],
        ) {
            Ok(_) => {}
            Err(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::ConstraintViolation => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn retained_value_ids(transaction: &Transaction<'_>) -> Result<BTreeSet<String>> {
    let mut retained = BTreeSet::new();
    let mut statement = transaction.prepare(
        "SELECT input_value_id FROM workflow_match_traces
         UNION SELECT input_value_id FROM workflow_iterations
         UNION SELECT input_value_id FROM workflow_waits",
    )?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    retained.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);

    for column in ["artifact_inputs_json", "artifact_outputs_json"] {
        for document in
            optional_json_documents(transaction, "workflow_capability_attempts", column)?
        {
            let records: Vec<CapabilityArtifactRecord> =
                serde_json::from_str(&document).map_err(|_| {
                    WorkflowProjectionError::Integrity("capability_artifacts_decode".into())
                })?;
            retained.extend(records.into_iter().map(|record| record.value_id));
        }
    }
    for document in
        optional_json_documents(transaction, "workflow_llm_attempts", "context_groups_json")?
    {
        let records: Vec<LlmContextGroupRecord> = serde_json::from_str(&document)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_context_groups_decode".into()))?;
        retained.extend(records.into_iter().map(|record| record.content_value_id));
    }
    for document in optional_json_documents(transaction, "workflow_llm_attempts", "messages_json")?
    {
        let records: Vec<LlmMessageRecord> = serde_json::from_str(&document)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_messages_decode".into()))?;
        retained.extend(records.into_iter().map(|record| record.content_value_id));
    }
    for document in
        optional_json_documents(transaction, "workflow_llm_attempts", "attachments_json")?
    {
        let records: Vec<CapabilityArtifactRecord> =
            serde_json::from_str(&document).map_err(|_| {
                WorkflowProjectionError::Integrity("capability_artifacts_decode".into())
            })?;
        retained.extend(records.into_iter().map(|record| record.value_id));
    }
    for document in
        optional_json_documents(transaction, "workflow_llm_attempts", "tool_calls_json")?
    {
        let records: Vec<LlmToolCallRecord> = serde_json::from_str(&document)
            .map_err(|_| WorkflowProjectionError::Integrity("llm_tool_calls_decode".into()))?;
        for record in records {
            retained.insert(record.input_value_id);
            retained.extend(record.output_value_id);
            retained.extend(record.error_value_id);
        }
    }
    for document in optional_json_documents(
        transaction,
        "workflow_llm_attempts",
        "response_messages_json",
    )? {
        let records: Vec<LlmResponseMessageRecord> =
            serde_json::from_str(&document).map_err(|_| {
                WorkflowProjectionError::Integrity("llm_response_messages_decode".into())
            })?;
        retained.extend(records.into_iter().map(|record| record.content_value_id));
    }
    Ok(retained)
}

fn optional_json_documents(
    transaction: &Transaction<'_>,
    table: &str,
    column: &str,
) -> Result<Vec<String>> {
    let allowed = matches!(
        (table, column),
        ("workflow_capability_attempts", "artifact_inputs_json")
            | ("workflow_capability_attempts", "artifact_outputs_json")
            | ("workflow_llm_attempts", "context_groups_json")
            | ("workflow_llm_attempts", "messages_json")
            | ("workflow_llm_attempts", "attachments_json")
            | ("workflow_llm_attempts", "tool_calls_json")
            | ("workflow_llm_attempts", "response_messages_json")
    );
    if !allowed {
        return Err(WorkflowProjectionError::Integrity(
            "value_reference_column".into(),
        ));
    }
    let sql = format!("SELECT {column} FROM {table} WHERE {column} IS NOT NULL");
    let mut statement = transaction.prepare(&sql)?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
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

fn capability_artifacts_json(
    transaction: &Transaction<'_>,
    values: &[v1::WorkflowCapabilityArtifactHandle],
) -> Result<String> {
    let records = values
        .iter()
        .map(|artifact| {
            let value = artifact.value.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("capability_artifact_value_missing".into())
            })?;
            insert_value(transaction, value)?;
            Ok(CapabilityArtifactRecord {
                handle_id: artifact.handle_id.clone(),
                role: artifact.role.clone(),
                value_id: value.value_id.clone(),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("capability_artifacts_encode".into()))
}

fn capability_logs_json(values: &[v1::WorkflowCapabilityLogEntry]) -> Result<String> {
    let records = values
        .iter()
        .map(|log| CapabilityLogRecord {
            sequence: log.sequence,
            level: log.level.clone(),
            message: log.message.clone(),
            offset_milliseconds: log.offset_milliseconds,
        })
        .collect::<Vec<_>>();
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("capability_logs_encode".into()))
}

fn llm_context_groups_json(
    transaction: &Transaction<'_>,
    values: &[v1::WorkflowLlmContextGroup],
) -> Result<String> {
    let records = values
        .iter()
        .map(|group| {
            let content = group.content.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("llm_context_value_missing".into())
            })?;
            insert_value(transaction, content)?;
            Ok(LlmContextGroupRecord {
                group_id: group.group_id.clone(),
                kind: group.kind.clone(),
                title: group.title.clone(),
                provenance: group.provenance.clone(),
                content_value_id: content.value_id.clone(),
                original_byte_count: group.original_byte_count,
                retained_byte_count: group.retained_byte_count,
                redaction_count: group.redaction_count,
                truncated: group.truncated,
                source_episode_ids: group.source_episode_ids.clone(),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_context_groups_encode".into()))
}

fn llm_messages_json(
    _transaction: &Transaction<'_>,
    values: &[v1::WorkflowLlmMessage],
) -> Result<String> {
    let records = values
        .iter()
        .map(|message| {
            Ok(LlmMessageRecord {
                message_id: message.message_id.clone(),
                sequence: message.sequence,
                role: message.role.clone(),
                context_group_id: message.context_group_id.clone(),
                summary: message.summary.clone(),
                content_value_id: message.content_value_id.clone(),
                estimated_tokens: message.estimated_tokens,
                redaction_count: message.redaction_count,
                truncated: message.truncated,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_messages_encode".into()))
}

fn llm_tool_definitions_json(values: &[v1::WorkflowLlmToolDefinition]) -> Result<String> {
    let records = values
        .iter()
        .map(|value| LlmToolDefinitionRecord {
            tool_id: value.tool_id.clone(),
            version: value.version.clone(),
            package_digest: value.package_digest.clone(),
            description: value.description.clone(),
            input_schema_ref: value.input_schema_ref.clone(),
            input_schema_digest: value.input_schema_digest.clone(),
            output_schema_ref: value.output_schema_ref.clone(),
            output_schema_digest: value.output_schema_digest.clone(),
        })
        .collect::<Vec<_>>();
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_tool_definitions_encode".into()))
}

fn decode_llm_tool_definitions(value: &str) -> Result<Vec<v1::WorkflowLlmToolDefinition>> {
    let records: Vec<LlmToolDefinitionRecord> = serde_json::from_str(value)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_tool_definitions_decode".into()))?;
    Ok(records
        .into_iter()
        .map(|value| v1::WorkflowLlmToolDefinition {
            tool_id: value.tool_id,
            version: value.version,
            package_digest: value.package_digest,
            description: value.description,
            input_schema_ref: value.input_schema_ref,
            input_schema_digest: value.input_schema_digest,
            output_schema_ref: value.output_schema_ref,
            output_schema_digest: value.output_schema_digest,
        })
        .collect())
}

fn decode_optional_message<M: Message + Default>(
    value: Option<&[u8]>,
    code: &'static str,
) -> Result<Option<M>> {
    value
        .map(|bytes| M::decode(bytes).map_err(|_| WorkflowProjectionError::Integrity(code.into())))
        .transpose()
}

fn llm_tool_calls_json(
    transaction: &Transaction<'_>,
    values: &[v1::WorkflowLlmToolCall],
) -> Result<String> {
    let records = values
        .iter()
        .map(|value| {
            let input = value.input.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("llm_tool_call_input_missing".into())
            })?;
            insert_value(transaction, input)?;
            let output_value_id = insert_optional_value(transaction, value.output.as_ref())?;
            let error_value_id = insert_optional_value(transaction, value.error.as_ref())?;
            Ok(LlmToolCallRecord {
                call_id: value.call_id.clone(),
                sequence: value.sequence,
                tool_id: value.tool_id.clone(),
                status: value.status.clone(),
                input_value_id: input.value_id.clone(),
                output_value_id,
                error_code: value.error_code.clone(),
                error_value_id,
                duration_milliseconds: value.duration_milliseconds,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_tool_calls_encode".into()))
}

fn llm_response_messages_json(
    transaction: &Transaction<'_>,
    values: &[v1::WorkflowLlmResponseMessage],
) -> Result<String> {
    let records = values
        .iter()
        .map(|value| {
            let content = value.content.as_ref().ok_or_else(|| {
                WorkflowProjectionError::Lifecycle("llm_response_content_missing".into())
            })?;
            insert_value(transaction, content)?;
            Ok(LlmResponseMessageRecord {
                message_id: value.message_id.clone(),
                sequence: value.sequence,
                role: value.role.clone(),
                kind: value.kind.clone(),
                summary: value.summary.clone(),
                content_value_id: content.value_id.clone(),
                tool_call_id: value.tool_call_id.clone(),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    serde_json::to_string(&records)
        .map_err(|_| WorkflowProjectionError::Integrity("llm_response_messages_encode".into()))
}

fn llm_outcome_name(value: i32) -> Result<&'static str> {
    match v1::WorkflowLlmAttemptOutcome::try_from(value) {
        Ok(v1::WorkflowLlmAttemptOutcome::Succeeded) => Ok("succeeded"),
        Ok(v1::WorkflowLlmAttemptOutcome::OutputValidationFailed) => Ok("output_validation_failed"),
        Ok(v1::WorkflowLlmAttemptOutcome::TimedOut) => Ok("timed_out"),
        Ok(v1::WorkflowLlmAttemptOutcome::Cancelled) => Ok("cancelled"),
        Ok(v1::WorkflowLlmAttemptOutcome::MalformedResult) => Ok("malformed_result"),
        Ok(v1::WorkflowLlmAttemptOutcome::Crashed) => Ok("crashed"),
        _ => lifecycle("llm_outcome_invalid"),
    }
}

fn capability_outcome_name(value: i32) -> Result<&'static str> {
    match v1::WorkflowCapabilityAttemptOutcome::try_from(value) {
        Ok(v1::WorkflowCapabilityAttemptOutcome::Succeeded) => Ok("succeeded"),
        Ok(v1::WorkflowCapabilityAttemptOutcome::InputValidationFailed) => {
            Ok("input_validation_failed")
        }
        Ok(v1::WorkflowCapabilityAttemptOutcome::OutputValidationFailed) => {
            Ok("output_validation_failed")
        }
        Ok(v1::WorkflowCapabilityAttemptOutcome::TimedOut) => Ok("timed_out"),
        Ok(v1::WorkflowCapabilityAttemptOutcome::Cancelled) => Ok("cancelled"),
        Ok(v1::WorkflowCapabilityAttemptOutcome::MalformedResult) => Ok("malformed_result"),
        Ok(v1::WorkflowCapabilityAttemptOutcome::Crashed) => Ok("crashed"),
        _ => lifecycle("capability_outcome_invalid"),
    }
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

fn wait_correlation_json(values: &[v1::WorkflowWaitCorrelation]) -> Result<String> {
    let pairs = values
        .iter()
        .map(|value| [value.key.clone(), value.sha256.clone()])
        .collect::<Vec<_>>();
    serde_json::to_string(&pairs)
        .map_err(|_| WorkflowProjectionError::Integrity("wait_correlation_encode_failed".into()))
}

fn decode_wait_correlation(value: &str) -> Result<Vec<v1::WorkflowWaitCorrelation>> {
    let pairs: Vec<[String; 2]> = serde_json::from_str(value)
        .map_err(|_| WorkflowProjectionError::Integrity("wait_correlation_decode_failed".into()))?;
    Ok(pairs
        .into_iter()
        .map(|[key, sha256]| v1::WorkflowWaitCorrelation { key, sha256 })
        .collect())
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

fn apply_projection_migration_11(transaction: &Transaction<'_>) -> Result<()> {
    for (column, declaration) in [
        ("tool_definitions_json", "TEXT NOT NULL DEFAULT '[]'"),
        ("tool_calls_json", "TEXT"),
        ("response_messages_json", "TEXT"),
        ("usage_wire", "BLOB"),
        ("validation_wire", "BLOB"),
        ("provider_receipt_wire", "BLOB"),
    ] {
        if !table_has_column(transaction, "workflow_llm_attempts", column)? {
            transaction.execute_batch(&format!(
                "ALTER TABLE workflow_llm_attempts ADD COLUMN {column} {declaration};"
            ))?;
        }
    }
    Ok(())
}

fn apply_projection_migration_12(transaction: &Transaction<'_>) -> Result<()> {
    for (column, declaration) in [
        (
            "retention_mode",
            "TEXT NOT NULL DEFAULT 'duration' CHECK (retention_mode IN ('duration', 'delete-after-success', 'forever'))",
        ),
        (
            "retention_days",
            "INTEGER NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 0 AND 3650)",
        ),
    ] {
        if !table_has_column(transaction, "workflow_runs", column)? {
            transaction.execute_batch(&format!(
                "ALTER TABLE workflow_runs ADD COLUMN {column} {declaration};"
            ))?;
        }
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
                "SELECT run_id, run_token_id, request_command_id, workflow_id, revision_id, package_digest, status, outcome, error_code, error_value_id, final_emission_ids_json, cancellation_command_id, cancellation_reason_code, retention_mode, retention_days, created_at_unix_millis, settled_at_unix_millis, first_store_position, last_store_position FROM workflow_runs ORDER BY run_id",
                19,
            )?,
            table_rows(
                connection,
                "cases",
                "SELECT installation_id, case_id, workflow_id, first_episode_id, last_episode_id, episode_count, created_at_unix_millis, updated_at_unix_millis, first_store_position, last_store_position FROM workflow_cases ORDER BY installation_id, case_id",
                10,
            )?,
            table_rows(
                connection,
                "episodes",
                "SELECT episode_id, installation_id, case_id, run_id, run_token_id, ordinal, kind, prior_episode_id, workflow_id, revision_id, package_digest, trigger_kind, trigger_event_id, compiled_context_value_id, source_episode_ids_json, source_event_ids_json, started_at_unix_millis, started_store_position FROM workflow_episodes ORDER BY installation_id, case_id, ordinal, episode_id",
                18,
            )?,
            table_rows(
                connection,
                "episode_inputs",
                "SELECT episode_id, port_id, value_id, ordinal FROM workflow_episode_inputs ORDER BY episode_id, ordinal, port_id",
                4,
            )?,
            table_rows(
                connection,
                "subflows",
                "SELECT invocation_id, run_id, attempt_id, execution_token_id, node_id, child_run_id, child_command_id, child_workflow_id, child_revision_id, child_package_id, child_package_digest, entrypoint, input_value_id, status, outcome, output_value_id, error_code, error_value_id, child_final_emission_ids_json, called_at_unix_millis, settled_at_unix_millis, called_store_position, settled_store_position FROM workflow_subflows ORDER BY run_id, called_store_position, invocation_id",
                23,
            )?,
            table_rows(
                connection,
                "capability_attempts",
                "SELECT invocation_id, run_id, attempt_id, execution_token_id, node_id, capability_id, version, package_digest, configuration_contract_digest, input_schema_digest, output_schema_digest, output_schema_ref, configuration_value_id, input_value_id, artifact_inputs_json, status, outcome, output_value_id, artifact_outputs_json, error_code, error_value_id, logs_json, timeout_milliseconds, deadline_unix_millis, elapsed_milliseconds, receipt_id, provider_run_reference, idempotency_key, started_at_unix_millis, settled_at_unix_millis, started_store_position, settled_store_position FROM workflow_capability_attempts ORDER BY run_id, started_store_position, invocation_id",
                32,
            )?,
            table_rows(
                connection,
                "llm_attempts",
                "SELECT invocation_id, run_id, attempt_id, execution_token_id, node_id, settings_wire, context_digest, context_groups_json, messages_json, prior_episode_ids_json, attachments_json, compilation_report_wire, output_schema_ref, output_schema_digest, input_value_id, status, outcome, output_value_id, error_code, error_value_id, timeout_milliseconds, deadline_unix_millis, elapsed_milliseconds, receipt_id, provider_run_reference, idempotency_key, started_at_unix_millis, settled_at_unix_millis, started_store_position, settled_store_position, tool_definitions_json, tool_calls_json, response_messages_json, usage_wire, validation_wire, provider_receipt_wire FROM workflow_llm_attempts ORDER BY run_id, started_store_position, invocation_id",
                36,
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
                "SELECT execution_token_id, run_id, run_token_id, parent_execution_token_id, fork_node_id, branch_id, branch_port_id, join_node_id, source_emission_id, iteration_node_id, iteration_index, iteration_count, resume_node_id, resume_reason, status, outcome, terminal_node_id, error_code, error_value_id, final_emission_ids_json, created_event_id, settled_event_id, created_at_unix_millis, settled_at_unix_millis, created_store_position, settled_store_position FROM workflow_execution_tokens ORDER BY run_id, created_store_position, execution_token_id",
                26,
            )?,
            table_rows(
                connection,
                "joins",
                "SELECT event_id, run_id, join_node_id, fork_node_id, resumed_execution_token_id, policy, threshold, decision, expected_execution_token_ids_json, arrived_execution_token_ids_json, failed_execution_token_ids_json, pending_execution_token_ids_json, cancel_remaining, error_code, evaluated_at_unix_millis, store_position FROM workflow_join_evaluations ORDER BY run_id, store_position, event_id",
                16,
            )?,
            table_rows(
                connection,
                "iterations",
                "SELECT event_id, run_id, iteration_node_id, parent_execution_token_id, controller_attempt_id, input_value_id, input_sha256, item_count, maximum_items, maximum_concurrency, failure_policy, decision, resumed_execution_token_id, expected_execution_token_ids_json, succeeded_execution_token_ids_json, failed_execution_token_ids_json, pending_execution_token_ids_json, error_code, output_value_id, planned_at_unix_millis, evaluated_at_unix_millis, planned_store_position, evaluated_store_position FROM workflow_iterations ORDER BY run_id, planned_store_position, event_id",
                23,
            )?,
            table_rows(
                connection,
                "retries",
                "SELECT event_id, run_id, retry_node_id, execution_token_id, controller_attempt_id, failed_attempt_id, target_node_id, error_code, decision, next_attempt_number, maximum_attempts, delay_milliseconds, eligible_at_unix_millis, retry_input_value_id, error_value_id, evaluated_at_unix_millis, store_position FROM workflow_retry_evaluations ORDER BY run_id, store_position, event_id",
                17,
            )?,
            table_rows(
                connection,
                "waits",
                "SELECT subscription_id, run_id, run_token_id, wait_node_id, execution_token_id, controller_attempt_id, workflow_id, revision_id, package_digest, kind, owner_kind, owner_id, correlation_json, input_value_id, input_sha256, status, decision, resolving_signal_id, output_value_id, reason_code, expires_at_unix_millis, subscribed_store_position, resolved_store_position FROM workflow_waits ORDER BY run_id, subscribed_store_position, subscription_id",
                23,
            )?,
            table_rows(
                connection,
                "wait_signals",
                "SELECT signal_id, run_id, signal_command_id, kind, owner_kind, owner_id, correlation_json, value_id, recorded_at_unix_millis, store_position FROM workflow_wait_signals ORDER BY run_id, store_position, signal_id",
                10,
            )?,
            table_rows(
                connection,
                "events",
                "SELECT event_id, run_id, kind, store_position, stream_sequence, occurred_at_unix_millis FROM workflow_projected_events ORDER BY store_position, event_id",
                6,
            )?,
            table_rows(
                connection,
                "purge_receipts",
                "SELECT run_id, purge_event_id, purge_command_id, workflow_id, revision_id, package_digest, mode, preview_evidence_digest, source_first_store_position, source_last_store_position, source_event_count, affected_attempt_count, affected_value_count, affected_file_handle_count, retained_promoted_handle_ids_json, affected_value_bytes, installation_id, historical_revision_retained, purged_at_unix_millis, purge_store_position FROM workflow_run_purge_receipts ORDER BY purge_store_position, run_id",
                20,
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

#[cfg(test)]
mod purge_preview_tests {
    use super::*;

    fn projected_value(
        value_id: &str,
        handle_id: &str,
        scope: &str,
        source_version_id: &str,
        byte_count: u64,
    ) -> v1::WorkflowProjectedValue {
        v1::WorkflowProjectedValue {
            value_id: value_id.into(),
            byte_count,
            storage: Some(v1::WorkflowStorageValueMetadata {
                handle_id: handle_id.into(),
                scope: scope.into(),
                source_version_id: source_version_id.into(),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn preview_deletes_job_values_and_retains_promoted_objects() {
        let run = v1::WorkflowProjectedRun {
            run_id: "run-retention-preview".into(),
            status: "succeeded".into(),
            outcome: "succeeded".into(),
            settled_at_unix_millis: 1_000,
            retention_policy: Some(WorkflowRunRetentionPolicy::DeleteAfterSuccess.as_proto()),
            attempts: vec![v1::WorkflowProjectedAttempt {
                attempt_id: "attempt-retention-preview".into(),
                ..Default::default()
            }],
            emissions: vec![
                v1::WorkflowProjectedEmission {
                    value: Some(projected_value("value-job", "handle-job", "job", "", 24)),
                    ..Default::default()
                },
                v1::WorkflowProjectedEmission {
                    value: Some(projected_value(
                        "value-promoted",
                        "handle-case",
                        "case",
                        "version-job-source",
                        48,
                    )),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };

        let preview = projected_purge_preview(&run, 1_000).unwrap();
        assert!(preview.manual_eligible);
        assert!(preview.automatic_eligible);
        assert_eq!(preview.affected_attempt_ids, ["attempt-retention-preview"]);
        assert_eq!(preview.affected_value_ids, ["value-job"]);
        assert_eq!(preview.affected_file_handle_ids, ["handle-job"]);
        assert_eq!(preview.retained_promoted_handle_ids, ["handle-case"]);
        assert_eq!(preview.affected_value_bytes, 24);
        assert_eq!(preview.evidence_digest.len(), 64);
    }

    #[test]
    fn preview_protects_case_episode_chains_from_run_only_purge() {
        let run = v1::WorkflowProjectedRun {
            run_id: "run-case-episode".into(),
            status: "succeeded".into(),
            outcome: "succeeded".into(),
            settled_at_unix_millis: 1_000,
            retention_policy: Some(WorkflowRunRetentionPolicy::DeleteAfterSuccess.as_proto()),
            episode: Some(Default::default()),
            ..Default::default()
        };

        let preview = projected_purge_preview(&run, 1_000).unwrap();
        assert!(!preview.manual_eligible);
        assert!(!preview.automatic_eligible);
        assert_eq!(preview.protected_reason, "case_episode");
    }
}
