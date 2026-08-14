//! Minimal durable local workflow executor.
//!
//! The executor consumes only a verified immutable compiled revision and the
//! typed journal contracts. It advances one deterministic event boundary at a
//! time, so resubmitting the same request after a process crash can only append
//! the next missing fact. This first slice supports no connector, model,
//! capability, storage dereference, arbitrary mapping, or external effect.

use crate::{
    journal::{Journal, JournalError, ReplayBasis},
    v1, workflow_canonical,
    workflow_library::{WorkflowLibraryError, WorkflowLibraryStore},
    workflow_match::{self, EvaluationOutcome, MatchConfig, MatchRoots, TraceOutcome},
    workflow_runtime::{self, WorkflowRuntimeCommand, WorkflowRuntimeEvent},
    workflow_schema::{self, WorkflowSchemaCheckOutcome, WorkflowSchemaCheckRequest},
    workflow_versions::WorkflowExecutionSupport,
};
use prost::Message;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
};

const MAXIMUM_EXECUTOR_TRANSITIONS: usize = 1_024;
const RUN_REPLAY_PAGE: u32 = 500;

#[derive(Debug)]
pub enum WorkflowExecutionError {
    Journal(JournalError),
    Library(WorkflowLibraryError),
    InvalidCommand(&'static str),
    Unsupported(String),
    Integrity(String),
    Lifecycle(String),
    Encoding(&'static str),
    InjectedInterruption,
}

impl fmt::Display for WorkflowExecutionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Journal(error) => write!(formatter, "workflow execution journal: {error}"),
            Self::Library(error) => write!(formatter, "workflow execution library: {error}"),
            Self::InvalidCommand(code) => write!(formatter, "workflow execution command: {code}"),
            Self::Unsupported(code) => write!(formatter, "workflow execution unsupported: {code}"),
            Self::Integrity(code) => write!(formatter, "workflow execution integrity: {code}"),
            Self::Lifecycle(code) => write!(formatter, "workflow execution lifecycle: {code}"),
            Self::Encoding(code) => write!(formatter, "workflow execution encoding: {code}"),
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

pub type Result<T> = std::result::Result<T, WorkflowExecutionError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableRunOutcome {
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
    storage: BTreeMap<String, Value>,
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

struct ExecutionPackage {
    compiled: CompiledWorkflow,
    schemas: BTreeMap<String, Value>,
}

#[derive(Default)]
struct RecordedRun {
    events: Vec<v1::EventEnvelope>,
    token: Option<v1::WorkflowRunTokenCreated>,
    attempts: Vec<RecordedAttempt>,
    emissions: BTreeMap<String, RecordedEmission>,
    edges: Vec<RecordedEdge>,
    cancellation: Option<v1::WorkflowRunCancellationRequested>,
    settled: Option<v1::WorkflowRunSettled>,
}

struct RecordedAttempt {
    started_event_id: String,
    started_store_position: u64,
    started: v1::WorkflowAttemptStarted,
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

pub fn execute(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
) -> Result<WorkflowExecutionResult> {
    execute_with_fault(journal, library, command, None)
}

#[doc(hidden)]
pub fn execute_with_fault_for_test(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
    fault: WorkflowExecutionFault,
) -> Result<WorkflowExecutionResult> {
    execute_with_fault(journal, library, command, Some(fault))
}

fn execute_with_fault(
    journal: &mut Journal,
    library: &WorkflowLibraryStore,
    command: &v1::CommandEnvelope,
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
    };
    let package = load_execution_package(library, &request)?;
    journal.admit_command(command)?;
    let token_id = stable_id("token", &[&request.run_id, &command.command_id]);
    let mut appended = 0;

    for _ in 0..MAXIMUM_EXECUTOR_TRANSITIONS {
        let state = recorded_run(journal, &request.run_id)?;
        if let Some(settled) = state.settled.as_ref() {
            return Ok(WorkflowExecutionResult {
                run_id: request.run_id.clone(),
                run_token_id: token_id,
                outcome: durable_outcome(settled.outcome)?,
                event_count: state.events.len(),
            });
        }

        let candidates = next_events(&package, command, &request, &token_id, &state)?;
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
    Err(WorkflowExecutionError::Lifecycle("transition_limit".into()))
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
        || !compiled.storage.is_empty()
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
                    | "control.match"
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

fn next_events(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
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

    if let Some(cancellation) = state.cancellation.as_ref() {
        if let Some(active) = active_attempt(state)? {
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
                },
                &cancellation.cancel_command_id,
                &request.run_id,
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
        let node = compiled_node(&package.compiled, &active.started.node_id)?;
        return node_event_sequence(package, command, request, token_id, state, active, node);
    }

    if let Some(last) = state.attempts.last()
        && let Some(settled) = last.settled.as_ref()
    {
        let node = compiled_node(&package.compiled, &settled.node_id)?;
        if node.node_type == "terminal.complete" {
            let input = node_input(request, state, &node.id)?;
            let emission_id = input.0.map(|edge| edge.emission_id.clone());
            return Ok(vec![run_settled_event(
                command.submitted_at_unix_millis,
                request,
                token_id,
                v1::WorkflowRunOutcome::Succeeded,
                String::new(),
                None,
                emission_id.into_iter().collect(),
                &stable_id("event", &[&request.run_id, "attempt-settled", &node.id]),
            )]);
        }
        if node.node_type == "terminal.fail" {
            let (_, value) = node_input(request, state, &node.id)?;
            let error_code = error_code(&value)?;
            return Ok(vec![run_settled_event(
                command.submitted_at_unix_millis,
                request,
                token_id,
                v1::WorkflowRunOutcome::Failed,
                error_code,
                Some(value),
                Vec::new(),
                &stable_id("event", &[&request.run_id, "attempt-settled", &node.id]),
            )]);
        }
    }

    let (node_id, causation_id) = next_ready_node(&package.compiled, state)?;
    let attempt_id = stable_id("attempt", &[&request.run_id, &node_id, "1"]);
    Ok(vec![runtime_event(
        command.submitted_at_unix_millis,
        &stable_id("event", &[&request.run_id, "attempt-started", &node_id]),
        workflow_runtime::WORKFLOW_ATTEMPT_STARTED_KIND,
        workflow_runtime::WORKFLOW_ATTEMPT_STARTED_TYPE,
        v1::WorkflowAttemptStarted {
            run_id: request.run_id.clone(),
            run_token_id: token_id.to_owned(),
            attempt_id,
            node_id,
            attempt_number: 1,
        },
        &causation_id,
        &request.run_id,
    )])
}

fn node_event_sequence(
    package: &ExecutionPackage,
    command: &v1::CommandEnvelope,
    request: &v1::RequestWorkflowRun,
    token_id: &str,
    state: &RecordedRun,
    attempt: &RecordedAttempt,
    node: &CompiledNode,
) -> Result<Vec<v1::EventEnvelope>> {
    let (_, input) = node_input(request, state, &node.id)?;
    let execution = execute_node(package, request, node, &input)?;
    let mut events = Vec::new();
    let mut causation_id = attempt.started_event_id.clone();

    if let Some(trace) = execution.match_trace {
        let event_id = stable_id("event", &[&request.run_id, "match-trace", &node.id]);
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
            },
            &causation_id,
            &request.run_id,
        ));
        causation_id = event_id;
    }

    let mut emission_ids = Vec::new();
    for (port_id, value) in execution.outputs {
        let emission_id = stable_id("emission", &[&request.run_id, &node.id, &port_id, "1"]);
        let emission_event_id = stable_id("event", &[&request.run_id, "port", &node.id, &port_id]);
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
        let edge_event_id = stable_id("event", &[&request.run_id, "edge", &edge.id, &emission_id]);
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
            },
            &causation_id,
            &request.run_id,
        ));
        causation_id = edge_event_id;
    }

    let settle_event_id = stable_id("event", &[&request.run_id, "attempt-settled", &node.id]);
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
        },
        &causation_id,
        &request.run_id,
    ));
    Ok(events)
}

fn execute_node(
    package: &ExecutionPackage,
    request: &v1::RequestWorkflowRun,
    node: &CompiledNode,
    input: &v1::WorkflowValueReference,
) -> Result<NodeExecution> {
    match node.node_type.as_str() {
        "trigger.manual" => Ok(success_output("success", input.clone())),
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

fn next_ready_node(compiled: &CompiledWorkflow, state: &RecordedRun) -> Result<(String, String)> {
    if state.attempts.is_empty() {
        return Ok((
            compiled.entrypoints[0].node_id.clone(),
            stable_id(
                "event",
                &[state.token.as_ref().unwrap().run_id.as_str(), "token"],
            ),
        ));
    }
    let attempted = state
        .attempts
        .iter()
        .map(|attempt| attempt.started.node_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut ready = state
        .edges
        .iter()
        .filter(|edge| {
            edge.payload.state == v1::WorkflowEdgeCheckpointState::Admitted as i32
                && !attempted.contains(edge.payload.target_node_id.as_str())
        })
        .collect::<Vec<_>>();
    ready.sort_by_key(|edge| edge.store_position);
    if ready.len() != 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "minimal_executor_requires_one_ready_node".into(),
        ));
    }
    Ok((
        ready[0].payload.target_node_id.clone(),
        ready[0].event_id.clone(),
    ))
}

fn node_input<'a>(
    request: &'a v1::RequestWorkflowRun,
    state: &'a RecordedRun,
    node_id: &str,
) -> Result<(
    Option<&'a v1::WorkflowEdgeCheckpointed>,
    v1::WorkflowValueReference,
)> {
    if state.attempts.is_empty()
        || state.attempts[0].started.node_id == node_id
            && state
                .edges
                .iter()
                .all(|edge| edge.payload.target_node_id != node_id)
    {
        return Ok((
            None,
            request.inputs[0]
                .value
                .clone()
                .ok_or_else(|| WorkflowExecutionError::Integrity("manual_input_missing".into()))?,
        ));
    }
    let incoming = state
        .edges
        .iter()
        .filter(|edge| {
            edge.payload.target_node_id == node_id
                && edge.payload.state == v1::WorkflowEdgeCheckpointState::Admitted as i32
        })
        .collect::<Vec<_>>();
    if incoming.len() != 1 {
        return Err(WorkflowExecutionError::Unsupported(
            "minimal_executor_requires_one_input".into(),
        ));
    }
    let emission = state
        .emissions
        .get(&incoming[0].payload.emission_id)
        .ok_or_else(|| WorkflowExecutionError::Lifecycle("input_emission_missing".into()))?;
    Ok((
        Some(&incoming[0].payload),
        emission
            .payload
            .value
            .clone()
            .ok_or_else(|| WorkflowExecutionError::Lifecycle("input_value_missing".into()))?,
    ))
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
            WorkflowRuntimeEvent::RunTokenCreated(payload) => {
                if state.token.replace(payload).is_some() {
                    return Err(WorkflowExecutionError::Lifecycle(
                        "duplicate_run_token".into(),
                    ));
                }
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
                    started: payload,
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
