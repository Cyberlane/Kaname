//! Bounded typed contracts for the durable workflow command/event journal.
//!
//! This module validates the semantic relationship between an envelope kind,
//! its Protobuf payload type, the workflow-run stream, and every identifier or
//! inline value before the generic journal stores bytes. It does not execute a
//! workflow or grant connector, storage, model, or effect authority.

use crate::{v1, workflow_canonical};
use prost::Message;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

pub const WORKFLOW_RUN_REQUEST_KIND: &str = "workflow.run.request";
pub const WORKFLOW_RUN_CANCEL_KIND: &str = "workflow.run.cancel";
pub const WORKFLOW_RUN_TOKEN_CREATED_KIND: &str = "workflow.run.token-created";
pub const WORKFLOW_EXECUTION_TOKEN_CREATED_KIND: &str = "workflow.execution-token.created";
pub const WORKFLOW_EXECUTION_TOKEN_SETTLED_KIND: &str = "workflow.execution-token.settled";
pub const WORKFLOW_JOIN_EVALUATED_KIND: &str = "workflow.join.evaluated";
pub const WORKFLOW_ITERATION_PLANNED_KIND: &str = "workflow.iteration.planned";
pub const WORKFLOW_ITERATION_EVALUATED_KIND: &str = "workflow.iteration.evaluated";
pub const WORKFLOW_RETRY_EVALUATED_KIND: &str = "workflow.retry.evaluated";
pub const WORKFLOW_ATTEMPT_STARTED_KIND: &str = "workflow.attempt.started";
pub const WORKFLOW_ATTEMPT_SETTLED_KIND: &str = "workflow.attempt.settled";
pub const WORKFLOW_PORT_EMITTED_KIND: &str = "workflow.port.emitted";
pub const WORKFLOW_EDGE_CHECKPOINTED_KIND: &str = "workflow.edge.checkpointed";
pub const WORKFLOW_MATCH_TRACE_RECORDED_KIND: &str = "workflow.match.trace-recorded";
pub const WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND: &str = "workflow.run.cancellation-requested";
pub const WORKFLOW_RUN_SETTLED_KIND: &str = "workflow.run.settled";

pub const WORKFLOW_RUN_REQUEST_TYPE: &str = "kaname.workflow.run-request.v1";
pub const WORKFLOW_RUN_CANCEL_TYPE: &str = "kaname.workflow.run-cancel.v1";
pub const WORKFLOW_RUN_TOKEN_CREATED_TYPE: &str = "kaname.workflow.run-token-created.v1";
pub const WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE: &str =
    "kaname.workflow.execution-token-created.v1";
pub const WORKFLOW_EXECUTION_TOKEN_SETTLED_TYPE: &str =
    "kaname.workflow.execution-token-settled.v1";
pub const WORKFLOW_JOIN_EVALUATED_TYPE: &str = "kaname.workflow.join-evaluated.v1";
pub const WORKFLOW_ITERATION_PLANNED_TYPE: &str = "kaname.workflow.iteration-planned.v1";
pub const WORKFLOW_ITERATION_EVALUATED_TYPE: &str = "kaname.workflow.iteration-evaluated.v1";
pub const WORKFLOW_RETRY_EVALUATED_TYPE: &str = "kaname.workflow.retry-evaluated.v1";
pub const WORKFLOW_ATTEMPT_STARTED_TYPE: &str = "kaname.workflow.attempt-started.v1";
pub const WORKFLOW_ATTEMPT_SETTLED_TYPE: &str = "kaname.workflow.attempt-settled.v1";
pub const WORKFLOW_PORT_EMITTED_TYPE: &str = "kaname.workflow.port-emitted.v1";
pub const WORKFLOW_EDGE_CHECKPOINTED_TYPE: &str = "kaname.workflow.edge-checkpointed.v1";
pub const WORKFLOW_MATCH_TRACE_RECORDED_TYPE: &str = "kaname.workflow.match-trace-recorded.v1";
pub const WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE: &str =
    "kaname.workflow.run-cancellation-requested.v1";
pub const WORKFLOW_RUN_SETTLED_TYPE: &str = "kaname.workflow.run-settled.v1";

const PROTOBUF_CONTENT_TYPE: &str = "application/x-protobuf";
const JSON_CONTENT_TYPE: &str = "application/json";
const MAXIMUM_TYPED_PAYLOAD_BYTES: usize = 48 * 1024;
const MAXIMUM_INLINE_VALUE_BYTES: usize = 32 * 1024;
const MAXIMUM_PORT_BINDINGS: usize = 64;
const MAXIMUM_TRACE_IDENTIFIERS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowRuntimeContractError {
    UnsupportedKind,
    Invalid(&'static str),
}

pub type Result<T> = std::result::Result<T, WorkflowRuntimeContractError>;

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowRuntimeCommand {
    RequestRun(v1::RequestWorkflowRun),
    CancelRun(v1::CancelWorkflowRun),
}

#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum WorkflowRuntimeEvent {
    RunTokenCreated(v1::WorkflowRunTokenCreated),
    ExecutionTokenCreated(v1::WorkflowExecutionTokenCreated),
    ExecutionTokenSettled(v1::WorkflowExecutionTokenSettled),
    JoinEvaluated(v1::WorkflowJoinEvaluated),
    IterationPlanned(v1::WorkflowIterationPlanned),
    IterationEvaluated(v1::WorkflowIterationEvaluated),
    RetryEvaluated(v1::WorkflowRetryEvaluated),
    AttemptStarted(v1::WorkflowAttemptStarted),
    AttemptSettled(v1::WorkflowAttemptSettled),
    PortEmitted(v1::WorkflowPortEmitted),
    EdgeCheckpointed(v1::WorkflowEdgeCheckpointed),
    MatchTraceRecorded(v1::WorkflowMatchTraceRecorded),
    RunCancellationRequested(v1::WorkflowRunCancellationRequested),
    RunSettled(v1::WorkflowRunSettled),
}

impl WorkflowRuntimeEvent {
    pub fn run_id(&self) -> &str {
        match self {
            Self::RunTokenCreated(payload) => &payload.run_id,
            Self::ExecutionTokenCreated(payload) => &payload.run_id,
            Self::ExecutionTokenSettled(payload) => &payload.run_id,
            Self::JoinEvaluated(payload) => &payload.run_id,
            Self::IterationPlanned(payload) => &payload.run_id,
            Self::IterationEvaluated(payload) => &payload.run_id,
            Self::RetryEvaluated(payload) => &payload.run_id,
            Self::AttemptStarted(payload) => &payload.run_id,
            Self::AttemptSettled(payload) => &payload.run_id,
            Self::PortEmitted(payload) => &payload.run_id,
            Self::EdgeCheckpointed(payload) => &payload.run_id,
            Self::MatchTraceRecorded(payload) => &payload.run_id,
            Self::RunCancellationRequested(payload) => &payload.run_id,
            Self::RunSettled(payload) => &payload.run_id,
        }
    }
}

pub fn is_workflow_runtime_kind(kind: &str) -> bool {
    [
        "workflow.run.",
        "workflow.attempt.",
        "workflow.port.",
        "workflow.edge.",
        "workflow.match.",
        "workflow.execution-token.",
        "workflow.join.",
        "workflow.iteration.",
        "workflow.retry.",
    ]
    .iter()
    .any(|prefix| kind.starts_with(prefix))
}

pub fn validate_workflow_command(command: &v1::CommandEnvelope) -> Result<()> {
    decode_workflow_command(command).map(|_| ())
}

pub fn decode_workflow_command(command: &v1::CommandEnvelope) -> Result<WorkflowRuntimeCommand> {
    validate_command_scope(command)?;
    match command.kind.as_str() {
        WORKFLOW_RUN_REQUEST_KIND => {
            let request: v1::RequestWorkflowRun =
                decode_payload(command.payload.as_ref(), WORKFLOW_RUN_REQUEST_TYPE)?;
            validate_run_request(&request)?;
            Ok(WorkflowRuntimeCommand::RequestRun(request))
        }
        WORKFLOW_RUN_CANCEL_KIND => {
            let request: v1::CancelWorkflowRun =
                decode_payload(command.payload.as_ref(), WORKFLOW_RUN_CANCEL_TYPE)?;
            validate_cancel_request(&request)?;
            Ok(WorkflowRuntimeCommand::CancelRun(request))
        }
        _ => Err(WorkflowRuntimeContractError::UnsupportedKind),
    }
}

pub fn validate_workflow_event(event: &v1::EventEnvelope) -> Result<()> {
    decode_workflow_event(event).map(|_| ())
}

pub fn decode_workflow_event(event: &v1::EventEnvelope) -> Result<WorkflowRuntimeEvent> {
    match event.kind.as_str() {
        WORKFLOW_RUN_TOKEN_CREATED_KIND => {
            let payload: v1::WorkflowRunTokenCreated =
                decode_payload(event.payload.as_ref(), WORKFLOW_RUN_TOKEN_CREATED_TYPE)?;
            validate_token_created(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::RunTokenCreated(payload))
        }
        WORKFLOW_EXECUTION_TOKEN_CREATED_KIND => {
            let payload: v1::WorkflowExecutionTokenCreated = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
            )?;
            validate_execution_token_created(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::ExecutionTokenCreated(payload))
        }
        WORKFLOW_EXECUTION_TOKEN_SETTLED_KIND => {
            let payload: v1::WorkflowExecutionTokenSettled = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_EXECUTION_TOKEN_SETTLED_TYPE,
            )?;
            validate_execution_token_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::ExecutionTokenSettled(payload))
        }
        WORKFLOW_JOIN_EVALUATED_KIND => {
            let payload: v1::WorkflowJoinEvaluated =
                decode_payload(event.payload.as_ref(), WORKFLOW_JOIN_EVALUATED_TYPE)?;
            validate_join_evaluated(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::JoinEvaluated(payload))
        }
        WORKFLOW_ITERATION_PLANNED_KIND => {
            let payload: v1::WorkflowIterationPlanned =
                decode_payload(event.payload.as_ref(), WORKFLOW_ITERATION_PLANNED_TYPE)?;
            validate_iteration_planned(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::IterationPlanned(payload))
        }
        WORKFLOW_ITERATION_EVALUATED_KIND => {
            let payload: v1::WorkflowIterationEvaluated =
                decode_payload(event.payload.as_ref(), WORKFLOW_ITERATION_EVALUATED_TYPE)?;
            validate_iteration_evaluated(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::IterationEvaluated(payload))
        }
        WORKFLOW_RETRY_EVALUATED_KIND => {
            let payload: v1::WorkflowRetryEvaluated =
                decode_payload(event.payload.as_ref(), WORKFLOW_RETRY_EVALUATED_TYPE)?;
            validate_retry_evaluated(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::RetryEvaluated(payload))
        }
        WORKFLOW_ATTEMPT_STARTED_KIND => {
            let payload: v1::WorkflowAttemptStarted =
                decode_payload(event.payload.as_ref(), WORKFLOW_ATTEMPT_STARTED_TYPE)?;
            validate_attempt_identity(
                &payload.run_id,
                &payload.run_token_id,
                &payload.attempt_id,
                &payload.node_id,
                payload.attempt_number,
            )?;
            validate_optional_execution_token(&payload.execution_token_id)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::AttemptStarted(payload))
        }
        WORKFLOW_ATTEMPT_SETTLED_KIND => {
            let payload: v1::WorkflowAttemptSettled =
                decode_payload(event.payload.as_ref(), WORKFLOW_ATTEMPT_SETTLED_TYPE)?;
            validate_attempt_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::AttemptSettled(payload))
        }
        WORKFLOW_PORT_EMITTED_KIND => {
            let payload: v1::WorkflowPortEmitted =
                decode_payload(event.payload.as_ref(), WORKFLOW_PORT_EMITTED_TYPE)?;
            validate_port_emission(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::PortEmitted(payload))
        }
        WORKFLOW_EDGE_CHECKPOINTED_KIND => {
            let payload: v1::WorkflowEdgeCheckpointed =
                decode_payload(event.payload.as_ref(), WORKFLOW_EDGE_CHECKPOINTED_TYPE)?;
            validate_edge_checkpoint(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::EdgeCheckpointed(payload))
        }
        WORKFLOW_MATCH_TRACE_RECORDED_KIND => {
            let payload: v1::WorkflowMatchTraceRecorded =
                decode_payload(event.payload.as_ref(), WORKFLOW_MATCH_TRACE_RECORDED_TYPE)?;
            validate_match_trace(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::MatchTraceRecorded(payload))
        }
        WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND => {
            let payload: v1::WorkflowRunCancellationRequested = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE,
            )?;
            validate_cancellation_requested(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::RunCancellationRequested(payload))
        }
        WORKFLOW_RUN_SETTLED_KIND => {
            let payload: v1::WorkflowRunSettled =
                decode_payload(event.payload.as_ref(), WORKFLOW_RUN_SETTLED_TYPE)?;
            validate_run_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::RunSettled(payload))
        }
        _ => Err(WorkflowRuntimeContractError::UnsupportedKind),
    }
}

fn validate_command_scope(command: &v1::CommandEnvelope) -> Result<()> {
    validate_identifier(&command.command_id, 128, "command_id")?;
    validate_identifier(&command.idempotency_key, 128, "idempotency_key")?;
    validate_identifier(&command.actor_id, 128, "actor_id")?;
    if command.expected_revision != 0 || command.submitted_at_unix_millis < 0 {
        return invalid("command_bounds");
    }
    let scope = command
        .scope
        .as_ref()
        .ok_or_else(|| invalid_error("scope"))?;
    validate_identifier(&scope.project_id, 128, "project_id")?;
    if !scope.workspace_id.is_empty() {
        validate_identifier(&scope.workspace_id, 128, "workspace_id")?;
    }
    if !scope.account_id.is_empty()
        || !scope.authority_id.is_empty()
        || !scope.egress_class.is_empty()
        || !scope.destination_digest.is_empty()
    {
        return invalid("command_authority_not_allowed");
    }
    Ok(())
}

fn validate_run_request(request: &v1::RequestWorkflowRun) -> Result<()> {
    validate_identifier(&request.run_id, 128, "run_id")?;
    validate_identifier(&request.workflow_id, 128, "workflow_id")?;
    validate_identifier(&request.revision_id, 128, "revision_id")?;
    validate_digest(&request.package_digest, "package_digest")?;
    validate_identifier(&request.trigger_kind, 64, "trigger_kind")?;
    if !request.trigger_event_id.is_empty() {
        validate_identifier(&request.trigger_event_id, 128, "trigger_event_id")?;
    }
    if !request.installation_id.is_empty() {
        validate_identifier(&request.installation_id, 128, "installation_id")?;
    }
    if !request.case_id.is_empty() {
        validate_identifier(&request.case_id, 128, "case_id")?;
    }
    if request.inputs.len() > MAXIMUM_PORT_BINDINGS {
        return invalid("input_count");
    }
    let mut ports = BTreeSet::new();
    for input in &request.inputs {
        validate_identifier(&input.port_id, 128, "input_port_id")?;
        if !ports.insert(input.port_id.as_str()) {
            return invalid("duplicate_input_port");
        }
        validate_value(input.value.as_ref())?;
    }
    Ok(())
}

fn validate_cancel_request(request: &v1::CancelWorkflowRun) -> Result<()> {
    validate_run_and_token(&request.run_id, &request.run_token_id)?;
    validate_identifier(&request.reason_code, 128, "reason_code")
}

fn validate_token_created(payload: &v1::WorkflowRunTokenCreated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.request_command_id, 128, "request_command_id")?;
    validate_identifier(&payload.workflow_id, 128, "workflow_id")?;
    validate_identifier(&payload.revision_id, 128, "revision_id")?;
    validate_digest(&payload.package_digest, "package_digest")
}

fn validate_execution_token_created(payload: &v1::WorkflowExecutionTokenCreated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.execution_token_id, 128, "execution_token_id")?;
    if payload.parent_execution_token_id.is_empty() {
        if !payload.fork_node_id.is_empty()
            || !payload.branch_id.is_empty()
            || !payload.branch_port_id.is_empty()
            || !payload.join_node_id.is_empty()
            || !payload.source_emission_id.is_empty()
            || !payload.iteration_node_id.is_empty()
            || payload.iteration_index != 0
            || payload.iteration_count != 0
            || !payload.resume_node_id.is_empty()
            || !payload.resume_reason.is_empty()
        {
            return invalid("root_execution_token_contract");
        }
        return Ok(());
    }
    validate_identifier(
        &payload.parent_execution_token_id,
        128,
        "parent_execution_token_id",
    )?;
    let branch = !payload.fork_node_id.is_empty();
    let iteration = !payload.iteration_node_id.is_empty();
    let resumed =
        !payload.resume_node_id.is_empty() || (!payload.join_node_id.is_empty() && !branch);
    if usize::from(branch) + usize::from(iteration) + usize::from(resumed) != 1 {
        return invalid("child_execution_token_contract");
    }
    if branch {
        validate_identifier(&payload.fork_node_id, 128, "fork_node_id")?;
        validate_identifier(&payload.branch_id, 128, "branch_id")?;
        validate_identifier(&payload.branch_port_id, 128, "branch_port_id")?;
        validate_identifier(&payload.join_node_id, 128, "join_node_id")?;
        validate_identifier(&payload.source_emission_id, 128, "source_emission_id")?;
        if !payload.iteration_node_id.is_empty()
            || payload.iteration_index != 0
            || payload.iteration_count != 0
            || !payload.resume_node_id.is_empty()
            || !payload.resume_reason.is_empty()
        {
            return invalid("branch_execution_token_contract");
        }
    } else if iteration {
        if !payload.fork_node_id.is_empty()
            || !payload.branch_id.is_empty()
            || payload.branch_port_id != "item"
            || !payload.join_node_id.is_empty()
            || payload.iteration_count == 0
            || payload.iteration_count > 256
            || payload.iteration_index >= payload.iteration_count
            || !payload.resume_node_id.is_empty()
            || !payload.resume_reason.is_empty()
        {
            return invalid("iteration_execution_token_contract");
        }
        validate_identifier(&payload.iteration_node_id, 128, "iteration_node_id")?;
        validate_identifier(&payload.source_emission_id, 128, "source_emission_id")?;
    } else {
        if !payload.branch_id.is_empty()
            || !payload.branch_port_id.is_empty()
            || !payload.source_emission_id.is_empty()
            || !payload.iteration_node_id.is_empty()
            || payload.iteration_index != 0
            || payload.iteration_count != 0
        {
            return invalid("resumed_execution_token_contract");
        }
        if !payload.resume_node_id.is_empty() {
            validate_identifier(&payload.resume_node_id, 128, "resume_node_id")?;
            if !matches!(payload.resume_reason.as_str(), "join" | "iteration") {
                return invalid("resume_reason");
            }
        } else {
            validate_identifier(&payload.join_node_id, 128, "join_node_id")?;
        }
    }
    Ok(())
}

fn validate_execution_token_settled(payload: &v1::WorkflowExecutionTokenSettled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.execution_token_id, 128, "execution_token_id")?;
    let outcome = v1::WorkflowExecutionTokenOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("execution_token_outcome"))?;
    match outcome {
        v1::WorkflowExecutionTokenOutcome::Completed => {
            validate_identifier(&payload.terminal_node_id, 128, "terminal_node_id")?;
            if !payload.join_node_id.is_empty()
                || !payload.error_code.is_empty()
                || payload.error.is_some()
            {
                return invalid("completed_execution_token_contract");
            }
        }
        v1::WorkflowExecutionTokenOutcome::Failed => {
            validate_identifier(&payload.terminal_node_id, 128, "terminal_node_id")?;
            validate_identifier(&payload.error_code, 128, "error_code")?;
            validate_value(payload.error.as_ref())?;
            if !payload.join_node_id.is_empty() {
                return invalid("failed_execution_token_contract");
            }
        }
        v1::WorkflowExecutionTokenOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "cancellation_code")?;
            if payload.error.is_some() {
                validate_value(payload.error.as_ref())?;
            }
        }
        v1::WorkflowExecutionTokenOutcome::Forked => {
            if !payload.terminal_node_id.is_empty()
                || !payload.join_node_id.is_empty()
                || !payload.error_code.is_empty()
                || payload.error.is_some()
            {
                return invalid("forked_execution_token_contract");
            }
        }
        v1::WorkflowExecutionTokenOutcome::Joined => {
            validate_identifier(&payload.join_node_id, 128, "join_node_id")?;
            if !payload.terminal_node_id.is_empty()
                || !payload.error_code.is_empty()
                || payload.error.is_some()
            {
                return invalid("joined_execution_token_contract");
            }
        }
        v1::WorkflowExecutionTokenOutcome::Iterated => {
            if !payload.terminal_node_id.is_empty()
                || !payload.join_node_id.is_empty()
                || !payload.error_code.is_empty()
                || payload.error.is_some()
            {
                return invalid("iterated_execution_token_contract");
            }
        }
        v1::WorkflowExecutionTokenOutcome::Unspecified => {
            return invalid("execution_token_outcome");
        }
    }
    validate_identifier_list(
        &payload.final_emission_ids,
        MAXIMUM_PORT_BINDINGS,
        "final_emission_ids",
    )
}

fn validate_iteration_planned(payload: &v1::WorkflowIterationPlanned) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.iteration_node_id, 128, "iteration_node_id")?;
    validate_identifier(
        &payload.parent_execution_token_id,
        128,
        "parent_execution_token_id",
    )?;
    validate_identifier(&payload.controller_attempt_id, 128, "controller_attempt_id")?;
    validate_identifier(&payload.input_value_id, 128, "input_value_id")?;
    validate_digest(&payload.input_sha256, "input_sha256")?;
    if payload.maximum_items == 0
        || payload.maximum_items > 256
        || payload.item_count > payload.maximum_items
        || payload.maximum_concurrency == 0
        || payload.maximum_concurrency > 64
        || payload.maximum_concurrency > payload.maximum_items
        || !matches!(payload.failure_policy.as_str(), "fail-fast" | "collect")
    {
        return invalid("iteration_plan_bounds");
    }
    Ok(())
}

fn validate_iteration_evaluated(payload: &v1::WorkflowIterationEvaluated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.iteration_node_id, 128, "iteration_node_id")?;
    validate_identifier(
        &payload.parent_execution_token_id,
        128,
        "parent_execution_token_id",
    )?;
    validate_identifier(
        &payload.resumed_execution_token_id,
        128,
        "resumed_execution_token_id",
    )?;
    if !matches!(payload.failure_policy.as_str(), "fail-fast" | "collect") {
        return invalid("iteration_failure_policy");
    }
    let decision = v1::WorkflowIterationDecision::try_from(payload.decision)
        .map_err(|_| invalid_error("iteration_decision"))?;
    if decision == v1::WorkflowIterationDecision::Unspecified {
        return invalid("iteration_decision");
    }
    for (values, code) in [
        (
            &payload.expected_execution_token_ids,
            "iteration_expected_tokens",
        ),
        (
            &payload.succeeded_execution_token_ids,
            "iteration_succeeded_tokens",
        ),
        (
            &payload.failed_execution_token_ids,
            "iteration_failed_tokens",
        ),
        (
            &payload.pending_execution_token_ids,
            "iteration_pending_tokens",
        ),
    ] {
        validate_identifier_list(values, 256, code)?;
    }
    let expected = payload
        .expected_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let succeeded = payload
        .succeeded_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let failed = payload
        .failed_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let pending = payload
        .pending_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let partition = succeeded
        .iter()
        .chain(failed.iter())
        .chain(pending.iter())
        .copied()
        .collect::<BTreeSet<_>>();
    if succeeded.len() + failed.len() + pending.len() != expected.len() || partition != expected {
        return invalid("iteration_token_partition");
    }
    validate_value(payload.output.as_ref())?;
    match decision {
        v1::WorkflowIterationDecision::Succeeded
            if !payload.error_code.is_empty()
                || !payload.pending_execution_token_ids.is_empty()
                || (payload.failure_policy == "fail-fast"
                    && !payload.failed_execution_token_ids.is_empty()) =>
        {
            invalid("iteration_success_contract")
        }
        v1::WorkflowIterationDecision::Failed => {
            validate_identifier(&payload.error_code, 128, "iteration_error_code")?;
            if payload.failed_execution_token_ids.is_empty() {
                return invalid("iteration_failure_contract");
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn validate_retry_evaluated(payload: &v1::WorkflowRetryEvaluated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.retry_node_id, "retry_node_id"),
        (&payload.execution_token_id, "execution_token_id"),
        (&payload.controller_attempt_id, "controller_attempt_id"),
        (&payload.failed_attempt_id, "failed_attempt_id"),
        (&payload.target_node_id, "target_node_id"),
        (&payload.error_code, "retry_error_code"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    let decision = v1::WorkflowRetryDecision::try_from(payload.decision)
        .map_err(|_| invalid_error("retry_decision"))?;
    if decision == v1::WorkflowRetryDecision::Unspecified
        || payload.maximum_attempts == 0
        || payload.maximum_attempts > 100
        || payload.next_attempt_number < 2
    {
        return invalid("retry_bounds");
    }
    validate_value(payload.retry_input.as_ref())?;
    validate_value(payload.error.as_ref())?;
    if decision == v1::WorkflowRetryDecision::Scheduled {
        if payload.next_attempt_number > payload.maximum_attempts
            || payload.delay_milliseconds == 0
            || payload.eligible_at_unix_millis <= 0
        {
            return invalid("retry_schedule");
        }
    } else if payload.delay_milliseconds != 0 || payload.eligible_at_unix_millis != 0 {
        return invalid("retry_non_schedule_deadline");
    }
    Ok(())
}

fn validate_join_evaluated(payload: &v1::WorkflowJoinEvaluated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.join_node_id, 128, "join_node_id")?;
    validate_identifier(&payload.fork_node_id, 128, "fork_node_id")?;
    validate_identifier(
        &payload.resumed_execution_token_id,
        128,
        "resumed_execution_token_id",
    )?;
    if !matches!(payload.policy.as_str(), "all" | "any" | "quorum") || payload.threshold == 0 {
        return invalid("join_policy");
    }
    let decision = v1::WorkflowJoinDecision::try_from(payload.decision)
        .map_err(|_| invalid_error("join_decision"))?;
    if decision == v1::WorkflowJoinDecision::Unspecified {
        return invalid("join_decision");
    }
    for (values, code) in [
        (
            &payload.expected_execution_token_ids,
            "join_expected_tokens",
        ),
        (&payload.arrived_execution_token_ids, "join_arrived_tokens"),
        (&payload.failed_execution_token_ids, "join_failed_tokens"),
        (&payload.pending_execution_token_ids, "join_pending_tokens"),
    ] {
        validate_identifier_list(values, MAXIMUM_PORT_BINDINGS, code)?;
    }
    let expected = payload
        .expected_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let arrived = payload
        .arrived_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let failed = payload
        .failed_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let pending = payload
        .pending_execution_token_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let partition = arrived
        .iter()
        .chain(failed.iter())
        .chain(pending.iter())
        .copied()
        .collect::<BTreeSet<_>>();
    if expected.len() < 2
        || usize::try_from(payload.threshold).map_or(true, |value| value > expected.len())
        || arrived.len() + failed.len() + pending.len() != expected.len()
        || partition != expected
        || (payload.policy == "all" && payload.threshold as usize != expected.len())
        || (payload.policy == "any" && payload.threshold != 1)
    {
        return invalid("join_token_partition");
    }
    let threshold = payload.threshold as usize;
    if (decision == v1::WorkflowJoinDecision::Succeeded && arrived.len() < threshold)
        || (decision == v1::WorkflowJoinDecision::Failed
            && arrived.len() + pending.len() >= threshold)
    {
        return invalid("join_decision_math");
    }
    match decision {
        v1::WorkflowJoinDecision::Succeeded if !payload.error_code.is_empty() => {
            invalid("join_success_error")
        }
        v1::WorkflowJoinDecision::Failed => {
            validate_identifier(&payload.error_code, 128, "join_error_code")
        }
        _ => Ok(()),
    }
}

fn validate_attempt_identity(
    run_id: &str,
    run_token_id: &str,
    attempt_id: &str,
    node_id: &str,
    attempt_number: u32,
) -> Result<()> {
    validate_run_and_token(run_id, run_token_id)?;
    validate_identifier(attempt_id, 128, "attempt_id")?;
    validate_identifier(node_id, 128, "node_id")?;
    if attempt_number == 0 || attempt_number > 1_000 {
        return invalid("attempt_number");
    }
    Ok(())
}

fn validate_optional_execution_token(value: &str) -> Result<()> {
    if value.is_empty() {
        Ok(())
    } else {
        validate_identifier(value, 128, "execution_token_id")
    }
}

fn validate_attempt_settled(payload: &v1::WorkflowAttemptSettled) -> Result<()> {
    validate_attempt_identity(
        &payload.run_id,
        &payload.run_token_id,
        &payload.attempt_id,
        &payload.node_id,
        payload.attempt_number,
    )?;
    validate_optional_execution_token(&payload.execution_token_id)?;
    let outcome = v1::WorkflowAttemptOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("attempt_outcome"))?;
    match outcome {
        v1::WorkflowAttemptOutcome::Succeeded => {
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("success_has_error");
            }
        }
        v1::WorkflowAttemptOutcome::Failed => {
            validate_identifier(&payload.error_code, 128, "error_code")?;
            validate_value(payload.error.as_ref())?;
        }
        v1::WorkflowAttemptOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "cancellation_code")?;
            if payload.error.is_some() {
                validate_value(payload.error.as_ref())?;
            }
        }
        v1::WorkflowAttemptOutcome::Unspecified => return invalid("attempt_outcome"),
    }
    validate_identifier_list(&payload.emission_ids, MAXIMUM_PORT_BINDINGS, "emission_ids")
}

fn validate_port_emission(payload: &v1::WorkflowPortEmitted) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.emission_id, 128, "emission_id")?;
    validate_identifier(&payload.attempt_id, 128, "attempt_id")?;
    validate_identifier(&payload.node_id, 128, "node_id")?;
    validate_identifier(&payload.port_id, 128, "port_id")?;
    validate_optional_execution_token(&payload.execution_token_id)?;
    validate_value(payload.value.as_ref())
}

fn validate_edge_checkpoint(payload: &v1::WorkflowEdgeCheckpointed) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.edge_id, 128, "edge_id")?;
    validate_identifier(&payload.emission_id, 128, "emission_id")?;
    validate_identifier(&payload.target_node_id, 128, "target_node_id")?;
    validate_identifier(&payload.target_port_id, 128, "target_port_id")?;
    validate_optional_execution_token(&payload.execution_token_id)?;
    match v1::WorkflowEdgeCheckpointState::try_from(payload.state) {
        Ok(
            v1::WorkflowEdgeCheckpointState::Admitted | v1::WorkflowEdgeCheckpointState::Skipped,
        ) => Ok(()),
        _ => invalid("edge_checkpoint_state"),
    }
}

fn validate_match_trace(payload: &v1::WorkflowMatchTraceRecorded) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.attempt_id, 128, "attempt_id")?;
    validate_identifier(&payload.node_id, 128, "node_id")?;
    validate_identifier(&payload.input_value_id, 128, "input_value_id")?;
    validate_optional_execution_token(&payload.execution_token_id)?;
    validate_identifier_list(
        &payload.evaluated_case_ids,
        MAXIMUM_TRACE_IDENTIFIERS,
        "evaluated_case_ids",
    )?;
    validate_identifier_list(
        &payload.matched_case_ids,
        MAXIMUM_TRACE_IDENTIFIERS,
        "matched_case_ids",
    )?;
    validate_identifier_list(
        &payload.emitted_port_ids,
        MAXIMUM_PORT_BINDINGS,
        "emitted_port_ids",
    )?;
    if payload.evaluated_case_ids.is_empty() || payload.emitted_port_ids.is_empty() {
        return invalid("match_trace_empty");
    }
    validate_value(payload.trace.as_ref())
}

fn validate_cancellation_requested(payload: &v1::WorkflowRunCancellationRequested) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.cancel_command_id, 128, "cancel_command_id")?;
    validate_identifier(&payload.reason_code, 128, "reason_code")
}

fn validate_run_settled(payload: &v1::WorkflowRunSettled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    let outcome = v1::WorkflowRunOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("run_outcome"))?;
    match outcome {
        v1::WorkflowRunOutcome::Succeeded => {
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("success_has_error");
            }
        }
        v1::WorkflowRunOutcome::Failed => {
            validate_identifier(&payload.error_code, 128, "error_code")?;
            validate_value(payload.error.as_ref())?;
        }
        v1::WorkflowRunOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "cancellation_code")?;
            if payload.error.is_some() {
                validate_value(payload.error.as_ref())?;
            }
        }
        v1::WorkflowRunOutcome::Unspecified => return invalid("run_outcome"),
    }
    validate_identifier_list(
        &payload.final_emission_ids,
        MAXIMUM_PORT_BINDINGS,
        "final_emission_ids",
    )
}

fn validate_event_context(event: &v1::EventEnvelope, run_id: &str) -> Result<()> {
    validate_identifier(&event.event_id, 128, "event_id")?;
    validate_identifier(&event.causation_id, 128, "causation_id")?;
    if event.occurred_at_unix_millis < 0
        || event.stream_id != format!("workflow-run:{run_id}")
        || event.correlation_id != run_id
    {
        return invalid("event_context");
    }
    let provenance = event
        .provenance
        .as_ref()
        .ok_or_else(|| invalid_error("event_provenance"))?;
    if provenance.source_kind != "workflow-runtime"
        || !provenance.provider_instance_id.is_empty()
        || !provenance.native_type.is_empty()
        || !provenance.native_cursor.is_empty()
        || !provenance.raw_evidence_digest.is_empty()
        || provenance.retention_class != v1::EvidenceRetentionClass::None as i32
    {
        return invalid("event_provenance");
    }
    Ok(())
}

fn validate_run_and_token(run_id: &str, run_token_id: &str) -> Result<()> {
    validate_identifier(run_id, 128, "run_id")?;
    validate_identifier(run_token_id, 128, "run_token_id")
}

fn validate_value(value: Option<&v1::WorkflowValueReference>) -> Result<()> {
    let value = value.ok_or_else(|| invalid_error("value_missing"))?;
    validate_identifier(&value.value_id, 128, "value_id")?;
    validate_text(&value.content_type, 128, "content_type")?;
    validate_digest(&value.sha256, "value_digest")?;
    let inline = !value.inline_canonical_json.is_empty();
    let stored = !value.storage_reference_id.is_empty();
    if inline == stored {
        return invalid("value_location");
    }
    if inline {
        let canonical = workflow_canonical::canonicalize(&value.inline_canonical_json)
            .map_err(|_| invalid_error("inline_value"))?;
        if value.content_type != JSON_CONTENT_TYPE
            || value.inline_canonical_json.len() > MAXIMUM_INLINE_VALUE_BYTES
            || value.byte_count != value.inline_canonical_json.len() as u64
            || value.sha256 != sha256_hex(&value.inline_canonical_json)
            || canonical.canonical_bytes != value.inline_canonical_json
        {
            return invalid("inline_value");
        }
    } else {
        validate_identifier(&value.storage_reference_id, 128, "storage_reference_id")?;
    }
    if let Some(storage) = value.storage.as_ref() {
        validate_text(&storage.logical_key, 512, "storage_logical_key")?;
        let summary = matches!(storage.result.as_str(), "listed" | "missing");
        if !summary {
            validate_identifier(&storage.handle_id, 128, "storage_handle_id")?;
            validate_identifier(&storage.version_id, 128, "storage_version_id")?;
        }
        if !matches!(
            storage.scope.as_str(),
            "job" | "case" | "workflow" | "account-binding"
        ) || (!summary && storage.revision == 0)
            || (summary
                && (!storage.handle_id.is_empty()
                    || !storage.version_id.is_empty()
                    || storage.revision != 0))
            || storage.byte_count != value.byte_count
            || !matches!(
                storage.result.as_str(),
                "read" | "written" | "deleted" | "promoted" | "listed" | "missing"
            )
        {
            return invalid("storage_metadata");
        }
        if !storage.previous_version_id.is_empty() {
            validate_identifier(
                &storage.previous_version_id,
                128,
                "storage_previous_version_id",
            )?;
        }
        if !storage.source_version_id.is_empty() {
            validate_identifier(&storage.source_version_id, 128, "storage_source_version_id")?;
        }
        if stored && value.storage_reference_id != storage.handle_id {
            return invalid("storage_reference_identity");
        }
    }
    Ok(())
}

fn validate_identifier_list(values: &[String], maximum: usize, code: &'static str) -> Result<()> {
    if values.len() > maximum {
        return invalid(code);
    }
    let mut unique = BTreeSet::new();
    for value in values {
        validate_identifier(value, 128, code)?;
        if !unique.insert(value.as_str()) {
            return invalid(code);
        }
    }
    Ok(())
}

fn validate_identifier(value: &str, maximum: usize, code: &'static str) -> Result<()> {
    if value.is_empty()
        || value.len() > maximum
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return invalid(code);
    }
    Ok(())
}

fn validate_text(value: &str, maximum: usize, code: &'static str) -> Result<()> {
    if value.is_empty() || value.len() > maximum || value.chars().any(char::is_control) {
        return invalid(code);
    }
    Ok(())
}

fn validate_digest(value: &str, code: &'static str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return invalid(code);
    }
    Ok(())
}

fn decode_payload<M>(payload: Option<&v1::OpaqueTypedPayload>, type_url: &str) -> Result<M>
where
    M: Message + Default,
{
    let payload = payload.ok_or_else(|| invalid_error("payload_missing"))?;
    if payload.type_url != type_url
        || payload.content_type != PROTOBUF_CONTENT_TYPE
        || payload.payload_version != 1
        || payload.value.is_empty()
        || payload.value.len() > MAXIMUM_TYPED_PAYLOAD_BYTES
    {
        return invalid("payload_envelope");
    }
    M::decode(payload.value.as_slice()).map_err(|_| invalid_error("payload_malformed"))
}

fn invalid<T>(code: &'static str) -> Result<T> {
    Err(invalid_error(code))
}

fn invalid_error(code: &'static str) -> WorkflowRuntimeContractError {
    WorkflowRuntimeContractError::Invalid(code)
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
