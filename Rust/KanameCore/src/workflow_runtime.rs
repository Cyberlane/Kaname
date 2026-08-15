//! Bounded typed contracts for the durable workflow command/event journal.
//!
//! This module validates the semantic relationship between an envelope kind,
//! its Protobuf payload type, the workflow-run stream, and every identifier or
//! inline value before the generic journal stores bytes. It does not execute a
//! workflow or grant connector, storage, model, or effect authority.

use crate::{
    policy::approval_fingerprint, v1, workflow_canonical,
    workflow_retention::WorkflowRunRetentionPolicy,
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

pub const WORKFLOW_RUN_REQUEST_KIND: &str = "workflow.run.request";
pub const WORKFLOW_RUN_CANCEL_KIND: &str = "workflow.run.cancel";
pub const WORKFLOW_WAIT_SIGNAL_KIND: &str = "workflow.wait.signal";
pub const WORKFLOW_CASE_EPISODE_STARTED_KIND: &str = "workflow.case.episode-started";
pub const WORKFLOW_SUBFLOW_CALLED_KIND: &str = "workflow.subflow.called";
pub const WORKFLOW_SUBFLOW_SETTLED_KIND: &str = "workflow.subflow.settled";
pub const WORKFLOW_RUN_TOKEN_CREATED_KIND: &str = "workflow.run.token-created";
pub const WORKFLOW_EXECUTION_TOKEN_CREATED_KIND: &str = "workflow.execution-token.created";
pub const WORKFLOW_EXECUTION_TOKEN_SETTLED_KIND: &str = "workflow.execution-token.settled";
pub const WORKFLOW_JOIN_EVALUATED_KIND: &str = "workflow.join.evaluated";
pub const WORKFLOW_ITERATION_PLANNED_KIND: &str = "workflow.iteration.planned";
pub const WORKFLOW_ITERATION_EVALUATED_KIND: &str = "workflow.iteration.evaluated";
pub const WORKFLOW_RETRY_EVALUATED_KIND: &str = "workflow.retry.evaluated";
pub const WORKFLOW_WAIT_SIGNAL_RECORDED_KIND: &str = "workflow.wait.signal-recorded";
pub const WORKFLOW_WAIT_SUBSCRIBED_KIND: &str = "workflow.wait.subscribed";
pub const WORKFLOW_WAIT_RESOLVED_KIND: &str = "workflow.wait.resolved";
pub const WORKFLOW_ATTEMPT_STARTED_KIND: &str = "workflow.attempt.started";
pub const WORKFLOW_CAPABILITY_ATTEMPT_STARTED_KIND: &str = "workflow.capability.attempt-started";
pub const WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_KIND: &str = "workflow.capability.attempt-settled";
pub const WORKFLOW_LLM_ATTEMPT_STARTED_KIND: &str = "workflow.llm.attempt-started";
pub const WORKFLOW_LLM_ATTEMPT_SETTLED_KIND: &str = "workflow.llm.attempt-settled";
pub const WORKFLOW_CONNECTOR_OBSERVATION_STARTED_KIND: &str =
    "workflow.connector-observation.started";
pub const WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_KIND: &str =
    "workflow.connector-observation.settled";
pub const WORKFLOW_EFFECT_PROPOSED_KIND: &str = "workflow.effect.proposed";
pub const WORKFLOW_EFFECT_AUTHORIZED_KIND: &str = "workflow.effect.authorized";
pub const WORKFLOW_EFFECT_DISPATCH_STARTED_KIND: &str = "workflow.effect.dispatch-started";
pub const WORKFLOW_EFFECT_DISPATCH_SETTLED_KIND: &str = "workflow.effect.dispatch-settled";
pub const WORKFLOW_EFFECT_RECONCILED_KIND: &str = "workflow.effect.reconciled";
pub const WORKFLOW_ATTEMPT_SETTLED_KIND: &str = "workflow.attempt.settled";
pub const WORKFLOW_PORT_EMITTED_KIND: &str = "workflow.port.emitted";
pub const WORKFLOW_EDGE_CHECKPOINTED_KIND: &str = "workflow.edge.checkpointed";
pub const WORKFLOW_MATCH_TRACE_RECORDED_KIND: &str = "workflow.match.trace-recorded";
pub const WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND: &str = "workflow.run.cancellation-requested";
pub const WORKFLOW_RUN_SETTLED_KIND: &str = "workflow.run.settled";
pub const WORKFLOW_RUN_PURGED_KIND: &str = "workflow.run.purged";

pub const WORKFLOW_RUN_REQUEST_TYPE: &str = "kaname.workflow.run-request.v1";
pub const WORKFLOW_RUN_CANCEL_TYPE: &str = "kaname.workflow.run-cancel.v1";
pub const WORKFLOW_WAIT_SIGNAL_TYPE: &str = "kaname.workflow.wait-signal.v1";
pub const WORKFLOW_CASE_EPISODE_STARTED_TYPE: &str = "kaname.workflow.case-episode-started.v1";
pub const WORKFLOW_SUBFLOW_CALLED_TYPE: &str = "kaname.workflow.subflow-called.v1";
pub const WORKFLOW_SUBFLOW_SETTLED_TYPE: &str = "kaname.workflow.subflow-settled.v1";
pub const WORKFLOW_RUN_TOKEN_CREATED_TYPE: &str = "kaname.workflow.run-token-created.v1";
pub const WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE: &str =
    "kaname.workflow.execution-token-created.v1";
pub const WORKFLOW_EXECUTION_TOKEN_SETTLED_TYPE: &str =
    "kaname.workflow.execution-token-settled.v1";
pub const WORKFLOW_JOIN_EVALUATED_TYPE: &str = "kaname.workflow.join-evaluated.v1";
pub const WORKFLOW_ITERATION_PLANNED_TYPE: &str = "kaname.workflow.iteration-planned.v1";
pub const WORKFLOW_ITERATION_EVALUATED_TYPE: &str = "kaname.workflow.iteration-evaluated.v1";
pub const WORKFLOW_RETRY_EVALUATED_TYPE: &str = "kaname.workflow.retry-evaluated.v1";
pub const WORKFLOW_WAIT_SIGNAL_RECORDED_TYPE: &str = "kaname.workflow.wait-signal-recorded.v1";
pub const WORKFLOW_WAIT_SUBSCRIBED_TYPE: &str = "kaname.workflow.wait-subscribed.v1";
pub const WORKFLOW_WAIT_RESOLVED_TYPE: &str = "kaname.workflow.wait-resolved.v1";
pub const WORKFLOW_ATTEMPT_STARTED_TYPE: &str = "kaname.workflow.attempt-started.v1";
pub const WORKFLOW_CAPABILITY_ATTEMPT_STARTED_TYPE: &str =
    "kaname.workflow.capability-attempt-started.v1";
pub const WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_TYPE: &str =
    "kaname.workflow.capability-attempt-settled.v1";
pub const WORKFLOW_LLM_ATTEMPT_STARTED_TYPE: &str = "kaname.workflow.llm-attempt-started.v1";
pub const WORKFLOW_LLM_ATTEMPT_SETTLED_TYPE: &str = "kaname.workflow.llm-attempt-settled.v1";
pub const WORKFLOW_CONNECTOR_OBSERVATION_STARTED_TYPE: &str =
    "kaname.workflow.connector-observation-started.v1";
pub const WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_TYPE: &str =
    "kaname.workflow.connector-observation-settled.v1";
pub const WORKFLOW_EFFECT_PROPOSED_TYPE: &str = "kaname.workflow.effect-proposed.v1";
pub const WORKFLOW_EFFECT_AUTHORIZED_TYPE: &str = "kaname.workflow.effect-authorized.v1";
pub const WORKFLOW_EFFECT_DISPATCH_STARTED_TYPE: &str =
    "kaname.workflow.effect-dispatch-started.v1";
pub const WORKFLOW_EFFECT_DISPATCH_SETTLED_TYPE: &str =
    "kaname.workflow.effect-dispatch-settled.v1";
pub const WORKFLOW_EFFECT_RECONCILED_TYPE: &str = "kaname.workflow.effect-reconciled.v1";
pub const WORKFLOW_ATTEMPT_SETTLED_TYPE: &str = "kaname.workflow.attempt-settled.v1";
pub const WORKFLOW_PORT_EMITTED_TYPE: &str = "kaname.workflow.port-emitted.v1";
pub const WORKFLOW_EDGE_CHECKPOINTED_TYPE: &str = "kaname.workflow.edge-checkpointed.v1";
pub const WORKFLOW_MATCH_TRACE_RECORDED_TYPE: &str = "kaname.workflow.match-trace-recorded.v1";
pub const WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE: &str =
    "kaname.workflow.run-cancellation-requested.v1";
pub const WORKFLOW_RUN_SETTLED_TYPE: &str = "kaname.workflow.run-settled.v1";
pub const WORKFLOW_RUN_PURGED_TYPE: &str = "kaname.workflow.run-purged.v1";

const PROTOBUF_CONTENT_TYPE: &str = "application/x-protobuf";
const JSON_CONTENT_TYPE: &str = "application/json";
const MAXIMUM_TYPED_PAYLOAD_BYTES: usize = 48 * 1024;
const MAXIMUM_INLINE_VALUE_BYTES: usize = 32 * 1024;
const MAXIMUM_PORT_BINDINGS: usize = 64;
const MAXIMUM_TRACE_IDENTIFIERS: usize = 256;
const MAXIMUM_CAPABILITY_LOGS: usize = 128;
const MAXIMUM_LLM_CONTEXT_GROUPS: usize = 64;
const MAXIMUM_LLM_MESSAGES: usize = 128;
const MAXIMUM_LLM_TOOLS: usize = 64;
const MAXIMUM_LLM_TOOL_CALLS: usize = 128;
const MAXIMUM_LLM_RESPONSE_MESSAGES: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowRuntimeContractError {
    UnsupportedKind,
    Invalid(&'static str),
}

pub type Result<T> = std::result::Result<T, WorkflowRuntimeContractError>;

#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum WorkflowRuntimeCommand {
    RequestRun(v1::RequestWorkflowRun),
    CancelRun(v1::CancelWorkflowRun),
    SignalWait(v1::SignalWorkflowWait),
}

#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum WorkflowRuntimeEvent {
    CaseEpisodeStarted(v1::WorkflowCaseEpisodeStarted),
    SubflowCalled(v1::WorkflowSubflowCalled),
    SubflowSettled(v1::WorkflowSubflowSettled),
    RunTokenCreated(v1::WorkflowRunTokenCreated),
    ExecutionTokenCreated(v1::WorkflowExecutionTokenCreated),
    ExecutionTokenSettled(v1::WorkflowExecutionTokenSettled),
    JoinEvaluated(v1::WorkflowJoinEvaluated),
    IterationPlanned(v1::WorkflowIterationPlanned),
    IterationEvaluated(v1::WorkflowIterationEvaluated),
    RetryEvaluated(v1::WorkflowRetryEvaluated),
    WaitSignalRecorded(v1::WorkflowWaitSignalRecorded),
    WaitSubscribed(v1::WorkflowWaitSubscribed),
    WaitResolved(v1::WorkflowWaitResolved),
    AttemptStarted(v1::WorkflowAttemptStarted),
    CapabilityAttemptStarted(v1::WorkflowCapabilityAttemptStarted),
    CapabilityAttemptSettled(v1::WorkflowCapabilityAttemptSettled),
    LlmAttemptStarted(v1::WorkflowLlmAttemptStarted),
    LlmAttemptSettled(v1::WorkflowLlmAttemptSettled),
    ConnectorObservationStarted(v1::WorkflowConnectorObservationStarted),
    ConnectorObservationSettled(v1::WorkflowConnectorObservationSettled),
    EffectProposed(v1::WorkflowEffectProposed),
    EffectAuthorized(v1::WorkflowEffectAuthorized),
    EffectDispatchStarted(v1::WorkflowEffectDispatchStarted),
    EffectDispatchSettled(v1::WorkflowEffectDispatchSettled),
    EffectReconciled(v1::WorkflowEffectReconciled),
    AttemptSettled(v1::WorkflowAttemptSettled),
    PortEmitted(v1::WorkflowPortEmitted),
    EdgeCheckpointed(v1::WorkflowEdgeCheckpointed),
    MatchTraceRecorded(v1::WorkflowMatchTraceRecorded),
    RunCancellationRequested(v1::WorkflowRunCancellationRequested),
    RunSettled(v1::WorkflowRunSettled),
    RunPurged(v1::WorkflowRunPurged),
}

impl WorkflowRuntimeEvent {
    pub fn run_id(&self) -> &str {
        match self {
            Self::CaseEpisodeStarted(payload) => &payload.run_id,
            Self::SubflowCalled(payload) => &payload.run_id,
            Self::SubflowSettled(payload) => &payload.run_id,
            Self::RunTokenCreated(payload) => &payload.run_id,
            Self::ExecutionTokenCreated(payload) => &payload.run_id,
            Self::ExecutionTokenSettled(payload) => &payload.run_id,
            Self::JoinEvaluated(payload) => &payload.run_id,
            Self::IterationPlanned(payload) => &payload.run_id,
            Self::IterationEvaluated(payload) => &payload.run_id,
            Self::RetryEvaluated(payload) => &payload.run_id,
            Self::WaitSignalRecorded(payload) => &payload.run_id,
            Self::WaitSubscribed(payload) => &payload.run_id,
            Self::WaitResolved(payload) => &payload.run_id,
            Self::AttemptStarted(payload) => &payload.run_id,
            Self::CapabilityAttemptStarted(payload) => &payload.run_id,
            Self::CapabilityAttemptSettled(payload) => &payload.run_id,
            Self::LlmAttemptStarted(payload) => &payload.run_id,
            Self::LlmAttemptSettled(payload) => &payload.run_id,
            Self::ConnectorObservationStarted(payload) => payload
                .intent
                .as_ref()
                .map_or("", |intent| intent.run_id.as_str()),
            Self::ConnectorObservationSettled(payload) => &payload.run_id,
            Self::EffectProposed(payload) => payload
                .intent
                .as_ref()
                .map_or("", |intent| intent.run_id.as_str()),
            Self::EffectAuthorized(payload) => &payload.run_id,
            Self::EffectDispatchStarted(payload) => &payload.run_id,
            Self::EffectDispatchSettled(payload) => &payload.run_id,
            Self::EffectReconciled(payload) => &payload.run_id,
            Self::AttemptSettled(payload) => &payload.run_id,
            Self::PortEmitted(payload) => &payload.run_id,
            Self::EdgeCheckpointed(payload) => &payload.run_id,
            Self::MatchTraceRecorded(payload) => &payload.run_id,
            Self::RunCancellationRequested(payload) => &payload.run_id,
            Self::RunSettled(payload) => &payload.run_id,
            Self::RunPurged(payload) => &payload.run_id,
        }
    }
}

pub fn is_workflow_runtime_kind(kind: &str) -> bool {
    [
        "workflow.run.",
        "workflow.attempt.",
        "workflow.capability.",
        "workflow.llm.",
        "workflow.connector-observation.",
        "workflow.effect.",
        "workflow.port.",
        "workflow.edge.",
        "workflow.match.",
        "workflow.execution-token.",
        "workflow.join.",
        "workflow.iteration.",
        "workflow.retry.",
        "workflow.wait.",
        "workflow.case.",
        "workflow.subflow.",
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
        WORKFLOW_WAIT_SIGNAL_KIND => {
            let request: v1::SignalWorkflowWait =
                decode_payload(command.payload.as_ref(), WORKFLOW_WAIT_SIGNAL_TYPE)?;
            validate_wait_signal(&request)?;
            Ok(WorkflowRuntimeCommand::SignalWait(request))
        }
        _ => Err(WorkflowRuntimeContractError::UnsupportedKind),
    }
}

pub fn validate_workflow_event(event: &v1::EventEnvelope) -> Result<()> {
    decode_workflow_event(event).map(|_| ())
}

pub fn decode_workflow_event(event: &v1::EventEnvelope) -> Result<WorkflowRuntimeEvent> {
    match event.kind.as_str() {
        WORKFLOW_CASE_EPISODE_STARTED_KIND => {
            let payload: v1::WorkflowCaseEpisodeStarted =
                decode_payload(event.payload.as_ref(), WORKFLOW_CASE_EPISODE_STARTED_TYPE)?;
            validate_case_episode_started(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::CaseEpisodeStarted(payload))
        }
        WORKFLOW_SUBFLOW_CALLED_KIND => {
            let payload: v1::WorkflowSubflowCalled =
                decode_payload(event.payload.as_ref(), WORKFLOW_SUBFLOW_CALLED_TYPE)?;
            validate_subflow_called(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::SubflowCalled(payload))
        }
        WORKFLOW_SUBFLOW_SETTLED_KIND => {
            let payload: v1::WorkflowSubflowSettled =
                decode_payload(event.payload.as_ref(), WORKFLOW_SUBFLOW_SETTLED_TYPE)?;
            validate_subflow_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::SubflowSettled(payload))
        }
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
        WORKFLOW_WAIT_SIGNAL_RECORDED_KIND => {
            let payload: v1::WorkflowWaitSignalRecorded =
                decode_payload(event.payload.as_ref(), WORKFLOW_WAIT_SIGNAL_RECORDED_TYPE)?;
            validate_wait_signal_recorded(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::WaitSignalRecorded(payload))
        }
        WORKFLOW_WAIT_SUBSCRIBED_KIND => {
            let payload: v1::WorkflowWaitSubscribed =
                decode_payload(event.payload.as_ref(), WORKFLOW_WAIT_SUBSCRIBED_TYPE)?;
            validate_wait_subscribed(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::WaitSubscribed(payload))
        }
        WORKFLOW_WAIT_RESOLVED_KIND => {
            let payload: v1::WorkflowWaitResolved =
                decode_payload(event.payload.as_ref(), WORKFLOW_WAIT_RESOLVED_TYPE)?;
            validate_wait_resolved(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::WaitResolved(payload))
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
        WORKFLOW_CAPABILITY_ATTEMPT_STARTED_KIND => {
            let payload: v1::WorkflowCapabilityAttemptStarted = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_CAPABILITY_ATTEMPT_STARTED_TYPE,
            )?;
            validate_capability_attempt_started(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::CapabilityAttemptStarted(payload))
        }
        WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_KIND => {
            let payload: v1::WorkflowCapabilityAttemptSettled = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_CAPABILITY_ATTEMPT_SETTLED_TYPE,
            )?;
            validate_capability_attempt_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::CapabilityAttemptSettled(payload))
        }
        WORKFLOW_LLM_ATTEMPT_STARTED_KIND => {
            let payload: v1::WorkflowLlmAttemptStarted =
                decode_payload(event.payload.as_ref(), WORKFLOW_LLM_ATTEMPT_STARTED_TYPE)?;
            validate_llm_attempt_started(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::LlmAttemptStarted(payload))
        }
        WORKFLOW_LLM_ATTEMPT_SETTLED_KIND => {
            let payload: v1::WorkflowLlmAttemptSettled =
                decode_payload(event.payload.as_ref(), WORKFLOW_LLM_ATTEMPT_SETTLED_TYPE)?;
            validate_llm_attempt_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::LlmAttemptSettled(payload))
        }
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_KIND => {
            let payload: v1::WorkflowConnectorObservationStarted = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_CONNECTOR_OBSERVATION_STARTED_TYPE,
            )?;
            validate_connector_observation_started(&payload)?;
            let run_id = &payload
                .intent
                .as_ref()
                .ok_or_else(|| invalid_error("connector_observation_intent_missing"))?
                .run_id;
            validate_event_context(event, run_id)?;
            Ok(WorkflowRuntimeEvent::ConnectorObservationStarted(payload))
        }
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_KIND => {
            let payload: v1::WorkflowConnectorObservationSettled = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_TYPE,
            )?;
            validate_connector_observation_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::ConnectorObservationSettled(payload))
        }
        WORKFLOW_EFFECT_PROPOSED_KIND => {
            let payload: v1::WorkflowEffectProposed =
                decode_payload(event.payload.as_ref(), WORKFLOW_EFFECT_PROPOSED_TYPE)?;
            validate_effect_proposed(&payload)?;
            let run_id = &payload
                .intent
                .as_ref()
                .ok_or_else(|| invalid_error("effect_intent_missing"))?
                .run_id;
            validate_event_context(event, run_id)?;
            Ok(WorkflowRuntimeEvent::EffectProposed(payload))
        }
        WORKFLOW_EFFECT_AUTHORIZED_KIND => {
            let payload: v1::WorkflowEffectAuthorized =
                decode_payload(event.payload.as_ref(), WORKFLOW_EFFECT_AUTHORIZED_TYPE)?;
            validate_effect_authorized(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::EffectAuthorized(payload))
        }
        WORKFLOW_EFFECT_DISPATCH_STARTED_KIND => {
            let payload: v1::WorkflowEffectDispatchStarted = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_EFFECT_DISPATCH_STARTED_TYPE,
            )?;
            validate_effect_dispatch_started(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::EffectDispatchStarted(payload))
        }
        WORKFLOW_EFFECT_DISPATCH_SETTLED_KIND => {
            let payload: v1::WorkflowEffectDispatchSettled = decode_payload(
                event.payload.as_ref(),
                WORKFLOW_EFFECT_DISPATCH_SETTLED_TYPE,
            )?;
            validate_effect_dispatch_settled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::EffectDispatchSettled(payload))
        }
        WORKFLOW_EFFECT_RECONCILED_KIND => {
            let payload: v1::WorkflowEffectReconciled =
                decode_payload(event.payload.as_ref(), WORKFLOW_EFFECT_RECONCILED_TYPE)?;
            validate_effect_reconciled(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::EffectReconciled(payload))
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
        WORKFLOW_RUN_PURGED_KIND => {
            let payload: v1::WorkflowRunPurged =
                decode_payload(event.payload.as_ref(), WORKFLOW_RUN_PURGED_TYPE)?;
            validate_run_purged(&payload)?;
            validate_event_context(event, &payload.run_id)?;
            Ok(WorkflowRuntimeEvent::RunPurged(payload))
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
    let has_episode = !request.episode_id.is_empty()
        || !request.episode_kind.is_empty()
        || !request.prior_episode_id.is_empty();
    if has_episode {
        if request.installation_id.is_empty() || request.case_id.is_empty() {
            return invalid("episode_owner");
        }
        validate_identifier(&request.episode_id, 128, "episode_id")?;
        validate_episode_kind(&request.episode_kind)?;
        if request.episode_kind == "initial" {
            if !request.prior_episode_id.is_empty() {
                return invalid("initial_episode_prior");
            }
        } else {
            validate_identifier(&request.prior_episode_id, 128, "prior_episode_id")?;
        }
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

pub fn workflow_effect_intent_digest(intent: &v1::WorkflowEffectIntent) -> String {
    sha256_hex(&intent.encode_to_vec())
}

pub fn workflow_effect_preview_digest(preview: &v1::WorkflowEffectPreview) -> String {
    let mut canonical = preview.clone();
    canonical.preview_digest.clear();
    sha256_hex(&canonical.encode_to_vec())
}

pub fn workflow_effect_connector_registration_digest(
    registration: &v1::WorkflowEffectConnectorRegistration,
) -> String {
    let mut canonical = registration.clone();
    canonical.registration_digest.clear();
    sha256_hex(&canonical.encode_to_vec())
}

pub fn workflow_connector_observation_intent_digest(
    intent: &v1::WorkflowConnectorObservationIntent,
) -> String {
    sha256_hex(&intent.encode_to_vec())
}

pub fn workflow_connector_observation_registration_digest(
    registration: &v1::WorkflowConnectorObservationRegistration,
) -> String {
    let mut canonical = registration.clone();
    canonical.registration_digest.clear();
    sha256_hex(&canonical.encode_to_vec())
}

fn validate_connector_observation_started(
    payload: &v1::WorkflowConnectorObservationStarted,
) -> Result<()> {
    let intent = payload
        .intent
        .as_ref()
        .ok_or_else(|| invalid_error("connector_observation_intent_missing"))?;
    validate_run_and_token(&intent.run_id, &intent.run_token_id)?;
    for (value, code) in [
        (&intent.observation_id, "connector_observation_id"),
        (&intent.connector_class, "connector_observation_class"),
        (
            &intent.account_binding_id,
            "connector_observation_account_binding",
        ),
        (&intent.operation, "connector_observation_operation"),
        (
            &intent.idempotency_key,
            "connector_observation_idempotency_key",
        ),
    ] {
        validate_identifier(value, 128, code)?;
    }
    validate_digest(
        &intent.target_fingerprint,
        "connector_observation_target_fingerprint",
    )?;
    validate_digest(
        &payload.intent_digest,
        "connector_observation_intent_digest",
    )?;
    validate_value(intent.request.as_ref())?;
    validate_observation_fields(
        &intent.requested_fields,
        "connector_observation_requested_fields",
    )?;
    if intent.idempotency_key != intent.observation_id
        || payload.intent_digest != workflow_connector_observation_intent_digest(intent)
        || payload.deadline_unix_millis <= 0
    {
        return invalid("connector_observation_intent_contract");
    }
    let registration = payload
        .registration
        .as_ref()
        .ok_or_else(|| invalid_error("connector_observation_registration_missing"))?;
    validate_connector_observation_registration(registration)?;
    if registration.connector_class != intent.connector_class
        || registration.account_binding_id != intent.account_binding_id
        || registration
            .allowed_operations
            .binary_search(&intent.operation)
            .is_err()
        || intent
            .requested_fields
            .iter()
            .any(|field| registration.allowed_fields.binary_search(field).is_err())
    {
        return invalid("connector_observation_registration_mismatch");
    }
    Ok(())
}

fn validate_connector_observation_registration(
    registration: &v1::WorkflowConnectorObservationRegistration,
) -> Result<()> {
    for (value, code) in [
        (&registration.connector_class, "connector_observation_class"),
        (
            &registration.account_binding_id,
            "connector_observation_account_binding",
        ),
        (&registration.binding_id, "connector_observation_binding"),
        (
            &registration.connector_version,
            "connector_observation_version",
        ),
    ] {
        validate_identifier(value, 128, code)?;
    }
    validate_digest(
        &registration.installation_digest,
        "connector_observation_installation_digest",
    )?;
    validate_digest(
        &registration.registration_digest,
        "connector_observation_registration_digest",
    )?;
    validate_identifier_list(
        &registration.allowed_operations,
        64,
        "connector_observation_allowed_operations",
    )?;
    validate_observation_fields(
        &registration.allowed_fields,
        "connector_observation_allowed_fields",
    )?;
    if registration.allowed_operations.is_empty()
        || registration
            .allowed_operations
            .windows(2)
            .any(|pair| pair[0] >= pair[1])
        || registration.maximum_result_bytes == 0
        || registration.maximum_result_bytes > MAXIMUM_INLINE_VALUE_BYTES as u64
        || registration.registration_digest
            != workflow_connector_observation_registration_digest(registration)
    {
        return invalid("connector_observation_registration_contract");
    }
    Ok(())
}

fn validate_connector_observation_settled(
    payload: &v1::WorkflowConnectorObservationSettled,
) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.observation_id, 128, "connector_observation_id")?;
    validate_identifier(
        &payload.idempotency_key,
        128,
        "connector_observation_idempotency_key",
    )?;
    validate_digest(
        &payload.intent_digest,
        "connector_observation_intent_digest",
    )?;
    if payload.idempotency_key != payload.observation_id
        || payload.elapsed_milliseconds > 86_400_000
    {
        return invalid("connector_observation_settlement_contract");
    }
    let outcome = v1::WorkflowConnectorObservationOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("connector_observation_outcome"))?;
    match outcome {
        v1::WorkflowConnectorObservationOutcome::Succeeded => {
            let output = payload
                .output
                .as_ref()
                .ok_or_else(|| invalid_error("connector_observation_output_missing"))?;
            validate_value(Some(output))?;
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("connector_observation_success_error");
            }
            let receipt = payload
                .receipt
                .as_ref()
                .ok_or_else(|| invalid_error("connector_observation_receipt_missing"))?;
            validate_identifier(&receipt.receipt_id, 256, "connector_observation_receipt_id")?;
            validate_digest(
                &receipt.evidence_digest,
                "connector_observation_evidence_digest",
            )?;
            validate_observation_fields(
                &receipt.observed_fields,
                "connector_observation_observed_fields",
            )?;
            if receipt.observed_fields.is_empty()
                || receipt.result_byte_count != output.byte_count
                || receipt.evidence_digest != output.sha256
            {
                return invalid("connector_observation_receipt_contract");
            }
        }
        v1::WorkflowConnectorObservationOutcome::Rejected
        | v1::WorkflowConnectorObservationOutcome::Failed => {
            validate_identifier(&payload.error_code, 128, "connector_observation_error_code")?;
            validate_value(payload.error.as_ref())?;
            if payload.output.is_some() || payload.receipt.is_some() {
                return invalid("connector_observation_failure_output");
            }
        }
        v1::WorkflowConnectorObservationOutcome::Unspecified => {
            return invalid("connector_observation_outcome");
        }
    }
    Ok(())
}

fn validate_observation_fields(values: &[String], code: &'static str) -> Result<()> {
    validate_identifier_list(values, 64, code)?;
    if values.windows(2).any(|pair| pair[0] >= pair[1])
        || values.iter().any(|field| {
            let field = field.to_ascii_lowercase();
            field.contains("body") || field.contains("attachment")
        })
    {
        return invalid(code);
    }
    Ok(())
}

fn validate_effect_proposed(payload: &v1::WorkflowEffectProposed) -> Result<()> {
    let intent = payload
        .intent
        .as_ref()
        .ok_or_else(|| invalid_error("effect_intent_missing"))?;
    validate_run_and_token(&intent.run_id, &intent.run_token_id)?;
    for (value, code) in [
        (&intent.effect_id, "effect_id"),
        (&intent.attempt_id, "attempt_id"),
        (&intent.execution_token_id, "execution_token_id"),
        (&intent.node_id, "node_id"),
        (&intent.workflow_id, "workflow_id"),
        (&intent.revision_id, "revision_id"),
        (&intent.connector_class, "connector_class"),
        (&intent.action, "effect_action"),
        (&intent.account_binding_id, "account_binding_id"),
        (&intent.idempotency_key, "effect_idempotency_key"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    for (value, code) in [
        (
            &intent.destination_fingerprint,
            "effect_destination_fingerprint",
        ),
        (&intent.input_digest, "effect_input_digest"),
        (&payload.intent_digest, "effect_intent_digest"),
    ] {
        validate_digest(value, code)?;
    }
    if payload.intent_digest != workflow_effect_intent_digest(intent) {
        return invalid("effect_intent_digest_mismatch");
    }
    let preview = payload
        .preview
        .as_ref()
        .ok_or_else(|| invalid_error("effect_preview_missing"))?;
    validate_text(&preview.summary, 1024, "effect_preview_summary")?;
    validate_text(&preview.consequence, 1024, "effect_preview_consequence")?;
    validate_digest(
        &preview.destination_fingerprint,
        "effect_preview_destination_fingerprint",
    )?;
    validate_digest(&preview.preview_digest, "effect_preview_digest")?;
    if preview.destination_fingerprint != intent.destination_fingerprint
        || preview.preview_digest != workflow_effect_preview_digest(preview)
    {
        return invalid("effect_preview_mismatch");
    }
    let approval = payload
        .approval_request
        .as_ref()
        .ok_or_else(|| invalid_error("effect_approval_missing"))?;
    validate_identifier(&approval.approval_id, 128, "approval_id")?;
    validate_identifier(
        &approval.policy_reference,
        128,
        "effect_approval_policy_reference",
    )?;
    if approval.action_kind != "workflow.effect"
        || approval.target_id != intent.effect_id
        || approval.target_revision != intent.revision_id
        || approval.effect_digest != hex::decode(&payload.intent_digest).unwrap_or_default()
        || approval.consequence != preview.consequence
        || approval.reversible != preview.reversible
        || approval.expires_at_unix_millis <= 0
        || approval.approval_payload_version != 1
        || approval.fingerprint != approval_fingerprint(approval)
    {
        return invalid("effect_approval_mismatch");
    }
    let scope = approval
        .scope
        .as_ref()
        .ok_or_else(|| invalid_error("effect_approval_scope_missing"))?;
    validate_identifier(&scope.project_id, 128, "effect_scope_project_id")?;
    if !scope.workspace_id.is_empty() {
        validate_identifier(&scope.workspace_id, 128, "effect_scope_workspace_id")?;
    }
    validate_identifier(&scope.account_id, 128, "effect_scope_account_id")?;
    validate_identifier(&scope.egress_class, 128, "effect_scope_egress_class")?;
    validate_digest(&scope.destination_digest, "effect_scope_destination_digest")?;
    if !scope.authority_id.is_empty()
        || scope.account_id != intent.account_binding_id
        || scope.destination_digest != intent.destination_fingerprint
    {
        return invalid("effect_approval_scope_mismatch");
    }
    Ok(())
}

fn validate_effect_authorized(payload: &v1::WorkflowEffectAuthorized) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.effect_id, "effect_id"),
        (&payload.grant_id, "effect_grant_id"),
        (&payload.idempotency_key, "effect_idempotency_key"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    for (value, code) in [
        (&payload.intent_digest, "effect_intent_digest"),
        (&payload.preview_digest, "effect_preview_digest"),
        (
            &payload.destination_fingerprint,
            "effect_destination_fingerprint",
        ),
    ] {
        validate_digest(value, code)?;
    }
    let resolution = payload
        .resolution
        .as_ref()
        .ok_or_else(|| invalid_error("effect_resolution_missing"))?;
    validate_identifier(&resolution.approval_id, 128, "approval_id")?;
    validate_identifier(&resolution.actor_id, 128, "approval_actor_id")?;
    validate_identifier(&resolution.device_id, 128, "approval_device_id")?;
    if v1::ApprovalDecision::try_from(resolution.decision) != Ok(v1::ApprovalDecision::Approve)
        || resolution.expected_fingerprint != payload.approval_fingerprint
        || payload.approval_fingerprint.len() != 32
        || payload.expires_at_unix_millis <= 0
    {
        return invalid("effect_authorization_mismatch");
    }
    Ok(())
}

fn validate_effect_connector_registration(
    registration: &v1::WorkflowEffectConnectorRegistration,
) -> Result<()> {
    for (value, code) in [
        (&registration.connector_class, "effect_connector_class"),
        (&registration.version, "effect_connector_version"),
        (&registration.binding_id, "effect_connector_binding_id"),
        (
            &registration.account_binding_id,
            "effect_connector_account_binding_id",
        ),
    ] {
        validate_identifier(value, 128, code)?;
    }
    validate_digest(
        &registration.package_digest,
        "effect_connector_package_digest",
    )?;
    validate_digest(
        &registration.registration_digest,
        "effect_connector_registration_digest",
    )?;
    if !registration.idempotent
        || !registration.supports_reconciliation
        || registration.allowed_actions.is_empty()
        || registration.allowed_actions.len() > 64
        || registration
            .allowed_actions
            .windows(2)
            .any(|pair| pair[0] >= pair[1])
        || registration.registration_digest
            != workflow_effect_connector_registration_digest(registration)
    {
        return invalid("effect_connector_registration_contract");
    }
    for action in &registration.allowed_actions {
        validate_identifier(action, 128, "effect_connector_allowed_action")?;
    }
    Ok(())
}

fn validate_effect_dispatch_started(payload: &v1::WorkflowEffectDispatchStarted) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.effect_id, "effect_id"),
        (&payload.dispatch_id, "effect_dispatch_id"),
        (&payload.grant_id, "effect_grant_id"),
        (&payload.idempotency_key, "effect_idempotency_key"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    for (value, code) in [
        (&payload.intent_digest, "effect_intent_digest"),
        (&payload.preview_digest, "effect_preview_digest"),
        (
            &payload.destination_fingerprint,
            "effect_destination_fingerprint",
        ),
    ] {
        validate_digest(value, code)?;
    }
    validate_effect_connector_registration(
        payload
            .registration
            .as_ref()
            .ok_or_else(|| invalid_error("effect_connector_registration_missing"))?,
    )?;
    if payload.deadline_unix_millis <= 0 {
        return invalid("effect_dispatch_deadline");
    }
    Ok(())
}

fn validate_effect_receipt(
    receipt: Option<&v1::WorkflowEffectReceipt>,
    expected: v1::WorkflowEffectReceiptOutcome,
) -> Result<()> {
    let receipt = receipt.ok_or_else(|| invalid_error("effect_receipt_missing"))?;
    validate_identifier(&receipt.receipt_id, 256, "effect_receipt_id")?;
    if !receipt.provider_reference.is_empty() {
        validate_identifier(
            &receipt.provider_reference,
            256,
            "effect_provider_reference",
        )?;
    }
    validate_digest(&receipt.evidence_digest, "effect_receipt_evidence_digest")?;
    if v1::WorkflowEffectReceiptOutcome::try_from(receipt.outcome) != Ok(expected) {
        return invalid("effect_receipt_outcome");
    }
    Ok(())
}

fn validate_effect_dispatch_settled(payload: &v1::WorkflowEffectDispatchSettled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.effect_id, "effect_id"),
        (&payload.dispatch_id, "effect_dispatch_id"),
        (&payload.grant_id, "effect_grant_id"),
        (&payload.idempotency_key, "effect_idempotency_key"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    if payload.elapsed_milliseconds > 86_400_000 {
        return invalid("effect_dispatch_elapsed");
    }
    let outcome = v1::WorkflowEffectDispatchOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("effect_dispatch_outcome"))?;
    let receipt_outcome = match outcome {
        v1::WorkflowEffectDispatchOutcome::Succeeded => {
            if !payload.error_code.is_empty() {
                return invalid("effect_dispatch_success_error");
            }
            v1::WorkflowEffectReceiptOutcome::Applied
        }
        v1::WorkflowEffectDispatchOutcome::Rejected
        | v1::WorkflowEffectDispatchOutcome::NotSent => {
            validate_identifier(&payload.error_code, 128, "effect_dispatch_error_code")?;
            v1::WorkflowEffectReceiptOutcome::NotApplied
        }
        v1::WorkflowEffectDispatchOutcome::Unknown => {
            validate_identifier(&payload.error_code, 128, "effect_dispatch_error_code")?;
            v1::WorkflowEffectReceiptOutcome::Unknown
        }
        v1::WorkflowEffectDispatchOutcome::Unspecified => {
            return invalid("effect_dispatch_outcome");
        }
    };
    validate_effect_receipt(payload.receipt.as_ref(), receipt_outcome)
}

fn validate_effect_reconciled(payload: &v1::WorkflowEffectReconciled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.effect_id, "effect_id"),
        (&payload.dispatch_id, "effect_dispatch_id"),
        (&payload.reconciliation_id, "effect_reconciliation_id"),
        (&payload.idempotency_key, "effect_idempotency_key"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    if payload.elapsed_milliseconds > 86_400_000 {
        return invalid("effect_reconciliation_elapsed");
    }
    let outcome = v1::WorkflowEffectReconciliationOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("effect_reconciliation_outcome"))?;
    let receipt_outcome = match outcome {
        v1::WorkflowEffectReconciliationOutcome::Applied => {
            if !payload.error_code.is_empty() {
                return invalid("effect_reconciliation_success_error");
            }
            v1::WorkflowEffectReceiptOutcome::Applied
        }
        v1::WorkflowEffectReconciliationOutcome::NotApplied => {
            validate_identifier(&payload.error_code, 128, "effect_reconciliation_error_code")?;
            v1::WorkflowEffectReceiptOutcome::NotApplied
        }
        v1::WorkflowEffectReconciliationOutcome::StillUnknown => {
            validate_identifier(&payload.error_code, 128, "effect_reconciliation_error_code")?;
            v1::WorkflowEffectReceiptOutcome::Unknown
        }
        v1::WorkflowEffectReconciliationOutcome::Unspecified => {
            return invalid("effect_reconciliation_outcome");
        }
    };
    validate_effect_receipt(payload.receipt.as_ref(), receipt_outcome)
}

fn validate_case_episode_started(payload: &v1::WorkflowCaseEpisodeStarted) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.installation_id, "installation_id"),
        (&payload.case_id, "case_id"),
        (&payload.episode_id, "episode_id"),
        (&payload.workflow_id, "workflow_id"),
        (&payload.revision_id, "revision_id"),
        (&payload.trigger_kind, "trigger_kind"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    if payload.ordinal == 0 {
        return invalid("episode_ordinal");
    }
    validate_episode_kind(&payload.kind)?;
    if payload.kind == "initial" {
        if !payload.prior_episode_id.is_empty() || payload.ordinal != 1 {
            return invalid("initial_episode_contract");
        }
    } else {
        validate_identifier(&payload.prior_episode_id, 128, "prior_episode_id")?;
        if payload.ordinal == 1 {
            return invalid("related_episode_ordinal");
        }
    }
    validate_digest(&payload.package_digest, "package_digest")?;
    if !payload.trigger_event_id.is_empty() {
        validate_identifier(&payload.trigger_event_id, 128, "trigger_event_id")?;
    }
    if payload.inputs.is_empty() || payload.inputs.len() > MAXIMUM_PORT_BINDINGS {
        return invalid("episode_input_count");
    }
    let mut ports = BTreeSet::new();
    for input in &payload.inputs {
        validate_identifier(&input.port_id, 128, "input_port_id")?;
        if !ports.insert(input.port_id.as_str()) {
            return invalid("duplicate_input_port");
        }
        validate_value(input.value.as_ref())?;
    }
    validate_value(payload.compiled_context.as_ref())?;
    validate_identifier_list(&payload.source_episode_ids, 64, "source_episode_id")?;
    validate_identifier_list(&payload.source_event_ids, 512, "source_event_id")?;
    if payload.source_episode_ids.len() + 1 != payload.ordinal as usize {
        return invalid("episode_source_count");
    }
    Ok(())
}

fn validate_episode_kind(kind: &str) -> Result<()> {
    if matches!(kind, "initial" | "delivery" | "correction" | "redelivery") {
        Ok(())
    } else {
        invalid("episode_kind")
    }
}

fn validate_subflow_called(payload: &v1::WorkflowSubflowCalled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.invocation_id, "subflow_invocation_id"),
        (&payload.attempt_id, "attempt_id"),
        (&payload.execution_token_id, "execution_token_id"),
        (&payload.node_id, "node_id"),
        (&payload.child_run_id, "child_run_id"),
        (&payload.child_command_id, "child_command_id"),
        (&payload.child_workflow_id, "child_workflow_id"),
        (&payload.child_revision_id, "child_revision_id"),
        (&payload.entrypoint, "subflow_entrypoint"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    validate_text(&payload.child_package_id, 255, "child_package_id")?;
    validate_digest(&payload.child_package_digest, "child_package_digest")?;
    validate_value(payload.input.as_ref())
}

fn validate_subflow_settled(payload: &v1::WorkflowSubflowSettled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.invocation_id, 128, "subflow_invocation_id")?;
    validate_identifier(&payload.child_run_id, 128, "child_run_id")?;
    let outcome = v1::WorkflowRunOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("subflow_outcome"))?;
    match outcome {
        v1::WorkflowRunOutcome::Succeeded => {
            validate_value(payload.output.as_ref())?;
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("subflow_success_contract");
            }
        }
        v1::WorkflowRunOutcome::Failed | v1::WorkflowRunOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "subflow_error_code")?;
            validate_value(payload.error.as_ref())?;
            if payload.output.is_some() {
                return invalid("subflow_failure_contract");
            }
        }
        v1::WorkflowRunOutcome::Unspecified => return invalid("subflow_outcome"),
    }
    validate_identifier_list(
        &payload.child_final_emission_ids,
        256,
        "child_final_emission_id",
    )
}

fn validate_cancel_request(request: &v1::CancelWorkflowRun) -> Result<()> {
    validate_run_and_token(&request.run_id, &request.run_token_id)?;
    validate_identifier(&request.reason_code, 128, "reason_code")
}

fn validate_wait_signal(request: &v1::SignalWorkflowWait) -> Result<()> {
    validate_identifier(&request.run_id, 128, "run_id")?;
    validate_identifier(&request.signal_id, 128, "signal_id")?;
    validate_wait_identity(
        &request.kind,
        &request.owner_kind,
        &request.owner_id,
        &request.correlation,
        false,
    )?;
    validate_value(request.value.as_ref())
}

fn validate_wait_signal_recorded(payload: &v1::WorkflowWaitSignalRecorded) -> Result<()> {
    validate_identifier(&payload.run_id, 128, "run_id")?;
    validate_identifier(&payload.signal_id, 128, "signal_id")?;
    validate_identifier(&payload.signal_command_id, 128, "signal_command_id")?;
    validate_wait_identity(
        &payload.kind,
        &payload.owner_kind,
        &payload.owner_id,
        &payload.correlation,
        false,
    )?;
    validate_value(payload.value.as_ref())
}

fn validate_wait_subscribed(payload: &v1::WorkflowWaitSubscribed) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.subscription_id, "subscription_id"),
        (&payload.wait_node_id, "wait_node_id"),
        (&payload.execution_token_id, "execution_token_id"),
        (&payload.controller_attempt_id, "controller_attempt_id"),
        (&payload.workflow_id, "workflow_id"),
        (&payload.revision_id, "revision_id"),
        (&payload.input_value_id, "input_value_id"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    validate_digest(&payload.package_digest, "package_digest")?;
    validate_digest(&payload.input_sha256, "input_sha256")?;
    validate_wait_identity(
        &payload.kind,
        &payload.owner_kind,
        &payload.owner_id,
        &payload.correlation,
        true,
    )?;
    if payload.expires_at_unix_millis <= 0 {
        return invalid("wait_expiry");
    }
    Ok(())
}

fn validate_wait_resolved(payload: &v1::WorkflowWaitResolved) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.subscription_id, 128, "subscription_id")?;
    let decision = v1::WorkflowWaitDecision::try_from(payload.decision)
        .map_err(|_| invalid_error("wait_decision"))?;
    match decision {
        v1::WorkflowWaitDecision::Resumed => {
            validate_identifier(&payload.signal_id, 128, "signal_id")?;
            validate_value(payload.output.as_ref())?;
            if !payload.reason_code.is_empty() {
                return invalid("wait_resume_contract");
            }
        }
        v1::WorkflowWaitDecision::Expired => {
            if !payload.signal_id.is_empty() {
                return invalid("wait_expiry_contract");
            }
            validate_value(payload.output.as_ref())?;
            if payload.reason_code != "wait.expired" {
                return invalid("wait_expiry_contract");
            }
        }
        v1::WorkflowWaitDecision::Cancelled => {
            if !payload.signal_id.is_empty() || payload.output.is_some() {
                return invalid("wait_cancellation_contract");
            }
            validate_identifier(&payload.reason_code, 128, "reason_code")?;
        }
        v1::WorkflowWaitDecision::Unspecified => return invalid("wait_decision"),
    }
    Ok(())
}

fn validate_wait_identity(
    kind: &str,
    owner_kind: &str,
    owner_id: &str,
    correlation: &[v1::WorkflowWaitCorrelation],
    timer_allowed: bool,
) -> Result<()> {
    if !matches!(kind, "event" | "reply") && !(timer_allowed && kind == "timer") {
        return invalid("wait_kind");
    }
    if !matches!(owner_kind, "case" | "installation" | "workflow") {
        return invalid("wait_owner_kind");
    }
    validate_identifier(owner_id, 128, "wait_owner_id")?;
    if correlation.is_empty() || correlation.len() > 16 {
        return invalid("wait_correlation_count");
    }
    let mut previous = None;
    for item in correlation {
        validate_text(&item.key, 512, "wait_correlation_key")?;
        validate_digest(&item.sha256, "wait_correlation_digest")?;
        if previous.is_some_and(|key: &str| key >= item.key.as_str()) {
            return invalid("wait_correlation_order");
        }
        previous = Some(item.key.as_str());
    }
    Ok(())
}

fn validate_token_created(payload: &v1::WorkflowRunTokenCreated) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.request_command_id, 128, "request_command_id")?;
    validate_identifier(&payload.workflow_id, 128, "workflow_id")?;
    validate_identifier(&payload.revision_id, 128, "revision_id")?;
    validate_digest(&payload.package_digest, "package_digest")?;
    WorkflowRunRetentionPolicy::from_proto(payload.retention_policy.as_ref())
        .map_err(|_| WorkflowRuntimeContractError::Invalid("run_retention_policy"))?;
    Ok(())
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

fn validate_capability_attempt_started(
    payload: &v1::WorkflowCapabilityAttemptStarted,
) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.invocation_id, 128, "capability_invocation_id")?;
    validate_identifier(&payload.attempt_id, 128, "attempt_id")?;
    validate_identifier(&payload.execution_token_id, 128, "execution_token_id")?;
    validate_identifier(&payload.node_id, 128, "node_id")?;
    validate_identifier(&payload.capability_id, 128, "capability_id")?;
    validate_identifier(&payload.version, 64, "capability_version")?;
    validate_digest(&payload.package_digest, "capability_package_digest")?;
    validate_digest(
        &payload.configuration_contract_digest,
        "capability_configuration_contract_digest",
    )?;
    validate_digest(
        &payload.input_schema_digest,
        "capability_input_schema_digest",
    )?;
    validate_digest(
        &payload.output_schema_digest,
        "capability_output_schema_digest",
    )?;
    validate_text(
        &payload.output_schema_ref,
        256,
        "capability_output_schema_ref",
    )?;
    validate_value(payload.configuration.as_ref())?;
    validate_value(payload.input.as_ref())?;
    validate_capability_artifacts(&payload.artifact_inputs)?;
    if payload.timeout_milliseconds == 0
        || payload.timeout_milliseconds > 86_400_000
        || payload.deadline_unix_millis < 0
    {
        return invalid("capability_timeout");
    }
    Ok(())
}

fn validate_capability_attempt_settled(
    payload: &v1::WorkflowCapabilityAttemptSettled,
) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.invocation_id, 128, "capability_invocation_id")?;
    validate_identifier(&payload.attempt_id, 128, "attempt_id")?;
    if payload.idempotency_key != payload.invocation_id {
        return invalid("capability_idempotency_key");
    }
    if payload.elapsed_milliseconds > 86_400_000 {
        return invalid("capability_elapsed");
    }
    validate_capability_logs(&payload.logs, payload.elapsed_milliseconds)?;
    validate_capability_artifacts(&payload.artifact_outputs)?;
    let outcome = v1::WorkflowCapabilityAttemptOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("capability_outcome"))?;
    match outcome {
        v1::WorkflowCapabilityAttemptOutcome::Succeeded => {
            validate_value(payload.output.as_ref())?;
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("capability_success_error");
            }
            validate_identifier(&payload.receipt_id, 256, "capability_receipt_id")?;
            if !payload.provider_run_reference.is_empty() {
                validate_identifier(
                    &payload.provider_run_reference,
                    256,
                    "capability_provider_run_reference",
                )?;
            }
        }
        v1::WorkflowCapabilityAttemptOutcome::InputValidationFailed
        | v1::WorkflowCapabilityAttemptOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "capability_error_code")?;
            if payload.output.is_some() || !payload.artifact_outputs.is_empty() {
                return invalid("capability_failure_output");
            }
            if payload.error.is_some() {
                validate_value(payload.error.as_ref())?;
            }
            if !payload.receipt_id.is_empty() {
                validate_identifier(&payload.receipt_id, 256, "capability_receipt_id")?;
            }
        }
        v1::WorkflowCapabilityAttemptOutcome::OutputValidationFailed
        | v1::WorkflowCapabilityAttemptOutcome::TimedOut
        | v1::WorkflowCapabilityAttemptOutcome::MalformedResult
        | v1::WorkflowCapabilityAttemptOutcome::Crashed => {
            validate_identifier(&payload.error_code, 128, "capability_error_code")?;
            validate_value(payload.error.as_ref())?;
            if payload.output.is_some() || !payload.artifact_outputs.is_empty() {
                return invalid("capability_failure_output");
            }
            validate_identifier(&payload.receipt_id, 256, "capability_receipt_id")?;
        }
        v1::WorkflowCapabilityAttemptOutcome::Unspecified => {
            return invalid("capability_outcome");
        }
    }
    Ok(())
}

fn validate_capability_artifacts(values: &[v1::WorkflowCapabilityArtifactHandle]) -> Result<()> {
    if values.len() > MAXIMUM_PORT_BINDINGS {
        return invalid("capability_artifact_count");
    }
    let mut handles = BTreeSet::new();
    for artifact in values {
        validate_identifier(&artifact.handle_id, 128, "capability_artifact_handle_id")?;
        validate_identifier(&artifact.role, 128, "capability_artifact_role")?;
        let value = artifact
            .value
            .as_ref()
            .ok_or_else(|| invalid_error("capability_artifact_value"))?;
        validate_value(Some(value))?;
        if value.storage_reference_id.is_empty()
            || !value.inline_canonical_json.is_empty()
            || value.storage.as_ref().is_none_or(|metadata| {
                metadata.handle_id != artifact.handle_id || metadata.handle_id.is_empty()
            })
            || !handles.insert(artifact.handle_id.as_str())
        {
            return invalid("capability_artifact_handle");
        }
    }
    Ok(())
}

fn validate_capability_logs(
    logs: &[v1::WorkflowCapabilityLogEntry],
    elapsed_milliseconds: u64,
) -> Result<()> {
    if logs.len() > MAXIMUM_CAPABILITY_LOGS {
        return invalid("capability_log_count");
    }
    for (index, log) in logs.iter().enumerate() {
        if log.sequence != (index + 1) as u32
            || !matches!(log.level.as_str(), "debug" | "info" | "warning" | "error")
            || log.offset_milliseconds > elapsed_milliseconds
        {
            return invalid("capability_log_contract");
        }
        validate_text(&log.message, 2_048, "capability_log_message")?;
    }
    Ok(())
}

fn validate_llm_attempt_started(payload: &v1::WorkflowLlmAttemptStarted) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    for (value, code) in [
        (&payload.invocation_id, "llm_invocation_id"),
        (&payload.attempt_id, "attempt_id"),
        (&payload.execution_token_id, "execution_token_id"),
        (&payload.node_id, "node_id"),
    ] {
        validate_identifier(value, 128, code)?;
    }
    let settings = payload
        .settings
        .as_ref()
        .ok_or_else(|| invalid_error("llm_settings"))?;
    validate_llm_settings(settings)?;
    validate_digest(&payload.context_digest, "llm_context_digest")?;
    validate_text(&payload.output_schema_ref, 256, "llm_output_schema_ref")?;
    validate_digest(&payload.output_schema_digest, "llm_output_schema_digest")?;
    validate_value(payload.input.as_ref())?;
    if payload.timeout_milliseconds == 0
        || payload.timeout_milliseconds > 86_400_000
        || payload.deadline_unix_millis < 0
        || payload.context_groups.is_empty()
        || payload.context_groups.len() > MAXIMUM_LLM_CONTEXT_GROUPS
        || payload.messages.is_empty()
        || payload.messages.len() > MAXIMUM_LLM_MESSAGES
    {
        return invalid("llm_started_bounds");
    }

    let mut group_ids = BTreeSet::new();
    let mut retained_bytes = 0_u64;
    let mut original_bytes = 0_u64;
    let mut redactions = 0_u32;
    for group in &payload.context_groups {
        validate_identifier(&group.group_id, 128, "llm_context_group_id")?;
        validate_identifier(&group.kind, 128, "llm_context_group_kind")?;
        validate_text(&group.title, 256, "llm_context_group_title")?;
        validate_text(&group.provenance, 512, "llm_context_group_provenance")?;
        validate_llm_safe_text(&group.provenance, "llm_context_group_provenance")?;
        validate_value(group.content.as_ref())?;
        let content = group
            .content
            .as_ref()
            .ok_or_else(|| invalid_error("llm_context_group_content"))?;
        if group.retained_byte_count != content.byte_count
            || group.original_byte_count < group.retained_byte_count
            || (!group.truncated && group.original_byte_count != group.retained_byte_count)
            || !group_ids.insert(group.group_id.as_str())
        {
            return invalid("llm_context_group_contract");
        }
        validate_identifier_list(
            &group.source_episode_ids,
            64,
            "llm_context_source_episode_id",
        )?;
        retained_bytes = retained_bytes.saturating_add(group.retained_byte_count);
        original_bytes = original_bytes.saturating_add(group.original_byte_count);
        redactions = redactions.saturating_add(group.redaction_count);
    }
    if retained_bytes > settings.maximum_context_bytes {
        return invalid("llm_context_byte_bound");
    }

    let mut message_ids = BTreeSet::new();
    for (index, message) in payload.messages.iter().enumerate() {
        validate_identifier(&message.message_id, 128, "llm_message_id")?;
        validate_identifier(
            &message.context_group_id,
            128,
            "llm_message_context_group_id",
        )?;
        validate_text(&message.summary, 512, "llm_message_summary")?;
        validate_llm_safe_text(&message.summary, "llm_message_summary")?;
        validate_identifier(
            &message.content_value_id,
            128,
            "llm_message_content_value_id",
        )?;
        let group = payload
            .context_groups
            .iter()
            .find(|group| group.group_id == message.context_group_id)
            .ok_or_else(|| invalid_error("llm_message_context_group"))?;
        if message.sequence != (index + 1) as u32
            || !matches!(
                message.role.as_str(),
                "system" | "developer" | "user" | "assistant" | "tool"
            )
            || !message_ids.insert(message.message_id.as_str())
            || group
                .content
                .as_ref()
                .is_none_or(|content| message.content_value_id != content.value_id)
            || message.redaction_count != group.redaction_count
            || message.truncated != group.truncated
        {
            return invalid("llm_message_contract");
        }
    }
    validate_identifier_list(&payload.prior_episode_ids, 64, "llm_prior_episode_id")?;
    validate_capability_artifacts(&payload.attachments)?;
    validate_llm_tool_definitions(&payload.tool_definitions)?;
    let report = payload
        .compilation_report
        .as_ref()
        .ok_or_else(|| invalid_error("llm_compilation_report"))?;
    validate_llm_compilation_report(
        report,
        &group_ids,
        payload.context_groups.len() as u32,
        retained_bytes,
        original_bytes,
        redactions,
    )
}

fn validate_llm_tool_definitions(values: &[v1::WorkflowLlmToolDefinition]) -> Result<()> {
    if values.len() > MAXIMUM_LLM_TOOLS {
        return invalid("llm_tool_definition_count");
    }
    let mut ids = BTreeSet::new();
    for value in values {
        validate_identifier(&value.tool_id, 128, "llm_tool_id")?;
        validate_identifier(&value.version, 64, "llm_tool_version")?;
        validate_digest(&value.package_digest, "llm_tool_package_digest")?;
        validate_text(&value.description, 512, "llm_tool_description")?;
        validate_llm_safe_text(&value.description, "llm_tool_description")?;
        validate_text(&value.input_schema_ref, 256, "llm_tool_input_schema_ref")?;
        validate_digest(&value.input_schema_digest, "llm_tool_input_schema_digest")?;
        validate_text(&value.output_schema_ref, 256, "llm_tool_output_schema_ref")?;
        validate_digest(&value.output_schema_digest, "llm_tool_output_schema_digest")?;
        if !ids.insert(value.tool_id.as_str()) {
            return invalid("llm_tool_definition_duplicate");
        }
    }
    Ok(())
}

fn validate_llm_settings(settings: &v1::WorkflowLlmModelSettings) -> Result<()> {
    validate_identifier(&settings.model_class, 128, "llm_model_class")?;
    validate_identifier(&settings.provider_id, 128, "llm_provider_id")?;
    validate_text(&settings.model_id, 256, "llm_model_id")?;
    validate_text(&settings.model_revision, 256, "llm_model_revision")?;
    if !matches!(
        settings.reasoning_effort.as_str(),
        "minimal" | "low" | "medium" | "high"
    ) || settings.temperature_milli > 2_000
        || !(256..=49_152).contains(&settings.maximum_context_bytes)
        || !(1..=65_536).contains(&settings.maximum_output_tokens)
        || !matches!(settings.conversation_scope.as_str(), "job" | "case")
    {
        return invalid("llm_settings_contract");
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_llm_compilation_report(
    report: &v1::WorkflowLlmCompilationReport,
    retained_group_ids: &BTreeSet<&str>,
    retained_group_count: u32,
    retained_byte_count: u64,
    retained_original_byte_count: u64,
    redaction_count: u32,
) -> Result<()> {
    if report.original_group_count < retained_group_count
        || report.retained_group_count != retained_group_count
        || report.original_byte_count < retained_original_byte_count
        || report.retained_byte_count != retained_byte_count
        || report.original_byte_count < report.retained_byte_count
        || report.redaction_count != redaction_count
    {
        return invalid("llm_compilation_report_totals");
    }
    validate_identifier_list(
        &report.truncated_group_ids,
        MAXIMUM_LLM_CONTEXT_GROUPS,
        "llm_truncated_group_id",
    )?;
    validate_identifier_list(
        &report.dropped_group_ids,
        MAXIMUM_LLM_CONTEXT_GROUPS,
        "llm_dropped_group_id",
    )?;
    let truncated = report
        .truncated_group_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let dropped = report
        .dropped_group_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    if !truncated.is_subset(retained_group_ids)
        || !truncated.is_disjoint(&dropped)
        || report.original_group_count
            != retained_group_count.saturating_add(report.dropped_group_ids.len() as u32)
    {
        return invalid("llm_compilation_report_groups");
    }
    if report.redaction_reasons.len() > 16 {
        return invalid("llm_redaction_reason_count");
    }
    let mut previous = None;
    for reason in &report.redaction_reasons {
        validate_identifier(reason, 64, "llm_redaction_reason")?;
        if previous.is_some_and(|value: &str| value >= reason.as_str()) {
            return invalid("llm_redaction_reason_order");
        }
        previous = Some(reason.as_str());
    }
    Ok(())
}

fn validate_llm_attempt_settled(payload: &v1::WorkflowLlmAttemptSettled) -> Result<()> {
    validate_run_and_token(&payload.run_id, &payload.run_token_id)?;
    validate_identifier(&payload.invocation_id, 128, "llm_invocation_id")?;
    validate_identifier(&payload.attempt_id, 128, "attempt_id")?;
    if payload.idempotency_key != payload.invocation_id || payload.elapsed_milliseconds > 86_400_000
    {
        return invalid("llm_settled_contract");
    }
    let outcome = v1::WorkflowLlmAttemptOutcome::try_from(payload.outcome)
        .map_err(|_| invalid_error("llm_outcome"))?;
    validate_llm_tool_calls(&payload.tool_calls, payload.elapsed_milliseconds)?;
    validate_llm_response_messages(&payload.response_messages, &payload.tool_calls)?;
    validate_llm_usage(payload.usage.as_ref(), payload.tool_calls.len())?;
    validate_llm_response_validation(payload.validation.as_ref(), outcome)?;
    validate_llm_provider_receipt(payload.provider_receipt.as_ref(), payload)?;
    match outcome {
        v1::WorkflowLlmAttemptOutcome::Succeeded => {
            validate_value(payload.output.as_ref())?;
            if !payload.error_code.is_empty() || payload.error.is_some() {
                return invalid("llm_success_contract");
            }
            validate_identifier(&payload.receipt_id, 256, "llm_receipt_id")?;
            if !payload.provider_run_reference.is_empty() {
                validate_identifier(
                    &payload.provider_run_reference,
                    256,
                    "llm_provider_run_reference",
                )?;
            }
        }
        v1::WorkflowLlmAttemptOutcome::Cancelled => {
            validate_identifier(&payload.error_code, 128, "llm_error_code")?;
            if payload.output.is_some() || payload.error.is_some() {
                return invalid("llm_cancelled_contract");
            }
            if !payload.receipt_id.is_empty() {
                validate_identifier(&payload.receipt_id, 256, "llm_receipt_id")?;
            }
        }
        v1::WorkflowLlmAttemptOutcome::OutputValidationFailed
        | v1::WorkflowLlmAttemptOutcome::TimedOut
        | v1::WorkflowLlmAttemptOutcome::MalformedResult
        | v1::WorkflowLlmAttemptOutcome::Crashed => {
            validate_identifier(&payload.error_code, 128, "llm_error_code")?;
            validate_value(payload.error.as_ref())?;
            if payload.output.is_some() {
                return invalid("llm_failure_contract");
            }
            validate_identifier(&payload.receipt_id, 256, "llm_receipt_id")?;
        }
        v1::WorkflowLlmAttemptOutcome::Unspecified => return invalid("llm_outcome"),
    }
    Ok(())
}

fn validate_llm_tool_calls(
    values: &[v1::WorkflowLlmToolCall],
    elapsed_milliseconds: u64,
) -> Result<()> {
    if values.len() > MAXIMUM_LLM_TOOL_CALLS {
        return invalid("llm_tool_call_count");
    }
    let mut ids = BTreeSet::new();
    for (index, value) in values.iter().enumerate() {
        validate_identifier(&value.call_id, 128, "llm_tool_call_id")?;
        validate_identifier(&value.tool_id, 128, "llm_tool_id")?;
        validate_value(value.input.as_ref())?;
        if value.sequence != (index + 1) as u32
            || value.duration_milliseconds > elapsed_milliseconds
            || !ids.insert(value.call_id.as_str())
        {
            return invalid("llm_tool_call_contract");
        }
        match value.status.as_str() {
            "succeeded" => {
                validate_value(value.output.as_ref())?;
                if !value.error_code.is_empty() || value.error.is_some() {
                    return invalid("llm_tool_call_success");
                }
            }
            "failed" => {
                validate_identifier(&value.error_code, 128, "llm_tool_error_code")?;
                validate_value(value.error.as_ref())?;
                if value.output.is_some() {
                    return invalid("llm_tool_call_failure");
                }
            }
            _ => return invalid("llm_tool_call_status"),
        }
    }
    Ok(())
}

fn validate_llm_response_messages(
    values: &[v1::WorkflowLlmResponseMessage],
    tool_calls: &[v1::WorkflowLlmToolCall],
) -> Result<()> {
    if values.len() > MAXIMUM_LLM_RESPONSE_MESSAGES {
        return invalid("llm_response_message_count");
    }
    let call_ids = tool_calls
        .iter()
        .map(|value| value.call_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut message_ids = BTreeSet::new();
    for (index, value) in values.iter().enumerate() {
        validate_identifier(&value.message_id, 128, "llm_response_message_id")?;
        validate_text(&value.summary, 2_048, "llm_response_summary")?;
        validate_llm_safe_text(&value.summary, "llm_response_summary")?;
        validate_value(value.content.as_ref())?;
        if value.sequence != (index + 1) as u32
            || !matches!(value.role.as_str(), "assistant" | "tool")
            || !matches!(
                value.kind.as_str(),
                "message" | "analysis_summary" | "tool_call" | "tool_result" | "final"
            )
            || (!value.tool_call_id.is_empty() && !call_ids.contains(value.tool_call_id.as_str()))
            || !message_ids.insert(value.message_id.as_str())
        {
            return invalid("llm_response_message_contract");
        }
    }
    Ok(())
}

fn validate_llm_usage(value: Option<&v1::WorkflowLlmUsage>, tool_call_count: usize) -> Result<()> {
    let Some(value) = value else {
        if tool_call_count == 0 {
            return Ok(());
        }
        return invalid("llm_usage_missing");
    };
    let total_tokens = value
        .input_tokens
        .checked_add(value.output_tokens)
        .and_then(|total| total.checked_add(value.reasoning_tokens));
    let total_cost = value
        .input_cost_micros
        .checked_add(value.output_cost_micros)
        .and_then(|total| total.checked_add(value.reasoning_cost_micros))
        .and_then(|total| total.checked_add(value.tool_cost_micros));
    if value.cached_input_tokens > value.input_tokens
        || total_tokens != Some(value.total_tokens)
        || total_cost != Some(value.total_cost_micros)
        || value.tool_call_count as usize != tool_call_count
        || (!value.cost_currency.is_empty()
            && (value.cost_currency.len() != 3
                || !value
                    .cost_currency
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase())))
        || (value.total_cost_micros > 0 && value.cost_currency.is_empty())
    {
        return invalid("llm_usage_contract");
    }
    Ok(())
}

fn validate_llm_response_validation(
    value: Option<&v1::WorkflowLlmResponseValidation>,
    outcome: v1::WorkflowLlmAttemptOutcome,
) -> Result<()> {
    if outcome == v1::WorkflowLlmAttemptOutcome::Cancelled {
        if value.is_some() {
            return invalid("llm_cancelled_validation");
        }
        return Ok(());
    }
    let value = value.ok_or_else(|| invalid_error("llm_response_validation"))?;
    validate_text(&value.schema_ref, 256, "llm_validation_schema_ref")?;
    validate_digest(&value.schema_digest, "llm_validation_schema_digest")?;
    if value.diagnostics.len() > 16
        || !value
            .diagnostics
            .iter()
            .all(|item| validate_text(item, 2_048, "llm_validation_diagnostic").is_ok())
        || match outcome {
            v1::WorkflowLlmAttemptOutcome::Succeeded => value.status != "succeeded",
            v1::WorkflowLlmAttemptOutcome::OutputValidationFailed => value.status != "failed",
            _ => value.status != "not_validated",
        }
    {
        return invalid("llm_response_validation_contract");
    }
    Ok(())
}

fn validate_llm_provider_receipt(
    value: Option<&v1::WorkflowLlmProviderReceipt>,
    payload: &v1::WorkflowLlmAttemptSettled,
) -> Result<()> {
    let Some(value) = value else {
        return Ok(());
    };
    validate_identifier(&value.request_id, 256, "llm_provider_request_id")?;
    validate_identifier(&value.response_id, 256, "llm_provider_response_id")?;
    validate_identifier(&value.receipt_id, 256, "llm_provider_receipt_id")?;
    validate_digest(&value.metadata_digest, "llm_provider_metadata_digest")?;
    if !value.provider_run_reference.is_empty() {
        validate_identifier(
            &value.provider_run_reference,
            256,
            "llm_provider_run_reference",
        )?;
    }
    if value.receipt_id != payload.receipt_id
        || (!payload.provider_run_reference.is_empty()
            && value.provider_run_reference != payload.provider_run_reference)
    {
        return invalid("llm_provider_receipt_contract");
    }
    Ok(())
}

fn validate_llm_safe_text(value: &str, code: &'static str) -> Result<()> {
    let normalized = value.to_ascii_lowercase().replace(['_', '-'], "");
    if value.contains("/Users/")
        || value.contains("file://")
        || value.contains("/home/")
        || value.contains("\\Users\\")
        || [
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
    {
        return invalid(code);
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

fn validate_run_purged(payload: &v1::WorkflowRunPurged) -> Result<()> {
    validate_identifier(&payload.run_id, 128, "run_id")?;
    validate_identifier(&payload.purge_command_id, 128, "purge_command_id")?;
    validate_identifier(&payload.workflow_id, 128, "workflow_id")?;
    validate_identifier(&payload.revision_id, 128, "revision_id")?;
    validate_digest(&payload.package_digest, "package_digest")?;
    validate_digest(
        &payload.preview_evidence_digest,
        "purge_preview_evidence_digest",
    )?;
    if !payload.installation_id.is_empty() {
        validate_identifier(&payload.installation_id, 128, "installation_id")?;
    } else if payload.affected_file_handle_count > 0 {
        return invalid("purge_storage_without_installation");
    }
    validate_identifier_list(
        &payload.retained_promoted_handle_ids,
        MAXIMUM_TRACE_IDENTIFIERS,
        "retained_promoted_handle_ids",
    )?;
    let mode = v1::WorkflowRunPurgeMode::try_from(payload.mode)
        .map_err(|_| invalid_error("purge_mode"))?;
    if mode == v1::WorkflowRunPurgeMode::Unspecified
        || payload.source_first_store_position == 0
        || payload.source_last_store_position < payload.source_first_store_position
        || payload.source_event_count == 0
        || !payload.historical_revision_retained
    {
        return invalid("purge_contract");
    }
    Ok(())
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
