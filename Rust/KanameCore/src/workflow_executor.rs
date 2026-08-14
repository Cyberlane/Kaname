//! Minimal durable local workflow executor.
//!
//! The executor consumes only a verified immutable compiled revision and the
//! typed journal contracts. It advances one deterministic event boundary at a
//! time, so resubmitting the same request after a process crash can only append
//! the next missing fact. This bounded slice supports typed scoped storage but
//! no connector, model, capability, arbitrary mapping, or external effect.

use crate::{
    journal::{Journal, JournalError, ReplayBasis},
    v1, workflow_canonical,
    workflow_library::{WorkflowLibraryError, WorkflowLibraryStore},
    workflow_match::{self, EvaluationOutcome, MatchConfig, MatchRoots, TraceOutcome},
    workflow_runtime::{self, WorkflowRuntimeCommand, WorkflowRuntimeEvent},
    workflow_schema::{self, WorkflowSchemaCheckOutcome, WorkflowSchemaCheckRequest},
    workflow_storage::{
        WorkflowScopedStorage, WorkflowStorageAccessContext, WorkflowStorageDeleteRequest,
        WorkflowStorageError, WorkflowStorageHandle, WorkflowStorageListRequest,
        WorkflowStorageNamespace, WorkflowStorageNamespaceQuota, WorkflowStoragePromoteRequest,
        WorkflowStorageReadRequest, WorkflowStorageScopeKind, WorkflowStorageValueInput,
        WorkflowStorageWriteRequest,
    },
    workflow_versions::WorkflowExecutionSupport,
};
use prost::Message;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    time::{SystemTime, UNIX_EPOCH},
};

const MAXIMUM_EXECUTOR_TRANSITIONS: usize = 1_024;
const RUN_REPLAY_PAGE: u32 = 500;
const CASE_HISTORY_PAGE: u32 = 500;
const MAXIMUM_CASE_EPISODES: usize = 64;
const MAXIMUM_INLINE_STORAGE_SUMMARY_BYTES: usize = 60 * 1024;

#[derive(Debug)]
pub enum WorkflowExecutionError {
    Journal(JournalError),
    Library(WorkflowLibraryError),
    Storage(WorkflowStorageError),
    InvalidCommand(&'static str),
    Unsupported(String),
    Integrity(String),
    Lifecycle(String),
    Encoding(&'static str),
    WaitingUntil(i64),
    InjectedInterruption,
}

impl fmt::Display for WorkflowExecutionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Journal(error) => write!(formatter, "workflow execution journal: {error}"),
            Self::Library(error) => write!(formatter, "workflow execution library: {error}"),
            Self::Storage(error) => write!(formatter, "workflow execution storage: {error}"),
            Self::InvalidCommand(code) => write!(formatter, "workflow execution command: {code}"),
            Self::Unsupported(code) => write!(formatter, "workflow execution unsupported: {code}"),
            Self::Integrity(code) => write!(formatter, "workflow execution integrity: {code}"),
            Self::Lifecycle(code) => write!(formatter, "workflow execution lifecycle: {code}"),
            Self::Encoding(code) => write!(formatter, "workflow execution encoding: {code}"),
            Self::WaitingUntil(deadline) => {
                write!(formatter, "workflow execution waiting until: {deadline}")
            }
            Self::InjectedInterruption => formatter.write_str("workflow execution interrupted"),
        }
    }
}

impl std::error::Error for WorkflowExecutionError {}

impl From<JournalError> for WorkflowExecutionError {
    fn from(value: JournalError) -> Self {
        Self::Journal(value)
    }
}

impl From<WorkflowLibraryError> for WorkflowExecutionError {
    fn from(value: WorkflowLibraryError) -> Self {
        Self::Library(value)
    }
}

impl From<WorkflowStorageError> for WorkflowExecutionError {
    fn from(value: WorkflowStorageError) -> Self {
        Self::Storage(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowExecutionError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableRunOutcome {
    Running,
    Waiting,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowExecutionResult {
    pub run_id: String,
    pub run_token_id: String,
    pub outcome: DurableRunOutcome,
    pub event_count: usize,
    pub next_attempt_at_unix_millis: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowExecutionFault {
    AfterNewEvent(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowCancellationReceipt {
    pub run_id: String,
    pub run_token_id: String,
    pub event_id: String,
    pub duplicate: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowWaitSignalReceipt {
    pub run_id: String,
    pub signal_id: String,
    pub event_id: String,
    pub duplicate: bool,
}

/// Host-resolved storage ownership. Runtime request fields pin these values in
/// the journal, but never authorize themselves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowStorageExecutionAuthority {
    pub installation_id: String,
    pub case_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledWorkflow {
    compiled_format_version: u32,
    workflow_id: String,
    package_id: String,
    definition_digest: String,
    layout_digest: String,
    schema_bundle_digest: String,
    dependency_lock_digest: String,
    configuration_contract_digest: String,
    entrypoints: Vec<CompiledEntrypoint>,
    nodes: Vec<CompiledNode>,
    edges: Vec<CompiledEdge>,
    resources: BTreeMap<String, String>,
    policies: BTreeMap<String, Value>,
    storage: BTreeMap<String, CompiledStorageDeclaration>,
    dependencies: Vec<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledEntrypoint {
    id: String,
    node_id: String,
    #[serde(default)]
    key: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledNode {
    id: String,
    key: String,
    name: String,
    #[serde(rename = "type")]
    node_type: String,
    type_version: u32,
    execution_availability: String,
    config: Value,
    ports: Vec<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledEdge {
    id: String,
    from: CompiledEndpoint,
    to: CompiledEndpoint,
    mapping_id: String,
    mapping: Value,
    #[serde(default)]
    ignored: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledEndpoint {
    node_id: String,
    port_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeSchemaBundle {
    bundle_version: u32,
    schemas: Vec<RuntimeSchema>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RuntimeSchema {
    id: String,
    schema: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledStorageDeclaration {
    key: String,
    scope: String,
    kind: String,
    schema_ref: String,
    maximum_bytes: u64,
    classification: String,
    #[serde(default)]
    conflict_policy: Option<String>,
}

struct ExecutionPackage {
    compiled: CompiledWorkflow,
    schemas: BTreeMap<String, Value>,
}

#[derive(Default)]
struct RecordedRun {
    events: Vec<v1::EventEnvelope>,
    episode: Option<v1::WorkflowCaseEpisodeStarted>,
    token: Option<v1::WorkflowRunTokenCreated>,
    execution_tokens: BTreeMap<String, RecordedExecutionToken>,
    joins: Vec<RecordedJoin>,
    iterations: Vec<RecordedIteration>,
    retries: Vec<RecordedRetry>,
    wait_signals: BTreeMap<String, RecordedWaitSignal>,
    waits: BTreeMap<String, RecordedWait>,
    attempts: Vec<RecordedAttempt>,
    emissions: BTreeMap<String, RecordedEmission>,
    edges: Vec<RecordedEdge>,
    cancellation: Option<v1::WorkflowRunCancellationRequested>,
    settled: Option<v1::WorkflowRunSettled>,
}

struct RecordedExecutionToken {
    created_event_id: String,
    created_store_position: u64,
    created: v1::WorkflowExecutionTokenCreated,
    settled_event_id: Option<String>,
    settled: Option<v1::WorkflowExecutionTokenSettled>,
}

struct RecordedJoin {
    event_id: String,
    store_position: u64,
    payload: v1::WorkflowJoinEvaluated,
}

struct RecordedIteration {
    planned_event_id: String,
    planned: v1::WorkflowIterationPlanned,
    evaluated_event_id: Option<String>,
    evaluated_store_position: Option<u64>,
    evaluated: Option<v1::WorkflowIterationEvaluated>,
}

struct RecordedRetry {
    event_id: String,
    payload: v1::WorkflowRetryEvaluated,
}

struct RecordedWaitSignal {
    event_id: String,
    store_position: u64,
    occurred_at_unix_millis: i64,
    payload: v1::WorkflowWaitSignalRecorded,
}

struct RecordedWait {
    subscribed_event_id: String,
    subscribed: v1::WorkflowWaitSubscribed,
    resolved_event_id: Option<String>,
    resolved: Option<v1::WorkflowWaitResolved>,
}

struct RecordedAttempt {
    started_event_id: String,
    started_store_position: u64,
    started_at_unix_millis: i64,
    started: v1::WorkflowAttemptStarted,
    settled_event_id: Option<String>,
    settled: Option<v1::WorkflowAttemptSettled>,
}

struct RecordedEmission {
    event_id: String,
    payload: v1::WorkflowPortEmitted,
}

struct RecordedEdge {
    event_id: String,
    store_position: u64,
    payload: v1::WorkflowEdgeCheckpointed,
}

struct HistoricalCaseEpisode {
    event_id: String,
    store_position: u64,
    started: v1::WorkflowCaseEpisodeStarted,
    emissions: BTreeMap<String, (String, v1::WorkflowPortEmitted)>,
    settled: Option<(String, v1::WorkflowRunSettled)>,
}

struct NodeExecution {
    match_trace: Option<MatchTraceOutput>,
    outputs: Vec<(String, v1::WorkflowValueReference)>,
    outcome: v1::WorkflowAttemptOutcome,
    error_code: String,
    error: Option<v1::WorkflowValueReference>,
}

struct MatchTraceOutput {
    input_value_id: String,
    evaluated_case_ids: Vec<String>,
    matched_case_ids: Vec<String>,
    emitted_port_ids: Vec<String>,
    value: v1::WorkflowValueReference,
}

struct CompletedRunOutcome {
    outcome: v1::WorkflowRunOutcome,
    error_code: String,
    error: Option<v1::WorkflowValueReference>,
    final_emission_ids: Vec<String>,
    causation_id: String,
}

pub fn execute(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    execute_internal(
        journal,
        library,
        None,
        None,
        command,
        current_unix_millis(),
        None,
    )
}

pub fn execute_at_unix_millis(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
) -> Result<WorkflowExecutionResult> {
    execute_internal(journal, library, None, None, command, now_unix_millis, None)
}

pub fn execute_with_storage(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    storage: &mut WorkflowScopedStorage,
    authority: &WorkflowStorageExecutionAuthority,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        command,
        current_unix_millis(),
        None,
    )
}

#[doc(hidden)]
pub fn execute_with_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    execute_internal(
        journal,
        library,
        None,
        None,
        command,
        current_unix_millis(),
        Some(fault),
    )
}

#[doc(hidden)]
pub fn execute_with_storage_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    storage: &mut WorkflowScopedStorage,
    authority: &WorkflowStorageExecutionAuthority,
    command: &v1::CommandEnvelope,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        command,
        current_unix_millis(),
        Some(fault),
    )
}

fn execute_internal(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    mut storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
    fault: Option<WorkflowExecutionFault>,
) -> Result<WorkflowExecutionResult> {
    let request = match workflow_runtime::decode_workflow_command(command)
        .map_err(|_| WorkflowExecutionError::InvalidCommand("request_contract"))?
    {
        WorkflowRuntimeCommand::RequestRun(request) => request,
        WorkflowRuntimeCommand::CancelRun(_) => {
            return Err(WorkflowExecutionError::InvalidCommand(
                "request_kind_required",
            ));
        }
        WorkflowRuntimeCommand::SignalWait(_) => {
            return Err(WorkflowExecutionError::InvalidCommand(
                "request_kind_required",
            ));
        }
    };
    let package = load_execution_package(library, &request)?;
    validate_storage_authority(&package, &request, storage.is_some(), authority)?;
    let token_id = stable_id("token", &[&request.run_id, &command.command_id]);
    let initial_state = recorded_run(journal, &request.run_id)?;
    let prepared_episode = if !request.episode_id.is_empty() && initial_state.episode.is_none() {
        Some(compile_case_episode_event(
            journal, command, &request, &token_id,
        )?)
    } else {
        None
    };
    journal.admit_command(command)?;
    let mut appended = 0;

    for _ in 0..MAXIMUM_EXECUTOR_TRANSITIONS {
        let state = recorded_run(journal, &request.run_id)?;
        if let Some(settled) = state.settled.as_ref() {
            return Ok(WorkflowExecutionResult {
                run_id: request.run_id.clone(),
                run_token_id: token_id,
                outcome: durable_outcome(settled.outcome)?,
                event_count: state.events.len(),
                next_attempt_at_unix_millis: None,
            });
        }

        let candidates = match next_events(
            &package,
            storage.as_deref_mut(),
            command,
            &request,
            &token_id,
            &state,
            now_unix_millis,
            prepared_episode.as_ref(),
        ) {
            Ok(events) => events,
            Err(WorkflowExecutionError::WaitingUntil(deadline)) => {
                return Ok(WorkflowExecutionResult {
                    run_id: request.run_id.clone(),
                    run_token_id: token_id,
                    outcome: DurableRunOutcome::Waiting,
                    event_count: state.events.len(),
                    next_attempt_at_unix_millis: Some(deadline),
                });
            }
            Err(error) => return Err(error),
        };
        if candidates.is_empty() {
            return Err(WorkflowExecutionError::Lifecycle(
                "no_deterministic_transition".into(),
            ));
        }
        let mut advanced = false;
        for candidate in candidates {
            let result = journal.append_event(candidate)?;
            if !result.duplicate {
                appended += 1;
                advanced = true;
                if fault == Some(WorkflowExecutionFault::AfterNewEvent(appended)) {
                    return Err(WorkflowExecutionError::InjectedInterruption);
                }
                break;
            }
        }
        if !advanced {
            continue;
        }
    }
    let state = recorded_run(journal, &request.run_id)?;
    Ok(WorkflowExecutionResult {
        run_id: request.run_id,
        run_token_id: token_id,
        outcome: DurableRunOutcome::Running,
        event_count: state.events.len(),
        next_attempt_at_unix_millis: None,
    })
}

pub fn request_cancellation(
    journal: &mut Journal,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowCancellationReceipt> {
    let request = match workflow_runtime::decode_workflow_command(command)
        .map_err(|_| WorkflowExecutionError::InvalidCommand("cancellation_contract"))?
    {
        WorkflowRuntimeCommand::CancelRun(request) => request,
        WorkflowRuntimeCommand::RequestRun(_) => {
            return Err(WorkflowExecutionError::InvalidCommand(
                "cancellation_kind_required",
            ));
        }
        WorkflowRuntimeCommand::SignalWait(_) => {
            return Err(WorkflowExecutionError::InvalidCommand(
                "cancellation_kind_required",
            ));
        }
    };
    let state = recorded_run(journal, &request.run_id)?;
    let token = state
        .token
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("run_token_missing".into()))?;
    if token.run_token_id != request.run_token_id {
        return Err(WorkflowExecutionError::Lifecycle(
            "run_token_mismatch".into(),
        ));
    }
    if state.settled.is_some() {
        return Err(WorkflowExecutionError::Lifecycle(
            "run_already_settled".into(),
        ));
    }
    journal.admit_command(command)?;
    let event_id = stable_id("event", &[&request.run_id, "cancel", &command.command_id]);
    let event = runtime_event(
        command.submitted_at_unix_millis,
        &event_id,
        workflow_runtime::WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND,
        workflow_runtime::WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE,
        v1::WorkflowRunCancellationRequested {
            run_id: request.run_id.clone(),
            run_token_id: request.run_token_id.clone(),
            cancel_command_id: command.command_id.clone(),
            reason_code: request.reason_code,
        },
        &command.command_id,
        &request.run_id,
    );
    let append = journal.append_event(event)?;
    Ok(WorkflowCancellationReceipt {
        run_id: request.run_id,
        run_token_id: request.run_token_id,
        event_id,
        duplicate: append.duplicate,
    })
}

/// Durably records an externally supplied event/reply signal. The run and its
/// wait subscription may be created before or after this command; matching is
/// performed only by the pinned wait identity during execution.
pub fn record_wait_signal(
    journal: &mut Journal,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowWaitSignalReceipt> {
    let signal = match workflow_runtime::decode_workflow_command(command)
        .map_err(|_| WorkflowExecutionError::InvalidCommand("wait_signal_contract"))?
    {
        WorkflowRuntimeCommand::SignalWait(signal) => signal,
        _ => {
            return Err(WorkflowExecutionError::InvalidCommand(
                "wait_signal_kind_required",
            ));
        }
    };
    journal.admit_command(command)?;
    let event_id = stable_id("event", &[&signal.run_id, "wait-signal", &signal.signal_id]);
    let event = runtime_event(
        command.submitted_at_unix_millis,
        &event_id,
        workflow_runtime::WORKFLOW_WAIT_SIGNAL_RECORDED_KIND,
        workflow_runtime::WORKFLOW_WAIT_SIGNAL_RECORDED_TYPE,
        v1::WorkflowWaitSignalRecorded {
            run_id: signal.run_id.clone(),
            signal_id: signal.signal_id.clone(),
            signal_command_id: command.command_id.clone(),
            kind: signal.kind,
            owner_kind: signal.owner_kind,
            owner_id: signal.owner_id,
            correlation: signal.correlation,
            value: signal.value,
        },
        &command.command_id,
        &signal.run_id,
    );
    let append = journal.append_event(event)?;
    Ok(WorkflowWaitSignalReceipt {
        run_id: signal.run_id,
        signal_id: signal.signal_id,
        event_id,
        duplicate: append.duplicate,
    })
}

fn load_execution_package(
    library: &WorkflowLibraryStore,
    request: &v1::RequestWorkflowRun,
) -> Result<ExecutionPackage> {
    let revision = library.load_workflow_revision(&request.revision_id, "active")?;
    if revision.summary.workflow_id != request.workflow_id
        || revision.summary.package_digest != request.package_digest
    {
        return Err(WorkflowExecutionError::Integrity(
            "revision_pin_mismatch".into(),
        ));
    }
    if revision.summary.execution_support != WorkflowExecutionSupport::Executable {
        return Err(WorkflowExecutionError::Unsupported(
            "revision_not_executable".into(),
        ));
    }
    let compiled: CompiledWorkflow = serde_json::from_slice(&revision.compiled_source)
        .map_err(|_| WorkflowExecutionError::Integrity("compiled_contract".into()))?;
    if compiled.compiled_format_version != 1
        || compiled.workflow_id != request.workflow_id
        || compiled.entrypoints.len() != 1
        || !compiled.resources.is_empty()
        || !compiled.policies.is_empty()
        || !compiled.dependencies.is_empty()
        || compiled.definition_digest.is_empty()
        || compiled.layout_digest.is_empty()
        || compiled.schema_bundle_digest.is_empty()
        || compiled.dependency_lock_digest.is_empty()
        || compiled.configuration_contract_digest.is_empty()
        || compiled.package_id.is_empty()
    {
        return Err(WorkflowExecutionError::Unsupported(
            "compiled_subset".into(),
        ));
    }
    validate_compiled_subset(&compiled)?;
    if !compiled.storage.is_empty() && request.installation_id.is_empty() {
        return Err(WorkflowExecutionError::InvalidCommand(
            "installation_id_required",
        ));
    }
    if compiled
        .storage
        .values()
        .any(|declaration| declaration.scope == "case")
        && request.case_id.is_empty()
    {
        return Err(WorkflowExecutionError::InvalidCommand("case_id_required"));
    }
    if compiled
        .nodes
        .iter()
        .any(|node| node.node_type == "data.case-context")
        && request.episode_id.is_empty()
    {
        return Err(WorkflowExecutionError::InvalidCommand(
            "case_episode_required",
        ));
    }
    let bundle: RuntimeSchemaBundle = serde_json::from_slice(&revision.schema_bundle_source)
        .map_err(|_| WorkflowExecutionError::Unsupported("schema_bundle_contract".into()))?;
    if bundle.bundle_version != 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "schema_bundle_version".into(),
        ));
    }
    let mut schemas = BTreeMap::new();
    for schema in bundle.schemas {
        if schema.id.is_empty() || schemas.insert(schema.id, schema.schema).is_some() {
            return Err(WorkflowExecutionError::Unsupported(
                "schema_bundle_identity".into(),
            ));
        }
    }
    for node in &compiled.nodes {
        if node.node_type == "data.validate" {
            let schema_ref = node
                .config
                .get("schemaRef")
                .and_then(Value::as_str)
                .ok_or_else(|| WorkflowExecutionError::Integrity("validate_schema_ref".into()))?;
            let schema = schemas.get(schema_ref).ok_or_else(|| {
                WorkflowExecutionError::Unsupported("validate_schema_missing".into())
            })?;
            let report = workflow_schema::check(&WorkflowSchemaCheckRequest {
                schema: schema.clone(),
                instance: Value::Null,
            });
            if report.outcome == WorkflowSchemaCheckOutcome::InvalidSchema {
                return Err(WorkflowExecutionError::Unsupported(
                    "validate_schema_invalid".into(),
                ));
            }
        }
        if node.node_type == "control.match" {
            let config: MatchConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("match_config".into()))?;
            if config.hit_policy == workflow_match::HitPolicy::All {
                return Err(WorkflowExecutionError::Unsupported(
                    "match_all_not_in_minimal_executor".into(),
                ));
            }
        }
        if node.node_type == "control.parallel" {
            let config: ParallelConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("parallel_config".into()))?;
            if config.branches.len() < 2 || config.branches.len() > 64 {
                return Err(WorkflowExecutionError::Integrity(
                    "parallel_branch_count".into(),
                ));
            }
            parallel_join_node(&compiled, node, &config)?;
        }
        if node.node_type == "control.join" {
            let config: JoinConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("join_config".into()))?;
            if !matches!(config.policy.as_str(), "all" | "any" | "quorum")
                || !config.required_branches.is_empty()
                || (config.policy == "quorum" && config.quorum.is_none())
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "join_policy_not_executable".into(),
                ));
            }
        }
        if node.node_type == "control.for-each" {
            let config: ForEachConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("for_each_config".into()))?;
            if config.items.root != "input"
                || config.item_binding != "item"
                || config.maximum_items == 0
                || config.maximum_items > 256
                || config.maximum_concurrency == 0
                || config.maximum_concurrency > 64
                || config.maximum_concurrency > config.maximum_items
                || !matches!(config.failure_policy.as_str(), "fail-fast" | "collect")
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "for_each_contract".into(),
                ));
            }
        }
        if node.node_type == "control.retry" {
            let config: RetryConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("retry_config".into()))?;
            if config.maximum_attempts == 0
                || config.maximum_attempts > 100
                || config.retry_on.is_empty()
                || config.retry_on.len() > 64
                || config.backoff.initial_seconds <= 0.0
                || config.backoff.initial_seconds > config.backoff.maximum_seconds
                || !matches!(config.backoff.mode.as_str(), "fixed" | "exponential")
                || !matches!(config.backoff.jitter.as_str(), "none" | "deterministic")
            {
                return Err(WorkflowExecutionError::Unsupported("retry_contract".into()));
            }
        }
        if node.node_type == "control.wait" {
            let config: WaitConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("wait_config".into()))?;
            let mut keys = BTreeSet::new();
            if !matches!(config.kind.as_str(), "timer" | "event" | "reply")
                || config.correlation.is_empty()
                || config.correlation.len() > 16
                || config.expiry_seconds == 0
                || config.expiry_seconds > 31_536_000
                || config.correlation.iter().any(|selector| {
                    selector.root != "input"
                        || selector.pointer.is_empty()
                        || !keys.insert(format!("{}:{}", selector.root, selector.pointer))
                })
            {
                return Err(WorkflowExecutionError::Unsupported("wait_contract".into()));
            }
        }
    }
    for (key, declaration) in &compiled.storage {
        if key != &declaration.key
            || !matches!(declaration.scope.as_str(), "job" | "case" | "workflow")
            || !matches!(declaration.kind.as_str(), "value" | "file" | "directory")
            || declaration.schema_ref.is_empty()
            || declaration.maximum_bytes == 0
            || !matches!(
                declaration.classification.as_str(),
                "public" | "internal" | "private" | "restricted"
            )
            || declaration
                .conflict_policy
                .as_deref()
                .is_some_and(|policy| !matches!(policy, "fail" | "compare-and-swap" | "replace"))
        {
            return Err(WorkflowExecutionError::Integrity(
                "compiled_storage_declaration".into(),
            ));
        }
    }
    if request.inputs.len() != 1
        || request.inputs[0].port_id != "input"
        || request.inputs[0]
            .value
            .as_ref()
            .is_none_or(|value| value.inline_canonical_json.is_empty())
    {
        return Err(WorkflowExecutionError::Unsupported(
            "single_inline_manual_input_required".into(),
        ));
    }
    Ok(ExecutionPackage { compiled, schemas })
}

fn validate_storage_authority(
    package: &ExecutionPackage,
    request: &v1::RequestWorkflowRun,
    storage_available: bool,
    authority: Option<&WorkflowStorageExecutionAuthority>,
) -> Result<()> {
    if package.compiled.storage.is_empty() {
        return Ok(());
    }
    if !storage_available {
        return Err(WorkflowExecutionError::Unsupported(
            "storage_service_required".into(),
        ));
    }
    let authority = authority
        .ok_or_else(|| WorkflowExecutionError::InvalidCommand("storage_authority_required"))?;
    if authority.installation_id != request.installation_id
        || authority.case_id.as_deref()
            != (!request.case_id.is_empty()).then_some(request.case_id.as_str())
    {
        return Err(WorkflowExecutionError::InvalidCommand(
            "storage_authority_mismatch",
        ));
    }
    Ok(())
}

fn validate_compiled_subset(compiled: &CompiledWorkflow) -> Result<()> {
    let nodes = compiled
        .nodes
        .iter()
        .map(|node| (node.id.as_str(), node))
        .collect::<BTreeMap<_, _>>();
    if nodes.len() != compiled.nodes.len() {
        return Err(WorkflowExecutionError::Integrity(
            "compiled_node_identity".into(),
        ));
    }
    let entrypoint = &compiled.entrypoints[0];
    if entrypoint.id.is_empty() || entrypoint.key.as_deref() == Some("") {
        return Err(WorkflowExecutionError::Integrity(
            "compiled_entrypoint".into(),
        ));
    }
    if nodes
        .get(entrypoint.node_id.as_str())
        .is_none_or(|node| node.node_type != "trigger.manual")
    {
        return Err(WorkflowExecutionError::Unsupported(
            "manual_entrypoint_required".into(),
        ));
    }
    for node in &compiled.nodes {
        if node.type_version != 1
            || node.execution_availability != "executable"
            || node.key.is_empty()
            || node.name.is_empty()
            || node.ports.is_empty()
            || !matches!(
                node.node_type.as_str(),
                "trigger.manual"
                    | "data.validate"
                    | "data.case-context"
                    | "control.match"
                    | "control.parallel"
                    | "control.join"
                    | "control.for-each"
                    | "control.retry"
                    | "control.wait"
                    | "storage.read"
                    | "storage.write"
                    | "storage.promote"
                    | "terminal.complete"
                    | "terminal.fail"
            )
        {
            return Err(WorkflowExecutionError::Unsupported(format!(
                "node:{}",
                node.node_type
            )));
        }
    }
    let mut edge_ids = BTreeSet::new();
    for edge in &compiled.edges {
        if !edge_ids.insert(edge.id.as_str())
            || edge.mapping_id.is_empty()
            || edge.ignored.unwrap_or(false)
            || edge.mapping != json!({"whole": true})
            || !nodes.contains_key(edge.from.node_id.as_str())
            || !nodes.contains_key(edge.to.node_id.as_str())
            || edge.from.port_id.is_empty()
            || edge.to.port_id.is_empty()
        {
            return Err(WorkflowExecutionError::Unsupported(
                "whole_value_edges_only".into(),
            ));
        }
    }
    Ok(())
}

fn compile_case_episode_event(
    journal: &Journal,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
) -> Result<v1::EventEnvelope> {
    let history = load_case_history(journal, request)?;
    if history.len() >= MAXIMUM_CASE_EPISODES {
        return Err(WorkflowExecutionError::Lifecycle(
            "case_episode_limit".into(),
        ));
    }
    let prior = history.last();
    match prior {
        None if request.episode_kind != "initial" || !request.prior_episode_id.is_empty() => {
            return Err(WorkflowExecutionError::Lifecycle(
                "case_initial_episode_required".into(),
            ));
        }
        Some(_) if request.episode_kind == "initial" => {
            return Err(WorkflowExecutionError::Lifecycle(
                "case_initial_episode_exists".into(),
            ));
        }
        Some(previous) if request.prior_episode_id != previous.started.episode_id => {
            return Err(WorkflowExecutionError::Lifecycle(
                "case_prior_episode_mismatch".into(),
            ));
        }
        Some(previous) if previous.settled.is_none() => {
            return Err(WorkflowExecutionError::Lifecycle(
                "case_prior_episode_not_settled".into(),
            ));
        }
        _ => {}
    }
    if history
        .iter()
        .any(|episode| episode.started.episode_id == request.episode_id)
    {
        return Err(WorkflowExecutionError::Lifecycle(
            "case_episode_identity_reused".into(),
        ));
    }

    let source_episode_ids = history
        .iter()
        .map(|episode| episode.started.episode_id.clone())
        .collect::<Vec<_>>();
    let source_event_ids = history
        .iter()
        .flat_map(|episode| {
            let mut ids = vec![episode.event_id.clone()];
            ids.extend(
                episode
                    .emissions
                    .values()
                    .map(|(event_id, _)| event_id.clone()),
            );
            if let Some((event_id, _)) = &episode.settled {
                ids.push(event_id.clone());
            }
            ids
        })
        .collect::<Vec<_>>();
    let context = json!({
        "caseId": request.case_id,
        "installationId": request.installation_id,
        "workflowId": request.workflow_id,
        "currentEpisode": {
            "episodeId": request.episode_id,
            "kind": request.episode_kind,
            "ordinal": history.len() + 1,
            "priorEpisodeId": request.prior_episode_id,
            "triggerKind": request.trigger_kind,
            "triggerEventId": request.trigger_event_id,
            "inputs": context_inputs(&request.inputs)?
        },
        "priorEpisodes": history
            .iter()
            .map(context_episode)
            .collect::<Result<Vec<_>>>()?,
        "sourceEpisodeIds": source_episode_ids,
        "sourceEventIds": source_event_ids
    });
    let compiled_context = value_from_json(
        &stable_id(
            "value",
            &[&request.run_id, &request.episode_id, "case-context"],
        ),
        &context,
    )?;
    let payload = v1::WorkflowCaseEpisodeStarted {
        run_id: request.run_id.clone(),
        run_token_id: run_token_id.to_owned(),
        installation_id: request.installation_id.clone(),
        case_id: request.case_id.clone(),
        episode_id: request.episode_id.clone(),
        ordinal: (history.len() + 1) as u32,
        kind: request.episode_kind.clone(),
        prior_episode_id: request.prior_episode_id.clone(),
        workflow_id: request.workflow_id.clone(),
        revision_id: request.revision_id.clone(),
        package_digest: request.package_digest.clone(),
        trigger_kind: request.trigger_kind.clone(),
        trigger_event_id: request.trigger_event_id.clone(),
        inputs: request.inputs.clone(),
        compiled_context: Some(compiled_context),
        source_episode_ids,
        source_event_ids,
    };
    Ok(runtime_event(
        command.submitted_at_unix_millis,
        &stable_id(
            "event",
            &[&request.run_id, "case-episode", &request.episode_id],
        ),
        workflow_runtime::WORKFLOW_CASE_EPISODE_STARTED_KIND,
        workflow_runtime::WORKFLOW_CASE_EPISODE_STARTED_TYPE,
        payload,
        &command.command_id,
        &request.run_id,
    ))
}

fn load_case_history(
    journal: &Journal,
    request: &v1::RequestWorkflowRun,
) -> Result<Vec<HistoricalCaseEpisode>> {
    let mut by_run = BTreeMap::<String, HistoricalCaseEpisode>::new();
    let mut after = 0;
    loop {
        let page = journal.event_page_after(after, CASE_HISTORY_PAGE)?;
        for envelope in page.events {
            match workflow_runtime::decode_workflow_event(&envelope) {
                Ok(WorkflowRuntimeEvent::CaseEpisodeStarted(payload))
                    if payload.installation_id == request.installation_id
                        && payload.case_id == request.case_id =>
                {
                    if payload.workflow_id != request.workflow_id {
                        return Err(WorkflowExecutionError::Integrity(
                            "case_workflow_mismatch".into(),
                        ));
                    }
                    if by_run
                        .insert(
                            payload.run_id.clone(),
                            HistoricalCaseEpisode {
                                event_id: envelope.event_id,
                                store_position: envelope.store_position,
                                started: payload,
                                emissions: BTreeMap::new(),
                                settled: None,
                            },
                        )
                        .is_some()
                    {
                        return Err(WorkflowExecutionError::Integrity(
                            "case_episode_run_duplicate".into(),
                        ));
                    }
                }
                Ok(WorkflowRuntimeEvent::PortEmitted(payload)) => {
                    if let Some(episode) = by_run.get_mut(&payload.run_id) {
                        episode
                            .emissions
                            .insert(payload.emission_id.clone(), (envelope.event_id, payload));
                    }
                }
                Ok(WorkflowRuntimeEvent::RunSettled(payload)) => {
                    if let Some(episode) = by_run.get_mut(&payload.run_id)
                        && episode
                            .settled
                            .replace((envelope.event_id, payload))
                            .is_some()
                    {
                        return Err(WorkflowExecutionError::Integrity(
                            "case_episode_settled_twice".into(),
                        ));
                    }
                }
                Ok(_) | Err(workflow_runtime::WorkflowRuntimeContractError::UnsupportedKind) => {}
                Err(_) => {
                    return Err(WorkflowExecutionError::Integrity(
                        "case_history_event_contract".into(),
                    ));
                }
            }
        }
        after = page.next_store_position;
        if !page.has_more {
            break;
        }
    }
    let mut history = by_run.into_values().collect::<Vec<_>>();
    history.sort_by_key(|episode| (episode.started.ordinal, episode.store_position));
    if history.len() > MAXIMUM_CASE_EPISODES {
        return Err(WorkflowExecutionError::Lifecycle(
            "case_episode_limit".into(),
        ));
    }
    for (index, episode) in history.iter().enumerate() {
        if episode.started.ordinal != (index + 1) as u32
            || (index == 0
                && (episode.started.kind != "initial"
                    || !episode.started.prior_episode_id.is_empty()))
            || (index > 0
                && episode.started.prior_episode_id != history[index - 1].started.episode_id)
        {
            return Err(WorkflowExecutionError::Integrity(
                "case_episode_chain".into(),
            ));
        }
    }
    Ok(history)
}

fn context_inputs(inputs: &[v1::WorkflowInputBinding]) -> Result<Vec<Value>> {
    inputs
        .iter()
        .map(|input| {
            Ok(json!({
                "portId": input.port_id,
                "value": context_value(input.value.as_ref().ok_or_else(|| {
                    WorkflowExecutionError::Integrity("case_input_value_missing".into())
                })?)?
            }))
        })
        .collect()
}

fn context_episode(episode: &HistoricalCaseEpisode) -> Result<Value> {
    let (settled_event_id, settled) = episode.settled.as_ref().ok_or_else(|| {
        WorkflowExecutionError::Lifecycle("case_prior_episode_not_settled".into())
    })?;
    let outputs = episode
        .emissions
        .values()
        .map(|(_, emission)| {
            Ok(json!({
                "emissionId": emission.emission_id,
                "nodeId": emission.node_id,
                "portId": emission.port_id,
                "value": context_value(emission.value.as_ref().ok_or_else(|| {
                    WorkflowExecutionError::Integrity("case_output_value_missing".into())
                })?)?
            }))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({
        "episodeId": episode.started.episode_id,
        "ordinal": episode.started.ordinal,
        "kind": episode.started.kind,
        "priorEpisodeId": episode.started.prior_episode_id,
        "runId": episode.started.run_id,
        "workflowId": episode.started.workflow_id,
        "revisionId": episode.started.revision_id,
        "packageDigest": episode.started.package_digest,
        "triggerKind": episode.started.trigger_kind,
        "triggerEventId": episode.started.trigger_event_id,
        "inputs": context_inputs(&episode.started.inputs)?,
        "outcome": run_outcome_name(settled.outcome)?,
        "finalEmissionIds": settled.final_emission_ids,
        "outputs": outputs,
        "source": {
            "episodeEventId": episode.event_id,
            "settledEventId": settled_event_id,
            "startedStorePosition": episode.store_position
        }
    }))
}

fn context_value(value: &v1::WorkflowValueReference) -> Result<Value> {
    let inline = if value.inline_canonical_json.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&value.inline_canonical_json)
            .map_err(|_| WorkflowExecutionError::Integrity("case_context_inline_json".into()))?
    };
    let storage = value.storage.as_ref().map(|metadata| {
        json!({
            "handleId": metadata.handle_id,
            "scope": metadata.scope,
            "logicalKey": metadata.logical_key,
            "versionId": metadata.version_id,
            "revision": metadata.revision,
            "previousVersionId": metadata.previous_version_id,
            "sourceVersionId": metadata.source_version_id,
            "result": metadata.result
        })
    });
    Ok(json!({
        "valueId": value.value_id,
        "contentType": value.content_type,
        "byteCount": value.byte_count,
        "sha256": value.sha256,
        "inline": inline,
        "storageReferenceId": value.storage_reference_id,
        "storage": storage
    }))
}

fn validate_recorded_episode(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    episode: &v1::WorkflowCaseEpisodeStarted,
) -> Result<()> {
    if request.episode_id.is_empty()
        || episode.run_id != request.run_id
        || episode.run_token_id != run_token_id
        || episode.installation_id != request.installation_id
        || episode.case_id != request.case_id
        || episode.episode_id != request.episode_id
        || episode.kind != request.episode_kind
        || episode.prior_episode_id != request.prior_episode_id
        || episode.workflow_id != request.workflow_id
        || episode.revision_id != request.revision_id
        || episode.package_digest != request.package_digest
        || episode.trigger_kind != request.trigger_kind
        || episode.trigger_event_id != request.trigger_event_id
        || episode.inputs != request.inputs
        || episode.compiled_context.is_none()
    {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_episode_pin_mismatch".into(),
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn next_events(
    package: &ExecutionPackage,
    storage: Option<&mut WorkflowScopedStorage>,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
    now_unix_millis: i64,
    prepared_episode: Option<&v1::EventEnvelope>,
) -> Result<Vec<v1::EventEnvelope>> {
    if state.token.is_none() {
        return Ok(vec![runtime_event(
            command.submitted_at_unix_millis,
            &stable_id("event", &[&request.run_id, "token"]),
            workflow_runtime::WORKFLOW_RUN_TOKEN_CREATED_KIND,
            workflow_runtime::WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            v1::WorkflowRunTokenCreated {
                run_id: request.run_id.clone(),
                run_token_id: token_id.to_owned(),
                request_command_id: command.command_id.clone(),
                workflow_id: request.workflow_id.clone(),
                revision_id: request.revision_id.clone(),
                package_digest: request.package_digest.clone(),
            },
            &command.command_id,
            &request.run_id,
        )]);
    }
    if !request.episode_id.is_empty() && state.episode.is_none() {
        return prepared_episode
            .cloned()
            .map(|event| vec![event])
            .ok_or_else(|| WorkflowExecutionError::Integrity("prepared_episode_missing".into()));
    }
    if let Some(episode) = state.episode.as_ref() {
        validate_recorded_episode(request, token_id, episode)?;
    }
    let token = state.token.as_ref().unwrap();
    if token.run_token_id != token_id
        || token.workflow_id != request.workflow_id
        || token.revision_id != request.revision_id
        || token.package_digest != request.package_digest
    {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_token_pin_mismatch".into(),
        ));
    }

    if state.execution_tokens.is_empty() {
        let execution_token_id = stable_id("execution-token", &[&request.run_id, "root"]);
        return Ok(vec![runtime_event(
            command.submitted_at_unix_millis,
            &stable_id("event", &[&request.run_id, "execution-token", "root"]),
            workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
            workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
            v1::WorkflowExecutionTokenCreated {
                run_id: request.run_id.clone(),
                run_token_id: token_id.to_owned(),
                execution_token_id,
                parent_execution_token_id: String::new(),
                fork_node_id: String::new(),
                branch_id: String::new(),
                branch_port_id: String::new(),
                join_node_id: String::new(),
                source_emission_id: String::new(),
                iteration_node_id: String::new(),
                iteration_index: 0,
                iteration_count: 0,
                resume_node_id: String::new(),
                resume_reason: String::new(),
            },
            &stable_id("event", &[&request.run_id, "token"]),
            &request.run_id,
        )]);
    }

    if let Some(cancellation) = state.cancellation.as_ref() {
        if let Some(active) = active_attempt(state)? {
            if let Some(wait) = state.waits.values().find(|wait| {
                wait.subscribed.controller_attempt_id == active.started.attempt_id
                    && wait.resolved.is_none()
            }) {
                return Ok(vec![runtime_event(
                    cancellation_time(state, command.submitted_at_unix_millis),
                    &stable_id(
                        "event",
                        &[
                            &request.run_id,
                            "wait-cancelled",
                            &wait.subscribed.subscription_id,
                        ],
                    ),
                    workflow_runtime::WORKFLOW_WAIT_RESOLVED_KIND,
                    workflow_runtime::WORKFLOW_WAIT_RESOLVED_TYPE,
                    v1::WorkflowWaitResolved {
                        run_id: request.run_id.clone(),
                        run_token_id: token_id.to_owned(),
                        subscription_id: wait.subscribed.subscription_id.clone(),
                        decision: v1::WorkflowWaitDecision::Cancelled as i32,
                        signal_id: String::new(),
                        output: None,
                        reason_code: cancellation.reason_code.clone(),
                    },
                    &cancellation.cancel_command_id,
                    &request.run_id,
                )]);
            }
            let emissions = emissions_for_attempt(state, &active.started.attempt_id);
            let event_id = stable_id(
                "event",
                &[
                    &request.run_id,
                    "attempt-cancelled",
                    &active.started.attempt_id,
                ],
            );
            return Ok(vec![runtime_event(
                cancellation_time(state, command.submitted_at_unix_millis),
                &event_id,
                workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_KIND,
                workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_TYPE,
                v1::WorkflowAttemptSettled {
                    run_id: request.run_id.clone(),
                    run_token_id: token_id.to_owned(),
                    attempt_id: active.started.attempt_id.clone(),
                    node_id: active.started.node_id.clone(),
                    attempt_number: active.started.attempt_number,
                    outcome: v1::WorkflowAttemptOutcome::Cancelled as i32,
                    error_code: cancellation.reason_code.clone(),
                    error: None,
                    emission_ids: emissions
                        .iter()
                        .map(|emission| emission.payload.emission_id.clone())
                        .collect(),
                    execution_token_id: active.started.execution_token_id.clone(),
                },
                &cancellation.cancel_command_id,
                &request.run_id,
            )]);
        }
        if let Some(execution_token) = active_execution_tokens(state).into_iter().next() {
            return Ok(vec![execution_token_settled_event(
                cancellation_time(state, command.submitted_at_unix_millis),
                request,
                token_id,
                &execution_token.created.execution_token_id,
                v1::WorkflowExecutionTokenOutcome::Cancelled,
                String::new(),
                String::new(),
                cancellation.reason_code.clone(),
                None,
                Vec::new(),
                &cancellation.cancel_command_id,
            )]);
        }
        return Ok(vec![run_settled_event(
            cancellation_time(state, command.submitted_at_unix_millis),
            request,
            token_id,
            v1::WorkflowRunOutcome::Cancelled,
            cancellation.reason_code.clone(),
            None,
            Vec::new(),
            &cancellation.cancel_command_id,
        )]);
    }

    if let Some(active) = active_attempt(state)? {
        return node_event_sequence(
            package,
            storage,
            command,
            request,
            token_id,
            state,
            active,
            now_unix_millis,
        );
    }

    if let Some(event) =
        pending_execution_token_settlement(package, command, request, token_id, state)?
    {
        return Ok(vec![event]);
    }

    if let Some(event) =
        pending_iteration_lifecycle_event(package, command, request, token_id, state)?
    {
        return Ok(vec![event]);
    }

    if let Some(event) = pending_join_lifecycle_event(package, command, request, token_id, state)? {
        return Ok(vec![event]);
    }

    if active_execution_tokens(state).is_empty() {
        let completed = completed_run_outcome(state)?;
        return Ok(vec![run_settled_event(
            command.submitted_at_unix_millis,
            request,
            token_id,
            completed.outcome,
            completed.error_code,
            completed.error,
            completed.final_emission_ids,
            &completed.causation_id,
        )]);
    }

    let (node_id, causation_id, execution_token_id) = next_ready_node(&package.compiled, state)?;
    let attempt_number = state
        .attempts
        .iter()
        .filter(|attempt| {
            attempt.started.execution_token_id == execution_token_id
                && attempt.started.node_id == node_id
        })
        .count() as u32
        + 1;
    let attempt_id = stable_id(
        "attempt",
        &[
            &request.run_id,
            &execution_token_id,
            &node_id,
            &attempt_number.to_string(),
        ],
    );
    Ok(vec![runtime_event(
        command.submitted_at_unix_millis,
        &stable_id(
            "event",
            &[
                &request.run_id,
                "attempt-started",
                &execution_token_id,
                &node_id,
                &attempt_number.to_string(),
            ],
        ),
        workflow_runtime::WORKFLOW_ATTEMPT_STARTED_KIND,
        workflow_runtime::WORKFLOW_ATTEMPT_STARTED_TYPE,
        v1::WorkflowAttemptStarted {
            run_id: request.run_id.clone(),
            run_token_id: token_id.to_owned(),
            attempt_id,
            node_id,
            attempt_number,
            execution_token_id,
        },
        &causation_id,
        &request.run_id,
    )])
}

#[allow(clippy::too_many_arguments)]
fn node_event_sequence(
    package: &ExecutionPackage,
    storage: Option<&mut WorkflowScopedStorage>,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    now_unix_millis: i64,
) -> Result<Vec<v1::EventEnvelope>> {
    let node = compiled_node(&package.compiled, &attempt.started.node_id)?;
    let inputs = node_inputs(
        request,
        state,
        &node.id,
        &attempt.started.execution_token_id,
    )?;
    if node.node_type == "control.for-each"
        && !state.iterations.iter().any(|iteration| {
            iteration.evaluated.as_ref().is_some_and(|evaluated| {
                evaluated.resumed_execution_token_id == attempt.started.execution_token_id
            })
        })
    {
        return for_each_controller_event_sequence(
            package, command, request, token_id, state, attempt, node, &inputs,
        );
    }
    if node.node_type == "control.retry" {
        return retry_controller_event_sequence(
            package,
            command,
            request,
            token_id,
            state,
            attempt,
            node,
            &inputs,
            now_unix_millis,
        );
    }
    if node.node_type == "control.wait" {
        return wait_controller_event_sequence(
            package,
            command,
            request,
            token_id,
            state,
            attempt,
            node,
            &inputs,
            now_unix_millis,
        );
    }
    let execution = if node.node_type == "control.join" {
        execute_join_node(
            request,
            node,
            state,
            &attempt.started.execution_token_id,
            &inputs,
        )?
    } else {
        let input = inputs
            .last()
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("node_input_missing".into()))?
            .1
            .clone();
        if node.node_type == "control.for-each" {
            execute_iteration_resume_node(node, state, &attempt.started.execution_token_id)?
        } else {
            execute_node(
                package,
                storage,
                request,
                state.episode.as_ref(),
                node,
                &attempt.started.attempt_id,
                command.submitted_at_unix_millis,
                &input,
            )?
        }
    };
    let mut events = Vec::new();
    let mut causation_id = attempt.started_event_id.clone();
    let execution_token_id = attempt.started.execution_token_id.as_str();

    if let Some(trace) = execution.match_trace {
        let event_id = stable_id(
            "event",
            &[&request.run_id, "match-trace", &attempt.started.attempt_id],
        );
        events.push(runtime_event(
            command.submitted_at_unix_millis,
            &event_id,
            workflow_runtime::WORKFLOW_MATCH_TRACE_RECORDED_KIND,
            workflow_runtime::WORKFLOW_MATCH_TRACE_RECORDED_TYPE,
            v1::WorkflowMatchTraceRecorded {
                run_id: request.run_id.clone(),
                run_token_id: token_id.to_owned(),
                attempt_id: attempt.started.attempt_id.clone(),
                node_id: node.id.clone(),
                input_value_id: trace.input_value_id,
                evaluated_case_ids: trace.evaluated_case_ids,
                matched_case_ids: trace.matched_case_ids,
                emitted_port_ids: trace.emitted_port_ids,
                trace: Some(trace.value),
                execution_token_id: execution_token_id.to_owned(),
            },
            &causation_id,
            &request.run_id,
        ));
        causation_id = event_id;
    }

    let mut emission_ids = Vec::new();
    for (port_id, value) in execution.outputs {
        let emission_id = stable_id(
            "emission",
            &[&request.run_id, &attempt.started.attempt_id, &port_id],
        );
        let edge_execution_token_id = if node.node_type == "control.parallel" {
            let config: ParallelConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("parallel_config".into()))?;
            let branch = config
                .branches
                .iter()
                .find(|branch| format!("case-{}", branch.id) == port_id)
                .ok_or_else(|| WorkflowExecutionError::Integrity("parallel_port".into()))?;
            let child_token_id = stable_id(
                "execution-token",
                &[&request.run_id, execution_token_id, &node.id, &branch.id],
            );
            let token_event_id = stable_id(
                "event",
                &[
                    &request.run_id,
                    "execution-token",
                    &child_token_id,
                    "created",
                ],
            );
            events.push(runtime_event(
                command.submitted_at_unix_millis,
                &token_event_id,
                workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
                workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
                v1::WorkflowExecutionTokenCreated {
                    run_id: request.run_id.clone(),
                    run_token_id: token_id.to_owned(),
                    execution_token_id: child_token_id.clone(),
                    parent_execution_token_id: execution_token_id.to_owned(),
                    fork_node_id: node.id.clone(),
                    branch_id: branch.id.clone(),
                    branch_port_id: port_id.clone(),
                    join_node_id: parallel_join_node(&package.compiled, node, &config)?,
                    source_emission_id: emission_id.clone(),
                    iteration_node_id: String::new(),
                    iteration_index: 0,
                    iteration_count: 0,
                    resume_node_id: String::new(),
                    resume_reason: String::new(),
                },
                &causation_id,
                &request.run_id,
            ));
            causation_id = token_event_id;
            child_token_id
        } else {
            execution_token_id.to_owned()
        };
        let emission_event_id = stable_id(
            "event",
            &[
                &request.run_id,
                "port",
                execution_token_id,
                &attempt.started.attempt_id,
                &port_id,
            ],
        );
        events.push(runtime_event(
            command.submitted_at_unix_millis,
            &emission_event_id,
            workflow_runtime::WORKFLOW_PORT_EMITTED_KIND,
            workflow_runtime::WORKFLOW_PORT_EMITTED_TYPE,
            v1::WorkflowPortEmitted {
                run_id: request.run_id.clone(),
                run_token_id: token_id.to_owned(),
                emission_id: emission_id.clone(),
                attempt_id: attempt.started.attempt_id.clone(),
                node_id: node.id.clone(),
                port_id: port_id.clone(),
                value: Some(value),
                execution_token_id: execution_token_id.to_owned(),
            },
            &causation_id,
            &request.run_id,
        ));
        causation_id = emission_event_id;
        emission_ids.push(emission_id.clone());

        let outgoing = package
            .compiled
            .edges
            .iter()
            .filter(|edge| edge.from.node_id == node.id && edge.from.port_id == port_id)
            .collect::<Vec<_>>();
        if outgoing.len() != 1 {
            return Err(WorkflowExecutionError::Unsupported(format!(
                "selected_port_edge_count:{}:{}",
                node.id, port_id
            )));
        }
        let edge = outgoing[0];
        let edge_event_id = stable_id(
            "event",
            &[
                &request.run_id,
                "edge",
                &edge_execution_token_id,
                &edge.id,
                &emission_id,
            ],
        );
        events.push(runtime_event(
            command.submitted_at_unix_millis,
            &edge_event_id,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_KIND,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_TYPE,
            v1::WorkflowEdgeCheckpointed {
                run_id: request.run_id.clone(),
                run_token_id: token_id.to_owned(),
                edge_id: edge.id.clone(),
                emission_id,
                target_node_id: edge.to.node_id.clone(),
                target_port_id: edge.to.port_id.clone(),
                state: v1::WorkflowEdgeCheckpointState::Admitted as i32,
                execution_token_id: edge_execution_token_id,
            },
            &causation_id,
            &request.run_id,
        ));
        causation_id = edge_event_id;
    }

    let settle_event_id = stable_id(
        "event",
        &[
            &request.run_id,
            "attempt-settled",
            execution_token_id,
            &attempt.started.attempt_id,
        ],
    );
    events.push(runtime_event(
        command.submitted_at_unix_millis,
        &settle_event_id,
        workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_KIND,
        workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_TYPE,
        v1::WorkflowAttemptSettled {
            run_id: request.run_id.clone(),
            run_token_id: token_id.to_owned(),
            attempt_id: attempt.started.attempt_id.clone(),
            node_id: node.id.clone(),
            attempt_number: attempt.started.attempt_number,
            outcome: execution.outcome as i32,
            error_code: execution.error_code,
            error: execution.error,
            emission_ids,
            execution_token_id: execution_token_id.to_owned(),
        },
        &causation_id,
        &request.run_id,
    ));
    Ok(events)
}

#[allow(clippy::too_many_arguments)]
fn for_each_controller_event_sequence(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<Vec<v1::EventEnvelope>> {
    let config: ForEachConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("for_each_config".into()))?;
    let input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("iteration_input_missing".into()))?
        .1
        .clone();
    let items = selected_iteration_items(&input, &config)?;
    let iteration = state
        .iterations
        .iter()
        .find(|iteration| iteration.planned.controller_attempt_id == attempt.started.attempt_id);
    if iteration.is_none() {
        return Ok(vec![runtime_event(
            command.submitted_at_unix_millis,
            &stable_id(
                "event",
                &[
                    &request.run_id,
                    "iteration-plan",
                    &attempt.started.attempt_id,
                ],
            ),
            workflow_runtime::WORKFLOW_ITERATION_PLANNED_KIND,
            workflow_runtime::WORKFLOW_ITERATION_PLANNED_TYPE,
            v1::WorkflowIterationPlanned {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                iteration_node_id: node.id.clone(),
                parent_execution_token_id: attempt.started.execution_token_id.clone(),
                controller_attempt_id: attempt.started.attempt_id.clone(),
                input_value_id: input.value_id.clone(),
                input_sha256: input.sha256.clone(),
                item_count: items.len() as u32,
                maximum_items: config.maximum_items,
                maximum_concurrency: config.maximum_concurrency,
                failure_policy: config.failure_policy,
            },
            &attempt.started_event_id,
            &request.run_id,
        )]);
    }
    let iteration = iteration.unwrap();
    if iteration.planned.input_value_id != input.value_id
        || iteration.planned.input_sha256 != input.sha256
        || iteration.planned.item_count as usize != items.len()
    {
        return Err(WorkflowExecutionError::Integrity(
            "iteration_plan_input_drift".into(),
        ));
    }
    let mut events = Vec::new();
    let item_edge = single_outgoing_edge(&package.compiled, node, "item")?;
    for (index, item) in items.iter().enumerate() {
        let emission_id = iteration_emission_id(request, node, index);
        events.push(runtime_event(
            command.submitted_at_unix_millis,
            &iteration_emission_event_id(request, node, index),
            workflow_runtime::WORKFLOW_PORT_EMITTED_KIND,
            workflow_runtime::WORKFLOW_PORT_EMITTED_TYPE,
            v1::WorkflowPortEmitted {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                emission_id,
                attempt_id: attempt.started.attempt_id.clone(),
                node_id: node.id.clone(),
                port_id: "item".into(),
                value: Some(iteration_item_value(request, node, index, item)?),
                execution_token_id: attempt.started.execution_token_id.clone(),
            },
            &iteration.planned_event_id,
            &request.run_id,
        ));
    }
    for index in 0..usize::min(items.len(), config.maximum_concurrency as usize) {
        events.extend(iteration_item_admission_events(
            command,
            request,
            run_token_id,
            node,
            attempt,
            item_edge,
            index,
            items.len(),
        ));
    }
    events.push(runtime_event(
        command.submitted_at_unix_millis,
        &stable_id(
            "event",
            &[
                &request.run_id,
                "attempt-settled",
                &attempt.started.attempt_id,
            ],
        ),
        workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_KIND,
        workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_TYPE,
        v1::WorkflowAttemptSettled {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            attempt_id: attempt.started.attempt_id.clone(),
            node_id: node.id.clone(),
            attempt_number: attempt.started.attempt_number,
            outcome: v1::WorkflowAttemptOutcome::Succeeded as i32,
            error_code: String::new(),
            error: None,
            emission_ids: (0..items.len())
                .map(|index| iteration_emission_id(request, node, index))
                .collect(),
            execution_token_id: attempt.started.execution_token_id.clone(),
        },
        events
            .last()
            .map(|event| event.event_id.as_str())
            .unwrap_or(iteration.planned_event_id.as_str()),
        &request.run_id,
    ));
    Ok(events)
}

fn selected_iteration_items(
    input: &v1::WorkflowValueReference,
    config: &ForEachConfig,
) -> Result<Vec<Value>> {
    let root = inline_json(input)?;
    let selected = root
        .pointer(&config.items.pointer)
        .ok_or_else(|| WorkflowExecutionError::Integrity("iteration_items_pointer".into()))?;
    let items = selected
        .as_array()
        .ok_or_else(|| WorkflowExecutionError::Integrity("iteration_items_array".into()))?;
    if items.len() > config.maximum_items as usize {
        return Err(WorkflowExecutionError::Lifecycle(
            "iteration_item_bound_exceeded".into(),
        ));
    }
    Ok(items.clone())
}

fn iteration_token_id(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    index: usize,
) -> String {
    stable_id(
        "execution-token",
        &[&request.run_id, &node.id, "iteration", &index.to_string()],
    )
}

fn iteration_emission_id(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    index: usize,
) -> String {
    stable_id(
        "emission",
        &[&request.run_id, &node.id, "item", &index.to_string()],
    )
}

fn iteration_emission_event_id(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    index: usize,
) -> String {
    stable_id(
        "event",
        &[
            &request.run_id,
            &node.id,
            "item-emitted",
            &index.to_string(),
        ],
    )
}

fn iteration_item_value(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    index: usize,
    item: &Value,
) -> Result<v1::WorkflowValueReference> {
    value_from_json(
        &stable_id(
            "value",
            &[&request.run_id, &node.id, "item", &index.to_string()],
        ),
        item,
    )
}

#[allow(clippy::too_many_arguments)]
fn iteration_item_admission_events(
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    node: &CompiledNode,
    attempt: &RecordedAttempt,
    edge: &CompiledEdge,
    index: usize,
    item_count: usize,
) -> Vec<v1::EventEnvelope> {
    let execution_token_id = iteration_token_id(request, node, index);
    let emission_id = iteration_emission_id(request, node, index);
    let token_event_id = stable_id(
        "event",
        &[&request.run_id, &node.id, "item-token", &index.to_string()],
    );
    let edge_event_id = stable_id(
        "event",
        &[&request.run_id, &node.id, "item-edge", &index.to_string()],
    );
    vec![
        runtime_event(
            command.submitted_at_unix_millis,
            &token_event_id,
            workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
            workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
            v1::WorkflowExecutionTokenCreated {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                execution_token_id: execution_token_id.clone(),
                parent_execution_token_id: attempt.started.execution_token_id.clone(),
                fork_node_id: String::new(),
                branch_id: String::new(),
                branch_port_id: "item".into(),
                join_node_id: String::new(),
                source_emission_id: emission_id.clone(),
                iteration_node_id: node.id.clone(),
                iteration_index: index as u32,
                iteration_count: item_count as u32,
                resume_node_id: String::new(),
                resume_reason: String::new(),
            },
            &iteration_emission_event_id(request, node, index),
            &request.run_id,
        ),
        runtime_event(
            command.submitted_at_unix_millis,
            &edge_event_id,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_KIND,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_TYPE,
            v1::WorkflowEdgeCheckpointed {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                edge_id: edge.id.clone(),
                emission_id,
                target_node_id: edge.to.node_id.clone(),
                target_port_id: edge.to.port_id.clone(),
                state: v1::WorkflowEdgeCheckpointState::Admitted as i32,
                execution_token_id,
            },
            &token_event_id,
            &request.run_id,
        ),
    ]
}

#[allow(clippy::too_many_arguments)]
fn retry_controller_event_sequence(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
    now_unix_millis: i64,
) -> Result<Vec<v1::EventEnvelope>> {
    let config: RetryConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("retry_config".into()))?;
    let recorded = state
        .retries
        .iter()
        .find(|retry| retry.payload.controller_attempt_id == attempt.started.attempt_id);
    if recorded.is_none() {
        let (incoming, error) = inputs
            .last()
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("retry_error_missing".into()))?;
        let incoming = incoming
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("retry_source_edge_missing".into()))?;
        let source_emission = state
            .emissions
            .get(&incoming.emission_id)
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("retry_source_emission".into()))?;
        let failed_attempt = state
            .attempts
            .iter()
            .find(|candidate| candidate.started.attempt_id == source_emission.payload.attempt_id)
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("retry_failed_attempt".into()))?;
        let target_edge = single_outgoing_edge(&package.compiled, node, "retry")?;
        if target_edge.to.node_id != failed_attempt.started.node_id {
            return Err(WorkflowExecutionError::Integrity(
                "retry_target_mismatch".into(),
            ));
        }
        let target_inputs = node_inputs(
            request,
            state,
            &failed_attempt.started.node_id,
            &attempt.started.execution_token_id,
        )?;
        let retry_input = target_inputs
            .last()
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("retry_input_missing".into()))?
            .1
            .clone();
        let target_attempt_count = state
            .attempts
            .iter()
            .filter(|candidate| {
                candidate.started.execution_token_id == attempt.started.execution_token_id
                    && candidate.started.node_id == failed_attempt.started.node_id
            })
            .count() as u32;
        let next_attempt_number = target_attempt_count + 1;
        let error_json = inline_json(error)?;
        let error_code = error_code(error)?;
        let decision =
            classify_retry_decision(&error_json, &error_code, &config, next_attempt_number);
        let delay_milliseconds = if decision == v1::WorkflowRetryDecision::Scheduled {
            retry_delay_milliseconds(request, node, &config, next_attempt_number)?
        } else {
            0
        };
        let eligible_at_unix_millis = if delay_milliseconds == 0 {
            0
        } else {
            attempt
                .started_at_unix_millis
                .checked_add(delay_milliseconds as i64)
                .ok_or_else(|| {
                    WorkflowExecutionError::Integrity("retry_deadline_overflow".into())
                })?
        };
        return Ok(vec![runtime_event(
            command.submitted_at_unix_millis,
            &stable_id(
                "event",
                &[
                    &request.run_id,
                    "retry-evaluated",
                    &attempt.started.attempt_id,
                ],
            ),
            workflow_runtime::WORKFLOW_RETRY_EVALUATED_KIND,
            workflow_runtime::WORKFLOW_RETRY_EVALUATED_TYPE,
            v1::WorkflowRetryEvaluated {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                retry_node_id: node.id.clone(),
                execution_token_id: attempt.started.execution_token_id.clone(),
                controller_attempt_id: attempt.started.attempt_id.clone(),
                failed_attempt_id: failed_attempt.started.attempt_id.clone(),
                target_node_id: failed_attempt.started.node_id.clone(),
                error_code,
                decision: decision as i32,
                next_attempt_number,
                maximum_attempts: config.maximum_attempts,
                delay_milliseconds,
                eligible_at_unix_millis,
                retry_input: Some(retry_input),
                error: Some(error.clone()),
            },
            &attempt.started_event_id,
            &request.run_id,
        )]);
    }
    let recorded = recorded.unwrap();
    let decision = v1::WorkflowRetryDecision::try_from(recorded.payload.decision)
        .map_err(|_| WorkflowExecutionError::Integrity("retry_decision".into()))?;
    if decision == v1::WorkflowRetryDecision::Scheduled
        && now_unix_millis < recorded.payload.eligible_at_unix_millis
    {
        return Err(WorkflowExecutionError::WaitingUntil(
            recorded.payload.eligible_at_unix_millis,
        ));
    }
    let (port_id, value) =
        match decision {
            v1::WorkflowRetryDecision::Scheduled => (
                "retry",
                recorded.payload.retry_input.clone().ok_or_else(|| {
                    WorkflowExecutionError::Integrity("retry_input_recorded".into())
                })?,
            ),
            v1::WorkflowRetryDecision::UnknownOutcome => (
                "unknown",
                recorded.payload.error.clone().ok_or_else(|| {
                    WorkflowExecutionError::Integrity("retry_error_recorded".into())
                })?,
            ),
            v1::WorkflowRetryDecision::Exhausted | v1::WorkflowRetryDecision::NotRetryable => (
                "exhausted",
                recorded.payload.error.clone().ok_or_else(|| {
                    WorkflowExecutionError::Integrity("retry_error_recorded".into())
                })?,
            ),
            v1::WorkflowRetryDecision::Unspecified => {
                return Err(WorkflowExecutionError::Integrity("retry_decision".into()));
            }
        };
    controller_output_events(
        &package.compiled,
        command,
        request,
        run_token_id,
        attempt,
        node,
        port_id,
        value,
        &recorded.event_id,
    )
}

#[allow(clippy::too_many_arguments)]
fn wait_controller_event_sequence(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
    now_unix_millis: i64,
) -> Result<Vec<v1::EventEnvelope>> {
    let config: WaitConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("wait_config".into()))?;
    let input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("wait_input_missing".into()))?
        .1
        .clone();
    let correlation = wait_correlation(&input, &config)?;
    let (owner_kind, owner_id) = wait_owner(request);
    let subscription_id = stable_id(
        "wait",
        &[&request.run_id, &node.id, &attempt.started.attempt_id],
    );
    let recorded = state.waits.get(&subscription_id);
    if recorded.is_none() {
        let expiry_millis = config
            .expiry_seconds
            .checked_mul(1_000)
            .and_then(|value| i64::try_from(value).ok())
            .and_then(|value| attempt.started_at_unix_millis.checked_add(value))
            .ok_or_else(|| WorkflowExecutionError::Integrity("wait_deadline_overflow".into()))?;
        return Ok(vec![runtime_event(
            command.submitted_at_unix_millis,
            &stable_id(
                "event",
                &[&request.run_id, "wait-subscribed", &subscription_id],
            ),
            workflow_runtime::WORKFLOW_WAIT_SUBSCRIBED_KIND,
            workflow_runtime::WORKFLOW_WAIT_SUBSCRIBED_TYPE,
            v1::WorkflowWaitSubscribed {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                subscription_id,
                wait_node_id: node.id.clone(),
                execution_token_id: attempt.started.execution_token_id.clone(),
                controller_attempt_id: attempt.started.attempt_id.clone(),
                workflow_id: request.workflow_id.clone(),
                revision_id: request.revision_id.clone(),
                package_digest: request.package_digest.clone(),
                kind: config.kind,
                owner_kind,
                owner_id,
                correlation,
                input_value_id: input.value_id,
                input_sha256: input.sha256,
                expires_at_unix_millis: expiry_millis,
            },
            &attempt.started_event_id,
            &request.run_id,
        )]);
    }
    let recorded = recorded.unwrap();
    if recorded.subscribed.run_token_id != run_token_id
        || recorded.subscribed.wait_node_id != node.id
        || recorded.subscribed.execution_token_id != attempt.started.execution_token_id
        || recorded.subscribed.controller_attempt_id != attempt.started.attempt_id
        || recorded.subscribed.workflow_id != request.workflow_id
        || recorded.subscribed.revision_id != request.revision_id
        || recorded.subscribed.package_digest != request.package_digest
        || recorded.subscribed.kind != config.kind
        || recorded.subscribed.owner_kind != owner_kind
        || recorded.subscribed.owner_id != owner_id
        || recorded.subscribed.correlation != correlation
        || recorded.subscribed.input_value_id != input.value_id
        || recorded.subscribed.input_sha256 != input.sha256
    {
        return Err(WorkflowExecutionError::Integrity("wait_pin_drift".into()));
    }
    if let Some(resolved) = recorded.resolved.as_ref() {
        let decision = v1::WorkflowWaitDecision::try_from(resolved.decision)
            .map_err(|_| WorkflowExecutionError::Integrity("wait_decision".into()))?;
        return match decision {
            v1::WorkflowWaitDecision::Resumed => controller_output_events(
                &package.compiled,
                command,
                request,
                run_token_id,
                attempt,
                node,
                "resumed",
                resolved
                    .output
                    .clone()
                    .ok_or_else(|| WorkflowExecutionError::Integrity("wait_output".into()))?,
                recorded
                    .resolved_event_id
                    .as_deref()
                    .ok_or_else(|| WorkflowExecutionError::Integrity("wait_event_id".into()))?,
            ),
            v1::WorkflowWaitDecision::Expired => controller_output_events(
                &package.compiled,
                command,
                request,
                run_token_id,
                attempt,
                node,
                "expired",
                resolved
                    .output
                    .clone()
                    .ok_or_else(|| WorkflowExecutionError::Integrity("wait_output".into()))?,
                recorded
                    .resolved_event_id
                    .as_deref()
                    .ok_or_else(|| WorkflowExecutionError::Integrity("wait_event_id".into()))?,
            ),
            v1::WorkflowWaitDecision::Cancelled => Err(WorkflowExecutionError::Lifecycle(
                "cancelled_wait_without_run_cancellation".into(),
            )),
            v1::WorkflowWaitDecision::Unspecified => {
                Err(WorkflowExecutionError::Integrity("wait_decision".into()))
            }
        };
    }

    let consumed = state
        .waits
        .values()
        .filter_map(|wait| wait.resolved.as_ref())
        .map(|resolved| resolved.signal_id.as_str())
        .filter(|signal_id| !signal_id.is_empty())
        .collect::<BTreeSet<_>>();
    let matching_signal = state
        .wait_signals
        .values()
        .filter(|signal| {
            !consumed.contains(signal.payload.signal_id.as_str())
                && signal.payload.kind == recorded.subscribed.kind
                && signal.payload.owner_kind == recorded.subscribed.owner_kind
                && signal.payload.owner_id == recorded.subscribed.owner_id
                && signal.payload.correlation == recorded.subscribed.correlation
                && signal.occurred_at_unix_millis <= recorded.subscribed.expires_at_unix_millis
        })
        .min_by_key(|signal| signal.store_position);
    if let Some(signal) = matching_signal {
        return Ok(vec![wait_resolved_event(
            signal.occurred_at_unix_millis,
            request,
            run_token_id,
            recorded,
            v1::WorkflowWaitDecision::Resumed,
            signal.payload.signal_id.clone(),
            signal.payload.value.clone(),
            String::new(),
            &signal.event_id,
        )]);
    }
    if now_unix_millis < recorded.subscribed.expires_at_unix_millis {
        return Err(WorkflowExecutionError::WaitingUntil(
            recorded.subscribed.expires_at_unix_millis,
        ));
    }
    if recorded.subscribed.kind == "timer" {
        let signal_id = stable_id("timer", &[&request.run_id, &subscription_id]);
        let output = value_from_json(
            &stable_id("value", &[&request.run_id, &subscription_id, "timer"]),
            &json!({
                "kind": "timer",
                "scheduledForUnixMillis": recorded.subscribed.expires_at_unix_millis,
                "subscriptionId": subscription_id,
            }),
        )?;
        return Ok(vec![wait_resolved_event(
            recorded.subscribed.expires_at_unix_millis,
            request,
            run_token_id,
            recorded,
            v1::WorkflowWaitDecision::Resumed,
            signal_id,
            Some(output),
            String::new(),
            &recorded.subscribed_event_id,
        )]);
    }
    let output = value_from_json(
        &stable_id("value", &[&request.run_id, &subscription_id, "expired"]),
        &json!({
            "kind": recorded.subscribed.kind,
            "expiredAtUnixMillis": recorded.subscribed.expires_at_unix_millis,
            "subscriptionId": subscription_id,
        }),
    )?;
    Ok(vec![wait_resolved_event(
        recorded.subscribed.expires_at_unix_millis,
        request,
        run_token_id,
        recorded,
        v1::WorkflowWaitDecision::Expired,
        String::new(),
        Some(output),
        "wait.expired".into(),
        &recorded.subscribed_event_id,
    )])
}

fn wait_owner(request: &v1::RequestWorkflowRun) -> (String, String) {
    if !request.case_id.is_empty() {
        ("case".into(), request.case_id.clone())
    } else if !request.installation_id.is_empty() {
        ("installation".into(), request.installation_id.clone())
    } else {
        ("workflow".into(), request.workflow_id.clone())
    }
}

fn wait_correlation(
    input: &v1::WorkflowValueReference,
    config: &WaitConfig,
) -> Result<Vec<v1::WorkflowWaitCorrelation>> {
    let root = inline_json(input)?;
    let mut correlation = config
        .correlation
        .iter()
        .map(|selector| {
            let value = root.pointer(&selector.pointer).ok_or_else(|| {
                WorkflowExecutionError::Lifecycle("wait_correlation_missing".into())
            })?;
            let canonical = workflow_canonical::canonicalize(
                &serde_json::to_vec(value)
                    .map_err(|_| WorkflowExecutionError::Encoding("wait_correlation"))?,
            )
            .map_err(|_| WorkflowExecutionError::Encoding("wait_correlation_canonical"))?;
            Ok(v1::WorkflowWaitCorrelation {
                key: format!("{}:{}", selector.root, selector.pointer),
                sha256: canonical
                    .sha256
                    .strip_prefix("sha256:")
                    .ok_or(WorkflowExecutionError::Encoding("wait_correlation_digest"))?
                    .to_owned(),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    correlation.sort_by(|left, right| left.key.cmp(&right.key));
    Ok(correlation)
}

#[allow(clippy::too_many_arguments)]
fn wait_resolved_event(
    occurred_at_unix_millis: i64,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    wait: &RecordedWait,
    decision: v1::WorkflowWaitDecision,
    signal_id: String,
    output: Option<v1::WorkflowValueReference>,
    reason_code: String,
    causation_id: &str,
) -> v1::EventEnvelope {
    runtime_event(
        occurred_at_unix_millis,
        &stable_id(
            "event",
            &[
                &request.run_id,
                "wait-resolved",
                &wait.subscribed.subscription_id,
            ],
        ),
        workflow_runtime::WORKFLOW_WAIT_RESOLVED_KIND,
        workflow_runtime::WORKFLOW_WAIT_RESOLVED_TYPE,
        v1::WorkflowWaitResolved {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            subscription_id: wait.subscribed.subscription_id.clone(),
            decision: decision as i32,
            signal_id,
            output,
            reason_code,
        },
        causation_id,
        &request.run_id,
    )
}

fn classify_retry_decision(
    error: &Value,
    error_code: &str,
    config: &RetryConfig,
    next_attempt_number: u32,
) -> v1::WorkflowRetryDecision {
    let unknown = error.get("outcome").and_then(Value::as_str) == Some("unknown")
        || error.get("retryability").and_then(Value::as_str) == Some("reconcile-first");
    if unknown {
        v1::WorkflowRetryDecision::UnknownOutcome
    } else if next_attempt_number > config.maximum_attempts {
        v1::WorkflowRetryDecision::Exhausted
    } else if error.get("retryability").and_then(Value::as_str) == Some("never")
        || !config.retry_on.iter().any(|code| code == error_code)
    {
        v1::WorkflowRetryDecision::NotRetryable
    } else {
        v1::WorkflowRetryDecision::Scheduled
    }
}

fn retry_delay_milliseconds(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    config: &RetryConfig,
    next_attempt_number: u32,
) -> Result<u64> {
    let exponent = next_attempt_number.saturating_sub(2).min(31);
    let seconds = if config.backoff.mode == "fixed" {
        config.backoff.initial_seconds
    } else {
        (config.backoff.initial_seconds * 2_f64.powi(exponent as i32))
            .min(config.backoff.maximum_seconds)
    };
    let mut milliseconds = (seconds * 1000.0).round() as u64;
    if config.backoff.jitter == "deterministic" {
        let digest = Sha256::digest(
            format!("{}:{}:{}", request.run_id, node.id, next_attempt_number).as_bytes(),
        );
        let basis_points = 7_500 + u16::from_be_bytes([digest[0], digest[1]]) as u64 % 5_001;
        milliseconds = milliseconds
            .checked_mul(basis_points)
            .and_then(|value| value.checked_div(10_000))
            .ok_or_else(|| WorkflowExecutionError::Integrity("retry_delay_overflow".into()))?;
    }
    Ok(milliseconds.max(1))
}

#[allow(clippy::too_many_arguments)]
fn controller_output_events(
    compiled: &CompiledWorkflow,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    port_id: &str,
    value: v1::WorkflowValueReference,
    causation_id: &str,
) -> Result<Vec<v1::EventEnvelope>> {
    let edge = single_outgoing_edge(compiled, node, port_id)?;
    let emission_id = stable_id(
        "emission",
        &[&request.run_id, &attempt.started.attempt_id, port_id],
    );
    let emission_event_id = stable_id(
        "event",
        &[
            &request.run_id,
            "port",
            &attempt.started.attempt_id,
            port_id,
        ],
    );
    let edge_event_id = stable_id(
        "event",
        &[
            &request.run_id,
            "edge",
            &attempt.started.attempt_id,
            &edge.id,
        ],
    );
    let settle_event_id = stable_id(
        "event",
        &[
            &request.run_id,
            "attempt-settled",
            &attempt.started.attempt_id,
        ],
    );
    Ok(vec![
        runtime_event(
            command.submitted_at_unix_millis,
            &emission_event_id,
            workflow_runtime::WORKFLOW_PORT_EMITTED_KIND,
            workflow_runtime::WORKFLOW_PORT_EMITTED_TYPE,
            v1::WorkflowPortEmitted {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                emission_id: emission_id.clone(),
                attempt_id: attempt.started.attempt_id.clone(),
                node_id: node.id.clone(),
                port_id: port_id.into(),
                value: Some(value),
                execution_token_id: attempt.started.execution_token_id.clone(),
            },
            causation_id,
            &request.run_id,
        ),
        runtime_event(
            command.submitted_at_unix_millis,
            &edge_event_id,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_KIND,
            workflow_runtime::WORKFLOW_EDGE_CHECKPOINTED_TYPE,
            v1::WorkflowEdgeCheckpointed {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                edge_id: edge.id.clone(),
                emission_id: emission_id.clone(),
                target_node_id: edge.to.node_id.clone(),
                target_port_id: edge.to.port_id.clone(),
                state: v1::WorkflowEdgeCheckpointState::Admitted as i32,
                execution_token_id: attempt.started.execution_token_id.clone(),
            },
            &emission_event_id,
            &request.run_id,
        ),
        runtime_event(
            command.submitted_at_unix_millis,
            &settle_event_id,
            workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_KIND,
            workflow_runtime::WORKFLOW_ATTEMPT_SETTLED_TYPE,
            v1::WorkflowAttemptSettled {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                attempt_id: attempt.started.attempt_id.clone(),
                node_id: node.id.clone(),
                attempt_number: attempt.started.attempt_number,
                outcome: v1::WorkflowAttemptOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                emission_ids: vec![emission_id],
                execution_token_id: attempt.started.execution_token_id.clone(),
            },
            &edge_event_id,
            &request.run_id,
        ),
    ])
}

fn single_outgoing_edge<'a>(
    compiled: &'a CompiledWorkflow,
    node: &CompiledNode,
    port_id: &str,
) -> Result<&'a CompiledEdge> {
    let edges = compiled
        .edges
        .iter()
        .filter(|edge| edge.from.node_id == node.id && edge.from.port_id == port_id)
        .collect::<Vec<_>>();
    if edges.len() != 1 {
        return Err(WorkflowExecutionError::Unsupported(format!(
            "selected_port_edge_count:{}:{}",
            node.id, port_id
        )));
    }
    Ok(edges[0])
}

#[allow(clippy::too_many_arguments)]
fn execute_node(
    package: &ExecutionPackage,
    storage: Option<&mut WorkflowScopedStorage>,
    request: &v1::RequestWorkflowRun,
    episode: Option<&v1::WorkflowCaseEpisodeStarted>,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
) -> Result<NodeExecution> {
    match node.node_type.as_str() {
        "trigger.manual" => Ok(success_output("success", input.clone())),
        "data.case-context" => {
            let context = episode
                .and_then(|episode| episode.compiled_context.clone())
                .ok_or(WorkflowExecutionError::InvalidCommand(
                    "case_episode_required",
                ))?;
            Ok(success_output("success", context))
        }
        "data.validate" => {
            let instance = inline_json(input)?;
            let schema_ref = node
                .config
                .get("schemaRef")
                .and_then(Value::as_str)
                .ok_or_else(|| WorkflowExecutionError::Integrity("validate_schema_ref".into()))?;
            let schema = package.schemas.get(schema_ref).ok_or_else(|| {
                WorkflowExecutionError::Integrity("validate_schema_missing".into())
            })?;
            let report = workflow_schema::check(&WorkflowSchemaCheckRequest {
                schema: schema.clone(),
                instance,
            });
            if report.outcome == WorkflowSchemaCheckOutcome::Valid {
                return Ok(success_output("success", input.clone()));
            }
            let error = value_from_json(
                &stable_id("value", &[&request.run_id, &node.id, "validation-error"]),
                &json!({
                    "code": "validation.failed",
                    "diagnostics": report.diagnostics,
                    "diagnosticsTruncated": report.diagnostics_truncated
                }),
            )?;
            Ok(failure_output("error", "validation.failed", error))
        }
        "control.match" => {
            let config: MatchConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("match_config".into()))?;
            let evaluation =
                workflow_match::evaluate(&config, &MatchRoots::with_input(inline_json(input)?));
            let trace_value = value_from_json(
                &stable_id("value", &[&request.run_id, &node.id, "match-trace"]),
                &serde_json::to_value(&evaluation)
                    .map_err(|_| WorkflowExecutionError::Encoding("match_trace"))?,
            )?;
            let evaluated_case_ids = evaluation
                .cases
                .iter()
                .filter(|case| case.outcome != TraceOutcome::NotEvaluated)
                .map(|case| case.case_id.clone())
                .collect::<Vec<_>>();
            let mut emitted_port_ids = evaluation.emitted_port_ids.clone();
            let (outputs, outcome, error_code, error) = match evaluation.outcome {
                EvaluationOutcome::Matched if emitted_port_ids.len() == 1 => (
                    vec![(emitted_port_ids[0].clone(), input.clone())],
                    v1::WorkflowAttemptOutcome::Succeeded,
                    String::new(),
                    None,
                ),
                EvaluationOutcome::Matched => {
                    return Err(WorkflowExecutionError::Unsupported(
                        "match_fanout_not_minimal".into(),
                    ));
                }
                EvaluationOutcome::NotMatched | EvaluationOutcome::EvaluationError => {
                    emitted_port_ids = vec!["error".into()];
                    let evaluation_error = evaluation.error.as_ref();
                    let code = evaluation_error
                        .map(|error| error.code.clone())
                        .unwrap_or_else(|| "match.no-route".into());
                    let value = value_from_json(
                        &stable_id("value", &[&request.run_id, &node.id, "match-error"]),
                        &json!({
                            "code": code,
                            "expressionId": evaluation_error.map(|error| error.expression_id.as_str()),
                            "message": evaluation_error.map(|error| error.message.as_str()).unwrap_or("No Match case or Otherwise route was selected.")
                        }),
                    )?;
                    (
                        vec![("error".into(), value.clone())],
                        v1::WorkflowAttemptOutcome::Failed,
                        code,
                        Some(value),
                    )
                }
            };
            Ok(NodeExecution {
                match_trace: Some(MatchTraceOutput {
                    input_value_id: input.value_id.clone(),
                    evaluated_case_ids,
                    matched_case_ids: evaluation.selected_case_ids,
                    emitted_port_ids,
                    value: trace_value,
                }),
                outputs,
                outcome,
                error_code,
                error,
            })
        }
        "control.parallel" => {
            let config: ParallelConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("parallel_config".into()))?;
            Ok(NodeExecution {
                match_trace: None,
                outputs: config
                    .branches
                    .into_iter()
                    .map(|branch| (format!("case-{}", branch.id), input.clone()))
                    .collect(),
                outcome: v1::WorkflowAttemptOutcome::Succeeded,
                error_code: String::new(),
                error: None,
            })
        }
        "storage.read" | "storage.write" | "storage.promote" => execute_storage_node(
            package,
            storage.ok_or_else(|| {
                WorkflowExecutionError::Unsupported("storage_service_required".into())
            })?,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
        ),
        "terminal.complete" => Ok(NodeExecution {
            match_trace: None,
            outputs: Vec::new(),
            outcome: v1::WorkflowAttemptOutcome::Succeeded,
            error_code: String::new(),
            error: None,
        }),
        "terminal.fail" => {
            let code = error_code(input)?;
            Ok(NodeExecution {
                match_trace: None,
                outputs: Vec::new(),
                outcome: v1::WorkflowAttemptOutcome::Failed,
                error_code: code,
                error: Some(input.clone()),
            })
        }
        _ => Err(WorkflowExecutionError::Unsupported(format!(
            "node:{}",
            node.node_type
        ))),
    }
}

fn execute_join_node(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    state: &RecordedRun,
    execution_token_id: &str,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<NodeExecution> {
    let config: JoinConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("join_config".into()))?;
    let join = state
        .joins
        .iter()
        .find(|join| join.payload.resumed_execution_token_id == execution_token_id)
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("join_decision_missing".into()))?;
    if join.payload.join_node_id != node.id
        || join.payload.policy != config.policy
        || join.payload.cancel_remaining != config.cancel_remaining
    {
        return Err(WorkflowExecutionError::Integrity(
            "join_decision_contract".into(),
        ));
    }
    let branches = inputs
        .iter()
        .filter_map(|(edge, value)| {
            edge.map(|edge| {
                json!({
                    "executionTokenId": edge.execution_token_id,
                    "emissionId": edge.emission_id,
                    "valueId": value.value_id,
                    "sha256": value.sha256,
                    "bytes": value.byte_count
                })
            })
        })
        .collect::<Vec<_>>();
    let summary = json!({
        "code": join.payload.error_code,
        "policy": join.payload.policy,
        "threshold": join.payload.threshold,
        "decision": if join.payload.decision == v1::WorkflowJoinDecision::Succeeded as i32 { "succeeded" } else { "failed" },
        "expectedExecutionTokenIds": join.payload.expected_execution_token_ids,
        "arrivedExecutionTokenIds": join.payload.arrived_execution_token_ids,
        "failedExecutionTokenIds": join.payload.failed_execution_token_ids,
        "pendingExecutionTokenIds": join.payload.pending_execution_token_ids,
        "branches": branches
    });
    let value = value_from_json(
        &stable_id(
            "value",
            &[&request.run_id, execution_token_id, &node.id, "join"],
        ),
        &summary,
    )?;
    match v1::WorkflowJoinDecision::try_from(join.payload.decision) {
        Ok(v1::WorkflowJoinDecision::Succeeded) => Ok(success_output("success", value)),
        Ok(v1::WorkflowJoinDecision::Failed) => {
            Ok(failure_output("error", &join.payload.error_code, value))
        }
        _ => Err(WorkflowExecutionError::Integrity(
            "join_decision_invalid".into(),
        )),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StorageReadConfig {
    #[serde(default = "default_storage_read_operation")]
    operation: String,
    scope: String,
    key: String,
    #[serde(default = "default_true")]
    required: bool,
    #[serde(default = "default_storage_list_limit")]
    limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StorageWriteConfig {
    #[serde(default = "default_storage_write_operation")]
    operation: String,
    scope: String,
    key: String,
    value: Option<StorageValueSelector>,
    conflict_policy: String,
    expected_revision: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoragePromoteConfig {
    from: String,
    to: String,
    source_key: String,
    destination_key: String,
    conflict_policy: String,
    expected_revision: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StorageValueSelector {
    root: String,
    pointer: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ParallelConfig {
    branches: Vec<ParallelBranch>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ParallelBranch {
    id: String,
    key: String,
    label: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JoinConfig {
    policy: String,
    quorum: Option<u32>,
    #[serde(default)]
    required_branches: Vec<String>,
    cancel_remaining: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ForEachConfig {
    items: StorageValueSelector,
    #[serde(rename = "as")]
    item_binding: String,
    maximum_items: u32,
    maximum_concurrency: u32,
    failure_policy: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RetryConfig {
    maximum_attempts: u32,
    retry_on: Vec<String>,
    backoff: RetryBackoffConfig,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RetryBackoffConfig {
    mode: String,
    initial_seconds: f64,
    maximum_seconds: f64,
    #[serde(default = "default_retry_jitter")]
    jitter: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WaitConfig {
    kind: String,
    correlation: Vec<StorageValueSelector>,
    expiry_seconds: u64,
}

fn default_retry_jitter() -> String {
    "none".into()
}

fn default_storage_read_operation() -> String {
    "read".into()
}

fn default_storage_write_operation() -> String {
    "write".into()
}

const fn default_storage_list_limit() -> u32 {
    100
}

const fn default_true() -> bool {
    true
}

fn execute_storage_node(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
) -> Result<NodeExecution> {
    let operation = match node.node_type.as_str() {
        "storage.read" => {
            execute_storage_read(package, storage, request, node, occurred_at_unix_millis)
        }
        "storage.write" => execute_storage_write(
            package,
            storage,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
        ),
        "storage.promote" => execute_storage_promote(
            package,
            storage,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
        ),
        _ => Err(WorkflowExecutionError::Integrity(
            "storage_node_type".into(),
        )),
    };
    match operation {
        Ok(value) => Ok(success_output("success", value)),
        Err(error) => {
            let code = storage_error_code(&error);
            let value = value_from_json(
                &stable_id("value", &[&request.run_id, &node.id, "storage-error"]),
                &json!({
                    "code": code,
                    "operation": node.node_type,
                    "retryable": matches!(error, WorkflowExecutionError::Storage(WorkflowStorageError::Conflict { .. }))
                }),
            )?;
            Ok(failure_output("error", code, value))
        }
    }
}

fn execute_storage_read(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    occurred_at_unix_millis: i64,
) -> Result<v1::WorkflowValueReference> {
    let config: StorageReadConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("storage_read_config".into()))?;
    let declaration = storage_declaration(package, &config.scope, &config.key)?;
    let (access, namespace) = storage_access(request, &config.scope)?;
    storage.ensure_namespace_capacity(
        namespace.clone(),
        storage_quota(package, &config.scope)?,
        occurred_at_unix_millis,
    )?;
    match config.operation.as_str() {
        "read" => {
            let receipt = storage.read_current(WorkflowStorageReadRequest {
                command_id: stable_id("storage-command", &[&request.run_id, &node.id, "read"]),
                access,
                namespace,
                logical_key: declaration.key.clone(),
                read_at_unix_millis: occurred_at_unix_millis,
            });
            match receipt {
                Ok(receipt) => Ok(storage_handle_value(
                    &stable_id("value", &[&request.run_id, &node.id, "read"]),
                    &receipt.handle,
                    "read",
                )),
                Err(WorkflowStorageError::NotFound(_)) if !config.required => {
                    storage_summary_value(
                        &stable_id("value", &[&request.run_id, &node.id, "missing"]),
                        &config.scope,
                        &config.key,
                        "missing",
                        &Value::Null,
                    )
                }
                Err(error) => Err(error.into()),
            }
        }
        "list" => {
            let receipt = storage.list_current_idempotent(WorkflowStorageListRequest {
                command_id: stable_id("storage-command", &[&request.run_id, &node.id, "list"]),
                access,
                namespace,
                prefix: Some(declaration.key.clone()),
                limit: config.limit,
                read_at_unix_millis: occurred_at_unix_millis,
            })?;
            let total_count = receipt.handles.len();
            let mut listed = receipt
                .handles
                .iter()
                .map(handle_summary)
                .collect::<Vec<_>>();
            while serde_json::to_vec(&json!({
                "items": &listed,
                "count": listed.len(),
                "totalCount": total_count,
                "truncated": listed.len() < total_count
            }))
            .is_ok_and(|bytes| bytes.len() > MAXIMUM_INLINE_STORAGE_SUMMARY_BYTES)
            {
                listed.pop();
            }
            storage_summary_value(
                &stable_id("value", &[&request.run_id, &node.id, "list"]),
                &config.scope,
                &config.key,
                "listed",
                &json!({
                    "items": &listed,
                    "count": listed.len(),
                    "totalCount": total_count,
                    "truncated": listed.len() < total_count
                }),
            )
        }
        _ => Err(WorkflowExecutionError::Integrity(
            "storage_read_operation".into(),
        )),
    }
}

#[allow(clippy::too_many_arguments)]
fn execute_storage_write(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
) -> Result<v1::WorkflowValueReference> {
    let config: StorageWriteConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("storage_write_config".into()))?;
    let declaration = storage_declaration(package, &config.scope, &config.key)?;
    if declaration
        .conflict_policy
        .as_deref()
        .is_some_and(|policy| policy != config.conflict_policy)
    {
        return Err(WorkflowExecutionError::Integrity(
            "storage_conflict_policy".into(),
        ));
    }
    let (access, namespace) = storage_access(request, &config.scope)?;
    storage.ensure_namespace_capacity(
        namespace.clone(),
        storage_quota(package, &config.scope)?,
        occurred_at_unix_millis,
    )?;
    if config.operation == "delete-reference" {
        let receipt = storage.delete_reference(WorkflowStorageDeleteRequest {
            command_id: stable_id("storage-command", &[&request.run_id, &node.id, "delete"]),
            access,
            namespace,
            logical_key: declaration.key.clone(),
            expected_revision: config.expected_revision.ok_or_else(|| {
                WorkflowExecutionError::Integrity("storage_delete_revision".into())
            })?,
            deleted_by_attempt_id: attempt_id.into(),
            deleted_at_unix_millis: occurred_at_unix_millis,
        })?;
        return Ok(storage_handle_value(
            &stable_id("value", &[&request.run_id, &node.id, "deleted"]),
            &receipt.handle,
            "deleted",
        ));
    }
    if config.operation != "write" {
        return Err(WorkflowExecutionError::Integrity(
            "storage_write_operation".into(),
        ));
    }
    let expected_revision = match config.conflict_policy.as_str() {
        "fail" => 0,
        "compare-and-swap" => config
            .expected_revision
            .ok_or_else(|| WorkflowExecutionError::Integrity("storage_expected_revision".into()))?,
        "replace" => storage
            .list_current(&access, &namespace, Some(&declaration.key), 1)?
            .into_iter()
            .find(|handle| handle.logical_key == declaration.key)
            .map_or(0, |handle| handle.revision),
        _ => {
            return Err(WorkflowExecutionError::Integrity(
                "storage_conflict_policy".into(),
            ));
        }
    };
    let selector = config
        .value
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("storage_value_selector".into()))?;
    let value = storage_input_value(storage, &access, &config.scope, selector, input)?;
    let version_id = stable_id("storage-version", &[&request.run_id, &node.id, "1"]);
    let receipt = storage.write_value(WorkflowStorageWriteRequest {
        command_id: stable_id("storage-command", &[&request.run_id, &node.id, "write"]),
        access,
        namespace: namespace.clone(),
        entry_id: stable_id(
            "storage-entry",
            &[&namespace.owner_id, &config.scope, &declaration.key],
        ),
        version_id: version_id.clone(),
        reference_id: matches!(value, WorkflowStorageValueInput::Object { .. })
            .then(|| stable_id("storage-reference", &[&version_id, "value"])),
        logical_key: declaration.key.clone(),
        expected_revision,
        schema_ref: Some(declaration.schema_ref.clone()),
        media_type: if declaration.kind == "value" {
            "application/json".into()
        } else {
            input.content_type.clone()
        },
        classification: declaration.classification.clone(),
        purpose: if declaration.kind == "value" {
            "value".into()
        } else {
            "file".into()
        },
        value,
        created_by_attempt_id: attempt_id.into(),
        created_at_unix_millis: occurred_at_unix_millis,
    })?;
    Ok(storage_handle_value(
        &stable_id("value", &[&request.run_id, &node.id, "written"]),
        &receipt.handle,
        "written",
    ))
}

#[allow(clippy::too_many_arguments)]
fn execute_storage_promote(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
) -> Result<v1::WorkflowValueReference> {
    let config: StoragePromoteConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("storage_promote_config".into()))?;
    let source_declaration = storage_declaration(package, &config.from, &config.source_key)?;
    let destination_declaration =
        storage_declaration(package, &config.to, &config.destination_key)?;
    if source_declaration.kind != destination_declaration.kind
        || source_declaration.schema_ref != destination_declaration.schema_ref
        || destination_declaration
            .conflict_policy
            .as_deref()
            .is_some_and(|policy| policy != config.conflict_policy)
    {
        return Err(WorkflowExecutionError::Integrity(
            "storage_promotion_contract".into(),
        ));
    }
    if input.storage_reference_id.is_empty() {
        return Err(WorkflowExecutionError::Integrity(
            "storage_promotion_input".into(),
        ));
    }
    let (access, source_namespace) = storage_access(request, &config.from)?;
    let (_, destination_namespace) = storage_access(request, &config.to)?;
    storage.ensure_namespace_capacity(
        source_namespace.clone(),
        storage_quota(package, &config.from)?,
        occurred_at_unix_millis,
    )?;
    storage.ensure_namespace_capacity(
        destination_namespace.clone(),
        storage_quota(package, &config.to)?,
        occurred_at_unix_millis,
    )?;
    let source_handle = storage.inspect_handle(&access, &input.storage_reference_id)?;
    if storage_scope_name(source_handle.scope_kind) != config.from
        || source_handle.logical_key != source_declaration.key
    {
        return Err(WorkflowExecutionError::Integrity(
            "storage_promotion_source".into(),
        ));
    }
    let expected_revision = match config.conflict_policy.as_str() {
        "fail" => 0,
        "compare-and-swap" => config
            .expected_revision
            .ok_or_else(|| WorkflowExecutionError::Integrity("storage_expected_revision".into()))?,
        "replace" => storage
            .list_current(
                &access,
                &destination_namespace,
                Some(&destination_declaration.key),
                1,
            )?
            .into_iter()
            .find(|handle| handle.logical_key == destination_declaration.key)
            .map_or(0, |handle| handle.revision),
        _ => {
            return Err(WorkflowExecutionError::Integrity(
                "storage_conflict_policy".into(),
            ));
        }
    };
    let version_id = stable_id("storage-version", &[&request.run_id, &node.id, "promoted"]);
    let receipt = storage.promote_value(WorkflowStoragePromoteRequest {
        command_id: stable_id("storage-command", &[&request.run_id, &node.id, "promote"]),
        access,
        source_namespace,
        destination_namespace: destination_namespace.clone(),
        source_handle_id: source_handle.handle_id,
        destination_entry_id: stable_id(
            "storage-entry",
            &[
                &destination_namespace.owner_id,
                &config.to,
                &destination_declaration.key,
            ],
        ),
        destination_version_id: version_id.clone(),
        destination_reference_id: (source_handle.value_kind == "object")
            .then(|| stable_id("storage-reference", &[&version_id, "promotion"])),
        destination_logical_key: destination_declaration.key.clone(),
        expected_revision,
        schema_ref: Some(destination_declaration.schema_ref.clone()),
        media_type: source_handle.media_type,
        classification: destination_declaration.classification.clone(),
        purpose: if destination_declaration.kind == "value" {
            "value".into()
        } else {
            "file".into()
        },
        promoted_by_attempt_id: attempt_id.into(),
        promoted_at_unix_millis: occurred_at_unix_millis,
    })?;
    Ok(storage_handle_value(
        &stable_id("value", &[&request.run_id, &node.id, "promoted"]),
        &receipt.handle,
        "promoted",
    ))
}

fn storage_declaration<'a>(
    package: &'a ExecutionPackage,
    scope: &str,
    key: &str,
) -> Result<&'a CompiledStorageDeclaration> {
    package
        .compiled
        .storage
        .get(key)
        .filter(|declaration| declaration.scope == scope && declaration.key == key)
        .ok_or_else(|| WorkflowExecutionError::Integrity("storage_declaration".into()))
}

fn storage_quota(package: &ExecutionPackage, scope: &str) -> Result<WorkflowStorageNamespaceQuota> {
    let declarations = package
        .compiled
        .storage
        .values()
        .filter(|declaration| declaration.scope == scope)
        .collect::<Vec<_>>();
    let maximum_item_count = declarations.len() as u64;
    let maximum_total_bytes = declarations.iter().try_fold(0_u64, |total, declaration| {
        total.checked_add(declaration.maximum_bytes)
    });
    let maximum_value_bytes = declarations
        .iter()
        .map(|declaration| declaration.maximum_bytes)
        .max()
        .unwrap_or_default();
    Ok(WorkflowStorageNamespaceQuota {
        maximum_item_count,
        maximum_total_bytes: maximum_total_bytes
            .ok_or_else(|| WorkflowExecutionError::Integrity("storage_quota_overflow".into()))?,
        maximum_value_bytes,
    })
}

fn storage_access(
    request: &v1::RequestWorkflowRun,
    scope: &str,
) -> Result<(WorkflowStorageAccessContext, WorkflowStorageNamespace)> {
    let access = WorkflowStorageAccessContext {
        run_id: Some(request.run_id.clone()),
        case_id: (!request.case_id.is_empty()).then(|| request.case_id.clone()),
        installation_id: request.installation_id.clone(),
        account_binding_ids: BTreeSet::new(),
    };
    let namespace = match scope {
        "job" => WorkflowStorageNamespace {
            kind: WorkflowStorageScopeKind::Job,
            owner_id: request.run_id.clone(),
            installation_id: Some(request.installation_id.clone()),
        },
        "case" => WorkflowStorageNamespace {
            kind: WorkflowStorageScopeKind::Case,
            owner_id: request.case_id.clone(),
            installation_id: Some(request.installation_id.clone()),
        },
        "workflow" => WorkflowStorageNamespace {
            kind: WorkflowStorageScopeKind::Installation,
            owner_id: request.installation_id.clone(),
            installation_id: Some(request.installation_id.clone()),
        },
        _ => {
            return Err(WorkflowExecutionError::Integrity("storage_scope".into()));
        }
    };
    Ok((access, namespace))
}

fn storage_input_value(
    storage: &WorkflowScopedStorage,
    access: &WorkflowStorageAccessContext,
    target_scope: &str,
    selector: &StorageValueSelector,
    input: &v1::WorkflowValueReference,
) -> Result<WorkflowStorageValueInput> {
    if selector.root != "input" {
        return Err(WorkflowExecutionError::Unsupported(
            "storage_value_root".into(),
        ));
    }
    if input.storage_reference_id.is_empty() {
        let selected = inline_json(input)?
            .pointer(&selector.pointer)
            .cloned()
            .ok_or_else(|| WorkflowExecutionError::Integrity("storage_value_pointer".into()))?;
        let encoded = serde_json::to_vec(&selected)
            .map_err(|_| WorkflowExecutionError::Encoding("storage_value"))?;
        let canonical = workflow_canonical::canonicalize(&encoded)
            .map_err(|_| WorkflowExecutionError::Encoding("storage_value_canonical"))?;
        return Ok(WorkflowStorageValueInput::InlineCanonicalJson {
            bytes: canonical.canonical_bytes,
        });
    }
    if !selector.pointer.is_empty() {
        return Err(WorkflowExecutionError::Unsupported(
            "stored_value_pointer".into(),
        ));
    }
    let handle = storage.inspect_handle(access, &input.storage_reference_id)?;
    if storage_scope_name(handle.scope_kind) != target_scope {
        return Err(WorkflowExecutionError::Unsupported(
            "storage_promotion_requires_node".into(),
        ));
    }
    if handle.value_kind == "object" {
        Ok(WorkflowStorageValueInput::Object {
            digest: handle.sha256,
            byte_count: handle.byte_count,
        })
    } else {
        let mut bytes = Vec::new();
        storage.copy_value(access, &handle.handle_id, handle.byte_count, &mut bytes)?;
        Ok(WorkflowStorageValueInput::InlineCanonicalJson { bytes })
    }
}

fn storage_handle_value(
    value_id: &str,
    handle: &WorkflowStorageHandle,
    result: &str,
) -> v1::WorkflowValueReference {
    v1::WorkflowValueReference {
        value_id: value_id.into(),
        content_type: handle.media_type.clone(),
        byte_count: handle.byte_count,
        sha256: handle.sha256.clone(),
        inline_canonical_json: Vec::new(),
        storage_reference_id: handle.handle_id.clone(),
        storage: Some(storage_metadata(handle, result)),
    }
}

fn storage_metadata(
    handle: &WorkflowStorageHandle,
    result: &str,
) -> v1::WorkflowStorageValueMetadata {
    v1::WorkflowStorageValueMetadata {
        handle_id: handle.handle_id.clone(),
        scope: storage_scope_name(handle.scope_kind).into(),
        logical_key: handle.logical_key.clone(),
        version_id: handle.version_id.clone(),
        revision: handle.revision,
        previous_version_id: handle.previous_version_id.clone().unwrap_or_default(),
        byte_count: handle.byte_count,
        result: result.into(),
        source_version_id: handle.source_version_id.clone().unwrap_or_default(),
    }
}

fn storage_summary_value(
    value_id: &str,
    scope: &str,
    key: &str,
    result: &str,
    value: &Value,
) -> Result<v1::WorkflowValueReference> {
    let mut reference = value_from_json(value_id, value)?;
    reference.storage = Some(v1::WorkflowStorageValueMetadata {
        handle_id: String::new(),
        scope: scope.into(),
        logical_key: key.into(),
        version_id: String::new(),
        revision: 0,
        previous_version_id: String::new(),
        byte_count: reference.byte_count,
        result: result.into(),
        source_version_id: String::new(),
    });
    Ok(reference)
}

fn handle_summary(handle: &WorkflowStorageHandle) -> Value {
    json!({
        "handleId": handle.handle_id,
        "scope": storage_scope_name(handle.scope_kind),
        "key": handle.logical_key,
        "versionId": handle.version_id,
        "revision": handle.revision,
        "previousVersionId": handle.previous_version_id,
        "bytes": handle.byte_count,
        "sha256": handle.sha256
    })
}

const fn storage_scope_name(scope: WorkflowStorageScopeKind) -> &'static str {
    match scope {
        WorkflowStorageScopeKind::Job => "job",
        WorkflowStorageScopeKind::Case => "case",
        WorkflowStorageScopeKind::Installation => "workflow",
        WorkflowStorageScopeKind::AccountBinding => "account-binding",
    }
}

fn storage_error_code(error: &WorkflowExecutionError) -> &'static str {
    match error {
        WorkflowExecutionError::Storage(WorkflowStorageError::Conflict { .. }) => {
            "storage.conflict"
        }
        WorkflowExecutionError::Storage(WorkflowStorageError::NotFound(_)) => "storage.not-found",
        WorkflowExecutionError::Storage(WorkflowStorageError::QuotaExceeded(_)) => {
            "storage.quota-exceeded"
        }
        WorkflowExecutionError::Storage(WorkflowStorageError::AccessDenied(_)) => {
            "storage.access-denied"
        }
        WorkflowExecutionError::Unsupported(_) => "storage.unsupported",
        WorkflowExecutionError::Integrity(_) => "storage.invalid",
        _ => "storage.failed",
    }
}

fn success_output(port: &str, value: v1::WorkflowValueReference) -> NodeExecution {
    NodeExecution {
        match_trace: None,
        outputs: vec![(port.into(), value)],
        outcome: v1::WorkflowAttemptOutcome::Succeeded,
        error_code: String::new(),
        error: None,
    }
}

fn failure_output(port: &str, code: &str, value: v1::WorkflowValueReference) -> NodeExecution {
    NodeExecution {
        match_trace: None,
        outputs: vec![(port.into(), value.clone())],
        outcome: v1::WorkflowAttemptOutcome::Failed,
        error_code: code.into(),
        error: Some(value),
    }
}

fn active_execution_tokens(state: &RecordedRun) -> Vec<&RecordedExecutionToken> {
    let mut tokens = state
        .execution_tokens
        .values()
        .filter(|token| token.settled.is_none())
        .collect::<Vec<_>>();
    tokens.sort_by_key(|token| token.created_store_position);
    tokens
}

fn pending_execution_token_settlement(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
) -> Result<Option<v1::EventEnvelope>> {
    for token in active_execution_tokens(state) {
        let Some(attempt) = state.attempts.iter().rev().find(|attempt| {
            attempt.started.execution_token_id == token.created.execution_token_id
                && attempt.settled.is_some()
        }) else {
            continue;
        };
        let node = compiled_node(&package.compiled, &attempt.started.node_id)?;
        let (outcome, terminal_node_id, error_code, error, final_emission_ids) =
            match node.node_type.as_str() {
                "control.parallel" => (
                    v1::WorkflowExecutionTokenOutcome::Forked,
                    String::new(),
                    String::new(),
                    None,
                    Vec::new(),
                ),
                "control.for-each" if token.created.resume_reason != "iteration" => (
                    v1::WorkflowExecutionTokenOutcome::Forked,
                    String::new(),
                    String::new(),
                    None,
                    Vec::new(),
                ),
                "terminal.complete" => {
                    let inputs =
                        node_inputs(request, state, &node.id, &token.created.execution_token_id)?;
                    (
                        v1::WorkflowExecutionTokenOutcome::Completed,
                        node.id.clone(),
                        String::new(),
                        None,
                        inputs
                            .iter()
                            .filter_map(|(edge, _)| edge.map(|edge| edge.emission_id.clone()))
                            .collect(),
                    )
                }
                "terminal.fail" => {
                    let settled = attempt.settled.as_ref().unwrap();
                    (
                        v1::WorkflowExecutionTokenOutcome::Failed,
                        node.id.clone(),
                        settled.error_code.clone(),
                        settled.error.clone(),
                        Vec::new(),
                    )
                }
                _ => continue,
            };
        return Ok(Some(execution_token_settled_event(
            command.submitted_at_unix_millis,
            request,
            run_token_id,
            &token.created.execution_token_id,
            outcome,
            terminal_node_id,
            String::new(),
            error_code,
            error,
            final_emission_ids,
            attempt
                .settled_event_id
                .as_deref()
                .ok_or_else(|| WorkflowExecutionError::Lifecycle("attempt_settle_event".into()))?,
        )));
    }
    Ok(None)
}

fn pending_iteration_lifecycle_event(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
) -> Result<Option<v1::EventEnvelope>> {
    for iteration in &state.iterations {
        let node = compiled_node(&package.compiled, &iteration.planned.iteration_node_id)?;
        let controller_attempt = state
            .attempts
            .iter()
            .find(|attempt| attempt.started.attempt_id == iteration.planned.controller_attempt_id)
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("iteration_attempt_missing".into()))?;
        if controller_attempt.settled.is_none() {
            continue;
        }
        if let Some(evaluated) = iteration.evaluated.as_ref() {
            if !state
                .execution_tokens
                .contains_key(&evaluated.resumed_execution_token_id)
            {
                return Ok(Some(runtime_event(
                    command.submitted_at_unix_millis,
                    &stable_id(
                        "event",
                        &[
                            &request.run_id,
                            "execution-token",
                            &evaluated.resumed_execution_token_id,
                            "created",
                        ],
                    ),
                    workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
                    workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
                    v1::WorkflowExecutionTokenCreated {
                        run_id: request.run_id.clone(),
                        run_token_id: run_token_id.to_owned(),
                        execution_token_id: evaluated.resumed_execution_token_id.clone(),
                        parent_execution_token_id: iteration
                            .planned
                            .parent_execution_token_id
                            .clone(),
                        fork_node_id: String::new(),
                        branch_id: String::new(),
                        branch_port_id: String::new(),
                        join_node_id: String::new(),
                        source_emission_id: String::new(),
                        iteration_node_id: String::new(),
                        iteration_index: 0,
                        iteration_count: 0,
                        resume_node_id: iteration.planned.iteration_node_id.clone(),
                        resume_reason: "iteration".into(),
                    },
                    iteration.evaluated_event_id.as_deref().ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("iteration_event".into())
                    })?,
                    &request.run_id,
                )));
            }
            if evaluated.decision == v1::WorkflowIterationDecision::Failed as i32 {
                for token_id in &evaluated.pending_execution_token_ids {
                    if state
                        .execution_tokens
                        .get(token_id)
                        .is_some_and(|token| token.settled.is_none())
                    {
                        return Ok(Some(execution_token_settled_event(
                            command.submitted_at_unix_millis,
                            request,
                            run_token_id,
                            token_id,
                            v1::WorkflowExecutionTokenOutcome::Cancelled,
                            String::new(),
                            String::new(),
                            "iteration.fail-fast-cancelled".into(),
                            None,
                            Vec::new(),
                            iteration.evaluated_event_id.as_deref().unwrap(),
                        )));
                    }
                }
            }
            continue;
        }

        let item_tokens = state
            .execution_tokens
            .values()
            .filter(|token| {
                token.created.iteration_node_id == iteration.planned.iteration_node_id
                    && token.created.parent_execution_token_id
                        == iteration.planned.parent_execution_token_id
            })
            .collect::<Vec<_>>();
        for token in item_tokens.iter().filter(|token| token.settled.is_none()) {
            if let Some(edge) = state.edges.iter().rev().find(|edge| {
                edge.payload.execution_token_id == token.created.execution_token_id
                    && edge.payload.target_node_id == iteration.planned.iteration_node_id
                    && matches!(
                        edge.payload.target_port_id.as_str(),
                        "item-success" | "item-error"
                    )
            }) {
                if edge.payload.target_port_id == "item-success" {
                    return Ok(Some(execution_token_settled_event(
                        command.submitted_at_unix_millis,
                        request,
                        run_token_id,
                        &token.created.execution_token_id,
                        v1::WorkflowExecutionTokenOutcome::Iterated,
                        String::new(),
                        String::new(),
                        String::new(),
                        None,
                        vec![edge.payload.emission_id.clone()],
                        &edge.event_id,
                    )));
                }
                let emission = state
                    .emissions
                    .get(&edge.payload.emission_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("iteration_error_emission".into())
                    })?;
                let error = emission.payload.value.clone().ok_or_else(|| {
                    WorkflowExecutionError::Lifecycle("iteration_error_value".into())
                })?;
                return Ok(Some(execution_token_settled_event(
                    command.submitted_at_unix_millis,
                    request,
                    run_token_id,
                    &token.created.execution_token_id,
                    v1::WorkflowExecutionTokenOutcome::Failed,
                    iteration.planned.iteration_node_id.clone(),
                    String::new(),
                    error_code(&error)?,
                    Some(error),
                    Vec::new(),
                    &edge.event_id,
                )));
            }
        }

        let expected = (0..iteration.planned.item_count as usize)
            .map(|index| iteration_token_id(request, node, index))
            .collect::<Vec<_>>();
        let succeeded = expected
            .iter()
            .filter(|token_id| {
                state.execution_tokens.get(*token_id).is_some_and(|token| {
                    token.settled.as_ref().is_some_and(|settled| {
                        settled.outcome == v1::WorkflowExecutionTokenOutcome::Iterated as i32
                    })
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        let failed = expected
            .iter()
            .filter(|token_id| {
                state.execution_tokens.get(*token_id).is_some_and(|token| {
                    token.settled.as_ref().is_some_and(|settled| {
                        settled.outcome == v1::WorkflowExecutionTokenOutcome::Failed as i32
                    })
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        let pending = expected
            .iter()
            .filter(|token_id| !succeeded.contains(token_id) && !failed.contains(token_id))
            .cloned()
            .collect::<Vec<_>>();
        let fail_fast = iteration.planned.failure_policy == "fail-fast";
        let decision = if fail_fast && !failed.is_empty() {
            Some(v1::WorkflowIterationDecision::Failed)
        } else if pending.is_empty() {
            Some(v1::WorkflowIterationDecision::Succeeded)
        } else {
            None
        };
        if let Some(decision) = decision {
            let error_code = if decision == v1::WorkflowIterationDecision::Failed {
                "iteration.item-failed"
            } else {
                ""
            };
            let output = value_from_json(
                &stable_id(
                    "value",
                    &[
                        &request.run_id,
                        &iteration.planned.iteration_node_id,
                        "iteration-result",
                    ],
                ),
                &json!({
                    "code": error_code,
                    "itemCount": iteration.planned.item_count,
                    "succeededCount": succeeded.len(),
                    "failedCount": failed.len(),
                    "pendingCount": pending.len(),
                    "failurePolicy": iteration.planned.failure_policy,
                    "decision": if decision == v1::WorkflowIterationDecision::Succeeded { "succeeded" } else { "failed" }
                }),
            )?;
            let resumed_execution_token_id = stable_id(
                "execution-token",
                &[
                    &request.run_id,
                    &iteration.planned.iteration_node_id,
                    &iteration.planned.parent_execution_token_id,
                    "resumed",
                ],
            );
            let causation_id = item_tokens
                .iter()
                .filter_map(|token| token.settled_event_id.as_deref())
                .next_back()
                .unwrap_or(iteration.planned_event_id.as_str());
            return Ok(Some(runtime_event(
                command.submitted_at_unix_millis,
                &stable_id(
                    "event",
                    &[
                        &request.run_id,
                        "iteration-evaluated",
                        &iteration.planned.iteration_node_id,
                        &iteration.planned.parent_execution_token_id,
                    ],
                ),
                workflow_runtime::WORKFLOW_ITERATION_EVALUATED_KIND,
                workflow_runtime::WORKFLOW_ITERATION_EVALUATED_TYPE,
                v1::WorkflowIterationEvaluated {
                    run_id: request.run_id.clone(),
                    run_token_id: run_token_id.to_owned(),
                    iteration_node_id: iteration.planned.iteration_node_id.clone(),
                    parent_execution_token_id: iteration.planned.parent_execution_token_id.clone(),
                    resumed_execution_token_id,
                    failure_policy: iteration.planned.failure_policy.clone(),
                    decision: decision as i32,
                    expected_execution_token_ids: expected,
                    succeeded_execution_token_ids: succeeded,
                    failed_execution_token_ids: failed,
                    pending_execution_token_ids: pending,
                    error_code: error_code.into(),
                    output: Some(output),
                },
                causation_id,
                &request.run_id,
            )));
        }

        let edge = single_outgoing_edge(&package.compiled, node, "item")?;
        for index in 0..iteration.planned.item_count as usize {
            if state
                .execution_tokens
                .contains_key(&iteration_token_id(request, node, index))
            {
                let candidates = iteration_item_admission_events(
                    command,
                    request,
                    run_token_id,
                    node,
                    controller_attempt,
                    edge,
                    index,
                    iteration.planned.item_count as usize,
                );
                if let Some(candidate) = candidates
                    .into_iter()
                    .find(|candidate| !event_recorded(state, &candidate.event_id))
                {
                    return Ok(Some(candidate));
                }
            }
        }
        let active_count = item_tokens
            .iter()
            .filter(|token| token.settled.is_none())
            .count();
        if active_count < iteration.planned.maximum_concurrency as usize
            && let Some(index) = (0..iteration.planned.item_count as usize).find(|index| {
                !state
                    .execution_tokens
                    .contains_key(&iteration_token_id(request, node, *index))
            })
        {
            let candidates = iteration_item_admission_events(
                command,
                request,
                run_token_id,
                node,
                controller_attempt,
                edge,
                index,
                iteration.planned.item_count as usize,
            );
            if let Some(candidate) = candidates
                .into_iter()
                .find(|candidate| !event_recorded(state, &candidate.event_id))
            {
                return Ok(Some(candidate));
            }
        }
    }
    Ok(None)
}

fn execute_iteration_resume_node(
    node: &CompiledNode,
    state: &RecordedRun,
    execution_token_id: &str,
) -> Result<NodeExecution> {
    let evaluated = state
        .iterations
        .iter()
        .filter_map(|iteration| iteration.evaluated.as_ref())
        .find(|evaluated| evaluated.resumed_execution_token_id == execution_token_id)
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("iteration_resume_missing".into()))?;
    if evaluated.iteration_node_id != node.id {
        return Err(WorkflowExecutionError::Integrity(
            "iteration_resume_node".into(),
        ));
    }
    let output = evaluated
        .output
        .clone()
        .ok_or_else(|| WorkflowExecutionError::Integrity("iteration_output".into()))?;
    match v1::WorkflowIterationDecision::try_from(evaluated.decision) {
        Ok(v1::WorkflowIterationDecision::Succeeded) => Ok(success_output("success", output)),
        Ok(v1::WorkflowIterationDecision::Failed) => {
            Ok(failure_output("error", &evaluated.error_code, output))
        }
        _ => Err(WorkflowExecutionError::Integrity(
            "iteration_decision".into(),
        )),
    }
}

fn event_recorded(state: &RecordedRun, event_id: &str) -> bool {
    state.events.iter().any(|event| event.event_id == event_id)
}

fn pending_join_lifecycle_event(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
) -> Result<Option<v1::EventEnvelope>> {
    let active = active_execution_tokens(state)
        .into_iter()
        .map(|token| (token.created.execution_token_id.as_str(), token))
        .collect::<BTreeMap<_, _>>();
    for join in &state.joins {
        if !state
            .execution_tokens
            .contains_key(&join.payload.resumed_execution_token_id)
        {
            let parent = join
                .payload
                .expected_execution_token_ids
                .iter()
                .find_map(|token_id| state.execution_tokens.get(token_id))
                .map(|token| token.created.parent_execution_token_id.clone())
                .ok_or_else(|| WorkflowExecutionError::Lifecycle("join_parent_missing".into()))?;
            return Ok(Some(runtime_event(
                command.submitted_at_unix_millis,
                &stable_id(
                    "event",
                    &[
                        &request.run_id,
                        "execution-token",
                        &join.payload.resumed_execution_token_id,
                        "created",
                    ],
                ),
                workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
                workflow_runtime::WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
                v1::WorkflowExecutionTokenCreated {
                    run_id: request.run_id.clone(),
                    run_token_id: run_token_id.to_owned(),
                    execution_token_id: join.payload.resumed_execution_token_id.clone(),
                    parent_execution_token_id: parent,
                    fork_node_id: String::new(),
                    branch_id: String::new(),
                    branch_port_id: String::new(),
                    join_node_id: join.payload.join_node_id.clone(),
                    source_emission_id: String::new(),
                    iteration_node_id: String::new(),
                    iteration_index: 0,
                    iteration_count: 0,
                    resume_node_id: join.payload.join_node_id.clone(),
                    resume_reason: "join".into(),
                },
                &join.event_id,
                &request.run_id,
            )));
        }
        for token_id in &join.payload.arrived_execution_token_ids {
            if active.contains_key(token_id.as_str()) {
                return Ok(Some(execution_token_settled_event(
                    command.submitted_at_unix_millis,
                    request,
                    run_token_id,
                    token_id,
                    v1::WorkflowExecutionTokenOutcome::Joined,
                    String::new(),
                    join.payload.join_node_id.clone(),
                    String::new(),
                    None,
                    Vec::new(),
                    &join.event_id,
                )));
            }
        }
        if join.payload.cancel_remaining
            || join.payload.decision == v1::WorkflowJoinDecision::Failed as i32
        {
            for token_id in &join.payload.pending_execution_token_ids {
                if active.contains_key(token_id.as_str()) {
                    return Ok(Some(execution_token_settled_event(
                        command.submitted_at_unix_millis,
                        request,
                        run_token_id,
                        token_id,
                        v1::WorkflowExecutionTokenOutcome::Cancelled,
                        String::new(),
                        String::new(),
                        "join.remaining-cancelled".into(),
                        None,
                        Vec::new(),
                        &join.event_id,
                    )));
                }
            }
        } else {
            for token_id in &join.payload.pending_execution_token_ids {
                if active.contains_key(token_id.as_str())
                    && state.edges.iter().any(|edge| {
                        edge.payload.execution_token_id == *token_id
                            && edge.payload.target_node_id == join.payload.join_node_id
                            && edge.payload.state
                                == v1::WorkflowEdgeCheckpointState::Admitted as i32
                    })
                {
                    return Ok(Some(execution_token_settled_event(
                        command.submitted_at_unix_millis,
                        request,
                        run_token_id,
                        token_id,
                        v1::WorkflowExecutionTokenOutcome::Joined,
                        String::new(),
                        join.payload.join_node_id.clone(),
                        String::new(),
                        None,
                        Vec::new(),
                        &join.event_id,
                    )));
                }
            }
        }
    }

    let mut fork_groups = BTreeMap::<(String, String), Vec<&RecordedExecutionToken>>::new();
    for token in state.execution_tokens.values().filter(|token| {
        !token.created.fork_node_id.is_empty() && !token.created.join_node_id.is_empty()
    }) {
        fork_groups
            .entry((
                token.created.fork_node_id.clone(),
                token.created.join_node_id.clone(),
            ))
            .or_default()
            .push(token);
    }
    for ((fork_node_id, join_node_id), mut tokens) in fork_groups {
        if state
            .joins
            .iter()
            .any(|join| join.payload.fork_node_id == fork_node_id)
        {
            continue;
        }
        tokens.sort_by_key(|token| token.created_store_position);
        let expected = tokens
            .iter()
            .map(|token| token.created.execution_token_id.clone())
            .collect::<Vec<_>>();
        let arrived = tokens
            .iter()
            .filter(|token| {
                state.edges.iter().any(|edge| {
                    edge.payload.execution_token_id == token.created.execution_token_id
                        && edge.payload.target_node_id == join_node_id
                        && edge.payload.state == v1::WorkflowEdgeCheckpointState::Admitted as i32
                })
            })
            .map(|token| token.created.execution_token_id.clone())
            .collect::<Vec<_>>();
        let arrived_set = arrived.iter().map(String::as_str).collect::<BTreeSet<_>>();
        let failed = tokens
            .iter()
            .filter(|token| {
                token.settled.is_some()
                    && !arrived_set.contains(token.created.execution_token_id.as_str())
            })
            .map(|token| token.created.execution_token_id.clone())
            .collect::<Vec<_>>();
        let pending = tokens
            .iter()
            .filter(|token| {
                !arrived_set.contains(token.created.execution_token_id.as_str())
                    && token.settled.is_none()
            })
            .map(|token| token.created.execution_token_id.clone())
            .collect::<Vec<_>>();
        let node = compiled_node(&package.compiled, &join_node_id)?;
        let config: JoinConfig = serde_json::from_value(node.config.clone())
            .map_err(|_| WorkflowExecutionError::Integrity("join_config".into()))?;
        let threshold = match config.policy.as_str() {
            "all" => expected.len() as u32,
            "any" => 1,
            "quorum" => config
                .quorum
                .ok_or_else(|| WorkflowExecutionError::Integrity("join_quorum".into()))?,
            _ => {
                return Err(WorkflowExecutionError::Unsupported(
                    "join_policy_not_executable".into(),
                ));
            }
        };
        let threshold_usize = threshold as usize;
        let decision = if arrived.len() >= threshold_usize {
            Some(v1::WorkflowJoinDecision::Succeeded)
        } else if arrived.len() + pending.len() < threshold_usize {
            Some(v1::WorkflowJoinDecision::Failed)
        } else {
            None
        };
        let Some(decision) = decision else {
            continue;
        };
        let error_code = if decision == v1::WorkflowJoinDecision::Failed {
            format!("join.{}-unreachable", config.policy)
        } else {
            String::new()
        };
        let resumed_execution_token_id = stable_id(
            "execution-token",
            &[&request.run_id, &fork_node_id, &join_node_id, "resumed"],
        );
        let event_id = stable_id(
            "event",
            &[&request.run_id, "join", &fork_node_id, &join_node_id],
        );
        let causation_id = arrived
            .last()
            .and_then(|token_id| {
                state.edges.iter().rev().find(|edge| {
                    edge.payload.execution_token_id == *token_id
                        && edge.payload.target_node_id == join_node_id
                })
            })
            .map(|edge| edge.event_id.as_str())
            .or_else(|| {
                failed.last().and_then(|token_id| {
                    state
                        .execution_tokens
                        .get(token_id)
                        .and_then(|token| token.settled_event_id.as_deref())
                })
            })
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("join_causation_missing".into()))?;
        return Ok(Some(runtime_event(
            command.submitted_at_unix_millis,
            &event_id,
            workflow_runtime::WORKFLOW_JOIN_EVALUATED_KIND,
            workflow_runtime::WORKFLOW_JOIN_EVALUATED_TYPE,
            v1::WorkflowJoinEvaluated {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                join_node_id,
                fork_node_id,
                resumed_execution_token_id,
                policy: config.policy,
                threshold,
                decision: decision as i32,
                expected_execution_token_ids: expected,
                arrived_execution_token_ids: arrived,
                failed_execution_token_ids: failed,
                pending_execution_token_ids: pending,
                cancel_remaining: config.cancel_remaining,
                error_code,
            },
            causation_id,
            &request.run_id,
        )));
    }
    Ok(None)
}

fn completed_run_outcome(state: &RecordedRun) -> Result<CompletedRunOutcome> {
    let joined_forks = state
        .joins
        .iter()
        .map(|join| join.payload.fork_node_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut terminal = state
        .execution_tokens
        .values()
        .filter(|token| {
            !joined_forks.contains(token.created.fork_node_id.as_str())
                && token.created.iteration_node_id.is_empty()
                && token.settled.as_ref().is_some_and(|settled| {
                    matches!(
                        v1::WorkflowExecutionTokenOutcome::try_from(settled.outcome),
                        Ok(v1::WorkflowExecutionTokenOutcome::Completed)
                            | Ok(v1::WorkflowExecutionTokenOutcome::Failed)
                    )
                })
        })
        .collect::<Vec<_>>();
    terminal.sort_by_key(|token| token.created_store_position);
    let selected = terminal
        .iter()
        .rev()
        .find(|token| {
            token.settled.as_ref().is_some_and(|settled| {
                settled.outcome == v1::WorkflowExecutionTokenOutcome::Failed as i32
            })
        })
        .copied()
        .or_else(|| terminal.last().copied())
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("terminal_token_missing".into()))?;
    let settled = selected.settled.as_ref().unwrap();
    let event_id = selected
        .settled_event_id
        .clone()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("token_settle_event_missing".into()))?;
    if settled.outcome == v1::WorkflowExecutionTokenOutcome::Failed as i32 {
        Ok(CompletedRunOutcome {
            outcome: v1::WorkflowRunOutcome::Failed,
            error_code: settled.error_code.clone(),
            error: settled.error.clone(),
            final_emission_ids: Vec::new(),
            causation_id: event_id,
        })
    } else {
        let final_emission_ids = terminal
            .iter()
            .flat_map(|token| token.settled.as_ref().unwrap().final_emission_ids.clone())
            .collect();
        Ok(CompletedRunOutcome {
            outcome: v1::WorkflowRunOutcome::Succeeded,
            error_code: String::new(),
            error: None,
            final_emission_ids,
            causation_id: event_id,
        })
    }
}

fn next_ready_node(
    compiled: &CompiledWorkflow,
    state: &RecordedRun,
) -> Result<(String, String, String)> {
    let mut ready = Vec::<(u8, u64, String, String, String)>::new();
    for token in active_execution_tokens(state) {
        let token_id = token.created.execution_token_id.as_str();
        if !token.created.resume_node_id.is_empty()
            && !state.attempts.iter().any(|attempt| {
                attempt.started.execution_token_id == token_id
                    && attempt.started.node_id == token.created.resume_node_id
            })
        {
            let causation = if token.created.resume_reason == "join" {
                state
                    .joins
                    .iter()
                    .find(|join| join.payload.resumed_execution_token_id == token_id)
                    .map(|join| (join.store_position, join.event_id.clone()))
            } else {
                state.iterations.iter().find_map(|iteration| {
                    iteration.evaluated.as_ref().and_then(|evaluated| {
                        (evaluated.resumed_execution_token_id == token_id).then(|| {
                            (
                                iteration.evaluated_store_position.unwrap_or_default(),
                                iteration.evaluated_event_id.clone().unwrap_or_default(),
                            )
                        })
                    })
                })
            }
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("resume_source_missing".into()))?;
            ready.push((
                0,
                causation.0,
                token.created.resume_node_id.clone(),
                causation.1,
                token_id.to_owned(),
            ));
            continue;
        }
        if !token.created.join_node_id.is_empty()
            && token.created.fork_node_id.is_empty()
            && token.created.resume_node_id.is_empty()
            && !state.attempts.iter().any(|attempt| {
                attempt.started.execution_token_id == token_id
                    && attempt.started.node_id == token.created.join_node_id
            })
        {
            let join = state
                .joins
                .iter()
                .find(|join| join.payload.resumed_execution_token_id == token_id)
                .ok_or_else(|| WorkflowExecutionError::Lifecycle("join_resume_missing".into()))?;
            ready.push((
                0,
                join.store_position,
                token.created.join_node_id.clone(),
                join.event_id.clone(),
                token_id.to_owned(),
            ));
            continue;
        }
        if token.created.parent_execution_token_id.is_empty()
            && !state.attempts.iter().any(|attempt| {
                attempt.started.execution_token_id == token_id
                    && attempt.started.node_id == compiled.entrypoints[0].node_id
            })
        {
            ready.push((
                1,
                token.created_store_position,
                compiled.entrypoints[0].node_id.clone(),
                token.created_event_id.clone(),
                token_id.to_owned(),
            ));
        }
        for edge in state.edges.iter().filter(|edge| {
            edge.payload.execution_token_id == token_id
                && edge.payload.state == v1::WorkflowEdgeCheckpointState::Admitted as i32
                && !state.attempts.iter().any(|attempt| {
                    attempt.started.execution_token_id == token_id
                        && attempt.started.node_id == edge.payload.target_node_id
                        && attempt.started_store_position > edge.store_position
                })
        }) {
            if compiled_node(compiled, &edge.payload.target_node_id)?.node_type == "control.join" {
                continue;
            }
            if compiled_node(compiled, &edge.payload.target_node_id)?.node_type
                == "control.for-each"
                && matches!(
                    edge.payload.target_port_id.as_str(),
                    "item-success" | "item-error"
                )
            {
                continue;
            }
            ready.push((
                1,
                edge.store_position,
                edge.payload.target_node_id.clone(),
                edge.event_id.clone(),
                token_id.to_owned(),
            ));
        }
    }
    ready.sort();
    ready
        .into_iter()
        .next()
        .map(|(_, _, node_id, causation_id, token_id)| (node_id, causation_id, token_id))
        .ok_or_else(|| {
            WorkflowExecutionError::Lifecycle(format!(
                "no_ready_execution_token:{}",
                active_execution_tokens(state)
                    .iter()
                    .map(|token| {
                        format!(
                            "{}[fork={},join={},attempts={}]",
                            token.created.execution_token_id,
                            token.created.fork_node_id,
                            token.created.join_node_id,
                            state
                                .attempts
                                .iter()
                                .filter(|attempt| attempt.started.execution_token_id
                                    == token.created.execution_token_id)
                                .map(|attempt| attempt.started.node_id.as_str())
                                .collect::<Vec<_>>()
                                .join("+")
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            ))
        })
}

fn node_inputs<'a>(
    request: &'a v1::RequestWorkflowRun,
    state: &'a RecordedRun,
    node_id: &str,
    execution_token_id: &str,
) -> Result<
    Vec<(
        Option<&'a v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )>,
> {
    if state
        .execution_tokens
        .get(execution_token_id)
        .is_some_and(|token| {
            token.created.resume_reason == "iteration" && token.created.resume_node_id == node_id
        })
    {
        let output = state
            .iterations
            .iter()
            .filter_map(|iteration| iteration.evaluated.as_ref())
            .find(|evaluated| evaluated.resumed_execution_token_id == execution_token_id)
            .and_then(|evaluated| evaluated.output.clone())
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("iteration_resume_input".into()))?;
        return Ok(vec![(None, output)]);
    }
    if state
        .execution_tokens
        .get(execution_token_id)
        .is_some_and(|token| token.created.parent_execution_token_id.is_empty())
        && state.edges.iter().all(|edge| {
            edge.payload.execution_token_id != execution_token_id
                || edge.payload.target_node_id != node_id
        })
    {
        return Ok(vec![(
            None,
            request.inputs[0]
                .value
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("manual_input_missing".into()))?,
        )]);
    }
    let join_tokens = state
        .joins
        .iter()
        .find(|join| {
            join.payload.resumed_execution_token_id == execution_token_id
                && join.payload.join_node_id == node_id
        })
        .map(|join| {
            join.payload
                .arrived_execution_token_ids
                .iter()
                .map(String::as_str)
                .collect::<BTreeSet<_>>()
        });
    let mut incoming = state
        .edges
        .iter()
        .filter(|edge| {
            edge.payload.target_node_id == node_id
                && edge.payload.state == v1::WorkflowEdgeCheckpointState::Admitted as i32
                && match &join_tokens {
                    Some(tokens) => tokens.contains(edge.payload.execution_token_id.as_str()),
                    None => edge.payload.execution_token_id == execution_token_id,
                }
        })
        .collect::<Vec<_>>();
    incoming.sort_by_key(|edge| edge.store_position);
    if join_tokens.is_none() && incoming.len() > 1 {
        incoming = incoming.into_iter().rev().take(1).collect();
    }
    if incoming.is_empty() {
        return Err(WorkflowExecutionError::Lifecycle(format!(
            "node_input_cardinality:{node_id}:{}",
            incoming.len()
        )));
    }
    incoming
        .into_iter()
        .map(|edge| {
            let emission = state
                .emissions
                .get(&edge.payload.emission_id)
                .ok_or_else(|| {
                    WorkflowExecutionError::Lifecycle("input_emission_missing".into())
                })?;
            Ok((
                Some(&edge.payload),
                emission.payload.value.clone().ok_or_else(|| {
                    WorkflowExecutionError::Lifecycle("input_value_missing".into())
                })?,
            ))
        })
        .collect()
}

fn recorded_run(journal: &Journal, run_id: &str) -> Result<RecordedRun> {
    let selector = format!("thread:workflow-run:{run_id}");
    let mut cursor = None;
    let mut envelopes = Vec::new();
    loop {
        let page = journal.replay(&selector, cursor.as_ref(), RUN_REPLAY_PAGE)?;
        if page.basis != ReplayBasis::Events {
            return Err(WorkflowExecutionError::Integrity(
                "run_replay_retention_gap".into(),
            ));
        }
        envelopes.extend(page.events);
        if !page.has_more {
            break;
        }
        cursor = Some(page.next_cursor);
    }
    let mut state = RecordedRun {
        events: envelopes.clone(),
        ..RecordedRun::default()
    };
    for envelope in envelopes {
        let event = workflow_runtime::decode_workflow_event(&envelope)
            .map_err(|_| WorkflowExecutionError::Integrity("recorded_event_contract".into()))?;
        if event.run_id() != run_id {
            return Err(WorkflowExecutionError::Integrity(
                "recorded_run_identity".into(),
            ));
        }
        match event {
            WorkflowRuntimeEvent::CaseEpisodeStarted(payload) => {
                if state.episode.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_case_episode".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::RunTokenCreated(payload) => {
                if state.token.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_run_token".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::ExecutionTokenCreated(payload) => {
                if state
                    .execution_tokens
                    .insert(
                        payload.execution_token_id.clone(),
                        RecordedExecutionToken {
                            created_event_id: envelope.event_id,
                            created_store_position: envelope.store_position,
                            created: payload,
                            settled_event_id: None,
                            settled: None,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_execution_token".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::ExecutionTokenSettled(payload) => {
                let token = state
                    .execution_tokens
                    .get_mut(&payload.execution_token_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("settled_execution_token_missing".into())
                    })?;
                if token.settled.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "execution_token_settled_twice".into(),
                    ));
                }
                token.settled_event_id = Some(envelope.event_id);
            }
            WorkflowRuntimeEvent::JoinEvaluated(payload) => {
                if state.joins.iter().any(|join| {
                    join.payload.join_node_id == payload.join_node_id
                        && join.payload.fork_node_id == payload.fork_node_id
                }) {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "join_evaluated_twice".into(),
                    ));
                }
                state.joins.push(RecordedJoin {
                    event_id: envelope.event_id,
                    store_position: envelope.store_position,
                    payload,
                });
            }
            WorkflowRuntimeEvent::IterationPlanned(payload) => {
                if state.iterations.iter().any(|iteration| {
                    iteration.planned.iteration_node_id == payload.iteration_node_id
                        && iteration.planned.parent_execution_token_id
                            == payload.parent_execution_token_id
                }) {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "iteration_planned_twice".into(),
                    ));
                }
                state.iterations.push(RecordedIteration {
                    planned_event_id: envelope.event_id,
                    planned: payload,
                    evaluated_event_id: None,
                    evaluated_store_position: None,
                    evaluated: None,
                });
            }
            WorkflowRuntimeEvent::IterationEvaluated(payload) => {
                let iteration = state
                    .iterations
                    .iter_mut()
                    .find(|iteration| {
                        iteration.planned.iteration_node_id == payload.iteration_node_id
                            && iteration.planned.parent_execution_token_id
                                == payload.parent_execution_token_id
                    })
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("iteration_plan_missing".into())
                    })?;
                if iteration.evaluated.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "iteration_evaluated_twice".into(),
                    ));
                }
                iteration.evaluated_event_id = Some(envelope.event_id);
                iteration.evaluated_store_position = Some(envelope.store_position);
            }
            WorkflowRuntimeEvent::RetryEvaluated(payload) => {
                if state.retries.iter().any(|retry| {
                    retry.payload.controller_attempt_id == payload.controller_attempt_id
                }) {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "retry_evaluated_twice".into(),
                    ));
                }
                state.retries.push(RecordedRetry {
                    event_id: envelope.event_id,
                    payload,
                });
            }
            WorkflowRuntimeEvent::WaitSignalRecorded(payload) => {
                if state
                    .wait_signals
                    .insert(
                        payload.signal_id.clone(),
                        RecordedWaitSignal {
                            event_id: envelope.event_id,
                            store_position: envelope.store_position,
                            occurred_at_unix_millis: envelope.occurred_at_unix_millis,
                            payload,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_wait_signal".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::WaitSubscribed(payload) => {
                if state
                    .waits
                    .insert(
                        payload.subscription_id.clone(),
                        RecordedWait {
                            subscribed_event_id: envelope.event_id,
                            subscribed: payload,
                            resolved_event_id: None,
                            resolved: None,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_wait_subscription".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::WaitResolved(payload) => {
                let wait = state
                    .waits
                    .get_mut(&payload.subscription_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("wait_subscription_missing".into())
                    })?;
                if wait.resolved.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "wait_resolved_twice".into(),
                    ));
                }
                wait.resolved_event_id = Some(envelope.event_id);
            }
            WorkflowRuntimeEvent::AttemptStarted(payload) => {
                if state
                    .attempts
                    .iter()
                    .any(|attempt| attempt.started.attempt_id == payload.attempt_id)
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_attempt".into(),
                    ));
                }
                state.attempts.push(RecordedAttempt {
                    started_event_id: envelope.event_id,
                    started_store_position: envelope.store_position,
                    started_at_unix_millis: envelope.occurred_at_unix_millis,
                    started: payload,
                    settled_event_id: None,
                    settled: None,
                });
            }
            WorkflowRuntimeEvent::AttemptSettled(payload) => {
                let attempt = state
                    .attempts
                    .iter_mut()
                    .find(|attempt| attempt.started.attempt_id == payload.attempt_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("settled_attempt_missing".into())
                    })?;
                if attempt.settled.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "attempt_settled_twice".into(),
                    ));
                }
                attempt.settled_event_id = Some(envelope.event_id);
            }
            WorkflowRuntimeEvent::PortEmitted(payload) => {
                if state
                    .emissions
                    .insert(
                        payload.emission_id.clone(),
                        RecordedEmission {
                            event_id: envelope.event_id,
                            payload,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_emission".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::EdgeCheckpointed(payload) => {
                state.edges.push(RecordedEdge {
                    event_id: envelope.event_id,
                    store_position: envelope.store_position,
                    payload,
                });
            }
            WorkflowRuntimeEvent::MatchTraceRecorded(_) => {}
            WorkflowRuntimeEvent::RunCancellationRequested(payload) => {
                if state.cancellation.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_cancellation".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::RunSettled(payload) => {
                if state.settled.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "run_settled_twice".into(),
                    ));
                }
            }
        }
    }
    state
        .attempts
        .sort_by_key(|attempt| attempt.started_store_position);
    Ok(state)
}

fn active_attempt(state: &RecordedRun) -> Result<Option<&RecordedAttempt>> {
    let active = state
        .attempts
        .iter()
        .filter(|attempt| attempt.settled.is_none())
        .collect::<Vec<_>>();
    if active.len() > 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "parallel_attempts_not_minimal".into(),
        ));
    }
    Ok(active.into_iter().next())
}

fn emissions_for_attempt<'a>(
    state: &'a RecordedRun,
    attempt_id: &str,
) -> Vec<&'a RecordedEmission> {
    let mut values = state
        .emissions
        .values()
        .filter(|emission| emission.payload.attempt_id == attempt_id)
        .collect::<Vec<_>>();
    values.sort_by(|left, right| left.event_id.cmp(&right.event_id));
    values
}

fn compiled_node<'a>(compiled: &'a CompiledWorkflow, node_id: &str) -> Result<&'a CompiledNode> {
    compiled
        .nodes
        .iter()
        .find(|node| node.id == node_id)
        .ok_or_else(|| WorkflowExecutionError::Integrity("compiled_node_missing".into()))
}

fn parallel_join_node(
    compiled: &CompiledWorkflow,
    node: &CompiledNode,
    config: &ParallelConfig,
) -> Result<String> {
    let mut common: Option<BTreeSet<String>> = None;
    for branch in &config.branches {
        if branch.key.is_empty() || branch.label.is_empty() {
            return Err(WorkflowExecutionError::Integrity(
                "parallel_branch_contract".into(),
            ));
        }
        let port_id = format!("case-{}", branch.id);
        let targets = compiled
            .edges
            .iter()
            .filter(|edge| edge.from.node_id == node.id && edge.from.port_id == port_id)
            .map(|edge| edge.to.node_id.clone())
            .collect::<Vec<_>>();
        if targets.len() != 1 {
            return Err(WorkflowExecutionError::Integrity(
                "parallel_branch_edge".into(),
            ));
        }
        let mut queue = std::collections::VecDeque::from(targets);
        let mut visited = BTreeSet::new();
        let mut joins = BTreeSet::new();
        while let Some(candidate) = queue.pop_front() {
            if !visited.insert(candidate.clone()) {
                continue;
            }
            let candidate_node = compiled_node(compiled, &candidate)?;
            if candidate_node.node_type == "control.join" {
                joins.insert(candidate);
                continue;
            }
            if candidate_node.node_type.starts_with("terminal.")
                || candidate_node.node_type == "control.parallel"
            {
                continue;
            }
            queue.extend(
                compiled
                    .edges
                    .iter()
                    .filter(|edge| edge.from.node_id == candidate_node.id)
                    .map(|edge| edge.to.node_id.clone()),
            );
        }
        common = Some(match common {
            None => joins,
            Some(existing) => existing.intersection(&joins).cloned().collect(),
        });
    }
    let common = common.unwrap_or_default();
    if common.len() != 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "parallel_requires_one_common_join".into(),
        ));
    }
    Ok(common.into_iter().next().unwrap())
}

fn inline_json(value: &v1::WorkflowValueReference) -> Result<Value> {
    if value.inline_canonical_json.is_empty() || !value.storage_reference_id.is_empty() {
        return Err(WorkflowExecutionError::Unsupported(
            "storage_value_not_in_minimal_executor".into(),
        ));
    }
    serde_json::from_slice(&value.inline_canonical_json)
        .map_err(|_| WorkflowExecutionError::Integrity("inline_value_json".into()))
}

fn value_from_json(value_id: &str, value: &Value) -> Result<v1::WorkflowValueReference> {
    let encoded =
        serde_json::to_vec(value).map_err(|_| WorkflowExecutionError::Encoding("runtime_value"))?;
    let canonical = workflow_canonical::canonicalize(&encoded)
        .map_err(|_| WorkflowExecutionError::Encoding("runtime_value_canonical"))?;
    let sha256 = canonical
        .sha256
        .strip_prefix("sha256:")
        .ok_or(WorkflowExecutionError::Encoding("runtime_value_digest"))?
        .to_owned();
    Ok(v1::WorkflowValueReference {
        value_id: value_id.to_owned(),
        content_type: "application/json".into(),
        byte_count: canonical.canonical_bytes.len() as u64,
        sha256,
        inline_canonical_json: canonical.canonical_bytes,
        storage_reference_id: String::new(),
        storage: None,
    })
}

fn error_code(value: &v1::WorkflowValueReference) -> Result<String> {
    inline_json(value)?
        .get("code")
        .and_then(Value::as_str)
        .filter(|code| !code.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| WorkflowExecutionError::Integrity("error_code_missing".into()))
}

#[allow(clippy::too_many_arguments)]
fn execution_token_settled_event(
    occurred_at_unix_millis: i64,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    execution_token_id: &str,
    outcome: v1::WorkflowExecutionTokenOutcome,
    terminal_node_id: String,
    join_node_id: String,
    error_code: String,
    error: Option<v1::WorkflowValueReference>,
    final_emission_ids: Vec<String>,
    causation_id: &str,
) -> v1::EventEnvelope {
    runtime_event(
        occurred_at_unix_millis,
        &stable_id(
            "event",
            &[
                &request.run_id,
                "execution-token",
                execution_token_id,
                "settled",
            ],
        ),
        workflow_runtime::WORKFLOW_EXECUTION_TOKEN_SETTLED_KIND,
        workflow_runtime::WORKFLOW_EXECUTION_TOKEN_SETTLED_TYPE,
        v1::WorkflowExecutionTokenSettled {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            execution_token_id: execution_token_id.to_owned(),
            outcome: outcome as i32,
            terminal_node_id,
            join_node_id,
            error_code,
            error,
            final_emission_ids,
        },
        causation_id,
        &request.run_id,
    )
}

#[allow(clippy::too_many_arguments)]
fn run_settled_event(
    occurred_at_unix_millis: i64,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    outcome: v1::WorkflowRunOutcome,
    error_code: String,
    error: Option<v1::WorkflowValueReference>,
    final_emission_ids: Vec<String>,
    causation_id: &str,
) -> v1::EventEnvelope {
    runtime_event(
        occurred_at_unix_millis,
        &stable_id("event", &[&request.run_id, "run-settled"]),
        workflow_runtime::WORKFLOW_RUN_SETTLED_KIND,
        workflow_runtime::WORKFLOW_RUN_SETTLED_TYPE,
        v1::WorkflowRunSettled {
            run_id: request.run_id.clone(),
            run_token_id: token_id.to_owned(),
            outcome: outcome as i32,
            error_code,
            error,
            final_emission_ids,
        },
        causation_id,
        &request.run_id,
    )
}

fn cancellation_time(state: &RecordedRun, fallback: i64) -> i64 {
    state
        .events
        .iter()
        .rev()
        .find(|event| event.kind == workflow_runtime::WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND)
        .map_or(fallback, |event| event.occurred_at_unix_millis)
}

fn current_unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or_default()
}

fn durable_outcome(value: i32) -> Result<DurableRunOutcome> {
    match v1::WorkflowRunOutcome::try_from(value) {
        Ok(v1::WorkflowRunOutcome::Succeeded) => Ok(DurableRunOutcome::Succeeded),
        Ok(v1::WorkflowRunOutcome::Failed) => Ok(DurableRunOutcome::Failed),
        Ok(v1::WorkflowRunOutcome::Cancelled) => Ok(DurableRunOutcome::Cancelled),
        _ => Err(WorkflowExecutionError::Integrity(
            "run_outcome_invalid".into(),
        )),
    }
}

fn run_outcome_name(value: i32) -> Result<&'static str> {
    match v1::WorkflowRunOutcome::try_from(value)
        .map_err(|_| WorkflowExecutionError::Integrity("run_outcome".into()))?
    {
        v1::WorkflowRunOutcome::Succeeded => Ok("succeeded"),
        v1::WorkflowRunOutcome::Failed => Ok("failed"),
        v1::WorkflowRunOutcome::Cancelled => Ok("cancelled"),
        v1::WorkflowRunOutcome::Unspecified => {
            Err(WorkflowExecutionError::Integrity("run_outcome".into()))
        }
    }
}

fn stable_id(prefix: &str, components: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for component in components {
        hasher.update((component.len() as u64).to_be_bytes());
        hasher.update(component.as_bytes());
    }
    format!("{prefix}-{}", &hex::encode(hasher.finalize())[..32])
}

#[allow(clippy::too_many_arguments)]
fn runtime_event<M: Message>(
    occurred_at_unix_millis: i64,
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    run_id: &str,
) -> v1::EventEnvelope {
    v1::EventEnvelope {
        schema_version: Some(v1::SchemaVersion { major: 1, minor: 0 }),
        event_id: event_id.into(),
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        store_position: 0,
        occurred_at_unix_millis,
        kind: kind.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
            payload_version: 1,
        }),
        correlation_id: run_id.into(),
        causation_id: causation_id.into(),
        provenance: Some(v1::EventProvenance {
            source_kind: "workflow-runtime".into(),
            provider_instance_id: String::new(),
            native_type: String::new(),
            native_cursor: Vec::new(),
            raw_evidence_digest: String::new(),
            retention_class: v1::EvidenceRetentionClass::None as i32,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn retry_config() -> RetryConfig {
        RetryConfig {
            maximum_attempts: 3,
            retry_on: vec!["connector.timeout".into()],
            backoff: RetryBackoffConfig {
                mode: "fixed".into(),
                initial_seconds: 1.0,
                maximum_seconds: 1.0,
                jitter: "none".into(),
            },
        }
    }

    #[test]
    fn unknown_effect_outcomes_always_route_to_reconciliation_before_retry() {
        let config = retry_config();
        for error in [
            json!({"code": "connector.timeout", "outcome": "unknown"}),
            json!({"code": "connector.timeout", "retryability": "reconcile-first"}),
        ] {
            assert_eq!(
                classify_retry_decision(&error, "connector.timeout", &config, 2),
                v1::WorkflowRetryDecision::UnknownOutcome
            );
        }
        assert_eq!(
            classify_retry_decision(
                &json!({"code": "connector.timeout"}),
                "connector.timeout",
                &config,
                2,
            ),
            v1::WorkflowRetryDecision::Scheduled
        );
        assert_eq!(
            classify_retry_decision(
                &json!({"code": "connector.timeout", "retryability": "never"}),
                "connector.timeout",
                &config,
                2,
            ),
            v1::WorkflowRetryDecision::NotRetryable
        );
    }
}
