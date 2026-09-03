//! Minimal durable local workflow executor.
//!
//! The executor consumes only a verified immutable compiled revision and the
//! typed journal contracts. It advances one deterministic event boundary at a
//! time, so resubmitting the same request after a process crash can only append
//! the next missing fact. This bounded slice supports typed scoped storage,
//! version-pinned idempotent capabilities through an explicitly supplied host,
//! and deterministic mapping evaluation over the `input` root for edges,
//! `data.map`, capability inputs, model prompts, subflow inputs, and
//! authority-gated connector effects through an explicitly supplied host.
//! Mapped values are recomputed on replay from the compiled mapping and the
//! journaled source value; they add no new journal facts.

use crate::{
    journal::{Journal, JournalError, ReplayBasis},
    v1, workflow_canonical,
    workflow_capabilities::{
        UnavailableWorkflowCapabilityHost, WorkflowCapabilityArtifactHandle,
        WorkflowCapabilityDefinition, WorkflowCapabilityHost, WorkflowCapabilityHostResult,
        WorkflowCapabilityInvocation, WorkflowCapabilityLog, WorkflowCapabilityValue,
    },
    workflow_effect_authority::stable_effect_id,
    workflow_effect_connector::{
        UnavailableWorkflowEffectHost, WorkflowEffectConnectorRequest, WorkflowEffectHost,
        dispatch_result_payload, reconciliation_result_payload, registration_matches,
    },
    workflow_expression::{self, ExpressionRoots},
    workflow_library::{WorkflowLibraryError, WorkflowLibraryStore},
    workflow_llm::{
        UnavailableWorkflowLlmProvider, WorkflowLlmInvocation, WorkflowLlmProvider,
        WorkflowLlmProviderDefinition, WorkflowLlmProviderResult, WorkflowLlmProviderToolResult,
        WorkflowLlmProviderTrace,
    },
    workflow_mail_effect::{
        WorkflowMailEffectClass, WorkflowMailEffectRequest, mail_effect_proposal,
    },
    workflow_match::{self, EvaluationOutcome, MatchConfig, MatchRoots, TraceOutcome},
    workflow_retention::WorkflowRunRetentionPolicy,
    workflow_runtime::{self, WorkflowRuntimeCommand, WorkflowRuntimeEvent},
    workflow_schema::{self, WorkflowSchemaCheckOutcome, WorkflowSchemaCheckRequest},
    workflow_storage::{
        WorkflowScopedStorage, WorkflowStorageAccessContext, WorkflowStorageDeleteRequest,
        WorkflowStorageError, WorkflowStorageHandle, WorkflowStorageListRequest,
        WorkflowStorageNamespace, WorkflowStorageNamespaceQuota, WorkflowStoragePromoteRequest,
        WorkflowStorageReadRequest, WorkflowStorageScopeKind, WorkflowStorageValueInput,
        WorkflowStorageWriteRequest,
    },
    workflow_versions::{WorkflowExecutionSupport, WorkflowRevisionContent},
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
const MAXIMUM_SUBFLOW_DEPTH: usize = 16;
const MAXIMUM_INLINE_STORAGE_SUMMARY_BYTES: usize = 60 * 1024;
const MAXIMUM_LLM_TOOLS: usize = 64;
const MAXIMUM_LLM_TOOL_CALLS: usize = 128;
const MAXIMUM_LLM_RESPONSE_MESSAGES: usize = 128;
const MAXIMUM_LLM_TRACE_VALUE_BYTES: usize = 24 * 1024;
const DEFAULT_CANCEL_REASON_CODE: &str = "cancel.requested";
const REVIEW_WAIT_KIND: &str = "event";
/// How long an `effect.connector` proposal stays approvable and dispatchable.
const EFFECT_AUTHORITY_WINDOW_MILLISECONDS: i64 = 900_000;
/// The read-only reconciliation checks one attempt may perform before it hands
/// the still-unknown outcome to the graph.
const MAXIMUM_EFFECT_RECONCILIATION_CHECKS: usize = 3;
/// How long a started dispatch may stay unsettled before its deadline passes.
const EFFECT_DISPATCH_TIMEOUT_MILLISECONDS: i64 = 60_000;

/// Node identities the durable executor accepts from a compiled revision.
pub const EXECUTOR_ADMITTED_NODE_TYPES: &[&str] = &[
    "compute.capability",
    "compute.llm",
    "control.decision",
    "control.for-each",
    "control.human-review",
    "control.join",
    "control.match",
    "control.parallel",
    "control.reconcile",
    "control.retry",
    "control.subflow",
    "control.wait",
    "data.case-context",
    "data.map",
    "data.register-artifact",
    "data.validate",
    "effect.connector",
    "storage.promote",
    "storage.read",
    "storage.write",
    "terminal.cancel",
    "terminal.complete",
    "terminal.fail",
    "trigger.event",
    "trigger.manual",
    "trigger.schedule",
];

/// Refusal code used when a compiled edge cannot be evaluated durably.
pub const EDGE_MAPPING_NOT_EXECUTABLE_CODE: &str = "edge_mapping_not_executable";

#[derive(Default)]
struct AdmittedLlmTrace {
    tool_calls: Vec<v1::WorkflowLlmToolCall>,
    response_messages: Vec<v1::WorkflowLlmResponseMessage>,
    usage: Option<v1::WorkflowLlmUsage>,
    provider_receipt: Option<v1::WorkflowLlmProviderReceipt>,
}

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

/// `trigger_kind` recorded on a run admitted from a `trigger.event` entrypoint.
pub const EVENT_TRIGGER_KIND: &str = "event";
/// `trigger_kind` recorded on a run admitted from a `trigger.schedule`
/// entrypoint.
pub const SCHEDULE_TRIGGER_KIND: &str = "schedule";

/// The pinned revision, ownership, and payload a triggered run inherits. The
/// trigger itself contributes only its deduplicated identity; this binding
/// carries no provider, credential, network, or effect authority.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkflowTriggerRunBinding {
    pub workflow_id: String,
    pub revision_id: String,
    pub package_digest: String,
    pub installation_id: String,
    pub case_id: String,
    pub input: v1::WorkflowValueReference,
    pub scope: v1::Scope,
    pub actor_id: String,
    /// When the host observed the trigger. It becomes both the command
    /// timestamp and the executor clock, so an admission is fully deterministic.
    pub observed_at_unix_millis: i64,
}

/// One provider event offered to a `trigger.event` entrypoint. Only the field
/// selected by the compiled `deduplication` mode is read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkflowEventTrigger {
    pub event_id: String,
    pub contract_key: String,
}

/// One occurrence offered to a `trigger.schedule` entrypoint. The occurrence has
/// misfired once `observed_at_unix_millis` on the binding is later than
/// `scheduled_for_unix_millis` by more than the grace window.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkflowScheduleTrigger {
    pub scheduled_for_unix_millis: i64,
    pub misfire_grace_millis: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowTriggerAdmission {
    /// The occurrence created a new run token.
    Admitted,
    /// The occurrence resolved to a run token that already existed; nothing was
    /// appended.
    Duplicate,
    /// A misfired schedule occurrence a `skip` policy discarded; nothing was
    /// appended and no command was admitted.
    Misfired,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowTriggerRunReceipt {
    pub admission: WorkflowTriggerAdmission,
    pub run_id: String,
    pub trigger_kind: String,
    pub trigger_event_id: String,
    /// The deterministic run request. It is absent only for a misfired
    /// occurrence, which never produces one.
    pub command: Option<v1::CommandEnvelope>,
    pub result: Option<WorkflowExecutionResult>,
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
    #[serde(default)]
    interfaces: BTreeMap<String, Vec<Value>>,
    nodes: Vec<CompiledNode>,
    edges: Vec<CompiledEdge>,
    resources: BTreeMap<String, String>,
    policies: BTreeMap<String, Value>,
    storage: BTreeMap<String, CompiledStorageDeclaration>,
    #[serde(default)]
    retention: WorkflowRunRetentionPolicy,
    dependencies: Vec<CompiledDependency>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledDependency {
    kind: String,
    id: String,
    #[serde(default)]
    version: Option<String>,
    digest: String,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SubflowConfig {
    package_id: String,
    revision_digest: String,
    entrypoint: String,
    input: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CapabilityConfig {
    capability_id: String,
    version: String,
    input: Value,
    #[serde(default)]
    configuration: Value,
    output_schema_ref: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LlmConfig {
    model_class: String,
    instructions: String,
    prompt: Value,
    context: Vec<Value>,
    tools: Vec<String>,
    output_schema_ref: String,
    #[serde(default = "default_job_conversation_scope")]
    conversation_scope: String,
    reasoning_effort: String,
    temperature_milli: u32,
    maximum_context_bytes: u64,
    maximum_output_tokens: u32,
    /// The per-attempt tool-call budget. An absent budget falls back to the
    /// global runtime bound, so a revision published before the field existed
    /// keeps executing unchanged.
    #[serde(default)]
    maximum_tool_calls: Option<u32>,
}

/// One `effect.connector` node. The action names the mail effect kind, and the
/// two contract fields are the exact preview and reconciliation contracts the
/// journaled evidence pins.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConnectorEffectConfig {
    connector_class: String,
    action: String,
    input: Value,
    preview_contract: String,
    reconciliation_contract: String,
    idempotency: String,
}

/// One compiled authority policy. The compiled artifact carries policies at the
/// top level without the per-node references the definition declares, so the
/// executor can only check that every declared policy is an authority policy it
/// can honour: it always demands a recorded owner resolution before dispatch.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledAuthorityPolicy {
    key: String,
    #[serde(rename = "type")]
    policy_type: String,
    type_version: u32,
    config: CompiledAuthorityPolicyConfig,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompiledAuthorityPolicyConfig {
    authority_class: String,
    approval: String,
    reversible: bool,
}

fn default_job_conversation_scope() -> String {
    "job".into()
}

/// The admitted per-attempt tool-call budget for one `compute.llm` node.
fn llm_tool_call_budget(config: &LlmConfig) -> usize {
    config
        .maximum_tool_calls
        .map_or(MAXIMUM_LLM_TOOL_CALLS, |budget| {
            (budget as usize).min(MAXIMUM_LLM_TOOL_CALLS)
        })
}

struct ExecutionPackage {
    compiled: CompiledWorkflow,
    schemas: BTreeMap<String, Value>,
    requires_storage: bool,
}

#[derive(Default)]
struct RecordedRun {
    events: Vec<v1::EventEnvelope>,
    episode: Option<v1::WorkflowCaseEpisodeStarted>,
    subflows: BTreeMap<String, RecordedSubflow>,
    token: Option<v1::WorkflowRunTokenCreated>,
    execution_tokens: BTreeMap<String, RecordedExecutionToken>,
    joins: Vec<RecordedJoin>,
    iterations: Vec<RecordedIteration>,
    retries: Vec<RecordedRetry>,
    wait_signals: BTreeMap<String, RecordedWaitSignal>,
    waits: BTreeMap<String, RecordedWait>,
    attempts: Vec<RecordedAttempt>,
    capability_attempts: BTreeMap<String, RecordedCapabilityAttempt>,
    llm_attempts: BTreeMap<String, RecordedLlmAttempt>,
    effects: BTreeMap<String, RecordedEffect>,
    emissions: BTreeMap<String, RecordedEmission>,
    edges: Vec<RecordedEdge>,
    cancellation: Option<v1::WorkflowRunCancellationRequested>,
    settled: Option<v1::WorkflowRunSettled>,
}

struct RecordedSubflow {
    called: v1::WorkflowSubflowCalled,
    settled: Option<v1::WorkflowSubflowSettled>,
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

struct RecordedCapabilityAttempt {
    started_event_id: String,
    started_at_unix_millis: i64,
    started: v1::WorkflowCapabilityAttemptStarted,
    settled_event_id: Option<String>,
    settled: Option<v1::WorkflowCapabilityAttemptSettled>,
}

struct RecordedLlmAttempt {
    started_event_id: String,
    started_at_unix_millis: i64,
    started: v1::WorkflowLlmAttemptStarted,
    settled_event_id: Option<String>,
    settled: Option<v1::WorkflowLlmAttemptSettled>,
}

struct RecordedEmission {
    event_id: String,
    payload: v1::WorkflowPortEmitted,
}

/// The journaled facts of one durable effect. Every phase carries the time it
/// was recorded, so a later phase can derive its own occurrence from durable
/// evidence instead of a wall clock and stay identical across replay.
struct RecordedEffect {
    proposed_event_id: String,
    proposed: v1::WorkflowEffectProposed,
    authorized_event_id: Option<String>,
    authorized: Option<v1::WorkflowEffectAuthorized>,
    dispatch_started_event_id: Option<String>,
    dispatch_started: Option<v1::WorkflowEffectDispatchStarted>,
    dispatch_started_at_unix_millis: i64,
    dispatch_settled_event_id: Option<String>,
    dispatch_settled: Option<v1::WorkflowEffectDispatchSettled>,
    dispatch_settled_at_unix_millis: i64,
    reconciliations: Vec<RecordedEffectReconciliation>,
}

struct RecordedEffectReconciliation {
    event_id: String,
    occurred_at_unix_millis: i64,
    payload: v1::WorkflowEffectReconciled,
}

impl RecordedEffect {
    fn latest_reconciliation(&self) -> Option<&RecordedEffectReconciliation> {
        self.reconciliations.last()
    }

    /// The event a further effect fact is caused by.
    fn latest_event_id(&self) -> &str {
        self.reconciliations
            .last()
            .map(|reconciliation| reconciliation.event_id.as_str())
            .or(self.dispatch_settled_event_id.as_deref())
            .or(self.dispatch_started_event_id.as_deref())
            .or(self.authorized_event_id.as_deref())
            .unwrap_or(&self.proposed_event_id)
    }

    /// The latest durable moment in this effect's history, which is the base a
    /// new reconciliation measures its own elapsed time from.
    fn latest_occurred_at_unix_millis(&self) -> i64 {
        self.reconciliations
            .last()
            .map(|reconciliation| reconciliation.occurred_at_unix_millis)
            .unwrap_or(self.dispatch_settled_at_unix_millis)
    }
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
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

pub fn execute_at_unix_millis(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        &mut effects,
        command,
        now_unix_millis,
        None,
        0,
        None,
    )
}

pub fn execute_with_storage(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    storage: &mut WorkflowScopedStorage,
    authority: &WorkflowStorageExecutionAuthority,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        &mut capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

/// Runs a revision with both injectable hosts the desktop can supply today:
/// an external capability host and an external LLM provider. Effects remain
/// unavailable until a connector host exists.
pub fn execute_with_hosts(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        capabilities,
        llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

pub fn execute_with_capabilities(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    capabilities: &mut dyn WorkflowCapabilityHost,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

pub fn execute_with_storage_and_capabilities(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    storage: &mut WorkflowScopedStorage,
    authority: &WorkflowStorageExecutionAuthority,
    capabilities: &mut dyn WorkflowCapabilityHost,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

pub fn execute_with_llm(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    llm: &mut dyn WorkflowLlmProvider,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
        None,
    )
}

/// Runs a revision whose `effect.connector` nodes dispatch through `effects`.
/// The host owns the connector registration and the local approval authority;
/// the executor only journals what the host returns.
pub fn execute_with_effects(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    effects: &mut dyn WorkflowEffectHost,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        effects,
        command,
        now_unix_millis,
        None,
        0,
        None,
    )
}

pub fn execute_with_storage_capabilities_and_llm(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    storage: &mut WorkflowScopedStorage,
    authority: &WorkflowStorageExecutionAuthority,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        capabilities,
        llm,
        &mut effects,
        command,
        current_unix_millis(),
        None,
        0,
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
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        Some(fault),
        0,
        None,
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
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        Some(storage),
        Some(authority),
        &mut capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        Some(fault),
        0,
        None,
    )
}

#[doc(hidden)]
pub fn execute_with_capabilities_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    capabilities: &mut dyn WorkflowCapabilityHost,
    command: &v1::CommandEnvelope,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        capabilities,
        &mut llm,
        &mut effects,
        command,
        current_unix_millis(),
        Some(fault),
        0,
        None,
    )
}

#[doc(hidden)]
pub fn execute_with_llm_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    llm: &mut dyn WorkflowLlmProvider,
    command: &v1::CommandEnvelope,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut effects = UnavailableWorkflowEffectHost;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        llm,
        &mut effects,
        command,
        current_unix_millis(),
        Some(fault),
        0,
        None,
    )
}

#[doc(hidden)]
pub fn execute_with_effects_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    effects: &mut dyn WorkflowEffectHost,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        effects,
        command,
        now_unix_millis,
        Some(fault),
        0,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn execute_internal(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    mut storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    effects: &mut dyn WorkflowEffectHost,
    command: &v1::CommandEnvelope,
    now_unix_millis: i64,
    fault: Option<WorkflowExecutionFault>,
    subflow_depth: usize,
    job_run_id: Option<&str>,
) -> Result<WorkflowExecutionResult> {
    if subflow_depth > MAXIMUM_SUBFLOW_DEPTH {
        return Err(WorkflowExecutionError::Lifecycle(
            "subflow_depth_exceeded".into(),
        ));
    }
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
    let job_run_id = job_run_id.unwrap_or(&request.run_id).to_owned();
    let package = load_execution_package(library, &request)?;
    validate_storage_authority(&package, &request, storage.is_some(), authority)?;
    validate_capability_host(&package, capabilities)?;
    validate_llm_provider(&package, llm)?;
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
            journal,
            library,
            &package,
            storage.as_deref_mut(),
            authority,
            capabilities,
            llm,
            effects,
            command,
            &request,
            &token_id,
            &state,
            now_unix_millis,
            prepared_episode.as_ref(),
            subflow_depth,
            &job_run_id,
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

/// Admits one deduplicated `trigger.event` occurrence as a durable run.
///
/// The compiled trigger decides which identity deduplicates: `event-id` keys on
/// the provider's own event identity, `contract-key` keys on a contract-scoped
/// key so a stream of provider events collapses onto one run. The run, command,
/// and idempotency identities all derive from that key, so a second admission of
/// the same occurrence finds the existing run token and appends nothing.
///
/// The trigger carries identity only. It grants no provider, credential,
/// network, or effect authority, and reads nothing from a live account.
pub fn execute_event_trigger(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    binding: &WorkflowTriggerRunBinding,
    trigger: &WorkflowEventTrigger,
) -> Result<WorkflowTriggerRunReceipt> {
    let compiled = load_trigger_revision(library, binding)?;
    let entrypoint = compiled_node(&compiled, &compiled.entrypoints[0].node_id)?;
    if entrypoint.node_type != "trigger.event" {
        return Err(WorkflowExecutionError::Unsupported(
            "event_trigger_entrypoint_required".into(),
        ));
    }
    let config = event_trigger_config(entrypoint)?;
    let key = match config.deduplication.as_str() {
        "event-id" => trigger.event_id.as_str(),
        _ => trigger.contract_key.as_str(),
    };
    if key.is_empty() {
        return Err(WorkflowExecutionError::InvalidCommand(
            "event_trigger_key_required",
        ));
    }
    let occurrence = stable_id(
        "event",
        &[&config.event_contract, &config.deduplication, key],
    );
    admit_trigger_run(journal, library, binding, EVENT_TRIGGER_KIND, &occurrence)
}

/// Admits one `trigger.schedule` occurrence as a durable run, honouring the
/// compiled misfire policy.
///
/// An occurrence has misfired once it is later than its grace window. `skip`
/// drops it without touching the journal; `run-once` still admits it. Because
/// the occurrence identity is derived from the schedule key and the scheduled
/// instant, a repeated catch-up pass over the same missed occurrence resolves to
/// the same run and appends nothing. The host remains responsible for advancing
/// its own schedule cursor past a coalesced catch-up window.
pub fn execute_schedule_trigger(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    binding: &WorkflowTriggerRunBinding,
    trigger: &WorkflowScheduleTrigger,
) -> Result<WorkflowTriggerRunReceipt> {
    let compiled = load_trigger_revision(library, binding)?;
    let entrypoint = compiled_node(&compiled, &compiled.entrypoints[0].node_id)?;
    if entrypoint.node_type != "trigger.schedule" {
        return Err(WorkflowExecutionError::Unsupported(
            "schedule_trigger_entrypoint_required".into(),
        ));
    }
    let config = schedule_trigger_config(entrypoint)?;
    if trigger.scheduled_for_unix_millis < 0 || trigger.misfire_grace_millis < 0 {
        return Err(WorkflowExecutionError::InvalidCommand(
            "schedule_trigger_window_required",
        ));
    }
    let occurrence = stable_id(
        "schedule",
        &[
            &config.schedule_key,
            &config.misfire_policy,
            &trigger.scheduled_for_unix_millis.to_string(),
        ],
    );
    let lateness = binding
        .observed_at_unix_millis
        .saturating_sub(trigger.scheduled_for_unix_millis);
    if lateness > trigger.misfire_grace_millis && config.misfire_policy == "skip" {
        return Ok(WorkflowTriggerRunReceipt {
            admission: WorkflowTriggerAdmission::Misfired,
            run_id: trigger_run_id(binding, &occurrence),
            trigger_kind: SCHEDULE_TRIGGER_KIND.into(),
            trigger_event_id: occurrence,
            command: None,
            result: None,
        });
    }
    admit_trigger_run(
        journal,
        library,
        binding,
        SCHEDULE_TRIGGER_KIND,
        &occurrence,
    )
}

fn admit_trigger_run(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    binding: &WorkflowTriggerRunBinding,
    trigger_kind: &str,
    occurrence: &str,
) -> Result<WorkflowTriggerRunReceipt> {
    let run_id = trigger_run_id(binding, occurrence);
    let command = trigger_run_command(binding, trigger_kind, occurrence, &run_id);
    let state = recorded_run(journal, &run_id)?;
    if let Some(token) = state.token.as_ref() {
        let outcome = match state.settled.as_ref() {
            Some(settled) => durable_outcome(settled.outcome)?,
            None => DurableRunOutcome::Running,
        };
        return Ok(WorkflowTriggerRunReceipt {
            admission: WorkflowTriggerAdmission::Duplicate,
            run_id: run_id.clone(),
            trigger_kind: trigger_kind.into(),
            trigger_event_id: occurrence.into(),
            command: Some(command),
            result: Some(WorkflowExecutionResult {
                run_id,
                run_token_id: token.run_token_id.clone(),
                outcome,
                event_count: state.events.len(),
                next_attempt_at_unix_millis: None,
            }),
        });
    }
    let mut capabilities = UnavailableWorkflowCapabilityHost;
    let mut llm = UnavailableWorkflowLlmProvider;
    let mut effects = UnavailableWorkflowEffectHost;
    let result = execute_internal(
        journal,
        library,
        None,
        None,
        &mut capabilities,
        &mut llm,
        &mut effects,
        &command,
        binding.observed_at_unix_millis,
        None,
        0,
        None,
    )?;
    Ok(WorkflowTriggerRunReceipt {
        admission: WorkflowTriggerAdmission::Admitted,
        run_id,
        trigger_kind: trigger_kind.into(),
        trigger_event_id: occurrence.into(),
        command: Some(command),
        result: Some(result),
    })
}

fn trigger_run_id(binding: &WorkflowTriggerRunBinding, occurrence: &str) -> String {
    stable_id(
        "run",
        &[&binding.workflow_id, &binding.revision_id, occurrence],
    )
}

fn trigger_run_command(
    binding: &WorkflowTriggerRunBinding,
    trigger_kind: &str,
    occurrence: &str,
    run_id: &str,
) -> v1::CommandEnvelope {
    let request = v1::RequestWorkflowRun {
        run_id: run_id.into(),
        workflow_id: binding.workflow_id.clone(),
        revision_id: binding.revision_id.clone(),
        package_digest: binding.package_digest.clone(),
        trigger_kind: trigger_kind.into(),
        trigger_event_id: occurrence.into(),
        inputs: vec![v1::WorkflowInputBinding {
            port_id: "input".into(),
            value: Some(binding.input.clone()),
        }],
        installation_id: binding.installation_id.clone(),
        case_id: binding.case_id.clone(),
        episode_id: String::new(),
        episode_kind: String::new(),
        prior_episode_id: String::new(),
    };
    v1::CommandEnvelope {
        schema_version: Some(v1::SchemaVersion { major: 1, minor: 0 }),
        command_id: stable_id("command", &[run_id, occurrence]),
        idempotency_key: stable_id("idempotency", &[run_id, occurrence]),
        kind: workflow_runtime::WORKFLOW_RUN_REQUEST_KIND.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: workflow_runtime::WORKFLOW_RUN_REQUEST_TYPE.into(),
            content_type: "application/x-protobuf".into(),
            value: request.encode_to_vec(),
            payload_version: 1,
        }),
        scope: Some(binding.scope.clone()),
        actor_id: binding.actor_id.clone(),
        expected_revision: 0,
        submitted_at_unix_millis: binding.observed_at_unix_millis,
    }
}

fn load_trigger_revision(
    library: &WorkflowLibraryStore,
    binding: &WorkflowTriggerRunBinding,
) -> Result<CompiledWorkflow> {
    let revision = library.load_workflow_revision(&binding.revision_id, "active")?;
    if revision.summary.workflow_id != binding.workflow_id
        || revision.summary.package_digest != binding.package_digest
    {
        return Err(WorkflowExecutionError::Integrity(
            "revision_pin_mismatch".into(),
        ));
    }
    let compiled: CompiledWorkflow = serde_json::from_slice(&revision.compiled_source)
        .map_err(|_| WorkflowExecutionError::Integrity("compiled_contract".into()))?;
    if compiled.entrypoints.len() != 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "compiled_subset".into(),
        ));
    }
    Ok(compiled)
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
    if compiled.dependencies.len() > 1_024
        || compiled.dependencies.iter().any(|dependency| {
            dependency.kind.is_empty()
                || dependency.id.is_empty()
                || dependency.digest.is_empty()
                || dependency.version.as_deref() == Some("")
        })
    {
        return Err(WorkflowExecutionError::Integrity(
            "compiled_dependency_contract".into(),
        ));
    }
    validate_compiled_subset(&compiled)?;
    validate_compiled_policies(&compiled)?;
    let (requires_storage, requires_case) =
        compiled_storage_requirements(library, &compiled, &mut BTreeSet::new(), 0)?;
    if requires_storage && request.installation_id.is_empty() {
        return Err(WorkflowExecutionError::InvalidCommand(
            "installation_id_required",
        ));
    }
    if requires_case && request.case_id.is_empty() {
        return Err(WorkflowExecutionError::InvalidCommand("case_id_required"));
    }
    if compiled
        .nodes
        .iter()
        .any(|node| node.node_type == "effect.connector")
        && request.installation_id.is_empty()
    {
        return Err(WorkflowExecutionError::InvalidCommand(
            "installation_id_required",
        ));
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
        if node.node_type == "trigger.event" {
            event_trigger_config(node)?;
        }
        if node.node_type == "trigger.schedule" {
            schedule_trigger_config(node)?;
        }
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
            let _: MatchConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("match_config".into()))?;
        }
        if node.node_type == "control.decision" {
            let config: DecisionConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("decision_config".into()))?;
            decision_match_config(&config)?;
        }
        if node.node_type == "control.reconcile" {
            let config: ReconcileConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("reconcile_config".into()))?;
            if config.effect.root != "input"
                || config.maximum_checks == 0
                || config.maximum_checks > 100
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "reconcile_contract".into(),
                ));
            }
        }
        if node.node_type == "control.human-review" {
            let config: HumanReviewConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("human_review_config".into()))?;
            if !workflow_expression::executable_mapping(&config.proposal)
                || config.authority_policy.is_empty()
                || config.expiry_seconds == 0
                || config.expiry_seconds > 2_592_000
                || !matches!(config.stale_check.as_str(), "revision" | "digest")
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "human_review_contract".into(),
                ));
            }
        }
        if node.node_type == "data.register-artifact" {
            let config: RegisterArtifactConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| {
                    WorkflowExecutionError::Integrity("register_artifact_config".into())
                })?;
            if config.role.is_empty()
                || config.media_types.is_empty()
                || config.media_types.len() > 32
                || config
                    .media_types
                    .iter()
                    .any(|media_type| media_type.is_empty() || media_type.len() > 255)
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "register_artifact_contract".into(),
                ));
            }
        }
        if node.node_type == "terminal.cancel" {
            let config: CancelConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("cancel_config".into()))?;
            if config
                .reason
                .as_ref()
                .is_some_and(|reason| !workflow_expression::executable_mapping(reason))
            {
                return Err(WorkflowExecutionError::Unsupported(
                    "cancel_contract".into(),
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
            let named_branches = config
                .required_branches
                .iter()
                .collect::<BTreeSet<_>>()
                .len();
            if !matches!(config.policy.as_str(), "all" | "any" | "quorum" | "named")
                || (config.policy != "named" && !config.required_branches.is_empty())
                || (config.policy == "quorum" && config.quorum.is_none())
                || (config.policy == "named"
                    && (config.required_branches.is_empty()
                        || config.required_branches.len() > 64
                        || named_branches != config.required_branches.len()))
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
        if node.node_type == "control.subflow" {
            resolve_subflow_revision(library, &compiled, node)?;
        }
        if node.node_type == "effect.connector" {
            validate_compiled_connector_effect(&compiled, node)?;
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
    validate_trigger_identity(&compiled, request)?;
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
    Ok(ExecutionPackage {
        compiled,
        schemas,
        requires_storage,
    })
}

fn validate_storage_authority(
    package: &ExecutionPackage,
    request: &v1::RequestWorkflowRun,
    storage_available: bool,
    authority: Option<&WorkflowStorageExecutionAuthority>,
) -> Result<()> {
    if !package.requires_storage {
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

fn validate_capability_host(
    package: &ExecutionPackage,
    capabilities: &dyn WorkflowCapabilityHost,
) -> Result<()> {
    let capability_nodes = package
        .compiled
        .nodes
        .iter()
        .filter(|node| node.node_type == "compute.capability")
        .collect::<Vec<_>>();
    if capability_nodes.is_empty() {
        return Ok(());
    }
    for node in capability_nodes {
        let (config, dependency, definition) =
            resolve_capability_definition(package, capabilities, node)?;
        if !workflow_expression::executable_mapping(&config.input)
            || !definition.idempotent
            || definition.timeout_milliseconds == 0
            || definition.timeout_milliseconds > 86_400_000
        {
            return Err(WorkflowExecutionError::Unsupported(
                "capability_execution_contract".into(),
            ));
        }
        if dependency.version.as_deref() != Some(config.version.as_str()) {
            return Err(WorkflowExecutionError::Integrity(
                "capability_dependency_version".into(),
            ));
        }
        let configuration = capability_configuration(&config)?;
        require_valid_schema(
            &definition.configuration_schema,
            "capability_configuration_schema",
        )?;
        require_valid_schema(&definition.input_schema, "capability_input_schema")?;
        require_valid_schema(&definition.output_schema, "capability_output_schema")?;
        require_schema_match(
            &definition.configuration_schema,
            configuration,
            "capability_configuration_invalid",
        )?;
        let bundled_output = package
            .schemas
            .get(&config.output_schema_ref)
            .ok_or_else(|| {
                WorkflowExecutionError::Unsupported("capability_output_schema_missing".into())
            })?;
        if schema_digest(bundled_output)? != schema_digest(&definition.output_schema)? {
            return Err(WorkflowExecutionError::Integrity(
                "capability_output_schema_pin".into(),
            ));
        }
    }
    Ok(())
}

fn resolve_capability_definition(
    package: &ExecutionPackage,
    capabilities: &dyn WorkflowCapabilityHost,
    node: &CompiledNode,
) -> Result<(
    CapabilityConfig,
    CompiledDependency,
    WorkflowCapabilityDefinition,
)> {
    let config: CapabilityConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("capability_config".into()))?;
    let dependencies = package
        .compiled
        .dependencies
        .iter()
        .filter(|dependency| {
            dependency.kind == "capability"
                && dependency.id == config.capability_id
                && dependency.version.as_deref() == Some(config.version.as_str())
        })
        .collect::<Vec<_>>();
    if dependencies.len() != 1 {
        return Err(WorkflowExecutionError::Integrity(
            "capability_dependency_pin".into(),
        ));
    }
    let mut dependency = dependencies[0].clone();
    dependency.digest = dependency
        .digest
        .strip_prefix("sha256:")
        .unwrap_or(&dependency.digest)
        .to_owned();
    if dependency.digest.len() != 64
        || !dependency
            .digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(WorkflowExecutionError::Integrity(
            "capability_dependency_digest".into(),
        ));
    }
    let definition = capabilities
        .definition(&config.capability_id, &config.version, &dependency.digest)
        .ok_or_else(|| WorkflowExecutionError::Unsupported("capability_not_registered".into()))?;
    if definition.capability_id != config.capability_id
        || definition.version != config.version
        || definition.package_digest != dependency.digest
    {
        return Err(WorkflowExecutionError::Integrity(
            "capability_registration_pin".into(),
        ));
    }
    Ok((config, dependency, definition))
}

fn validate_llm_provider(
    package: &ExecutionPackage,
    provider: &dyn WorkflowLlmProvider,
) -> Result<()> {
    for node in package
        .compiled
        .nodes
        .iter()
        .filter(|node| node.node_type == "compute.llm")
    {
        let config = llm_config(node)?;
        let definition = provider.definition(&config.model_class).ok_or_else(|| {
            WorkflowExecutionError::Unsupported("llm_provider_not_registered".into())
        })?;
        if definition.model_class != config.model_class
            || definition.provider_id.is_empty()
            || definition.provider_id.len() > 128
            || !definition.provider_id.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':')
            })
            || definition.model_id.is_empty()
            || definition.model_id.len() > 256
            || definition.model_revision.is_empty()
            || definition.model_revision.len() > 256
            || [&definition.model_id, &definition.model_revision]
                .iter()
                .any(|value| {
                    value.chars().any(char::is_control)
                        || llm_string_contains_host_path(value)
                        || llm_string_contains_secret(value)
                })
            || !definition.idempotent
            || definition.timeout_milliseconds == 0
            || definition.timeout_milliseconds > 86_400_000
            || definition.maximum_context_bytes < config.maximum_context_bytes
            || config.maximum_context_bytes < 256
            || config.maximum_context_bytes > 49_152
            || config.maximum_output_tokens == 0
            || config.maximum_output_tokens > 65_536
            || config.temperature_milli > 2_000
            || !matches!(
                config.reasoning_effort.as_str(),
                "minimal" | "low" | "medium" | "high"
            )
            || !matches!(config.conversation_scope.as_str(), "job" | "case")
            || !workflow_expression::executable_mapping(&config.prompt)
            || config.instructions.is_empty()
            || config
                .maximum_tool_calls
                .is_some_and(|budget| budget == 0 || budget as usize > MAXIMUM_LLM_TOOL_CALLS)
            || (config.tools.is_empty() && config.maximum_tool_calls.is_some())
        {
            return Err(WorkflowExecutionError::Unsupported(
                "llm_execution_contract".into(),
            ));
        }
        let output_schema = package
            .schemas
            .get(&config.output_schema_ref)
            .ok_or_else(|| {
                WorkflowExecutionError::Unsupported("llm_output_schema_missing".into())
            })?;
        require_valid_schema(output_schema, "llm_output_schema")?;
        validate_llm_context_references(&config.context)?;
        validated_llm_tool_definitions(package, &config, &definition)?;
    }
    Ok(())
}

fn validated_llm_tool_definitions(
    package: &ExecutionPackage,
    config: &LlmConfig,
    definition: &WorkflowLlmProviderDefinition,
) -> Result<Vec<v1::WorkflowLlmToolDefinition>> {
    if config.tools.len() > MAXIMUM_LLM_TOOLS
        || definition.tools.len() != config.tools.len()
        || config.tools.iter().collect::<BTreeSet<_>>().len() != config.tools.len()
    {
        return Err(WorkflowExecutionError::Unsupported(
            "llm_tool_definition_set".into(),
        ));
    }
    let mut admitted = Vec::with_capacity(config.tools.len());
    for tool_id in &config.tools {
        let tool = definition
            .tools
            .iter()
            .find(|tool| &tool.tool_id == tool_id)
            .ok_or_else(|| WorkflowExecutionError::Unsupported("llm_tool_not_registered".into()))?;
        let dependency = package
            .compiled
            .dependencies
            .iter()
            .find(|item| item.kind == "tool" && item.id == *tool_id)
            .ok_or_else(|| {
                WorkflowExecutionError::Integrity("llm_tool_dependency_missing".into())
            })?;
        if tool.tool_id.is_empty()
            || tool.tool_id.len() > 128
            || tool.version.is_empty()
            || tool.version.len() > 64
            || tool.package_digest.len() != 64
            || dependency.digest != tool.package_digest
            || dependency
                .version
                .as_deref()
                .is_some_and(|version| version != tool.version)
            || tool.description.is_empty()
            || tool.description.len() > 512
            || llm_string_contains_host_path(&tool.description)
            || llm_string_contains_secret(&tool.description)
            || tool.input_schema_ref.is_empty()
            || tool.input_schema_ref.len() > 256
            || tool.output_schema_ref.is_empty()
            || tool.output_schema_ref.len() > 256
        {
            return Err(WorkflowExecutionError::Unsupported(
                "llm_tool_definition_contract".into(),
            ));
        }
        let bundled_input = package.schemas.get(&tool.input_schema_ref).ok_or_else(|| {
            WorkflowExecutionError::Integrity("llm_tool_input_schema_missing".into())
        })?;
        let bundled_output = package
            .schemas
            .get(&tool.output_schema_ref)
            .ok_or_else(|| {
                WorkflowExecutionError::Integrity("llm_tool_output_schema_missing".into())
            })?;
        require_valid_schema(bundled_input, "llm_tool_input_schema")?;
        require_valid_schema(bundled_output, "llm_tool_output_schema")?;
        if schema_digest(bundled_input)? != schema_digest(&tool.input_schema)?
            || schema_digest(bundled_output)? != schema_digest(&tool.output_schema)?
        {
            return Err(WorkflowExecutionError::Integrity(
                "llm_tool_schema_pin".into(),
            ));
        }
        admitted.push(v1::WorkflowLlmToolDefinition {
            tool_id: tool.tool_id.clone(),
            version: tool.version.clone(),
            package_digest: tool.package_digest.clone(),
            description: tool.description.clone(),
            input_schema_ref: tool.input_schema_ref.clone(),
            input_schema_digest: schema_digest(&tool.input_schema)?,
            output_schema_ref: tool.output_schema_ref.clone(),
            output_schema_digest: schema_digest(&tool.output_schema)?,
        });
    }
    Ok(admitted)
}

fn llm_config(node: &CompiledNode) -> Result<LlmConfig> {
    serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("llm_config".into()))
}

fn validate_llm_context_references(references: &[Value]) -> Result<()> {
    if references.len() > 64 {
        return Err(WorkflowExecutionError::Unsupported(
            "llm_context_reference_limit".into(),
        ));
    }
    for reference in references {
        let root = reference.get("root").and_then(Value::as_str);
        let pointer = reference.get("pointer").and_then(Value::as_str);
        if root != Some("case")
            || pointer.is_none_or(|pointer| {
                pointer.len() > 512 || (!pointer.is_empty() && !pointer.starts_with('/'))
            })
        {
            return Err(WorkflowExecutionError::Unsupported(
                "llm_context_reference_contract".into(),
            ));
        }
    }
    Ok(())
}

fn capability_configuration(config: &CapabilityConfig) -> Result<Value> {
    let configuration = if config.configuration.is_null() {
        json!({})
    } else {
        config.configuration.clone()
    };
    if !configuration.is_object() {
        return Err(WorkflowExecutionError::Integrity(
            "capability_configuration".into(),
        ));
    }
    Ok(configuration)
}

fn require_valid_schema(schema: &Value, code: &'static str) -> Result<()> {
    let report = workflow_schema::check(&WorkflowSchemaCheckRequest {
        schema: schema.clone(),
        instance: Value::Null,
    });
    if report.outcome == WorkflowSchemaCheckOutcome::InvalidSchema {
        return Err(WorkflowExecutionError::Unsupported(code.into()));
    }
    Ok(())
}

fn require_schema_match(schema: &Value, instance: Value, code: &'static str) -> Result<()> {
    let report = workflow_schema::check(&WorkflowSchemaCheckRequest {
        schema: schema.clone(),
        instance,
    });
    if report.outcome != WorkflowSchemaCheckOutcome::Valid {
        return Err(WorkflowExecutionError::Unsupported(code.into()));
    }
    Ok(())
}

fn schema_digest(schema: &Value) -> Result<String> {
    let encoded = serde_json::to_vec(schema)
        .map_err(|_| WorkflowExecutionError::Encoding("capability_schema"))?;
    workflow_canonical::canonicalize(&encoded)
        .map(|report| report.sha256.trim_start_matches("sha256:").to_owned())
        .map_err(|_| WorkflowExecutionError::Encoding("capability_schema"))
}

fn compiled_storage_requirements(
    library: &WorkflowLibraryStore,
    compiled: &CompiledWorkflow,
    visited: &mut BTreeSet<String>,
    depth: usize,
) -> Result<(bool, bool)> {
    if depth > MAXIMUM_SUBFLOW_DEPTH {
        return Err(WorkflowExecutionError::Lifecycle(
            "subflow_depth_exceeded".into(),
        ));
    }
    let mut requires_storage = !compiled.storage.is_empty();
    let mut requires_case = compiled
        .storage
        .values()
        .any(|declaration| declaration.scope == "case");
    for node in compiled
        .nodes
        .iter()
        .filter(|node| node.node_type == "control.subflow")
    {
        let (_, revision, child) = resolve_subflow_revision(library, compiled, node)?;
        let identity = format!("{}:{}", child.package_id, revision.summary.package_digest);
        if !visited.insert(identity.clone()) {
            return Err(WorkflowExecutionError::Integrity(
                "subflow_dependency_cycle".into(),
            ));
        }
        let child_requirements =
            compiled_storage_requirements(library, &child, visited, depth + 1)?;
        visited.remove(&identity);
        requires_storage |= child_requirements.0;
        requires_case |= child_requirements.1;
    }
    Ok((requires_storage, requires_case))
}

/// Admits the policies a compiled revision may carry. Only authority policies
/// that require an owner decision are executable here, because the effect path
/// records an approval grant for every dispatch and cannot honour a policy that
/// waives one.
fn validate_compiled_policies(compiled: &CompiledWorkflow) -> Result<()> {
    if compiled.policies.len() > 256 {
        return Err(WorkflowExecutionError::Unsupported(
            "compiled_policy_count".into(),
        ));
    }
    for (key, policy) in &compiled.policies {
        let policy: CompiledAuthorityPolicy = serde_json::from_value(policy.clone())
            .map_err(|_| WorkflowExecutionError::Unsupported("policy_not_executable".into()))?;
        if &policy.key != key
            || policy.policy_type != "authority"
            || policy.type_version != 1
            || policy.config.authority_class.is_empty()
            || policy.config.authority_class.len() > 128
            || !matches!(
                policy.config.approval.as_str(),
                "always" | "standing-grant-eligible"
            )
            // A standing grant pre-approves later effects, so it may only cover
            // an authority class the owner can undo.
            || (policy.config.approval == "standing-grant-eligible" && !policy.config.reversible)
        {
            return Err(WorkflowExecutionError::Unsupported(
                "policy_not_executable".into(),
            ));
        }
    }
    Ok(())
}

/// The exact connector package this executable slice admits, and the durable
/// connector class its intents carry.
const MAIL_CONNECTOR_PACKAGE_ID: &str = "dev.kaname.mail";

fn validate_compiled_connector_effect(
    compiled: &CompiledWorkflow,
    node: &CompiledNode,
) -> Result<()> {
    let config: ConnectorEffectConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("connector_effect_config".into()))?;
    if config.connector_class != MAIL_CONNECTOR_PACKAGE_ID
        || WorkflowMailEffectClass::from_action(&config.action).is_none()
        || !workflow_expression::executable_mapping(&config.input)
        || config.preview_contract.is_empty()
        || config.preview_contract.len() > 240
        || config.reconciliation_contract.is_empty()
        || config.reconciliation_contract.len() > 240
        || !matches!(config.idempotency.as_str(), "required" | "reconcile-only")
    {
        return Err(WorkflowExecutionError::Unsupported(
            "connector_effect_contract".into(),
        ));
    }
    if !compiled
        .dependencies
        .iter()
        .any(|dependency| dependency.kind == "connector" && dependency.id == config.connector_class)
    {
        return Err(WorkflowExecutionError::Integrity(
            "connector_effect_dependency".into(),
        ));
    }
    Ok(())
}

fn validate_compiled_subset(compiled: &CompiledWorkflow) -> Result<()> {
    compiled
        .retention
        .validate()
        .map_err(|_| WorkflowExecutionError::Integrity("compiled_retention_policy".into()))?;
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
        .is_none_or(|node| !is_executable_trigger(node.node_type.as_str()))
    {
        return Err(WorkflowExecutionError::Unsupported(
            "trigger_entrypoint_required".into(),
        ));
    }
    for node in &compiled.nodes {
        if node.type_version != 1
            || node.execution_availability != "executable"
            || node.key.is_empty()
            || node.name.is_empty()
            || node.ports.is_empty()
            || !EXECUTOR_ADMITTED_NODE_TYPES.contains(&node.node_type.as_str())
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
            || !workflow_expression::executable_mapping(&edge.mapping)
            || !nodes.contains_key(edge.from.node_id.as_str())
            || !nodes.contains_key(edge.to.node_id.as_str())
            || edge.from.port_id.is_empty()
            || edge.to.port_id.is_empty()
        {
            return Err(WorkflowExecutionError::Unsupported(
                EDGE_MAPPING_NOT_EXECUTABLE_CODE.into(),
            ));
        }
    }
    Ok(())
}

/// Validates the node and edge portion of a compiler artifact through the same
/// admission gate used when the executor loads an active revision.
pub fn validate_compiled_source_node_admission(compiled_source: &[u8]) -> Result<()> {
    let compiled: CompiledWorkflow = serde_json::from_slice(compiled_source)
        .map_err(|_| WorkflowExecutionError::Integrity("compiled_contract".into()))?;
    validate_compiled_subset(&compiled)
}

fn is_executable_trigger(node_type: &str) -> bool {
    matches!(
        node_type,
        "trigger.manual" | "trigger.event" | "trigger.schedule"
    )
}

fn event_trigger_config(node: &CompiledNode) -> Result<EventTriggerConfig> {
    let config: EventTriggerConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("event_trigger_config".into()))?;
    if config.event_contract.is_empty()
        || config.event_contract.len() > 240
        || !matches!(config.deduplication.as_str(), "event-id" | "contract-key")
        || !config.correlation.is_empty()
    {
        return Err(WorkflowExecutionError::Unsupported(
            "event_trigger_contract".into(),
        ));
    }
    Ok(config)
}

fn schedule_trigger_config(node: &CompiledNode) -> Result<ScheduleTriggerConfig> {
    let config: ScheduleTriggerConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("schedule_trigger_config".into()))?;
    if config.schedule_key.is_empty()
        || config.schedule_key.len() > 64
        || !matches!(config.misfire_policy.as_str(), "skip" | "run-once")
    {
        return Err(WorkflowExecutionError::Unsupported(
            "schedule_trigger_contract".into(),
        ));
    }
    Ok(config)
}

/// A `trigger.manual` entrypoint keeps whatever kind the host recorded, because
/// a native mail or calendar signal may still start a manual graph. An event or
/// schedule entrypoint must instead carry its own admitted trigger identity so
/// replay can attribute the run to exactly one deduplicated occurrence.
fn validate_trigger_identity(
    compiled: &CompiledWorkflow,
    request: &v1::RequestWorkflowRun,
) -> Result<()> {
    let entrypoint = compiled_node(compiled, &compiled.entrypoints[0].node_id)?;
    let required = match entrypoint.node_type.as_str() {
        "trigger.event" => EVENT_TRIGGER_KIND,
        "trigger.schedule" => SCHEDULE_TRIGGER_KIND,
        _ => return Ok(()),
    };
    if request.trigger_kind != required || request.trigger_event_id.is_empty() {
        return Err(WorkflowExecutionError::InvalidCommand(
            "trigger_identity_required",
        ));
    }
    Ok(())
}

fn resolve_subflow_revision(
    library: &WorkflowLibraryStore,
    parent: &CompiledWorkflow,
    node: &CompiledNode,
) -> Result<(SubflowConfig, WorkflowRevisionContent, CompiledWorkflow)> {
    let config: SubflowConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("subflow_config".into()))?;
    if !workflow_expression::executable_mapping(&config.input) {
        return Err(WorkflowExecutionError::Unsupported(
            "subflow_input_mapping".into(),
        ));
    }
    let pins = parent
        .dependencies
        .iter()
        .filter(|dependency| {
            dependency.kind == "subflow"
                && dependency.id == config.package_id
                && dependency.digest == config.revision_digest
        })
        .count();
    if pins != 1 {
        return Err(WorkflowExecutionError::Integrity(
            "subflow_dependency_lock".into(),
        ));
    }
    let revision = library
        .load_workflow_revision_by_package_digest(&config.package_id, &config.revision_digest)?;
    if revision.summary.execution_support != WorkflowExecutionSupport::Executable {
        return Err(WorkflowExecutionError::Unsupported(
            "subflow_revision_not_executable".into(),
        ));
    }
    let child: CompiledWorkflow = serde_json::from_slice(&revision.compiled_source)
        .map_err(|_| WorkflowExecutionError::Integrity("subflow_compiled_contract".into()))?;
    let digest = config
        .revision_digest
        .strip_prefix("sha256:")
        .unwrap_or(&config.revision_digest);
    if child.compiled_format_version != 1
        || child.package_id != config.package_id
        || child.workflow_id != revision.summary.workflow_id
        || revision.summary.package_digest != digest.to_ascii_lowercase()
        || child.entrypoints.len() != 1
        || child.entrypoints[0].key.as_deref() != Some(config.entrypoint.as_str())
        || child.entrypoints[0].id.is_empty()
        || child.entrypoints[0].node_id.is_empty()
        || !subflow_interface_is_compatible(&child, &config.entrypoint)
    {
        return Err(WorkflowExecutionError::Integrity(
            "subflow_pin_or_interface_mismatch".into(),
        ));
    }
    Ok((config, revision, child))
}

fn subflow_interface_is_compatible(compiled: &CompiledWorkflow, entrypoint: &str) -> bool {
    let Some(ports) = compiled.interfaces.get(entrypoint) else {
        return false;
    };
    let compatible = |id: &str, direction: &str, required: bool| {
        ports.iter().any(|port| {
            port.get("id").and_then(Value::as_str) == Some(id)
                && port.get("key").and_then(Value::as_str) == Some(id)
                && port.get("direction").and_then(Value::as_str) == Some(direction)
                && port.get("cardinality").and_then(Value::as_str) == Some("one")
                && port.get("schemaRef").and_then(Value::as_str)
                    == Some("dev.kaname.workflow.data/v1")
                && port.get("required").and_then(Value::as_bool) == Some(required)
        })
    };
    ports.len() == 2 && compatible("input", "input", true) && compatible("success", "output", true)
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
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    package: &ExecutionPackage,
    mut storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    effects: &mut dyn WorkflowEffectHost,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
    now_unix_millis: i64,
    prepared_episode: Option<&v1::EventEnvelope>,
    subflow_depth: usize,
    job_run_id: &str,
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
                retention_policy: Some(package.compiled.retention.as_proto()),
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
            let invocation_id = stable_id(
                "subflow",
                &[
                    &request.run_id,
                    &active.started.attempt_id,
                    &active.started.node_id,
                ],
            );
            if let Some(recorded) = state
                .subflows
                .get(&invocation_id)
                .filter(|recorded| recorded.settled.is_none())
            {
                cascade_subflow_cancellation(
                    journal,
                    library,
                    storage.as_deref_mut(),
                    authority,
                    capabilities,
                    llm,
                    effects,
                    command,
                    request,
                    recorded,
                    cancellation,
                    now_unix_millis,
                    subflow_depth,
                    job_run_id,
                )?;
                return Ok(vec![subflow_settled_event(
                    journal, command, request, token_id, recorded,
                )?]);
            }
            if let Some(recorded) = state.capability_attempts.values().find(|recorded| {
                recorded.started.attempt_id == active.started.attempt_id
                    && recorded.settled.is_none()
            }) {
                let elapsed = cancellation_time(state, command.submitted_at_unix_millis)
                    .saturating_sub(recorded.started_at_unix_millis)
                    .max(0) as u64;
                return Ok(vec![capability_settled_event(
                    recorded,
                    command,
                    request,
                    token_id,
                    v1::WorkflowCapabilityAttemptOutcome::Cancelled,
                    None,
                    Vec::new(),
                    &cancellation.reason_code,
                    None,
                    Vec::new(),
                    elapsed,
                    String::new(),
                    String::new(),
                )]);
            }
            if let Some(recorded) = state.llm_attempts.values().find(|recorded| {
                recorded.started.attempt_id == active.started.attempt_id
                    && recorded.settled.is_none()
            }) {
                let elapsed = cancellation_time(state, command.submitted_at_unix_millis)
                    .saturating_sub(recorded.started_at_unix_millis)
                    .max(0) as u64;
                return Ok(vec![llm_settled_event(
                    recorded,
                    request,
                    token_id,
                    v1::WorkflowLlmAttemptOutcome::Cancelled,
                    None,
                    &cancellation.reason_code,
                    None,
                    elapsed,
                    String::new(),
                    String::new(),
                    AdmittedLlmTrace::default(),
                    None,
                )]);
            }
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
            journal,
            library,
            package,
            storage,
            authority,
            capabilities,
            llm,
            effects,
            command,
            request,
            token_id,
            state,
            active,
            now_unix_millis,
            subflow_depth,
            job_run_id,
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
/// Applies a mapping to a flowing value. `whole` passes the value through
/// untouched. Evaluation failures come back as the inner `Err` so callers can
/// route them to the node's error port instead of failing the run.
fn apply_mapping(
    mapping: &Value,
    value: &v1::WorkflowValueReference,
    mapped_value_id: &str,
) -> Result<
    std::result::Result<v1::WorkflowValueReference, workflow_expression::ExpressionEvaluationError>,
> {
    if mapping == &json!({"whole": true}) {
        return Ok(Ok(value.clone()));
    }
    let input = inline_json(value)?;
    match workflow_expression::evaluate(mapping, &ExpressionRoots::with_input(input)) {
        Ok(result) => Ok(Ok(value_from_json(mapped_value_id, &result)?)),
        Err(error) => Ok(Err(error)),
    }
}

fn mapping_failure_value(
    request: &v1::RequestWorkflowRun,
    node_id: &str,
    context: &str,
    error: &workflow_expression::ExpressionEvaluationError,
) -> Result<v1::WorkflowValueReference> {
    value_from_json(
        &stable_id(
            "value",
            &[&request.run_id, node_id, context, "mapping-error"],
        ),
        &json!({
            "code": error.code,
            "context": context,
            "expressionPath": error.expression_path,
            "message": error.message,
        }),
    )
}

/// The node-config mapping the executor evaluates against the node's input
/// before the node runs, if the node type declares one.
fn node_config_mapping(node: &CompiledNode) -> Option<&Value> {
    let field = match node.node_type.as_str() {
        "compute.capability" | "control.subflow" | "effect.connector" => "input",
        "compute.llm" => "prompt",
        "control.human-review" => "proposal",
        _ => return None,
    };
    node.config.get(field)
}

#[allow(clippy::type_complexity)]
fn mapped_node_inputs<'a>(
    package: &ExecutionPackage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    raw_inputs: Vec<(
        Option<&'a v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )>,
) -> Result<(
    Vec<(
        Option<&'a v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )>,
    Option<(String, v1::WorkflowValueReference)>,
)> {
    let mut inputs = Vec::with_capacity(raw_inputs.len());
    for (edge, value) in raw_inputs {
        let mapped = match edge {
            Some(payload) => {
                let compiled_edge = package
                    .compiled
                    .edges
                    .iter()
                    .find(|candidate| candidate.id == payload.edge_id)
                    .ok_or_else(|| WorkflowExecutionError::Integrity("edge_identity".into()))?;
                match apply_mapping(
                    &compiled_edge.mapping,
                    &value,
                    &stable_id(
                        "value",
                        &[
                            &request.run_id,
                            &payload.edge_id,
                            &payload.emission_id,
                            "mapped",
                        ],
                    ),
                )? {
                    Ok(mapped) => mapped,
                    Err(error) => {
                        let failure = mapping_failure_value(
                            request,
                            &node.id,
                            &format!("edge:{}", payload.edge_id),
                            &error,
                        )?;
                        inputs.push((edge, value));
                        return Ok((inputs, Some((error.code, failure))));
                    }
                }
            }
            None => value,
        };
        inputs.push((edge, mapped));
    }
    if let Some(mapping) = node_config_mapping(node)
        && mapping != &json!({"whole": true})
        && let Some((_, input)) = inputs.last()
        && let Err(error) = workflow_expression::evaluate(
            mapping,
            &ExpressionRoots::with_input(inline_json(input)?),
        )
    {
        let failure = mapping_failure_value(request, &node.id, "config", &error)?;
        return Ok((inputs, Some((error.code, failure))));
    }
    Ok((inputs, None))
}

#[allow(clippy::too_many_arguments)]
fn node_event_sequence(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    package: &ExecutionPackage,
    mut storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    effects: &mut dyn WorkflowEffectHost,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    now_unix_millis: i64,
    subflow_depth: usize,
    job_run_id: &str,
) -> Result<Vec<v1::EventEnvelope>> {
    let node = compiled_node(&package.compiled, &attempt.started.node_id)?;
    let raw_inputs = node_inputs(
        request,
        state,
        &node.id,
        &attempt.started.execution_token_id,
    )?;
    let (inputs, mapping_failure) = mapped_node_inputs(package, request, node, raw_inputs)?;
    if mapping_failure.is_none()
        && node.node_type == "control.subflow"
        && let Some(events) = pending_subflow_event_sequence(
            journal,
            library,
            package,
            storage.as_deref_mut(),
            authority,
            capabilities,
            llm,
            effects,
            command,
            request,
            token_id,
            state,
            attempt,
            node,
            &inputs,
            now_unix_millis,
            subflow_depth,
            job_run_id,
        )?
    {
        return Ok(events);
    }
    if mapping_failure.is_none()
        && node.node_type == "compute.capability"
        && let Some(events) = pending_capability_event_sequence(
            package,
            capabilities,
            command,
            request,
            token_id,
            state,
            attempt,
            node,
            &inputs,
        )?
    {
        return Ok(events);
    }
    if mapping_failure.is_none()
        && node.node_type == "compute.llm"
        && let Some(events) = pending_llm_event_sequence(
            package, llm, request, token_id, state, attempt, node, &inputs,
        )?
    {
        return Ok(events);
    }
    if mapping_failure.is_none()
        && node.node_type == "effect.connector"
        && let Some(events) = pending_effect_event_sequence(
            effects, request, token_id, state, attempt, node, &inputs,
        )?
    {
        return Ok(events);
    }
    if mapping_failure.is_none()
        && node.node_type == "control.for-each"
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
    if mapping_failure.is_none() && node.node_type == "control.retry" {
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
    if mapping_failure.is_none() && node.node_type == "control.wait" {
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
    if mapping_failure.is_none() && node.node_type == "control.human-review" {
        return human_review_controller_event_sequence(
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
    let execution = if let Some((code, value)) = mapping_failure {
        failure_output("error", &code, value)
    } else if node.node_type == "compute.capability" {
        execute_settled_capability_node(request, state, attempt, node)?
    } else if node.node_type == "compute.llm" {
        execute_settled_llm_node(request, state, attempt, node)?
    } else if node.node_type == "effect.connector" {
        execute_settled_effect_node(request, state, attempt, node, &inputs)?
    } else if node.node_type == "control.subflow" {
        execute_settled_subflow_node(request, state, attempt, node)?
    } else if node.node_type == "control.join" {
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
                job_run_id,
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
    let match_fan_out = node.node_type == "control.match" && execution.outputs.len() > 1;
    for (port_id, value) in execution.outputs {
        let emission_id = stable_id(
            "emission",
            &[&request.run_id, &attempt.started.attempt_id, &port_id],
        );
        let edge_execution_token_id = if match_fan_out {
            let branch_id = port_id
                .strip_prefix("case-")
                .ok_or_else(|| WorkflowExecutionError::Integrity("match_case_port".into()))?
                .to_owned();
            let child_token_id = stable_id(
                "execution-token",
                &[&request.run_id, execution_token_id, &node.id, &branch_id],
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
                    branch_id,
                    branch_port_id: port_id.clone(),
                    join_node_id: String::new(),
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
        } else if node.node_type == "control.parallel" {
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

/// Human review is a wait whose correlation pins the authority policy and the
/// exact proposal an approver saw, so a late or re-proposed decision cannot
/// resume the run silently.
#[allow(clippy::too_many_arguments)]
fn human_review_controller_event_sequence(
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
    let config: HumanReviewConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("human_review_config".into()))?;
    let input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("review_input_missing".into()))?
        .1
        .clone();
    let proposal = apply_mapping(
        &config.proposal,
        &input,
        &stable_id(
            "value",
            &[
                &request.run_id,
                &node.id,
                &attempt.started.attempt_id,
                "proposal",
            ],
        ),
    )?
    .map_err(|_| WorkflowExecutionError::Integrity("review_proposal_mapping".into()))?;
    let proposal_digest = canonical_sha256(&inline_json(&proposal)?)?;
    let correlation = review_correlation(&config, &proposal_digest)?;
    let (owner_kind, owner_id) = wait_owner(request);
    let subscription_id = stable_id(
        "review",
        &[&request.run_id, &node.id, &attempt.started.attempt_id],
    );
    let Some(recorded) = state.waits.get(&subscription_id) else {
        let expiry_millis = config
            .expiry_seconds
            .checked_mul(1_000)
            .and_then(|value| i64::try_from(value).ok())
            .and_then(|value| attempt.started_at_unix_millis.checked_add(value))
            .ok_or_else(|| WorkflowExecutionError::Integrity("review_deadline_overflow".into()))?;
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
                kind: REVIEW_WAIT_KIND.into(),
                owner_kind,
                owner_id,
                correlation,
                input_value_id: proposal.value_id,
                input_sha256: proposal.sha256,
                expires_at_unix_millis: expiry_millis,
            },
            &attempt.started_event_id,
            &request.run_id,
        )]);
    };
    if recorded.subscribed.run_token_id != run_token_id
        || recorded.subscribed.wait_node_id != node.id
        || recorded.subscribed.execution_token_id != attempt.started.execution_token_id
        || recorded.subscribed.controller_attempt_id != attempt.started.attempt_id
        || recorded.subscribed.workflow_id != request.workflow_id
        || recorded.subscribed.revision_id != request.revision_id
        || recorded.subscribed.package_digest != request.package_digest
        || recorded.subscribed.kind != REVIEW_WAIT_KIND
        || recorded.subscribed.owner_kind != owner_kind
        || recorded.subscribed.owner_id != owner_id
        || recorded.subscribed.correlation != correlation
        || recorded.subscribed.input_value_id != proposal.value_id
        || recorded.subscribed.input_sha256 != proposal.sha256
    {
        return Err(WorkflowExecutionError::Integrity("review_pin_drift".into()));
    }
    if let Some(resolved) = recorded.resolved.as_ref() {
        let resolved_event_id = recorded
            .resolved_event_id
            .as_deref()
            .ok_or_else(|| WorkflowExecutionError::Integrity("review_event_id".into()))?;
        let decision = v1::WorkflowWaitDecision::try_from(resolved.decision)
            .map_err(|_| WorkflowExecutionError::Integrity("review_decision".into()))?;
        let (port_id, outcome, error_code, value) = match decision {
            v1::WorkflowWaitDecision::Resumed => review_outcome(
                request,
                node,
                &config,
                &proposal,
                &proposal_digest,
                resolved
                    .output
                    .as_ref()
                    .ok_or_else(|| WorkflowExecutionError::Integrity("review_output".into()))?,
            )?,
            v1::WorkflowWaitDecision::Expired => (
                "error",
                v1::WorkflowAttemptOutcome::Failed,
                "review.expired",
                value_from_json(
                    &stable_id("value", &[&request.run_id, &node.id, "review-expired"]),
                    &json!({
                        "code": "review.expired",
                        "authorityPolicy": config.authority_policy,
                        "proposalDigest": proposal_digest,
                        "expiredAtUnixMillis": recorded.subscribed.expires_at_unix_millis
                    }),
                )?,
            ),
            v1::WorkflowWaitDecision::Cancelled => {
                return Err(WorkflowExecutionError::Lifecycle(
                    "cancelled_wait_without_run_cancellation".into(),
                ));
            }
            v1::WorkflowWaitDecision::Unspecified => {
                return Err(WorkflowExecutionError::Integrity("review_decision".into()));
            }
        };
        return controller_settled_events(
            &package.compiled,
            command,
            request,
            run_token_id,
            attempt,
            node,
            port_id,
            value,
            outcome,
            error_code.into(),
            resolved_event_id,
        );
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
    let output = value_from_json(
        &stable_id("value", &[&request.run_id, &subscription_id, "expired"]),
        &json!({
            "kind": REVIEW_WAIT_KIND,
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

fn review_correlation(
    config: &HumanReviewConfig,
    proposal_digest: &str,
) -> Result<Vec<v1::WorkflowWaitCorrelation>> {
    let mut correlation = [
        (
            "review:/authorityPolicy",
            json!(config.authority_policy.clone()),
        ),
        ("review:/proposalDigest", json!(proposal_digest)),
    ]
    .into_iter()
    .map(|(key, value)| {
        Ok(v1::WorkflowWaitCorrelation {
            key: key.into(),
            sha256: canonical_sha256(&value)?,
        })
    })
    .collect::<Result<Vec<_>>>()?;
    correlation.sort_by(|left, right| left.key.cmp(&right.key));
    Ok(correlation)
}

/// Maps an approver's signal onto the review ports. A stale proposal digest
/// beats the decision itself: a decision made against a superseded proposal
/// never approves.
fn review_outcome(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    config: &HumanReviewConfig,
    proposal: &v1::WorkflowValueReference,
    proposal_digest: &str,
    signal: &v1::WorkflowValueReference,
) -> Result<(
    &'static str,
    v1::WorkflowAttemptOutcome,
    &'static str,
    v1::WorkflowValueReference,
)> {
    let signal = inline_json(signal)?;
    let decision = signal
        .get("decision")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let signalled_digest = signal.get("proposalDigest").and_then(Value::as_str);
    let stale = config.stale_check == "digest"
        && signalled_digest.is_some_and(|digest| digest != proposal_digest);
    let code = if stale {
        "review.stale"
    } else {
        match decision {
            "approve" => {
                return Ok((
                    "success",
                    v1::WorkflowAttemptOutcome::Succeeded,
                    "",
                    proposal.clone(),
                ));
            }
            "reject" => "review.rejected",
            _ => "review.decision-invalid",
        }
    };
    let value = value_from_json(
        &stable_id("value", &[&request.run_id, &node.id, code]),
        &json!({
            "code": code,
            "decision": decision,
            "authorityPolicy": config.authority_policy,
            "proposalDigest": proposal_digest,
            "signalledProposalDigest": signalled_digest
        }),
    )?;
    Ok(("error", v1::WorkflowAttemptOutcome::Failed, code, value))
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
    controller_settled_events(
        compiled,
        command,
        request,
        run_token_id,
        attempt,
        node,
        port_id,
        value,
        v1::WorkflowAttemptOutcome::Succeeded,
        String::new(),
        causation_id,
    )
}

#[allow(clippy::too_many_arguments)]
fn controller_settled_events(
    compiled: &CompiledWorkflow,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    port_id: &str,
    value: v1::WorkflowValueReference,
    outcome: v1::WorkflowAttemptOutcome,
    error_code: String,
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
    let settled_error = (outcome == v1::WorkflowAttemptOutcome::Failed).then(|| value.clone());
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
                outcome: outcome as i32,
                error: settled_error,
                error_code,
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
fn pending_subflow_event_sequence(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    package: &ExecutionPackage,
    storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    effects: &mut dyn WorkflowEffectHost,
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
    subflow_depth: usize,
    job_run_id: &str,
) -> Result<Option<Vec<v1::EventEnvelope>>> {
    let invocation_id = stable_id(
        "subflow",
        &[&request.run_id, &attempt.started.attempt_id, &node.id],
    );
    let Some(recorded) = state.subflows.get(&invocation_id) else {
        let edge_input = inputs
            .last()
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("subflow_input_missing".into()))?
            .1
            .clone();
        let (config, child_revision, _) =
            resolve_subflow_revision(library, &package.compiled, node)?;
        let input = apply_mapping(
            &config.input,
            &edge_input,
            &stable_id(
                "value",
                &[
                    &request.run_id,
                    &attempt.started.attempt_id,
                    "subflow-input",
                ],
            ),
        )?
        .map_err(|_| WorkflowExecutionError::Integrity("subflow_input_mapping".into()))?;
        let child_run_id = stable_id("run", &[&request.run_id, &invocation_id, "child"]);
        let child_command_id = stable_id("command", &[&child_run_id, "request"]);
        let event_id = stable_id(
            "event",
            &[&request.run_id, "subflow-called", &invocation_id],
        );
        return Ok(Some(vec![runtime_event(
            command.submitted_at_unix_millis,
            &event_id,
            workflow_runtime::WORKFLOW_SUBFLOW_CALLED_KIND,
            workflow_runtime::WORKFLOW_SUBFLOW_CALLED_TYPE,
            v1::WorkflowSubflowCalled {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                invocation_id,
                attempt_id: attempt.started.attempt_id.clone(),
                execution_token_id: attempt.started.execution_token_id.clone(),
                node_id: node.id.clone(),
                child_run_id,
                child_command_id,
                child_workflow_id: child_revision.summary.workflow_id,
                child_revision_id: child_revision.summary.revision_id,
                child_package_id: config.package_id,
                child_package_digest: child_revision.summary.package_digest,
                entrypoint: config.entrypoint,
                input: Some(input),
            },
            &attempt.started_event_id,
            &request.run_id,
        )]));
    };
    validate_recorded_subflow_call(request, run_token_id, attempt, node, recorded)?;
    if recorded.settled.is_some() {
        return Ok(None);
    }

    let child_command = subflow_child_command(command, request, &recorded.called)?;
    let child_result = execute_internal(
        journal,
        library,
        storage,
        authority,
        capabilities,
        llm,
        effects,
        &child_command,
        now_unix_millis,
        None,
        subflow_depth + 1,
        Some(job_run_id),
    )?;
    if child_result.outcome == DurableRunOutcome::Waiting {
        return Err(WorkflowExecutionError::WaitingUntil(
            child_result
                .next_attempt_at_unix_millis
                .ok_or_else(|| WorkflowExecutionError::Integrity("subflow_wait_deadline".into()))?,
        ));
    }
    if child_result.outcome == DurableRunOutcome::Running {
        return Err(WorkflowExecutionError::Lifecycle(
            "subflow_transition_limit".into(),
        ));
    }
    Ok(Some(vec![subflow_settled_event(
        journal,
        command,
        request,
        run_token_id,
        recorded,
    )?]))
}

fn subflow_settled_event(
    journal: &Journal,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    recorded: &RecordedSubflow,
) -> Result<v1::EventEnvelope> {
    let child_state = recorded_run(journal, &recorded.called.child_run_id)?;
    let child_settled = child_state
        .settled
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("subflow_child_not_settled".into()))?;
    let outcome = v1::WorkflowRunOutcome::try_from(child_settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("subflow_child_outcome".into()))?;
    let (output, error_code, error) = match outcome {
        v1::WorkflowRunOutcome::Succeeded => (
            Some(subflow_success_value(&child_state, child_settled)?),
            String::new(),
            None,
        ),
        v1::WorkflowRunOutcome::Failed | v1::WorkflowRunOutcome::Cancelled => {
            let error_code = if child_settled.error_code.is_empty() {
                "subflow.cancelled".to_owned()
            } else {
                child_settled.error_code.clone()
            };
            let error = child_settled.error.clone().or_else(|| {
                value_from_json(
                    &stable_id(
                        "value",
                        &[&request.run_id, &recorded.called.invocation_id, "error"],
                    ),
                    &json!({
                        "code": error_code,
                        "childRunId": recorded.called.child_run_id,
                        "childRevisionId": recorded.called.child_revision_id
                    }),
                )
                .ok()
            });
            (None, error_code, error)
        }
        v1::WorkflowRunOutcome::Unspecified => {
            return Err(WorkflowExecutionError::Integrity(
                "subflow_child_outcome".into(),
            ));
        }
    };
    let error = if outcome == v1::WorkflowRunOutcome::Succeeded {
        None
    } else {
        Some(error.ok_or_else(|| WorkflowExecutionError::Encoding("subflow_error"))?)
    };
    let event_id = stable_id(
        "event",
        &[
            &request.run_id,
            "subflow-settled",
            &recorded.called.invocation_id,
        ],
    );
    Ok(runtime_event(
        command.submitted_at_unix_millis,
        &event_id,
        workflow_runtime::WORKFLOW_SUBFLOW_SETTLED_KIND,
        workflow_runtime::WORKFLOW_SUBFLOW_SETTLED_TYPE,
        v1::WorkflowSubflowSettled {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            invocation_id: recorded.called.invocation_id.clone(),
            child_run_id: recorded.called.child_run_id.clone(),
            outcome: outcome as i32,
            output,
            error_code,
            error,
            child_final_emission_ids: child_settled.final_emission_ids.clone(),
        },
        child_state
            .events
            .last()
            .map(|event| event.event_id.as_str())
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("subflow_child_event".into()))?,
        &request.run_id,
    ))
}

#[allow(clippy::too_many_arguments)]
fn cascade_subflow_cancellation(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    mut storage: Option<&mut WorkflowScopedStorage>,
    authority: Option<&WorkflowStorageExecutionAuthority>,
    capabilities: &mut dyn WorkflowCapabilityHost,
    llm: &mut dyn WorkflowLlmProvider,
    effects: &mut dyn WorkflowEffectHost,
    parent_command: &v1::CommandEnvelope,
    parent_request: &v1::RequestWorkflowRun,
    recorded: &RecordedSubflow,
    cancellation: &v1::WorkflowRunCancellationRequested,
    now_unix_millis: i64,
    subflow_depth: usize,
    job_run_id: &str,
) -> Result<()> {
    let child_command = subflow_child_command(parent_command, parent_request, &recorded.called)?;
    let mut child_state = recorded_run(journal, &recorded.called.child_run_id)?;
    if child_state.token.is_none() {
        execute_internal(
            journal,
            library,
            storage.as_deref_mut(),
            authority,
            capabilities,
            llm,
            effects,
            &child_command,
            now_unix_millis,
            None,
            subflow_depth + 1,
            Some(job_run_id),
        )?;
        child_state = recorded_run(journal, &recorded.called.child_run_id)?;
    }
    if child_state.settled.is_some() {
        return Ok(());
    }
    let child_token_id = child_state
        .token
        .as_ref()
        .map(|token| token.run_token_id.clone())
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("subflow_child_token_missing".into()))?;
    if child_state.cancellation.is_none() {
        request_cancellation(
            journal,
            &subflow_child_cancel_command(
                parent_command,
                &recorded.called,
                &child_token_id,
                cancellation,
            ),
        )?;
    }
    let result = execute_internal(
        journal,
        library,
        storage,
        authority,
        capabilities,
        llm,
        effects,
        &child_command,
        now_unix_millis,
        None,
        subflow_depth + 1,
        Some(job_run_id),
    )?;
    if matches!(
        result.outcome,
        DurableRunOutcome::Running | DurableRunOutcome::Waiting
    ) {
        return Err(WorkflowExecutionError::Lifecycle(
            "subflow_child_cancellation_incomplete".into(),
        ));
    }
    Ok(())
}

fn subflow_child_cancel_command(
    parent_command: &v1::CommandEnvelope,
    called: &v1::WorkflowSubflowCalled,
    child_token_id: &str,
    cancellation: &v1::WorkflowRunCancellationRequested,
) -> v1::CommandEnvelope {
    let command_id = stable_id(
        "command",
        &[
            &called.child_run_id,
            "cancel",
            &cancellation.cancel_command_id,
        ],
    );
    v1::CommandEnvelope {
        schema_version: Some(v1::SchemaVersion { major: 1, minor: 0 }),
        command_id: command_id.clone(),
        idempotency_key: stable_id("idempotency", &[&command_id]),
        kind: workflow_runtime::WORKFLOW_RUN_CANCEL_KIND.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: workflow_runtime::WORKFLOW_RUN_CANCEL_TYPE.into(),
            content_type: "application/x-protobuf".into(),
            value: v1::CancelWorkflowRun {
                run_id: called.child_run_id.clone(),
                run_token_id: child_token_id.to_owned(),
                reason_code: cancellation.reason_code.clone(),
            }
            .encode_to_vec(),
            payload_version: 1,
        }),
        scope: parent_command.scope.clone(),
        actor_id: parent_command.actor_id.clone(),
        expected_revision: 0,
        submitted_at_unix_millis: parent_command.submitted_at_unix_millis,
    }
}

fn validate_recorded_subflow_call(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    recorded: &RecordedSubflow,
) -> Result<()> {
    if recorded.called.run_id != request.run_id
        || recorded.called.run_token_id != run_token_id
        || recorded.called.attempt_id != attempt.started.attempt_id
        || recorded.called.execution_token_id != attempt.started.execution_token_id
        || recorded.called.node_id != node.id
        || recorded.called.input.is_none()
    {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_subflow_call_mismatch".into(),
        ));
    }
    Ok(())
}

fn subflow_child_command(
    parent_command: &v1::CommandEnvelope,
    parent_request: &v1::RequestWorkflowRun,
    called: &v1::WorkflowSubflowCalled,
) -> Result<v1::CommandEnvelope> {
    let input = called
        .input
        .clone()
        .ok_or_else(|| WorkflowExecutionError::Integrity("subflow_input_missing".into()))?;
    Ok(v1::CommandEnvelope {
        schema_version: Some(v1::SchemaVersion { major: 1, minor: 0 }),
        command_id: called.child_command_id.clone(),
        idempotency_key: stable_id("idempotency", &[&called.child_command_id]),
        kind: workflow_runtime::WORKFLOW_RUN_REQUEST_KIND.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: workflow_runtime::WORKFLOW_RUN_REQUEST_TYPE.into(),
            content_type: "application/x-protobuf".into(),
            value: v1::RequestWorkflowRun {
                run_id: called.child_run_id.clone(),
                workflow_id: called.child_workflow_id.clone(),
                revision_id: called.child_revision_id.clone(),
                package_digest: called.child_package_digest.clone(),
                trigger_kind: "workflow.subflow".into(),
                trigger_event_id: called.invocation_id.clone(),
                inputs: vec![v1::WorkflowInputBinding {
                    port_id: "input".into(),
                    value: Some(input),
                }],
                installation_id: parent_request.installation_id.clone(),
                case_id: parent_request.case_id.clone(),
                episode_id: String::new(),
                episode_kind: String::new(),
                prior_episode_id: String::new(),
            }
            .encode_to_vec(),
            payload_version: 1,
        }),
        scope: parent_command.scope.clone(),
        actor_id: parent_command.actor_id.clone(),
        expected_revision: 0,
        submitted_at_unix_millis: parent_command.submitted_at_unix_millis,
    })
}

fn subflow_success_value(
    child_state: &RecordedRun,
    settled: &v1::WorkflowRunSettled,
) -> Result<v1::WorkflowValueReference> {
    if settled.final_emission_ids.len() != 1 {
        return Err(WorkflowExecutionError::Integrity(
            "subflow_output_cardinality".into(),
        ));
    }
    child_state
        .emissions
        .get(&settled.final_emission_ids[0])
        .and_then(|emission| emission.payload.value.clone())
        .ok_or_else(|| WorkflowExecutionError::Integrity("subflow_output_missing".into()))
}

fn execute_settled_subflow_node(
    request: &v1::RequestWorkflowRun,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> Result<NodeExecution> {
    let invocation_id = stable_id(
        "subflow",
        &[&request.run_id, &attempt.started.attempt_id, &node.id],
    );
    let settled = state
        .subflows
        .get(&invocation_id)
        .and_then(|recorded| recorded.settled.as_ref())
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("subflow_not_settled".into()))?;
    match v1::WorkflowRunOutcome::try_from(settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("subflow_outcome".into()))?
    {
        v1::WorkflowRunOutcome::Succeeded => Ok(success_output(
            "success",
            settled
                .output
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("subflow_output".into()))?,
        )),
        v1::WorkflowRunOutcome::Failed | v1::WorkflowRunOutcome::Cancelled => Ok(failure_output(
            "error",
            &settled.error_code,
            settled
                .error
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("subflow_error".into()))?,
        )),
        v1::WorkflowRunOutcome::Unspecified => {
            Err(WorkflowExecutionError::Integrity("subflow_outcome".into()))
        }
    }
}

fn pending_capability_event_sequence(
    package: &ExecutionPackage,
    capabilities: &mut dyn WorkflowCapabilityHost,
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
) -> Result<Option<Vec<v1::EventEnvelope>>> {
    let invocation_id = capability_invocation_id(request, attempt, node);
    let edge_input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("capability_input_missing".into()))?
        .1
        .clone();
    let (config, dependency, definition) =
        resolve_capability_definition(package, capabilities, node)?;
    let input = apply_mapping(
        &config.input,
        &edge_input,
        &stable_id(
            "value",
            &[
                &request.run_id,
                &attempt.started.attempt_id,
                "capability-input",
            ],
        ),
    )?
    .map_err(|_| WorkflowExecutionError::Integrity("capability_input_mapping".into()))?;
    let Some(recorded) = state.capability_attempts.get(&invocation_id) else {
        let configuration = capability_configuration(&config)?;
        let configuration_value = value_from_json(
            &stable_id(
                "value",
                &[
                    &request.run_id,
                    &attempt.started.attempt_id,
                    "capability-configuration",
                ],
            ),
            &configuration,
        )?;
        let event_id = stable_id(
            "event",
            &[&request.run_id, "capability-started", &invocation_id],
        );
        let timeout_milliseconds = definition.timeout_milliseconds;
        let deadline_unix_millis = attempt
            .started_at_unix_millis
            .checked_add(timeout_milliseconds as i64)
            .ok_or_else(|| WorkflowExecutionError::Encoding("capability_deadline"))?;
        return Ok(Some(vec![runtime_event(
            attempt.started_at_unix_millis,
            &event_id,
            workflow_runtime::WORKFLOW_CAPABILITY_ATTEMPT_STARTED_KIND,
            workflow_runtime::WORKFLOW_CAPABILITY_ATTEMPT_STARTED_TYPE,
            v1::WorkflowCapabilityAttemptStarted {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                invocation_id,
                attempt_id: attempt.started.attempt_id.clone(),
                execution_token_id: attempt.started.execution_token_id.clone(),
                node_id: node.id.clone(),
                capability_id: config.capability_id,
                version: config.version,
                package_digest: dependency.digest,
                configuration_contract_digest: schema_digest(&definition.configuration_schema)?,
                input_schema_digest: schema_digest(&definition.input_schema)?,
                output_schema_digest: schema_digest(&definition.output_schema)?,
                output_schema_ref: config.output_schema_ref,
                configuration: Some(configuration_value),
                input: Some(input.clone()),
                artifact_inputs: artifact_handles_from_value(&input, "input"),
                timeout_milliseconds,
                deadline_unix_millis,
            },
            &attempt.started_event_id,
            &request.run_id,
        )]));
    };
    validate_recorded_capability_attempt(
        request,
        run_token_id,
        attempt,
        node,
        &input,
        &config,
        &dependency,
        &definition,
        recorded,
    )?;
    if recorded.settled.is_some() {
        return Ok(None);
    }

    let input_instance = capability_value_instance(&input)?;
    let validation = workflow_schema::check(&WorkflowSchemaCheckRequest {
        schema: definition.input_schema.clone(),
        instance: input_instance,
    });
    if validation.outcome != WorkflowSchemaCheckOutcome::Valid {
        let error = capability_error_value(
            request,
            &invocation_id,
            "capability.input-validation-failed",
            "The capability input did not match its registered schema.",
            Some(json!({
                "diagnostics": validation.diagnostics,
                "diagnosticsTruncated": validation.diagnostics_truncated
            })),
        )?;
        return Ok(Some(vec![capability_settled_event(
            recorded,
            command,
            request,
            run_token_id,
            v1::WorkflowCapabilityAttemptOutcome::InputValidationFailed,
            None,
            Vec::new(),
            "capability.input-validation-failed",
            Some(error),
            Vec::new(),
            0,
            String::new(),
            String::new(),
        )]));
    }

    let configuration = capability_configuration(&config)?;
    let invocation = WorkflowCapabilityInvocation {
        invocation_id: invocation_id.clone(),
        run_id: request.run_id.clone(),
        attempt_id: attempt.started.attempt_id.clone(),
        node_id: node.id.clone(),
        capability_id: config.capability_id,
        version: config.version,
        package_digest: dependency.digest,
        configuration,
        input,
        artifact_inputs: capability_artifact_inputs(&recorded.started.artifact_inputs),
        timeout_milliseconds: definition.timeout_milliseconds,
    };
    let result = capabilities.invoke(&invocation);
    Ok(Some(vec![capability_host_result_event(
        request,
        run_token_id,
        command,
        recorded,
        &definition,
        result,
    )?]))
}

#[allow(clippy::too_many_arguments)]
fn validate_recorded_capability_attempt(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    input: &v1::WorkflowValueReference,
    config: &CapabilityConfig,
    dependency: &CompiledDependency,
    definition: &WorkflowCapabilityDefinition,
    recorded: &RecordedCapabilityAttempt,
) -> Result<()> {
    let configuration = capability_configuration(config)?;
    let configuration_value = value_from_json(
        &stable_id(
            "value",
            &[
                &request.run_id,
                &attempt.started.attempt_id,
                "capability-configuration",
            ],
        ),
        &configuration,
    )?;
    if recorded.started.run_id != request.run_id
        || recorded.started.run_token_id != run_token_id
        || recorded.started.attempt_id != attempt.started.attempt_id
        || recorded.started.execution_token_id != attempt.started.execution_token_id
        || recorded.started.node_id != node.id
        || recorded.started.capability_id != config.capability_id
        || recorded.started.version != config.version
        || recorded.started.package_digest != dependency.digest
        || recorded.started.configuration_contract_digest
            != schema_digest(&definition.configuration_schema)?
        || recorded.started.input_schema_digest != schema_digest(&definition.input_schema)?
        || recorded.started.output_schema_digest != schema_digest(&definition.output_schema)?
        || recorded.started.output_schema_ref != config.output_schema_ref
        || recorded.started.configuration.as_ref() != Some(&configuration_value)
        || recorded.started.input.as_ref() != Some(input)
        || recorded.started.timeout_milliseconds != definition.timeout_milliseconds
        || recorded.started.deadline_unix_millis
            != recorded
                .started_at_unix_millis
                .checked_add(definition.timeout_milliseconds as i64)
                .ok_or_else(|| WorkflowExecutionError::Encoding("capability_deadline"))?
    {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_capability_pin_mismatch".into(),
        ));
    }
    Ok(())
}

fn capability_host_result_event(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    command: &v1::CommandEnvelope,
    recorded: &RecordedCapabilityAttempt,
    definition: &WorkflowCapabilityDefinition,
    result: WorkflowCapabilityHostResult,
) -> Result<v1::EventEnvelope> {
    let invocation_id = recorded.started.invocation_id.as_str();
    match result {
        WorkflowCapabilityHostResult::Succeeded {
            output,
            artifacts,
            logs,
            elapsed_milliseconds,
            receipt_id,
            provider_run_reference,
        } if elapsed_milliseconds <= definition.timeout_milliseconds => {
            let output = capability_output_value(request, invocation_id, output)?;
            let report = workflow_schema::check(&WorkflowSchemaCheckRequest {
                schema: definition.output_schema.clone(),
                instance: capability_value_instance(&output)?,
            });
            if report.outcome != WorkflowSchemaCheckOutcome::Valid {
                let error = capability_error_value(
                    request,
                    invocation_id,
                    "capability.output-validation-failed",
                    "The capability output did not match its registered schema.",
                    Some(json!({
                        "diagnostics": report.diagnostics,
                        "diagnosticsTruncated": report.diagnostics_truncated
                    })),
                )?;
                return Ok(capability_settled_event(
                    recorded,
                    command,
                    request,
                    run_token_id,
                    v1::WorkflowCapabilityAttemptOutcome::OutputValidationFailed,
                    None,
                    Vec::new(),
                    "capability.output-validation-failed",
                    Some(error),
                    capability_logs(logs, elapsed_milliseconds),
                    elapsed_milliseconds,
                    normalized_receipt_id(&receipt_id, invocation_id),
                    String::new(),
                ));
            }
            let artifacts = capability_artifact_outputs(artifacts)?;
            Ok(capability_settled_event(
                recorded,
                command,
                request,
                run_token_id,
                v1::WorkflowCapabilityAttemptOutcome::Succeeded,
                Some(output),
                artifacts,
                "",
                None,
                capability_logs(logs, elapsed_milliseconds),
                elapsed_milliseconds,
                normalized_receipt_id(&receipt_id, invocation_id),
                normalized_optional_identifier(&provider_run_reference, "provider", invocation_id),
            ))
        }
        WorkflowCapabilityHostResult::Succeeded {
            logs,
            elapsed_milliseconds,
            receipt_id,
            ..
        }
        | WorkflowCapabilityHostResult::TimedOut {
            logs,
            elapsed_milliseconds,
            receipt_id,
        } => {
            let error = capability_error_value(
                request,
                invocation_id,
                "capability.timeout",
                "The capability exceeded its registered execution deadline.",
                None,
            )?;
            Ok(capability_settled_event(
                recorded,
                command,
                request,
                run_token_id,
                v1::WorkflowCapabilityAttemptOutcome::TimedOut,
                None,
                Vec::new(),
                "capability.timeout",
                Some(error),
                capability_logs(logs, elapsed_milliseconds),
                elapsed_milliseconds.min(86_400_000),
                normalized_receipt_id(&receipt_id, invocation_id),
                String::new(),
            ))
        }
        WorkflowCapabilityHostResult::MalformedResult {
            summary,
            logs,
            elapsed_milliseconds,
            receipt_id,
        } => capability_failure_result_event(
            request,
            run_token_id,
            command,
            recorded,
            v1::WorkflowCapabilityAttemptOutcome::MalformedResult,
            "capability.malformed-result",
            &summary,
            logs,
            elapsed_milliseconds,
            receipt_id,
        ),
        WorkflowCapabilityHostResult::Crashed {
            summary,
            logs,
            elapsed_milliseconds,
            receipt_id,
        } => capability_failure_result_event(
            request,
            run_token_id,
            command,
            recorded,
            v1::WorkflowCapabilityAttemptOutcome::Crashed,
            "capability.crashed",
            &summary,
            logs,
            elapsed_milliseconds,
            receipt_id,
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn capability_failure_result_event(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    command: &v1::CommandEnvelope,
    recorded: &RecordedCapabilityAttempt,
    outcome: v1::WorkflowCapabilityAttemptOutcome,
    error_code: &str,
    summary: &str,
    logs: Vec<WorkflowCapabilityLog>,
    elapsed_milliseconds: u64,
    receipt_id: String,
) -> Result<v1::EventEnvelope> {
    let invocation_id = recorded.started.invocation_id.as_str();
    let error = capability_error_value(
        request,
        invocation_id,
        error_code,
        &sanitize_capability_text(summary),
        None,
    )?;
    Ok(capability_settled_event(
        recorded,
        command,
        request,
        run_token_id,
        outcome,
        None,
        Vec::new(),
        error_code,
        Some(error),
        capability_logs(logs, elapsed_milliseconds),
        elapsed_milliseconds.min(86_400_000),
        normalized_receipt_id(&receipt_id, invocation_id),
        String::new(),
    ))
}

#[allow(clippy::too_many_arguments)]
fn capability_settled_event(
    recorded: &RecordedCapabilityAttempt,
    _command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    outcome: v1::WorkflowCapabilityAttemptOutcome,
    output: Option<v1::WorkflowValueReference>,
    artifact_outputs: Vec<v1::WorkflowCapabilityArtifactHandle>,
    error_code: &str,
    error: Option<v1::WorkflowValueReference>,
    logs: Vec<v1::WorkflowCapabilityLogEntry>,
    elapsed_milliseconds: u64,
    receipt_id: String,
    provider_run_reference: String,
) -> v1::EventEnvelope {
    let invocation_id = recorded.started.invocation_id.as_str();
    runtime_event(
        recorded
            .started_at_unix_millis
            .saturating_add(elapsed_milliseconds.min(i64::MAX as u64) as i64),
        &stable_id(
            "event",
            &[&request.run_id, "capability-settled", invocation_id],
        ),
        workflow_runtime::WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_KIND,
        workflow_runtime::WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_TYPE,
        v1::WorkflowCapabilityAttemptSettled {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            invocation_id: invocation_id.to_owned(),
            attempt_id: recorded.started.attempt_id.clone(),
            outcome: outcome as i32,
            output,
            artifact_outputs,
            error_code: error_code.to_owned(),
            error,
            logs,
            elapsed_milliseconds,
            receipt_id,
            provider_run_reference,
            idempotency_key: invocation_id.to_owned(),
        },
        &recorded.started_event_id,
        &request.run_id,
    )
}

fn execute_settled_capability_node(
    request: &v1::RequestWorkflowRun,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> Result<NodeExecution> {
    let invocation_id = capability_invocation_id(request, attempt, node);
    let settled = state
        .capability_attempts
        .get(&invocation_id)
        .and_then(|recorded| recorded.settled.as_ref())
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("capability_not_settled".into()))?;
    match v1::WorkflowCapabilityAttemptOutcome::try_from(settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("capability_outcome".into()))?
    {
        v1::WorkflowCapabilityAttemptOutcome::Succeeded => Ok(success_output(
            "success",
            settled
                .output
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("capability_output".into()))?,
        )),
        v1::WorkflowCapabilityAttemptOutcome::InputValidationFailed
        | v1::WorkflowCapabilityAttemptOutcome::OutputValidationFailed
        | v1::WorkflowCapabilityAttemptOutcome::TimedOut
        | v1::WorkflowCapabilityAttemptOutcome::MalformedResult
        | v1::WorkflowCapabilityAttemptOutcome::Crashed => {
            let error = settled
                .error
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("capability_error".into()))?;
            Ok(failure_output("error", &settled.error_code, error))
        }
        v1::WorkflowCapabilityAttemptOutcome::Cancelled => Err(WorkflowExecutionError::Lifecycle(
            "cancelled_capability_reentered".into(),
        )),
        v1::WorkflowCapabilityAttemptOutcome::Unspecified => Err(
            WorkflowExecutionError::Integrity("capability_outcome".into()),
        ),
    }
}

fn capability_invocation_id(
    request: &v1::RequestWorkflowRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> String {
    stable_id(
        "capability",
        &[&request.run_id, &attempt.started.attempt_id, &node.id],
    )
}

fn capability_value_instance(value: &v1::WorkflowValueReference) -> Result<Value> {
    if !value.inline_canonical_json.is_empty() {
        return inline_json(value);
    }
    context_value(value)
}

fn capability_output_value(
    request: &v1::RequestWorkflowRun,
    invocation_id: &str,
    output: WorkflowCapabilityValue,
) -> Result<v1::WorkflowValueReference> {
    match output {
        WorkflowCapabilityValue::Json(value) => value_from_json(
            &stable_id(
                "value",
                &[&request.run_id, invocation_id, "capability-output"],
            ),
            &value,
        ),
        WorkflowCapabilityValue::StorageReference(value)
            if value.inline_canonical_json.is_empty()
                && !value.storage_reference_id.is_empty()
                && value.storage.is_some() =>
        {
            Ok(value)
        }
        WorkflowCapabilityValue::StorageReference(_) => Err(WorkflowExecutionError::Integrity(
            "capability_output_handle".into(),
        )),
    }
}

fn artifact_handles_from_value(
    value: &v1::WorkflowValueReference,
    role: &str,
) -> Vec<v1::WorkflowCapabilityArtifactHandle> {
    value
        .storage
        .as_ref()
        .filter(|metadata| !metadata.handle_id.is_empty())
        .map(|metadata| {
            vec![v1::WorkflowCapabilityArtifactHandle {
                handle_id: metadata.handle_id.clone(),
                role: role.to_owned(),
                value: Some(value.clone()),
            }]
        })
        .unwrap_or_default()
}

fn capability_artifact_inputs(
    values: &[v1::WorkflowCapabilityArtifactHandle],
) -> Vec<WorkflowCapabilityArtifactHandle> {
    values
        .iter()
        .filter_map(|artifact| {
            artifact
                .value
                .clone()
                .map(|value| WorkflowCapabilityArtifactHandle {
                    value,
                    role: artifact.role.clone(),
                })
        })
        .collect()
}

fn capability_artifact_outputs(
    values: Vec<WorkflowCapabilityArtifactHandle>,
) -> Result<Vec<v1::WorkflowCapabilityArtifactHandle>> {
    values
        .into_iter()
        .map(|artifact| {
            let metadata = artifact.value.storage.as_ref().ok_or_else(|| {
                WorkflowExecutionError::Integrity("capability_artifact_metadata".into())
            })?;
            if artifact.value.inline_canonical_json.is_empty()
                && !artifact.value.storage_reference_id.is_empty()
                && !metadata.handle_id.is_empty()
                && !artifact.role.is_empty()
            {
                Ok(v1::WorkflowCapabilityArtifactHandle {
                    handle_id: metadata.handle_id.clone(),
                    role: artifact.role,
                    value: Some(artifact.value),
                })
            } else {
                Err(WorkflowExecutionError::Integrity(
                    "capability_artifact_handle".into(),
                ))
            }
        })
        .collect()
}

fn capability_logs(
    logs: Vec<WorkflowCapabilityLog>,
    elapsed_milliseconds: u64,
) -> Vec<v1::WorkflowCapabilityLogEntry> {
    logs.into_iter()
        .take(128)
        .enumerate()
        .map(|(index, log)| v1::WorkflowCapabilityLogEntry {
            sequence: (index + 1) as u32,
            level: match log.level.as_str() {
                "debug" | "info" | "warning" | "error" => log.level,
                _ => "info".into(),
            },
            message: sanitize_capability_text(&log.message),
            offset_milliseconds: log.offset_milliseconds.min(elapsed_milliseconds),
        })
        .collect()
}

fn sanitize_capability_text(value: &str) -> String {
    let lowered = value.to_ascii_lowercase();
    if ["authorization", "password", "secret", "api_key", "api-key"]
        .iter()
        .any(|marker| lowered.contains(marker))
    {
        return "[redacted sensitive capability evidence]".into();
    }
    let sanitized = value
        .split_whitespace()
        .map(|part| {
            if part.starts_with('/') || part.starts_with("file://") {
                "[redacted-path]"
            } else {
                part
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let bounded = sanitized.chars().take(2_048).collect::<String>();
    if bounded.is_empty() {
        "Capability evidence unavailable.".into()
    } else {
        bounded
    }
}

fn normalized_receipt_id(value: &str, invocation_id: &str) -> String {
    normalized_optional_identifier(value, "receipt", invocation_id)
}

fn normalized_optional_identifier(value: &str, prefix: &str, invocation_id: &str) -> String {
    if !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        value.to_owned()
    } else if value.is_empty() {
        String::new()
    } else {
        stable_id(prefix, &[invocation_id, value])
    }
}

fn capability_error_value(
    request: &v1::RequestWorkflowRun,
    invocation_id: &str,
    code: &str,
    summary: &str,
    details: Option<Value>,
) -> Result<v1::WorkflowValueReference> {
    value_from_json(
        &stable_id(
            "value",
            &[&request.run_id, invocation_id, "capability-error", code],
        ),
        &json!({
            "code": code,
            "summary": summary,
            "details": details
        }),
    )
}

struct CompiledLlmContext {
    settings: v1::WorkflowLlmModelSettings,
    context_digest: String,
    groups: Vec<v1::WorkflowLlmContextGroup>,
    messages: Vec<v1::WorkflowLlmMessage>,
    prior_episode_ids: Vec<String>,
    attachments: Vec<v1::WorkflowCapabilityArtifactHandle>,
    report: v1::WorkflowLlmCompilationReport,
}

struct PendingLlmGroup {
    group_id: String,
    kind: String,
    title: String,
    provenance: String,
    role: Option<String>,
    summary: String,
    content: Value,
    source_episode_ids: Vec<String>,
    redaction_count: u32,
}

#[allow(clippy::too_many_arguments)]
fn pending_llm_event_sequence(
    package: &ExecutionPackage,
    provider: &mut dyn WorkflowLlmProvider,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<Option<Vec<v1::EventEnvelope>>> {
    let invocation_id = llm_invocation_id(request, attempt, node);
    let input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("llm_input_missing".into()))?
        .1
        .clone();
    let config = llm_config(node)?;
    let definition = provider
        .definition(&config.model_class)
        .ok_or_else(|| WorkflowExecutionError::Unsupported("llm_provider_not_registered".into()))?;
    let output_schema = package
        .schemas
        .get(&config.output_schema_ref)
        .ok_or_else(|| WorkflowExecutionError::Unsupported("llm_output_schema_missing".into()))?;
    let tool_definitions = validated_llm_tool_definitions(package, &config, &definition)?;
    let admitted_inputs = inputs
        .iter()
        .map(|(_, value)| value.clone())
        .collect::<Vec<_>>();
    let compiled = compile_llm_context(
        request,
        state.episode.as_ref(),
        attempt,
        node,
        &input,
        &admitted_inputs,
        &config,
        &definition,
        output_schema,
    )?;
    let Some(recorded) = state.llm_attempts.get(&invocation_id) else {
        let deadline_unix_millis = attempt
            .started_at_unix_millis
            .checked_add(definition.timeout_milliseconds as i64)
            .ok_or_else(|| WorkflowExecutionError::Encoding("llm_deadline"))?;
        return Ok(Some(vec![runtime_event(
            attempt.started_at_unix_millis,
            &stable_id("event", &[&request.run_id, "llm-started", &invocation_id]),
            workflow_runtime::WORKFLOW_LLM_ATTEMPT_STARTED_KIND,
            workflow_runtime::WORKFLOW_LLM_ATTEMPT_STARTED_TYPE,
            v1::WorkflowLlmAttemptStarted {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                invocation_id,
                attempt_id: attempt.started.attempt_id.clone(),
                execution_token_id: attempt.started.execution_token_id.clone(),
                node_id: node.id.clone(),
                settings: Some(compiled.settings),
                context_digest: compiled.context_digest,
                context_groups: compiled.groups,
                messages: compiled.messages,
                prior_episode_ids: compiled.prior_episode_ids,
                attachments: compiled.attachments,
                compilation_report: Some(compiled.report),
                output_schema_ref: config.output_schema_ref,
                output_schema_digest: schema_digest(output_schema)?,
                input: Some(input),
                timeout_milliseconds: definition.timeout_milliseconds,
                deadline_unix_millis,
                tool_definitions: tool_definitions.clone(),
            },
            &attempt.started_event_id,
            &request.run_id,
        )]));
    };
    validate_recorded_llm_attempt(
        request,
        run_token_id,
        attempt,
        node,
        &input,
        &config,
        &definition,
        output_schema,
        &compiled,
        &tool_definitions,
        recorded,
    )?;
    if recorded.settled.is_some() {
        return Ok(None);
    }

    let invocation = WorkflowLlmInvocation {
        invocation_id: invocation_id.clone(),
        run_id: request.run_id.clone(),
        attempt_id: attempt.started.attempt_id.clone(),
        node_id: node.id.clone(),
        settings: compiled.settings,
        context_digest: compiled.context_digest,
        context_groups: compiled.groups,
        messages: compiled.messages,
        prior_episode_ids: compiled.prior_episode_ids,
        attachments: compiled.attachments,
        tool_definitions,
        output_schema: output_schema.clone(),
        timeout_milliseconds: definition.timeout_milliseconds,
    };
    let result = provider.invoke(&invocation);
    Ok(Some(vec![llm_provider_result_event(
        request,
        run_token_id,
        recorded,
        output_schema,
        &definition,
        llm_tool_call_budget(&config),
        result,
    )?]))
}

#[allow(clippy::too_many_arguments)]
fn validate_recorded_llm_attempt(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    input: &v1::WorkflowValueReference,
    config: &LlmConfig,
    definition: &WorkflowLlmProviderDefinition,
    output_schema: &Value,
    compiled: &CompiledLlmContext,
    tool_definitions: &[v1::WorkflowLlmToolDefinition],
    recorded: &RecordedLlmAttempt,
) -> Result<()> {
    let started = &recorded.started;
    if started.run_id != request.run_id
        || started.run_token_id != run_token_id
        || started.attempt_id != attempt.started.attempt_id
        || started.execution_token_id != attempt.started.execution_token_id
        || started.node_id != node.id
        || started.settings.as_ref() != Some(&compiled.settings)
        || started.context_digest != compiled.context_digest
        || started.context_groups != compiled.groups
        || started.messages != compiled.messages
        || started.prior_episode_ids != compiled.prior_episode_ids
        || started.attachments != compiled.attachments
        || started.compilation_report.as_ref() != Some(&compiled.report)
        || started.output_schema_ref != config.output_schema_ref
        || started.output_schema_digest != schema_digest(output_schema)?
        || started.input.as_ref() != Some(input)
        || started.tool_definitions != tool_definitions
        || started.timeout_milliseconds != definition.timeout_milliseconds
        || started.deadline_unix_millis
            != recorded
                .started_at_unix_millis
                .checked_add(definition.timeout_milliseconds as i64)
                .ok_or_else(|| WorkflowExecutionError::Encoding("llm_deadline"))?
    {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_llm_pin_mismatch".into(),
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn compile_llm_context(
    request: &v1::RequestWorkflowRun,
    episode: Option<&v1::WorkflowCaseEpisodeStarted>,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    input: &v1::WorkflowValueReference,
    admitted_inputs: &[v1::WorkflowValueReference],
    config: &LlmConfig,
    definition: &WorkflowLlmProviderDefinition,
    output_schema: &Value,
) -> Result<CompiledLlmContext> {
    let settings = v1::WorkflowLlmModelSettings {
        model_class: config.model_class.clone(),
        provider_id: definition.provider_id.clone(),
        model_id: definition.model_id.clone(),
        model_revision: definition.model_revision.clone(),
        reasoning_effort: config.reasoning_effort.clone(),
        temperature_milli: config.temperature_milli,
        maximum_context_bytes: config.maximum_context_bytes,
        maximum_output_tokens: config.maximum_output_tokens,
        conversation_scope: config.conversation_scope.clone(),
    };
    let mut reasons = BTreeSet::new();
    let mut pending = Vec::new();
    pending.push(llm_group(
        "system-policy",
        "system_policy",
        "System policy",
        "Kaname host policy",
        Some("system"),
        "Bounded workflow policy and output contract",
        json!({
            "policy": "Use only the recorded workflow context. Do not reveal hidden reasoning or request credentials, host paths, or undeclared external effects.",
            "outputSchemaDigest": schema_digest(output_schema)?,
            "maximumToolCalls": llm_tool_call_budget(config),
        }),
        Vec::new(),
        &mut reasons,
    ));
    pending.push(llm_group(
        "workflow-instructions",
        "workflow_instructions",
        "Workflow instructions",
        &format!("Workflow revision {}", request.revision_id),
        Some("developer"),
        "Version-pinned workflow instructions",
        json!({"instructions": config.instructions}),
        Vec::new(),
        &mut reasons,
    ));
    let prompt_instance = if config.prompt == json!({"whole": true}) {
        capability_value_instance(input)?
    } else {
        workflow_expression::evaluate(
            &config.prompt,
            &ExpressionRoots::with_input(inline_json(input)?),
        )
        .map_err(|_| WorkflowExecutionError::Integrity("llm_prompt_mapping".into()))?
    };
    pending.push(llm_group(
        "current-input",
        "current_input",
        "Current input",
        &format!("Node {} attempt {}", node.id, attempt.started.attempt_id),
        Some("user"),
        "Current typed workflow input",
        prompt_instance,
        Vec::new(),
        &mut reasons,
    ));

    let mut prior_episode_ids = Vec::new();
    if !config.context.is_empty() || config.conversation_scope == "case" {
        let episode = episode.ok_or(WorkflowExecutionError::InvalidCommand(
            "case_episode_required",
        ))?;
        let root =
            inline_json(episode.compiled_context.as_ref().ok_or_else(|| {
                WorkflowExecutionError::Integrity("case_context_missing".into())
            })?)?;
        prior_episode_ids = episode.source_episode_ids.clone();
        for (index, reference) in config.context.iter().enumerate() {
            let pointer = reference
                .get("pointer")
                .and_then(Value::as_str)
                .ok_or_else(|| WorkflowExecutionError::Integrity("llm_context_pointer".into()))?;
            let selected = if pointer.is_empty() {
                root.clone()
            } else {
                root.pointer(pointer).cloned().ok_or_else(|| {
                    WorkflowExecutionError::InvalidCommand("llm_context_pointer_missing")
                })?
            };
            pending.push(llm_group(
                &format!("case-context-{index:02}"),
                "prior_case_episodes",
                "Prior case episodes",
                &format!("Case {} · pointer {}", episode.case_id, pointer),
                None,
                "Immutable prior case context",
                selected,
                episode.source_episode_ids.clone(),
                &mut reasons,
            ));
        }
    }

    let attachments = llm_attachment_handles(admitted_inputs, episode);
    if !attachments.is_empty() {
        let attachment_summary = attachments
            .iter()
            .map(|attachment| {
                json!({
                    "handleId": attachment.handle_id,
                    "role": attachment.role,
                    "valueId": attachment.value.as_ref().map(|value| value.value_id.clone()).unwrap_or_default(),
                    "contentType": attachment.value.as_ref().map(|value| value.content_type.clone()).unwrap_or_default(),
                    "sha256": attachment.value.as_ref().map(|value| value.sha256.clone()).unwrap_or_default(),
                    "byteCount": attachment.value.as_ref().map(|value| value.byte_count).unwrap_or_default(),
                })
            })
            .collect::<Vec<_>>();
        pending.push(llm_group(
            "attachments",
            "attachments",
            "Attachments and sources",
            "Opaque workflow storage handles",
            None,
            "Opaque attachment metadata",
            Value::Array(attachment_summary),
            prior_episode_ids.clone(),
            &mut reasons,
        ));
    }

    let original_group_count = pending.len() as u32;
    let original_byte_count = pending.iter().try_fold(0_u64, |total, group| {
        canonical_json_bytes(&group.content).map(|bytes| total.saturating_add(bytes.len() as u64))
    })?;
    let mut retained_total = 0_u64;
    let mut groups = Vec::new();
    let mut messages = Vec::new();
    let mut truncated_group_ids = Vec::new();
    let mut dropped_group_ids = Vec::new();
    let mut total_redactions = 0_u32;
    for group in pending {
        total_redactions = total_redactions.saturating_add(group.redaction_count);
        let original = canonical_json_bytes(&group.content)?;
        let (content, truncated) = if retained_total.saturating_add(original.len() as u64)
            <= config.maximum_context_bytes
        {
            (group.content, false)
        } else {
            let replacement = json!({
                "truncated": true,
                "originalByteCount": original.len(),
                "sha256": canonical_sha256(&group.content)?,
            });
            let replacement_bytes = canonical_json_bytes(&replacement)?;
            if retained_total.saturating_add(replacement_bytes.len() as u64)
                > config.maximum_context_bytes
            {
                dropped_group_ids.push(group.group_id);
                continue;
            }
            truncated_group_ids.push(group.group_id.clone());
            (replacement, true)
        };
        let retained = canonical_json_bytes(&content)?;
        retained_total = retained_total.saturating_add(retained.len() as u64);
        let content_value = value_from_json(
            &stable_id(
                "value",
                &[
                    &request.run_id,
                    &attempt.started.attempt_id,
                    &group.group_id,
                ],
            ),
            &content,
        )?;
        if let Some(role) = group.role {
            messages.push(v1::WorkflowLlmMessage {
                message_id: stable_id(
                    "llm-message",
                    &[
                        &request.run_id,
                        &attempt.started.attempt_id,
                        &group.group_id,
                    ],
                ),
                sequence: (messages.len() + 1) as u32,
                role,
                context_group_id: group.group_id.clone(),
                summary: group.summary,
                content_value_id: content_value.value_id.clone(),
                estimated_tokens: (retained.len() as u64).div_ceil(4),
                redaction_count: group.redaction_count,
                truncated,
            });
        }
        groups.push(v1::WorkflowLlmContextGroup {
            group_id: group.group_id,
            kind: group.kind,
            title: group.title,
            provenance: group.provenance,
            content: Some(content_value),
            original_byte_count: original.len() as u64,
            retained_byte_count: retained.len() as u64,
            redaction_count: group.redaction_count,
            truncated,
            source_episode_ids: group.source_episode_ids,
        });
    }
    let report = v1::WorkflowLlmCompilationReport {
        original_group_count,
        retained_group_count: groups.len() as u32,
        original_byte_count,
        retained_byte_count: retained_total,
        redaction_count: total_redactions,
        truncated_group_ids,
        dropped_group_ids,
        redaction_reasons: reasons.into_iter().collect(),
    };
    let context_digest = llm_context_digest(
        &settings,
        &groups,
        &messages,
        &prior_episode_ids,
        &attachments,
        &report,
        &schema_digest(output_schema)?,
    )?;
    Ok(CompiledLlmContext {
        settings,
        context_digest,
        groups,
        messages,
        prior_episode_ids,
        attachments,
        report,
    })
}

#[allow(clippy::too_many_arguments)]
fn llm_group(
    group_id: &str,
    kind: &str,
    title: &str,
    provenance: &str,
    role: Option<&str>,
    summary: &str,
    content: Value,
    source_episode_ids: Vec<String>,
    reasons: &mut BTreeSet<String>,
) -> PendingLlmGroup {
    let mut redaction_count = 0;
    let content = redact_llm_value(content, &mut redaction_count, reasons);
    PendingLlmGroup {
        group_id: group_id.into(),
        kind: kind.into(),
        title: title.into(),
        provenance: sanitize_llm_label(provenance),
        role: role.map(str::to_owned),
        summary: summary.into(),
        content,
        source_episode_ids,
        redaction_count,
    }
}

fn redact_llm_value(
    value: Value,
    redaction_count: &mut u32,
    reasons: &mut BTreeSet<String>,
) -> Value {
    match value {
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| {
                    let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
                    let value = if [
                        "authorization",
                        "apikey",
                        "accesstoken",
                        "refreshtoken",
                        "password",
                        "secret",
                        "credential",
                    ]
                    .iter()
                    .any(|sensitive| normalized.contains(sensitive))
                    {
                        *redaction_count = redaction_count.saturating_add(1);
                        reasons.insert("sensitive-field".into());
                        Value::String("[redacted]".into())
                    } else {
                        redact_llm_value(value, redaction_count, reasons)
                    };
                    (key, value)
                })
                .collect(),
        ),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| redact_llm_value(value, redaction_count, reasons))
                .collect(),
        ),
        Value::String(value) if llm_string_contains_host_path(&value) => {
            *redaction_count = redaction_count.saturating_add(1);
            reasons.insert("host-path".into());
            Value::String("[redacted host path]".into())
        }
        Value::String(value) if llm_string_contains_secret(&value) => {
            *redaction_count = redaction_count.saturating_add(1);
            reasons.insert("secret-marker".into());
            Value::String("[redacted secret]".into())
        }
        other => other,
    }
}

fn llm_string_contains_host_path(value: &str) -> bool {
    value.contains("/Users/")
        || value.contains("file://")
        || value.contains("/home/")
        || value.contains("\\Users\\")
}

fn llm_string_contains_secret(value: &str) -> bool {
    let normalized = value.to_ascii_lowercase().replace(['_', '-'], "");
    [
        "authorization:",
        "bearer ",
        "apikey=",
        "apikey:",
        "password=",
        "password:",
        "secret=",
        "secret:",
        "credential=",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
}

fn sanitize_llm_label(value: &str) -> String {
    if llm_string_contains_host_path(value) || llm_string_contains_secret(value) {
        "Redacted provenance".into()
    } else {
        value.chars().take(512).collect()
    }
}

/// Collects the artifact references reachable from this attempt's admitted
/// inputs and its case episode. Each handle keeps its opaque identity and its
/// content digest, so a prompt can name an artifact without the model, the
/// provider, or the journal ever seeing a host path or the artifact bytes.
fn llm_attachment_handles(
    admitted_inputs: &[v1::WorkflowValueReference],
    episode: Option<&v1::WorkflowCaseEpisodeStarted>,
) -> Vec<v1::WorkflowCapabilityArtifactHandle> {
    let mut values = admitted_inputs
        .iter()
        .flat_map(|input| artifact_handles_from_value(input, "current-input"))
        .collect::<Vec<_>>();
    if let Some(episode) = episode {
        for binding in &episode.inputs {
            if let Some(value) = binding.value.as_ref() {
                values.extend(artifact_handles_from_value(value, "case-input"));
            }
        }
    }
    values.sort_by(|left, right| left.handle_id.cmp(&right.handle_id));
    values.dedup_by(|left, right| left.handle_id == right.handle_id);
    values.truncate(64);
    values
}

fn llm_context_digest(
    settings: &v1::WorkflowLlmModelSettings,
    groups: &[v1::WorkflowLlmContextGroup],
    messages: &[v1::WorkflowLlmMessage],
    prior_episode_ids: &[String],
    attachments: &[v1::WorkflowCapabilityArtifactHandle],
    report: &v1::WorkflowLlmCompilationReport,
    output_schema_digest: &str,
) -> Result<String> {
    let value = json!({
        "settings": {
            "modelClass": settings.model_class,
            "providerId": settings.provider_id,
            "modelId": settings.model_id,
            "modelRevision": settings.model_revision,
            "reasoningEffort": settings.reasoning_effort,
            "temperatureMilli": settings.temperature_milli,
            "maximumContextBytes": settings.maximum_context_bytes,
            "maximumOutputTokens": settings.maximum_output_tokens,
            "conversationScope": settings.conversation_scope,
        },
        "groups": groups.iter().map(|group| json!({
            "id": group.group_id,
            "kind": group.kind,
            "contentSha256": group.content.as_ref().map(|value| value.sha256.clone()).unwrap_or_default(),
            "truncated": group.truncated,
            "redactionCount": group.redaction_count,
            "sourceEpisodeIds": group.source_episode_ids,
        })).collect::<Vec<_>>(),
        "messages": messages.iter().map(|message| json!({
            "id": message.message_id,
            "sequence": message.sequence,
            "role": message.role,
            "groupId": message.context_group_id,
            "contentValueId": message.content_value_id,
        })).collect::<Vec<_>>(),
        "priorEpisodeIds": prior_episode_ids,
        "attachments": attachments.iter().map(|attachment| json!({
            "handleId": attachment.handle_id,
            "role": attachment.role,
            "sha256": attachment.value.as_ref().map(|value| value.sha256.clone()).unwrap_or_default(),
        })).collect::<Vec<_>>(),
        "report": {
            "originalGroupCount": report.original_group_count,
            "retainedGroupCount": report.retained_group_count,
            "originalByteCount": report.original_byte_count,
            "retainedByteCount": report.retained_byte_count,
            "redactionCount": report.redaction_count,
            "truncatedGroupIds": report.truncated_group_ids,
            "droppedGroupIds": report.dropped_group_ids,
            "redactionReasons": report.redaction_reasons,
        },
        "outputSchemaDigest": output_schema_digest,
    });
    canonical_sha256(&value)
}

fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>> {
    let encoded =
        serde_json::to_vec(value).map_err(|_| WorkflowExecutionError::Encoding("llm_context"))?;
    workflow_canonical::canonicalize(&encoded)
        .map(|report| report.canonical_bytes)
        .map_err(|_| WorkflowExecutionError::Encoding("llm_context"))
}

fn canonical_sha256(value: &Value) -> Result<String> {
    let encoded =
        serde_json::to_vec(value).map_err(|_| WorkflowExecutionError::Encoding("llm_context"))?;
    workflow_canonical::canonicalize(&encoded)
        .map(|report| report.sha256.trim_start_matches("sha256:").to_owned())
        .map_err(|_| WorkflowExecutionError::Encoding("llm_context"))
}

#[allow(clippy::too_many_arguments)]
fn llm_provider_result_event(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    recorded: &RecordedLlmAttempt,
    output_schema: &Value,
    definition: &WorkflowLlmProviderDefinition,
    tool_call_budget: usize,
    result: WorkflowLlmProviderResult,
) -> Result<v1::EventEnvelope> {
    let invocation_id = recorded.started.invocation_id.as_str();
    match result {
        WorkflowLlmProviderResult::Succeeded {
            output,
            elapsed_milliseconds,
            receipt_id,
            provider_run_reference,
            trace,
        } if elapsed_milliseconds <= definition.timeout_milliseconds => {
            if trace.tool_calls.len() > tool_call_budget {
                return llm_failure_result_event(
                    request,
                    run_token_id,
                    recorded,
                    v1::WorkflowLlmAttemptOutcome::MalformedResult,
                    "llm.tool-call-budget-exceeded",
                    "The model made more tool calls than this node's recorded budget allows.",
                    elapsed_milliseconds,
                    receipt_id,
                    AdmittedLlmTrace::default(),
                );
            }
            if llm_value_contains_private_marker(&output) {
                return llm_failure_result_event(
                    request,
                    run_token_id,
                    recorded,
                    v1::WorkflowLlmAttemptOutcome::MalformedResult,
                    "llm.private-output-rejected",
                    "The model returned content that cannot enter durable workflow evidence.",
                    elapsed_milliseconds,
                    receipt_id,
                    AdmittedLlmTrace::default(),
                );
            }
            let admitted_trace = match admit_llm_trace(
                request,
                recorded,
                definition,
                tool_call_budget,
                &receipt_id,
                &provider_run_reference,
                trace,
            ) {
                Ok(trace) => trace,
                Err(_) => {
                    return llm_failure_result_event(
                        request,
                        run_token_id,
                        recorded,
                        v1::WorkflowLlmAttemptOutcome::MalformedResult,
                        "llm.trace-invalid",
                        "The model provider returned invalid tool or response evidence.",
                        elapsed_milliseconds,
                        receipt_id,
                        AdmittedLlmTrace::default(),
                    );
                }
            };
            let output = value_from_json(
                &stable_id("value", &[&request.run_id, invocation_id, "llm-output"]),
                &output,
            )?;
            let validation = workflow_schema::check(&WorkflowSchemaCheckRequest {
                schema: output_schema.clone(),
                instance: inline_json(&output)?,
            });
            if validation.outcome != WorkflowSchemaCheckOutcome::Valid {
                let error = capability_error_value(
                    request,
                    invocation_id,
                    "llm.output-validation-failed",
                    "The model output did not match the registered schema.",
                    Some(json!({
                        "diagnostics": validation.diagnostics,
                        "diagnosticsTruncated": validation.diagnostics_truncated,
                    })),
                )?;
                return Ok(llm_settled_event(
                    recorded,
                    request,
                    run_token_id,
                    v1::WorkflowLlmAttemptOutcome::OutputValidationFailed,
                    None,
                    "llm.output-validation-failed",
                    Some(error),
                    elapsed_milliseconds,
                    normalized_receipt_id(&receipt_id, invocation_id),
                    String::new(),
                    admitted_trace,
                    Some(llm_response_validation(
                        "failed",
                        &recorded.started.output_schema_ref,
                        &recorded.started.output_schema_digest,
                        validation
                            .diagnostics
                            .into_iter()
                            .map(|diagnostic| {
                                format!(
                                    "{} at {}: {}",
                                    diagnostic.code, diagnostic.instance_path, diagnostic.message
                                )
                            })
                            .collect(),
                        validation.diagnostics_truncated,
                    )),
                ));
            }
            Ok(llm_settled_event(
                recorded,
                request,
                run_token_id,
                v1::WorkflowLlmAttemptOutcome::Succeeded,
                Some(output),
                "",
                None,
                elapsed_milliseconds,
                normalized_receipt_id(&receipt_id, invocation_id),
                normalized_optional_identifier(&provider_run_reference, "provider", invocation_id),
                admitted_trace,
                Some(llm_response_validation(
                    "succeeded",
                    &recorded.started.output_schema_ref,
                    &recorded.started.output_schema_digest,
                    Vec::new(),
                    false,
                )),
            ))
        }
        WorkflowLlmProviderResult::Succeeded {
            elapsed_milliseconds,
            receipt_id,
            ..
        }
        | WorkflowLlmProviderResult::TimedOut {
            elapsed_milliseconds,
            receipt_id,
            ..
        } => llm_failure_result_event(
            request,
            run_token_id,
            recorded,
            v1::WorkflowLlmAttemptOutcome::TimedOut,
            "llm.timeout",
            "The model exceeded its registered execution deadline.",
            elapsed_milliseconds,
            receipt_id,
            AdmittedLlmTrace::default(),
        ),
        WorkflowLlmProviderResult::MalformedResult {
            summary,
            elapsed_milliseconds,
            receipt_id,
            trace,
        } => llm_failure_result_event(
            request,
            run_token_id,
            recorded,
            v1::WorkflowLlmAttemptOutcome::MalformedResult,
            "llm.malformed-result",
            &summary,
            elapsed_milliseconds,
            receipt_id.clone(),
            admit_llm_trace(
                request,
                recorded,
                definition,
                tool_call_budget,
                &receipt_id,
                "",
                trace,
            )
            .unwrap_or_default(),
        ),
        WorkflowLlmProviderResult::Crashed {
            summary,
            elapsed_milliseconds,
            receipt_id,
            trace,
        } => llm_failure_result_event(
            request,
            run_token_id,
            recorded,
            v1::WorkflowLlmAttemptOutcome::Crashed,
            "llm.crashed",
            &summary,
            elapsed_milliseconds,
            receipt_id.clone(),
            admit_llm_trace(
                request,
                recorded,
                definition,
                tool_call_budget,
                &receipt_id,
                "",
                trace,
            )
            .unwrap_or_default(),
        ),
    }
}

#[allow(clippy::too_many_arguments)]
fn admit_llm_trace(
    request: &v1::RequestWorkflowRun,
    recorded: &RecordedLlmAttempt,
    definition: &WorkflowLlmProviderDefinition,
    tool_call_budget: usize,
    receipt_id: &str,
    provider_run_reference: &str,
    trace: WorkflowLlmProviderTrace,
) -> Result<AdmittedLlmTrace> {
    if trace.tool_calls.len() > tool_call_budget.min(MAXIMUM_LLM_TOOL_CALLS)
        || trace.response_messages.len() > MAXIMUM_LLM_RESPONSE_MESSAGES
        || llm_value_contains_private_marker(&trace.receipt_metadata)
    {
        return Err(WorkflowExecutionError::Integrity("llm_trace_bounds".into()));
    }
    let invocation_id = recorded.started.invocation_id.as_str();
    let mut retained_bytes = 0_usize;
    let mut call_ids = BTreeSet::new();
    let mut tool_calls = Vec::with_capacity(trace.tool_calls.len());
    for (index, call) in trace.tool_calls.into_iter().enumerate() {
        let tool = definition
            .tools
            .iter()
            .find(|tool| tool.tool_id == call.tool_id)
            .ok_or_else(|| WorkflowExecutionError::Integrity("llm_trace_tool".into()))?;
        let call_id = normalized_optional_identifier(&call.call_id, "tool-call", invocation_id);
        if call_id.is_empty()
            || !call_ids.insert(call_id.clone())
            || call.duration_milliseconds > 86_400_000
            || llm_value_contains_private_marker(&call.input)
            || workflow_schema::check(&WorkflowSchemaCheckRequest {
                schema: tool.input_schema.clone(),
                instance: call.input.clone(),
            })
            .outcome
                != WorkflowSchemaCheckOutcome::Valid
        {
            return Err(WorkflowExecutionError::Integrity(
                "llm_trace_tool_input".into(),
            ));
        }
        let input = Some(llm_trace_value(
            request,
            invocation_id,
            &format!("tool-call-{}-input", index + 1),
            &call.input,
            &mut retained_bytes,
        )?);
        let (status, output, error_code, error) = match call.result {
            WorkflowLlmProviderToolResult::Succeeded(output) => {
                if llm_value_contains_private_marker(&output)
                    || workflow_schema::check(&WorkflowSchemaCheckRequest {
                        schema: tool.output_schema.clone(),
                        instance: output.clone(),
                    })
                    .outcome
                        != WorkflowSchemaCheckOutcome::Valid
                {
                    return Err(WorkflowExecutionError::Integrity(
                        "llm_trace_tool_output".into(),
                    ));
                }
                (
                    "succeeded".to_owned(),
                    Some(llm_trace_value(
                        request,
                        invocation_id,
                        &format!("tool-call-{}-output", index + 1),
                        &output,
                        &mut retained_bytes,
                    )?),
                    String::new(),
                    None,
                )
            }
            WorkflowLlmProviderToolResult::Failed { code, error } => {
                if llm_value_contains_private_marker(&error) {
                    return Err(WorkflowExecutionError::Integrity(
                        "llm_trace_tool_error".into(),
                    ));
                }
                let code = normalized_optional_identifier(&code, "tool-error", invocation_id);
                if code.is_empty() {
                    return Err(WorkflowExecutionError::Integrity(
                        "llm_trace_tool_error_code".into(),
                    ));
                }
                (
                    "failed".to_owned(),
                    None,
                    code,
                    Some(llm_trace_value(
                        request,
                        invocation_id,
                        &format!("tool-call-{}-error", index + 1),
                        &error,
                        &mut retained_bytes,
                    )?),
                )
            }
        };
        tool_calls.push(v1::WorkflowLlmToolCall {
            call_id,
            sequence: (index + 1) as u32,
            tool_id: call.tool_id,
            status,
            input,
            output,
            error_code,
            error,
            duration_milliseconds: call.duration_milliseconds,
        });
    }

    let mut message_ids = BTreeSet::new();
    let mut response_messages = Vec::with_capacity(trace.response_messages.len());
    for (index, message) in trace.response_messages.into_iter().enumerate() {
        let message_id =
            normalized_optional_identifier(&message.message_id, "response-message", invocation_id);
        let tool_call_id = message.tool_call_id.unwrap_or_default();
        if message_id.is_empty()
            || !message_ids.insert(message_id.clone())
            || !matches!(message.role.as_str(), "assistant" | "tool")
            || !matches!(
                message.kind.as_str(),
                "message" | "analysis_summary" | "tool_call" | "tool_result" | "final"
            )
            || (!tool_call_id.is_empty() && !call_ids.contains(&tool_call_id))
            || llm_value_contains_private_marker(&message.content)
        {
            return Err(WorkflowExecutionError::Integrity(
                "llm_trace_response_message".into(),
            ));
        }
        response_messages.push(v1::WorkflowLlmResponseMessage {
            message_id,
            sequence: (index + 1) as u32,
            role: message.role,
            kind: message.kind,
            summary: sanitize_capability_text(&message.summary),
            content: Some(llm_trace_value(
                request,
                invocation_id,
                &format!("response-message-{}", index + 1),
                &message.content,
                &mut retained_bytes,
            )?),
            tool_call_id,
        });
    }

    let usage = trace.usage;
    let total_tokens = usage
        .input_tokens
        .checked_add(usage.output_tokens)
        .and_then(|value| value.checked_add(usage.reasoning_tokens))
        .ok_or_else(|| WorkflowExecutionError::Integrity("llm_trace_usage".into()))?;
    let total_cost_micros = usage
        .input_cost_micros
        .checked_add(usage.output_cost_micros)
        .and_then(|value| value.checked_add(usage.reasoning_cost_micros))
        .and_then(|value| value.checked_add(usage.tool_cost_micros))
        .ok_or_else(|| WorkflowExecutionError::Integrity("llm_trace_cost".into()))?;
    if usage.cached_input_tokens > usage.input_tokens
        || (!usage.cost_currency.is_empty()
            && (usage.cost_currency.len() != 3
                || !usage
                    .cost_currency
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase())))
        || (total_cost_micros > 0 && usage.cost_currency.is_empty())
    {
        return Err(WorkflowExecutionError::Integrity("llm_trace_usage".into()));
    }
    let metadata_bytes = canonical_json_bytes(&trace.receipt_metadata)?;
    if metadata_bytes.len() > MAXIMUM_LLM_TRACE_VALUE_BYTES {
        return Err(WorkflowExecutionError::Integrity(
            "llm_trace_receipt_metadata".into(),
        ));
    }
    Ok(AdmittedLlmTrace {
        tool_calls,
        response_messages,
        usage: Some(v1::WorkflowLlmUsage {
            input_tokens: usage.input_tokens,
            cached_input_tokens: usage.cached_input_tokens,
            output_tokens: usage.output_tokens,
            reasoning_tokens: usage.reasoning_tokens,
            total_tokens,
            tool_call_count: call_ids.len() as u32,
            cost_currency: usage.cost_currency,
            input_cost_micros: usage.input_cost_micros,
            output_cost_micros: usage.output_cost_micros,
            reasoning_cost_micros: usage.reasoning_cost_micros,
            tool_cost_micros: usage.tool_cost_micros,
            total_cost_micros,
        }),
        provider_receipt: Some(v1::WorkflowLlmProviderReceipt {
            request_id: normalized_optional_identifier(
                &trace.request_id,
                "provider-request",
                invocation_id,
            ),
            response_id: normalized_optional_identifier(
                &trace.response_id,
                "provider-response",
                invocation_id,
            ),
            receipt_id: normalized_receipt_id(receipt_id, invocation_id),
            provider_run_reference: normalized_optional_identifier(
                provider_run_reference,
                "provider",
                invocation_id,
            ),
            metadata_digest: canonical_sha256(&trace.receipt_metadata)?,
        }),
    })
}

fn llm_trace_value(
    request: &v1::RequestWorkflowRun,
    invocation_id: &str,
    role: &str,
    value: &Value,
    retained_bytes: &mut usize,
) -> Result<v1::WorkflowValueReference> {
    let canonical = canonical_json_bytes(value)?;
    let admitted =
        if retained_bytes.saturating_add(canonical.len()) <= MAXIMUM_LLM_TRACE_VALUE_BYTES {
            value.clone()
        } else {
            json!({
                "summarized": true,
                "originalByteCount": canonical.len(),
                "sha256": canonical_sha256(value)?,
            })
        };
    *retained_bytes = retained_bytes.saturating_add(canonical_json_bytes(&admitted)?.len());
    value_from_json(
        &stable_id("value", &[&request.run_id, invocation_id, role]),
        &admitted,
    )
}

fn llm_response_validation(
    status: &str,
    schema_ref: &str,
    schema_digest: &str,
    diagnostics: Vec<String>,
    diagnostics_truncated: bool,
) -> v1::WorkflowLlmResponseValidation {
    v1::WorkflowLlmResponseValidation {
        status: status.to_owned(),
        schema_ref: schema_ref.to_owned(),
        schema_digest: schema_digest.to_owned(),
        diagnostics: diagnostics
            .into_iter()
            .take(16)
            .map(|value| sanitize_capability_text(&value))
            .collect(),
        diagnostics_truncated,
    }
}

fn llm_value_contains_private_marker(value: &Value) -> bool {
    match value {
        Value::Object(values) => values.iter().any(|(key, value)| {
            let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
            [
                "authorization",
                "apikey",
                "accesstoken",
                "refreshtoken",
                "password",
                "secret",
                "credential",
            ]
            .iter()
            .any(|sensitive| normalized.contains(sensitive))
                || llm_value_contains_private_marker(value)
        }),
        Value::Array(values) => values.iter().any(llm_value_contains_private_marker),
        Value::String(value) => {
            llm_string_contains_host_path(value) || llm_string_contains_secret(value)
        }
        _ => false,
    }
}

#[allow(clippy::too_many_arguments)]
fn llm_failure_result_event(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    recorded: &RecordedLlmAttempt,
    outcome: v1::WorkflowLlmAttemptOutcome,
    error_code: &str,
    summary: &str,
    elapsed_milliseconds: u64,
    receipt_id: String,
    trace: AdmittedLlmTrace,
) -> Result<v1::EventEnvelope> {
    let invocation_id = recorded.started.invocation_id.as_str();
    let error = capability_error_value(
        request,
        invocation_id,
        error_code,
        &sanitize_capability_text(summary),
        None,
    )?;
    Ok(llm_settled_event(
        recorded,
        request,
        run_token_id,
        outcome,
        None,
        error_code,
        Some(error),
        elapsed_milliseconds.min(86_400_000),
        normalized_receipt_id(&receipt_id, invocation_id),
        String::new(),
        trace,
        Some(llm_response_validation(
            "not_validated",
            &recorded.started.output_schema_ref,
            &recorded.started.output_schema_digest,
            Vec::new(),
            false,
        )),
    ))
}

#[allow(clippy::too_many_arguments)]
fn llm_settled_event(
    recorded: &RecordedLlmAttempt,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    outcome: v1::WorkflowLlmAttemptOutcome,
    output: Option<v1::WorkflowValueReference>,
    error_code: &str,
    error: Option<v1::WorkflowValueReference>,
    elapsed_milliseconds: u64,
    receipt_id: String,
    provider_run_reference: String,
    trace: AdmittedLlmTrace,
    validation: Option<v1::WorkflowLlmResponseValidation>,
) -> v1::EventEnvelope {
    let invocation_id = recorded.started.invocation_id.as_str();
    runtime_event(
        recorded
            .started_at_unix_millis
            .saturating_add(elapsed_milliseconds.min(i64::MAX as u64) as i64),
        &stable_id("event", &[&request.run_id, "llm-settled", invocation_id]),
        workflow_runtime::WORKFLOW_LLM_ATTEMPT_SETTLED_KIND,
        workflow_runtime::WORKFLOW_LLM_ATTEMPT_SETTLED_TYPE,
        v1::WorkflowLlmAttemptSettled {
            run_id: request.run_id.clone(),
            run_token_id: run_token_id.to_owned(),
            invocation_id: invocation_id.to_owned(),
            attempt_id: recorded.started.attempt_id.clone(),
            outcome: outcome as i32,
            output,
            error_code: error_code.to_owned(),
            error,
            elapsed_milliseconds,
            receipt_id,
            provider_run_reference,
            idempotency_key: invocation_id.to_owned(),
            tool_calls: trace.tool_calls,
            response_messages: trace.response_messages,
            usage: trace.usage,
            validation,
            provider_receipt: trace.provider_receipt,
        },
        &recorded.started_event_id,
        &request.run_id,
    )
}

fn execute_settled_llm_node(
    request: &v1::RequestWorkflowRun,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> Result<NodeExecution> {
    let invocation_id = llm_invocation_id(request, attempt, node);
    let settled = state
        .llm_attempts
        .get(&invocation_id)
        .and_then(|recorded| recorded.settled.as_ref())
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("llm_not_settled".into()))?;
    match v1::WorkflowLlmAttemptOutcome::try_from(settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("llm_outcome".into()))?
    {
        v1::WorkflowLlmAttemptOutcome::Succeeded => Ok(success_output(
            "success",
            settled
                .output
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("llm_output".into()))?,
        )),
        v1::WorkflowLlmAttemptOutcome::OutputValidationFailed
        | v1::WorkflowLlmAttemptOutcome::TimedOut
        | v1::WorkflowLlmAttemptOutcome::MalformedResult
        | v1::WorkflowLlmAttemptOutcome::Crashed => Ok(failure_output(
            "error",
            &settled.error_code,
            settled
                .error
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("llm_error".into()))?,
        )),
        v1::WorkflowLlmAttemptOutcome::Cancelled => Err(WorkflowExecutionError::Lifecycle(
            "cancelled_llm_reentered".into(),
        )),
        v1::WorkflowLlmAttemptOutcome::Unspecified => {
            Err(WorkflowExecutionError::Integrity("llm_outcome".into()))
        }
    }
}

fn llm_invocation_id(
    request: &v1::RequestWorkflowRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> String {
    stable_id(
        "llm",
        &[&request.run_id, &attempt.started.attempt_id, &node.id],
    )
}

/// One `effect.connector` attempt, either ready to reach the connector host or
/// already refused before any authority exists.
enum EffectPreparation {
    Ready(Box<PreparedEffect>),
    Refused { code: &'static str, detail: Value },
}

struct PreparedEffect {
    proposal: v1::WorkflowEffectProposed,
    effect_id: String,
}

/// Builds the exact proposal one attempt would record. The result is derived
/// only from the compiled node, the mapped input, and durable attempt facts, so
/// every replay of the same attempt produces the same effect identity.
fn prepare_effect(
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<EffectPreparation> {
    let config: ConnectorEffectConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("connector_effect_config".into()))?;
    let class = WorkflowMailEffectClass::from_action(&config.action)
        .ok_or_else(|| WorkflowExecutionError::Integrity("connector_effect_action".into()))?;
    let edge_input = inputs
        .last()
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("effect_input_missing".into()))?
        .1
        .clone();
    let mapped = apply_mapping(
        &config.input,
        &edge_input,
        &stable_id(
            "value",
            &[&request.run_id, &attempt.started.attempt_id, "effect-input"],
        ),
    )?;
    let input = match mapped {
        Ok(value) => value,
        Err(error) => {
            return Ok(EffectPreparation::Refused {
                code: "effect.input-mapping-failed",
                detail: json!({
                    "action": config.action,
                    "expressionPath": error.expression_path,
                    "reason": error.code
                }),
            });
        }
    };
    let payload = inline_json(&input)?;
    let account_binding_id = payload
        .get("accountBindingId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let destination_fingerprint = payload
        .get("destinationFingerprint")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let proposal = mail_effect_proposal(WorkflowMailEffectRequest {
        class,
        run_id: request.run_id.clone(),
        run_token_id: run_token_id.to_owned(),
        attempt_id: attempt.started.attempt_id.clone(),
        execution_token_id: attempt.started.execution_token_id.clone(),
        node_id: node.id.clone(),
        workflow_id: request.workflow_id.clone(),
        revision_id: request.revision_id.clone(),
        project_id: request.installation_id.clone(),
        workspace_id: request.case_id.clone(),
        account_binding_id,
        destination_fingerprint,
        input_digest: input.sha256.clone(),
        expires_at_unix_millis: attempt
            .started_at_unix_millis
            .saturating_add(EFFECT_AUTHORITY_WINDOW_MILLISECONDS),
    });
    let proposal = match proposal {
        Ok(proposal) => proposal,
        Err(error) => {
            return Ok(EffectPreparation::Refused {
                code: "effect.input-rejected",
                detail: json!({"action": config.action, "reason": error.to_string()}),
            });
        }
    };
    let effect_id = proposal
        .intent
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("effect_intent_missing".into()))?
        .effect_id
        .clone();
    Ok(EffectPreparation::Ready(Box::new(PreparedEffect {
        proposal,
        effect_id,
    })))
}

/// Advances one `effect.connector` attempt by a single durable fact: propose,
/// authorize, start dispatch, settle dispatch, then bounded reconciliation.
///
/// The journaled dispatch-started fact is the outbox boundary. The executor
/// offers a dispatch record to the connector at most once per pass, and an
/// interrupted pass re-offers the same record under the same idempotency key,
/// which the registration must honour (`idempotent` and `supportsReconciliation`
/// are both required before an intent may cross the boundary at all). Returning
/// `None` hands the attempt to `execute_settled_effect_node`, which reads the
/// journaled facts and selects the node's port.
#[allow(clippy::too_many_arguments)]
fn pending_effect_event_sequence(
    effects: &mut dyn WorkflowEffectHost,
    request: &v1::RequestWorkflowRun,
    run_token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<Option<Vec<v1::EventEnvelope>>> {
    let EffectPreparation::Ready(prepared) =
        prepare_effect(request, run_token_id, attempt, node, inputs)?
    else {
        return Ok(None);
    };
    let proposal = &prepared.proposal;
    let effect_id = prepared.effect_id.as_str();
    let intent = proposal
        .intent
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("effect_intent_missing".into()))?;
    let approval = proposal
        .approval_request
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("effect_approval_missing".into()))?;
    let preview = proposal
        .preview
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("effect_preview_missing".into()))?;
    let Some(recorded) = state.effects.get(effect_id) else {
        return Ok(Some(vec![runtime_event(
            attempt.started_at_unix_millis,
            &effect_event_id(request, "effect-proposed", effect_id),
            workflow_runtime::WORKFLOW_EFFECT_PROPOSED_KIND,
            workflow_runtime::WORKFLOW_EFFECT_PROPOSED_TYPE,
            proposal.clone(),
            &attempt.started_event_id,
            &request.run_id,
        )]));
    };
    if &recorded.proposed != proposal {
        return Err(WorkflowExecutionError::Integrity(
            "recorded_effect_proposal_mismatch".into(),
        ));
    }
    let Some(authorization) = recorded.authorized.as_ref() else {
        // Authority stays outside the executor: the host returns the exact
        // resolution an owner recorded for this approval request, or nothing.
        let Some(resolution) = effects.authorize(proposal) else {
            return Ok(None);
        };
        if resolution.approval_id != approval.approval_id
            || resolution.expected_fingerprint != approval.fingerprint
            || v1::ApprovalDecision::try_from(resolution.decision)
                != Ok(v1::ApprovalDecision::Approve)
        {
            return Ok(None);
        }
        return Ok(Some(vec![runtime_event(
            attempt.started_at_unix_millis,
            &effect_event_id(request, "effect-authorized", effect_id),
            workflow_runtime::WORKFLOW_EFFECT_AUTHORIZED_KIND,
            workflow_runtime::WORKFLOW_EFFECT_AUTHORIZED_TYPE,
            v1::WorkflowEffectAuthorized {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                effect_id: effect_id.to_owned(),
                grant_id: stable_effect_id("effect-grant", &approval.approval_id, effect_id),
                resolution: Some(resolution),
                approval_fingerprint: approval.fingerprint.clone(),
                intent_digest: proposal.intent_digest.clone(),
                preview_digest: preview.preview_digest.clone(),
                destination_fingerprint: intent.destination_fingerprint.clone(),
                idempotency_key: intent.idempotency_key.clone(),
                expires_at_unix_millis: approval.expires_at_unix_millis,
            },
            &recorded.proposed_event_id,
            &request.run_id,
        )]));
    };
    let Some(dispatch) = recorded.dispatch_started.as_ref() else {
        let Some(registration) =
            effects.registration(&intent.connector_class, &intent.account_binding_id)
        else {
            return Ok(None);
        };
        if !registration_matches(&registration, intent) {
            return Ok(None);
        }
        let dispatch_id = stable_effect_id("effect-dispatch", effect_id, &intent.idempotency_key);
        return Ok(Some(vec![runtime_event(
            attempt.started_at_unix_millis,
            &effect_event_id(request, "effect-dispatch-started", effect_id),
            workflow_runtime::WORKFLOW_EFFECT_DISPATCH_STARTED_KIND,
            workflow_runtime::WORKFLOW_EFFECT_DISPATCH_STARTED_TYPE,
            v1::WorkflowEffectDispatchStarted {
                run_id: request.run_id.clone(),
                run_token_id: run_token_id.to_owned(),
                effect_id: effect_id.to_owned(),
                dispatch_id,
                grant_id: authorization.grant_id.clone(),
                intent_digest: proposal.intent_digest.clone(),
                preview_digest: preview.preview_digest.clone(),
                destination_fingerprint: intent.destination_fingerprint.clone(),
                idempotency_key: intent.idempotency_key.clone(),
                registration: Some(registration),
                deadline_unix_millis: authorization.expires_at_unix_millis.min(
                    attempt
                        .started_at_unix_millis
                        .saturating_add(EFFECT_DISPATCH_TIMEOUT_MILLISECONDS),
                ),
            },
            recorded.latest_event_id(),
            &request.run_id,
        )]));
    };
    let mut connector_request = WorkflowEffectConnectorRequest {
        proposal: proposal.clone(),
        authorization: authorization.clone(),
        dispatch: dispatch.clone(),
        prior_receipt: None,
    };
    let Some(settled) = recorded.dispatch_settled.as_ref() else {
        let result =
            dispatch_result_payload(&connector_request, effects.dispatch(&connector_request));
        return Ok(Some(vec![runtime_event(
            occurred_after_effect_phase(
                recorded.dispatch_started_at_unix_millis,
                result.elapsed_milliseconds,
            ),
            &effect_event_id(request, "effect-dispatch-settled", effect_id),
            workflow_runtime::WORKFLOW_EFFECT_DISPATCH_SETTLED_KIND,
            workflow_runtime::WORKFLOW_EFFECT_DISPATCH_SETTLED_TYPE,
            result,
            recorded.latest_event_id(),
            &request.run_id,
        )]));
    };
    if v1::WorkflowEffectDispatchOutcome::try_from(settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("effect_dispatch_outcome".into()))?
        != v1::WorkflowEffectDispatchOutcome::Unknown
    {
        return Ok(None);
    }
    if let Some(latest) = recorded.latest_reconciliation()
        && v1::WorkflowEffectReconciliationOutcome::try_from(latest.payload.outcome).map_err(
            |_| WorkflowExecutionError::Integrity("effect_reconciliation_outcome".into()),
        )? != v1::WorkflowEffectReconciliationOutcome::StillUnknown
    {
        return Ok(None);
    }
    let ordinal = recorded.reconciliations.len();
    if ordinal >= MAXIMUM_EFFECT_RECONCILIATION_CHECKS {
        return Ok(None);
    }
    connector_request.prior_receipt = settled.receipt.clone();
    let reconciliation_id = stable_effect_id(
        "effect-reconciliation",
        effect_id,
        &format!("{}:{}", dispatch.dispatch_id, ordinal + 1),
    );
    let reconciled = reconciliation_result_payload(
        &connector_request,
        reconciliation_id,
        effects.reconcile(&connector_request),
    );
    Ok(Some(vec![runtime_event(
        occurred_after_effect_phase(
            recorded.latest_occurred_at_unix_millis(),
            reconciled.elapsed_milliseconds,
        ),
        &effect_event_id(
            request,
            &format!("effect-reconciled-{}", ordinal + 1),
            effect_id,
        ),
        workflow_runtime::WORKFLOW_EFFECT_RECONCILED_KIND,
        workflow_runtime::WORKFLOW_EFFECT_RECONCILED_TYPE,
        reconciled,
        recorded.latest_event_id(),
        &request.run_id,
    )]))
}

fn effect_event_id(request: &v1::RequestWorkflowRun, phase: &str, effect_id: &str) -> String {
    stable_id("event", &[&request.run_id, phase, effect_id])
}

fn occurred_after_effect_phase(started_at_unix_millis: i64, elapsed_milliseconds: u64) -> i64 {
    started_at_unix_millis.saturating_add(i64::try_from(elapsed_milliseconds).unwrap_or(i64::MAX))
}

/// Selects the node's port from the journaled effect facts. `success` carries
/// the applied receipt; `error` carries the projection status and the number of
/// reconciliation checks already spent, which is exactly what a downstream
/// `control.reconcile` node reads to continue an unknown outcome.
fn execute_settled_effect_node(
    request: &v1::RequestWorkflowRun,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
    inputs: &[(
        Option<&v1::WorkflowEdgeCheckpointed>,
        v1::WorkflowValueReference,
    )],
) -> Result<NodeExecution> {
    let prepared = match prepare_effect(
        request,
        &attempt.started.run_token_id,
        attempt,
        node,
        inputs,
    )? {
        EffectPreparation::Ready(prepared) => prepared,
        EffectPreparation::Refused { code, detail } => {
            let value = effect_outcome_value(request, node, code, String::new(), 0, detail)?;
            return Ok(failure_output("error", code, value));
        }
    };
    let effect_id = prepared.effect_id.as_str();
    let recorded = state
        .effects
        .get(effect_id)
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("effect_not_proposed".into()))?;
    let checks = recorded.reconciliations.len() as u64;
    let failure = |code: &'static str, status: &str, detail: Value| -> Result<NodeExecution> {
        let value = effect_outcome_value(
            request,
            node,
            code,
            effect_id.to_owned(),
            checks,
            merged_effect_detail(status, detail),
        )?;
        Ok(failure_output("error", code, value))
    };
    if recorded.authorized.is_none() {
        return failure("effect.not-authorized", "proposed", json!({}));
    }
    let Some(dispatch) = recorded.dispatch_started.as_ref() else {
        return failure("effect.connector-unavailable", "authorized", json!({}));
    };
    let Some(settled) = recorded.dispatch_settled.as_ref() else {
        return failure("effect.dispatch-interrupted", "dispatching", json!({}));
    };
    if let Some(latest) = recorded.latest_reconciliation() {
        let outcome = v1::WorkflowEffectReconciliationOutcome::try_from(latest.payload.outcome)
            .map_err(|_| {
                WorkflowExecutionError::Integrity("effect_reconciliation_outcome".into())
            })?;
        return match outcome {
            v1::WorkflowEffectReconciliationOutcome::Applied => Ok(success_output(
                "success",
                effect_applied_value(
                    request,
                    node,
                    effect_id,
                    checks,
                    "reconciled_applied",
                    &latest.payload.receipt,
                )?,
            )),
            v1::WorkflowEffectReconciliationOutcome::NotApplied => failure(
                "effect.not-applied",
                "reconciled_not_applied",
                json!({"reason": latest.payload.error_code}),
            ),
            v1::WorkflowEffectReconciliationOutcome::StillUnknown => failure(
                "effect.outcome-unknown",
                "outcome_unknown",
                json!({
                    "dispatchId": dispatch.dispatch_id,
                    "reason": latest.payload.error_code
                }),
            ),
            v1::WorkflowEffectReconciliationOutcome::Unspecified => Err(
                WorkflowExecutionError::Integrity("effect_reconciliation_outcome".into()),
            ),
        };
    }
    match v1::WorkflowEffectDispatchOutcome::try_from(settled.outcome)
        .map_err(|_| WorkflowExecutionError::Integrity("effect_dispatch_outcome".into()))?
    {
        v1::WorkflowEffectDispatchOutcome::Succeeded => Ok(success_output(
            "success",
            effect_applied_value(
                request,
                node,
                effect_id,
                checks,
                "succeeded",
                &settled.receipt,
            )?,
        )),
        v1::WorkflowEffectDispatchOutcome::Rejected => failure(
            "effect.rejected",
            "rejected",
            json!({"reason": settled.error_code}),
        ),
        v1::WorkflowEffectDispatchOutcome::NotSent => failure(
            "effect.not-sent",
            "not_sent",
            json!({"reason": settled.error_code}),
        ),
        v1::WorkflowEffectDispatchOutcome::Unknown => failure(
            "effect.outcome-unknown",
            "outcome_unknown",
            json!({
                "dispatchId": dispatch.dispatch_id,
                "reason": settled.error_code
            }),
        ),
        v1::WorkflowEffectDispatchOutcome::Unspecified => Err(WorkflowExecutionError::Integrity(
            "effect_dispatch_outcome".into(),
        )),
    }
}

fn merged_effect_detail(status: &str, detail: Value) -> Value {
    let mut merged = json!({"status": status});
    if let (Some(target), Some(fields)) = (merged.as_object_mut(), detail.as_object()) {
        for (key, value) in fields {
            target.insert(key.clone(), value.clone());
        }
    }
    merged
}

fn effect_outcome_value(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    code: &str,
    effect_id: String,
    checks: u64,
    detail: Value,
) -> Result<v1::WorkflowValueReference> {
    let mut payload = json!({
        "code": code,
        "effectId": effect_id,
        "checks": checks
    });
    if let (Some(target), Some(fields)) = (payload.as_object_mut(), detail.as_object()) {
        for (key, value) in fields {
            target.insert(key.clone(), value.clone());
        }
    }
    value_from_json(
        &stable_id("value", &[&request.run_id, &node.id, code, &effect_id]),
        &payload,
    )
}

fn effect_applied_value(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    effect_id: &str,
    checks: u64,
    status: &str,
    receipt: &Option<v1::WorkflowEffectReceipt>,
) -> Result<v1::WorkflowValueReference> {
    let receipt = receipt
        .as_ref()
        .ok_or_else(|| WorkflowExecutionError::Integrity("effect_receipt_missing".into()))?;
    effect_outcome_value(
        request,
        node,
        "effect.applied",
        effect_id.to_owned(),
        checks,
        json!({
            "status": status,
            "receiptId": receipt.receipt_id,
            "evidenceDigest": receipt.evidence_digest
        }),
    )
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
    job_run_id: &str,
) -> Result<NodeExecution> {
    match node.node_type.as_str() {
        "trigger.manual" | "trigger.event" | "trigger.schedule" => {
            Ok(success_output("success", input.clone()))
        }
        "data.case-context" => {
            let context = episode
                .and_then(|episode| episode.compiled_context.clone())
                .ok_or(WorkflowExecutionError::InvalidCommand(
                    "case_episode_required",
                ))?;
            Ok(success_output("success", context))
        }
        "data.map" => {
            let mapping = node
                .config
                .get("mapping")
                .ok_or_else(|| WorkflowExecutionError::Integrity("map_config".into()))?;
            match apply_mapping(
                mapping,
                input,
                &stable_id(
                    "value",
                    &[&request.run_id, &node.id, attempt_id, "map-output"],
                ),
            )? {
                Ok(value) => Ok(success_output("success", value)),
                Err(error) => {
                    let value = mapping_failure_value(request, &node.id, "mapping", &error)?;
                    Ok(failure_output("error", &error.code, value))
                }
            }
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
                EvaluationOutcome::Matched if !emitted_port_ids.is_empty() => (
                    emitted_port_ids
                        .iter()
                        .map(|port_id| (port_id.clone(), input.clone()))
                        .collect(),
                    v1::WorkflowAttemptOutcome::Succeeded,
                    String::new(),
                    None,
                ),
                EvaluationOutcome::Matched
                | EvaluationOutcome::NotMatched
                | EvaluationOutcome::EvaluationError => {
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
        "control.decision" => {
            let config: DecisionConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("decision_config".into()))?;
            let evaluation = workflow_match::evaluate(
                &decision_match_config(&config)?,
                &MatchRoots::with_input(inline_json(input)?),
            );
            match evaluation.outcome {
                EvaluationOutcome::Matched
                    if evaluation.selected_case_ids.first().map(String::as_str)
                        == Some(DECISION_MATCHED_CASE_ID) =>
                {
                    Ok(success_output("matched", input.clone()))
                }
                EvaluationOutcome::Matched => Ok(success_output("not-matched", input.clone())),
                EvaluationOutcome::NotMatched | EvaluationOutcome::EvaluationError => {
                    let evaluation_error = evaluation.error.as_ref();
                    let code = evaluation_error
                        .map(|error| error.code.clone())
                        .unwrap_or_else(|| "decision.no-route".into());
                    let value = value_from_json(
                        &stable_id("value", &[&request.run_id, &node.id, "decision-error"]),
                        &json!({
                            "code": code,
                            "expressionId": evaluation_error.map(|error| error.expression_id.as_str()),
                            "message": evaluation_error
                                .map(|error| error.message.as_str())
                                .unwrap_or("The Decision condition did not resolve.")
                        }),
                    )?;
                    Ok(failure_output("error", &code, value))
                }
            }
        }
        "control.reconcile" => execute_reconcile_node(request, node, input),
        "data.register-artifact" => execute_register_artifact_node(
            package,
            storage.ok_or_else(|| {
                WorkflowExecutionError::Unsupported("storage_service_required".into())
            })?,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
            job_run_id,
        ),
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
            job_run_id,
        ),
        "terminal.complete" => Ok(NodeExecution {
            match_trace: None,
            outputs: Vec::new(),
            outcome: v1::WorkflowAttemptOutcome::Succeeded,
            error_code: String::new(),
            error: None,
        }),
        "terminal.fail" => {
            let error = match node.config.get("error") {
                Some(mapping) => apply_mapping(
                    mapping,
                    input,
                    &stable_id("value", &[&request.run_id, &node.id, "terminal-error"]),
                )?
                .unwrap_or_else(|_| input.clone()),
                None => input.clone(),
            };
            let code = error_code(&error)?;
            Ok(NodeExecution {
                match_trace: None,
                outputs: Vec::new(),
                outcome: v1::WorkflowAttemptOutcome::Failed,
                error_code: code,
                error: Some(error),
            })
        }
        "terminal.cancel" => {
            let config: CancelConfig = serde_json::from_value(node.config.clone())
                .map_err(|_| WorkflowExecutionError::Integrity("cancel_config".into()))?;
            let reason = match config.reason.as_ref() {
                Some(mapping) => apply_mapping(
                    mapping,
                    input,
                    &stable_id("value", &[&request.run_id, &node.id, "cancel-reason"]),
                )?
                .unwrap_or_else(|_| input.clone()),
                None => input.clone(),
            };
            Ok(NodeExecution {
                match_trace: None,
                outputs: Vec::new(),
                outcome: v1::WorkflowAttemptOutcome::Cancelled,
                error_code: cancellation_reason_code(&reason)?,
                error: Some(reason),
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
struct EventTriggerConfig {
    event_contract: String,
    deduplication: String,
    #[serde(default)]
    correlation: Vec<StorageValueSelector>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScheduleTriggerConfig {
    schedule_key: String,
    misfire_policy: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WaitConfig {
    kind: String,
    correlation: Vec<StorageValueSelector>,
    expiry_seconds: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecisionConfig {
    when: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReconcileConfig {
    effect: StorageValueSelector,
    maximum_checks: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HumanReviewConfig {
    proposal: Value,
    authority_policy: String,
    expiry_seconds: u64,
    stale_check: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RegisterArtifactConfig {
    role: String,
    media_types: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CancelConfig {
    #[serde(default)]
    reason: Option<Value>,
}

const DECISION_MATCHED_CASE_ID: &str = "decision-matched";
const DECISION_OTHERWISE_CASE_ID: &str = "decision-not-matched";

/// A Decision is a two-way Match over the whole node input, so it reuses the
/// audited Match condition evaluator rather than a second condition engine.
fn decision_match_config(config: &DecisionConfig) -> Result<MatchConfig> {
    serde_json::from_value(json!({
        "value": {"root": "input", "pointer": ""},
        "hitPolicy": "first",
        "cases": [{
            "id": DECISION_MATCHED_CASE_ID,
            "key": "matched",
            "label": "Matched",
            "when": config.when.clone()
        }],
        "otherwise": {
            "id": DECISION_OTHERWISE_CASE_ID,
            "key": "not-matched",
            "label": "Not matched"
        }
    }))
    .map_err(|_| WorkflowExecutionError::Integrity("decision_condition".into()))
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

/// Reconcile settles an unknown effect outcome from the envelope the caller
/// already journaled. The executor has no live effect connector in this slice,
/// so it advances the bounded check counter instead of probing a provider.
fn execute_reconcile_node(
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    input: &v1::WorkflowValueReference,
) -> Result<NodeExecution> {
    let config: ReconcileConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("reconcile_config".into()))?;
    let unknown = inline_json(input)?;
    let effect_id = unknown
        .pointer(&config.effect.pointer)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let status = unknown
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let checks = unknown.get("checks").and_then(Value::as_u64).unwrap_or(0) as u32;
    let summary = |code: &str, checks: u32| -> Result<v1::WorkflowValueReference> {
        value_from_json(
            &stable_id("value", &[&request.run_id, &node.id, code]),
            &json!({
                "code": code,
                "effectId": effect_id,
                "status": status,
                "checks": checks,
                "maximumChecks": config.maximum_checks
            }),
        )
    };
    if effect_id.is_empty() {
        let value = summary("reconcile.effect-missing", checks)?;
        return Ok(failure_output("failure", "reconcile.effect-missing", value));
    }
    match status {
        "reconciled_applied" => Ok(success_output(
            "success",
            summary("reconcile.applied", checks)?,
        )),
        "reconciled_not_applied" => Ok(failure_output(
            "failure",
            "reconcile.not-applied",
            summary("reconcile.not-applied", checks)?,
        )),
        "outcome_unknown" if checks < config.maximum_checks => Ok(NodeExecution {
            match_trace: None,
            outputs: vec![(
                "still-unknown".into(),
                summary("reconcile.still-unknown", checks + 1)?,
            )],
            outcome: v1::WorkflowAttemptOutcome::Succeeded,
            error_code: String::new(),
            error: None,
        }),
        "outcome_unknown" => Ok(failure_output(
            "failure",
            "reconcile.exhausted",
            summary("reconcile.exhausted", checks)?,
        )),
        _ => Ok(failure_output(
            "failure",
            "reconcile.status-invalid",
            summary("reconcile.status-invalid", checks)?,
        )),
    }
}

/// Registers an inline artifact envelope in the job storage namespace declared
/// under the node's role, so the artifact keeps a durable handle and digest.
#[allow(clippy::too_many_arguments)]
fn execute_register_artifact_node(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
    job_run_id: &str,
) -> Result<NodeExecution> {
    let config: RegisterArtifactConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("register_artifact_config".into()))?;
    let artifact = inline_json(input)?;
    let media_type = artifact
        .get("mediaType")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let content = artifact_content_bytes(&artifact);
    let rejection = if media_type.is_empty() || content.is_none() {
        Some("artifact.malformed")
    } else if !config.media_types.contains(&media_type) {
        Some("artifact.media-type-rejected")
    } else {
        None
    };
    if let Some(code) = rejection {
        let value = value_from_json(
            &stable_id("value", &[&request.run_id, &node.id, "artifact-error"]),
            &json!({
                "code": code,
                "role": config.role,
                "mediaType": media_type,
                "acceptedMediaTypes": config.media_types
            }),
        )?;
        return Ok(failure_output("error", code, value));
    }
    let content = content.unwrap();
    let mut stored = artifact;
    let envelope = stored
        .as_object_mut()
        .ok_or_else(|| WorkflowExecutionError::Integrity("artifact_envelope".into()))?;
    envelope.insert("role".into(), json!(config.role));
    envelope.insert("byteCount".into(), json!(content.len()));
    envelope.insert(
        "contentSha256".into(),
        json!(hex::encode(Sha256::digest(&content))),
    );
    let declaration = storage_declaration(package, "job", &config.role)?;
    let (access, namespace) = storage_access(request, "job", job_run_id)?;
    storage.ensure_namespace_capacity(
        namespace.clone(),
        storage_quota(package, "job")?,
        occurred_at_unix_millis,
    )?;
    let version_id = stable_id("storage-version", &[&request.run_id, &node.id, "artifact"]);
    let receipt = storage.write_value(WorkflowStorageWriteRequest {
        command_id: stable_id("storage-command", &[&request.run_id, &node.id, "artifact"]),
        access,
        namespace: namespace.clone(),
        entry_id: stable_id(
            "storage-entry",
            &[&namespace.owner_id, "job", &declaration.key],
        ),
        version_id,
        reference_id: None,
        logical_key: declaration.key.clone(),
        expected_revision: 0,
        schema_ref: Some(declaration.schema_ref.clone()),
        media_type: media_type.clone(),
        classification: declaration.classification.clone(),
        purpose: "artifact".into(),
        value: WorkflowStorageValueInput::InlineCanonicalJson {
            bytes: canonical_json_bytes(&stored)?,
        },
        created_by_attempt_id: attempt_id.into(),
        created_at_unix_millis: occurred_at_unix_millis,
    })?;
    Ok(success_output(
        "success",
        storage_handle_value(
            &stable_id("value", &[&request.run_id, &node.id, "artifact"]),
            &receipt.handle,
            "written",
        ),
    ))
}

/// Fixture artifacts arrive inline as UTF-8 text or Base64 content.
fn artifact_content_bytes(artifact: &Value) -> Option<Vec<u8>> {
    if let Some(text) = artifact.get("text").and_then(Value::as_str) {
        return Some(text.as_bytes().to_vec());
    }
    decode_base64(artifact.get("bytesBase64").and_then(Value::as_str)?)
}

fn decode_base64(encoded: &str) -> Option<Vec<u8>> {
    let symbols = encoded.trim_end_matches('=');
    if !encoded.len().is_multiple_of(4) || encoded.len() - symbols.len() > 2 {
        return None;
    }
    let mut bits = 0_u32;
    let mut width = 0_u32;
    let mut decoded = Vec::with_capacity(symbols.len() / 4 * 3);
    for symbol in symbols.bytes() {
        let value = match symbol {
            b'A'..=b'Z' => symbol - b'A',
            b'a'..=b'z' => symbol - b'a' + 26,
            b'0'..=b'9' => symbol - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(value);
        width += 6;
        if width >= 8 {
            width -= 8;
            decoded.push(((bits >> width) & 0xff) as u8);
        }
    }
    ((bits & ((1 << width) - 1)) == 0).then_some(decoded)
}

#[allow(clippy::too_many_arguments)]
fn execute_storage_node(
    package: &ExecutionPackage,
    storage: &mut WorkflowScopedStorage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    attempt_id: &str,
    occurred_at_unix_millis: i64,
    input: &v1::WorkflowValueReference,
    job_run_id: &str,
) -> Result<NodeExecution> {
    let operation = match node.node_type.as_str() {
        "storage.read" => execute_storage_read(
            package,
            storage,
            request,
            node,
            occurred_at_unix_millis,
            job_run_id,
        ),
        "storage.write" => execute_storage_write(
            package,
            storage,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
            job_run_id,
        ),
        "storage.promote" => execute_storage_promote(
            package,
            storage,
            request,
            node,
            attempt_id,
            occurred_at_unix_millis,
            input,
            job_run_id,
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
    job_run_id: &str,
) -> Result<v1::WorkflowValueReference> {
    let config: StorageReadConfig = serde_json::from_value(node.config.clone())
        .map_err(|_| WorkflowExecutionError::Integrity("storage_read_config".into()))?;
    let declaration = storage_declaration(package, &config.scope, &config.key)?;
    let (access, namespace) = storage_access(request, &config.scope, job_run_id)?;
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
    job_run_id: &str,
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
    let (access, namespace) = storage_access(request, &config.scope, job_run_id)?;
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
    job_run_id: &str,
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
    let (access, source_namespace) = storage_access(request, &config.from, job_run_id)?;
    let (_, destination_namespace) = storage_access(request, &config.to, job_run_id)?;
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
    job_run_id: &str,
) -> Result<(WorkflowStorageAccessContext, WorkflowStorageNamespace)> {
    let access = WorkflowStorageAccessContext {
        run_id: Some(job_run_id.to_owned()),
        case_id: (!request.case_id.is_empty()).then(|| request.case_id.clone()),
        installation_id: request.installation_id.clone(),
        account_binding_ids: BTreeSet::new(),
    };
    let namespace = match scope {
        "job" => WorkflowStorageNamespace {
            kind: WorkflowStorageScopeKind::Job,
            owner_id: job_run_id.to_owned(),
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
                "control.match"
                    if attempt
                        .settled
                        .as_ref()
                        .is_some_and(|settled| settled.emission_ids.len() > 1) =>
                {
                    (
                        v1::WorkflowExecutionTokenOutcome::Forked,
                        String::new(),
                        String::new(),
                        None,
                        Vec::new(),
                    )
                }
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
                "terminal.cancel" => {
                    let settled = attempt.settled.as_ref().unwrap();
                    (
                        v1::WorkflowExecutionTokenOutcome::Cancelled,
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
            "named" => config.required_branches.len() as u32,
            _ => {
                return Err(WorkflowExecutionError::Unsupported(
                    "join_policy_not_executable".into(),
                ));
            }
        };
        let threshold_usize = threshold as usize;
        // A named join waits for the exact branch identities it lists, so it
        // counts branch arrivals rather than any arrival.
        let (satisfied, reachable) = if config.policy == "named" {
            let branch_of = |token_id: &String| {
                state
                    .execution_tokens
                    .get(token_id)
                    .map(|token| token.created.branch_id.clone())
                    .unwrap_or_default()
            };
            let arrived_branches = arrived.iter().map(branch_of).collect::<BTreeSet<_>>();
            let pending_branches = pending.iter().map(branch_of).collect::<BTreeSet<_>>();
            (
                config
                    .required_branches
                    .iter()
                    .filter(|branch| arrived_branches.contains(*branch))
                    .count(),
                config
                    .required_branches
                    .iter()
                    .filter(|branch| {
                        arrived_branches.contains(*branch) || pending_branches.contains(*branch)
                    })
                    .count(),
            )
        } else {
            (arrived.len(), arrived.len() + pending.len())
        };
        let decision = if satisfied >= threshold_usize {
            Some(v1::WorkflowJoinDecision::Succeeded)
        } else if reachable < threshold_usize {
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
                    ) || (settled.outcome == v1::WorkflowExecutionTokenOutcome::Cancelled as i32
                        && !settled.terminal_node_id.is_empty())
                })
        })
        .collect::<Vec<_>>();
    terminal.sort_by_key(|token| token.created_store_position);
    let outcome_of = |token: &&RecordedExecutionToken| {
        token.settled.as_ref().map_or(0, |settled| settled.outcome)
    };
    let selected = terminal
        .iter()
        .rev()
        .find(|token| outcome_of(token) == v1::WorkflowExecutionTokenOutcome::Failed as i32)
        .or_else(|| {
            terminal.iter().rev().find(|token| {
                outcome_of(token) == v1::WorkflowExecutionTokenOutcome::Cancelled as i32
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
    if settled.outcome == v1::WorkflowExecutionTokenOutcome::Cancelled as i32 {
        Ok(CompletedRunOutcome {
            outcome: v1::WorkflowRunOutcome::Cancelled,
            error_code: settled.error_code.clone(),
            error: settled.error.clone(),
            final_emission_ids: Vec::new(),
            causation_id: event_id,
        })
    } else if settled.outcome == v1::WorkflowExecutionTokenOutcome::Failed as i32 {
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
            WorkflowRuntimeEvent::SubflowCalled(payload) => {
                if state
                    .subflows
                    .insert(
                        payload.invocation_id.clone(),
                        RecordedSubflow {
                            called: payload,
                            settled: None,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_subflow_call".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::SubflowSettled(payload) => {
                let subflow = state
                    .subflows
                    .get_mut(&payload.invocation_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("subflow_call_missing".into())
                    })?;
                if subflow.called.child_run_id != payload.child_run_id
                    || subflow.settled.replace(payload).is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "subflow_settled_mismatch".into(),
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
            WorkflowRuntimeEvent::CapabilityAttemptStarted(payload) => {
                if state
                    .capability_attempts
                    .insert(
                        payload.invocation_id.clone(),
                        RecordedCapabilityAttempt {
                            started_event_id: envelope.event_id,
                            started_at_unix_millis: envelope.occurred_at_unix_millis,
                            started: payload,
                            settled_event_id: None,
                            settled: None,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_capability_attempt".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::CapabilityAttemptSettled(payload) => {
                let capability = state
                    .capability_attempts
                    .get_mut(&payload.invocation_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle(
                            "capability_attempt_started_missing".into(),
                        )
                    })?;
                if capability.started.attempt_id != payload.attempt_id
                    || capability.settled.replace(payload).is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "capability_attempt_settled_mismatch".into(),
                    ));
                }
                capability.settled_event_id = Some(envelope.event_id);
            }
            WorkflowRuntimeEvent::LlmAttemptStarted(payload) => {
                if state
                    .llm_attempts
                    .insert(
                        payload.invocation_id.clone(),
                        RecordedLlmAttempt {
                            started_event_id: envelope.event_id,
                            started_at_unix_millis: envelope.occurred_at_unix_millis,
                            started: payload,
                            settled_event_id: None,
                            settled: None,
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_llm_attempt".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::LlmAttemptSettled(payload) => {
                let llm = state
                    .llm_attempts
                    .get_mut(&payload.invocation_id)
                    .ok_or_else(|| {
                        WorkflowExecutionError::Lifecycle("llm_attempt_started_missing".into())
                    })?;
                if llm.started.attempt_id != payload.attempt_id
                    || llm.settled.replace(payload).is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "llm_attempt_settled_mismatch".into(),
                    ));
                }
                llm.settled_event_id = Some(envelope.event_id);
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
            WorkflowRuntimeEvent::EffectProposed(payload) => {
                let effect_id = payload
                    .intent
                    .as_ref()
                    .ok_or_else(|| {
                        WorkflowExecutionError::Integrity("effect_intent_missing".into())
                    })?
                    .effect_id
                    .clone();
                if state
                    .effects
                    .insert(
                        effect_id,
                        RecordedEffect {
                            proposed_event_id: envelope.event_id,
                            proposed: payload,
                            authorized_event_id: None,
                            authorized: None,
                            dispatch_started_event_id: None,
                            dispatch_started: None,
                            dispatch_started_at_unix_millis: 0,
                            dispatch_settled_event_id: None,
                            dispatch_settled: None,
                            dispatch_settled_at_unix_millis: 0,
                            reconciliations: Vec::new(),
                        },
                    )
                    .is_some()
                {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_effect_proposal".into(),
                    ));
                }
            }
            WorkflowRuntimeEvent::EffectAuthorized(payload) => {
                let effect = recorded_effect_mut(&mut state, &payload.effect_id)?;
                if effect.authorized.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "effect_authorized_twice".into(),
                    ));
                }
                effect.authorized_event_id = Some(envelope.event_id);
            }
            WorkflowRuntimeEvent::EffectDispatchStarted(payload) => {
                let effect = recorded_effect_mut(&mut state, &payload.effect_id)?;
                if effect.dispatch_started.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "effect_dispatched_twice".into(),
                    ));
                }
                effect.dispatch_started_event_id = Some(envelope.event_id);
                effect.dispatch_started_at_unix_millis = envelope.occurred_at_unix_millis;
            }
            WorkflowRuntimeEvent::EffectDispatchSettled(payload) => {
                let effect = recorded_effect_mut(&mut state, &payload.effect_id)?;
                if effect.dispatch_settled.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "effect_dispatch_settled_twice".into(),
                    ));
                }
                effect.dispatch_settled_event_id = Some(envelope.event_id);
                effect.dispatch_settled_at_unix_millis = envelope.occurred_at_unix_millis;
            }
            WorkflowRuntimeEvent::EffectReconciled(payload) => {
                let effect = recorded_effect_mut(&mut state, &payload.effect_id)?;
                effect.reconciliations.push(RecordedEffectReconciliation {
                    event_id: envelope.event_id,
                    occurred_at_unix_millis: envelope.occurred_at_unix_millis,
                    payload,
                });
            }
            WorkflowRuntimeEvent::ConnectorObservationStarted(_)
            | WorkflowRuntimeEvent::ConnectorObservationSettled(_) => {
                // Read-only connector qualification has a separate two-phase
                // coordinator. Replay observes its receipts but cannot invoke
                // a provider or turn a read into effect authority.
            }
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
            WorkflowRuntimeEvent::RunPurged(_) => {
                return Err(WorkflowExecutionError::Lifecycle("run_purged".into()));
            }
        }
    }
    state
        .attempts
        .sort_by_key(|attempt| attempt.started_store_position);
    Ok(state)
}

fn recorded_effect_mut<'a>(
    state: &'a mut RecordedRun,
    effect_id: &str,
) -> Result<&'a mut RecordedEffect> {
    state
        .effects
        .get_mut(effect_id)
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("effect_proposal_missing".into()))
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

/// Cancel carries an operator-facing reason rather than a failure, so a plain
/// string, a `{"code": ...}` envelope, and an unmapped input all settle.
fn cancellation_reason_code(value: &v1::WorkflowValueReference) -> Result<String> {
    let reason = inline_json(value)?;
    let code = reason
        .as_str()
        .or_else(|| reason.get("code").and_then(Value::as_str))
        .or_else(|| reason.get("reason").and_then(Value::as_str))
        .filter(|code| !code.is_empty())
        .unwrap_or(DEFAULT_CANCEL_REASON_CODE);
    Ok(code.to_owned())
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
