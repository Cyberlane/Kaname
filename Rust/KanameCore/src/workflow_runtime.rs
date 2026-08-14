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
pub enum WorkflowRuntimeEvent {
    RunTokenCreated(v1::WorkflowRunTokenCreated),
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
    ]
    .iter()
    .any(|prefix| kind.starts_with(prefix))
}

pub fn validate_workflow_command(command: &v1::CommandEnvelope) -> Result<()> {
    validate_command_scope(command)?;
    match command.kind.as_str() {
        WORKFLOW_RUN_REQUEST_KIND => {
            let request: v1::RequestWorkflowRun =
                decode_payload(command.payload.as_ref(), WORKFLOW_RUN_REQUEST_TYPE)?;
            validate_run_request(&request)
        }
        WORKFLOW_RUN_CANCEL_KIND => {
            let request: v1::CancelWorkflowRun =
                decode_payload(command.payload.as_ref(), WORKFLOW_RUN_CANCEL_TYPE)?;
            validate_cancel_request(&request)
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

fn validate_attempt_settled(payload: &v1::WorkflowAttemptSettled) -> Result<()> {
    validate_attempt_identity(
        &payload.run_id,
        &payload.run_token_id,
        &payload.attempt_id,
        &payload.node_id,
        payload.attempt_number,
    )?;
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
    validate_value(payload.value.as_ref())
}

fn validate_edge_checkpoint(payload: &v1::WorkflowEdgeCheckpointed) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.edge_id, 128, "edge_id")?;
    validate_identifier(&payload.emission_id, 128, "emission_id")?;
    validate_identifier(&payload.target_node_id, 128, "target_node_id")?;
    validate_identifier(&payload.target_port_id, 128, "target_port_id")?;
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
