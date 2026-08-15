//! Durable, read-only connector observation admission.
//!
//! The started fact is persisted before the host reads a provider. If the host
//! restarts after that boundary, it may repeat only the same read-only request;
//! this contract contains no mutation, draft, send, or effect authority.

use crate::{
    SCHEMA_MAJOR,
    journal::Journal,
    v1,
    workflow_projection::{WorkflowProjectionError, WorkflowRunProjection},
    workflow_runtime::{
        self, WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_TYPE, WORKFLOW_CONNECTOR_OBSERVATION_STARTED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_TYPE, WorkflowRuntimeContractError,
        workflow_connector_observation_intent_digest,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::fmt;

const DEFAULT_OBSERVATION_TIMEOUT_MILLISECONDS: i64 = 60_000;

#[derive(Debug)]
pub enum WorkflowConnectorObservationError {
    Projection(WorkflowProjectionError),
    Invalid(&'static str),
    NotFound,
    AlreadySettled,
}

impl fmt::Display for WorkflowConnectorObservationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Projection(error) => write!(formatter, "workflow connector observation: {error}"),
            Self::Invalid(code) => formatter.write_str(code),
            Self::NotFound => formatter.write_str("workflow_connector_observation_not_found"),
            Self::AlreadySettled => {
                formatter.write_str("workflow_connector_observation_already_settled")
            }
        }
    }
}

impl std::error::Error for WorkflowConnectorObservationError {}

impl From<WorkflowProjectionError> for WorkflowConnectorObservationError {
    fn from(value: WorkflowProjectionError) -> Self {
        Self::Projection(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowConnectorObservationError>;

pub fn begin_workflow_connector_observation(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    request: v1::BeginWorkflowConnectorObservationRequest,
) -> Result<v1::BeginWorkflowConnectorObservationResponse> {
    validate_schema_request(
        request.schema_version.as_ref(),
        &request.request_id,
        request.started_at_unix_millis,
    )?;
    let intent = request
        .intent
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_intent_missing",
        ))?;
    let registration = request
        .registration
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_registration_missing",
        ))?;
    let started = v1::WorkflowConnectorObservationStarted {
        intent_digest: workflow_connector_observation_intent_digest(&intent),
        intent: Some(intent.clone()),
        registration: Some(registration),
        deadline_unix_millis: request
            .started_at_unix_millis
            .saturating_add(DEFAULT_OBSERVATION_TIMEOUT_MILLISECONDS),
    };
    validate_started(&started)?;

    projection.catch_up(journal)?;
    if let Some(existing) = projection.connector_observation(&intent.observation_id)? {
        if existing.started.as_ref() != Some(&started) {
            return Err(WorkflowConnectorObservationError::Invalid(
                "connector_observation_identity_reuse",
            ));
        }
        return Ok(v1::BeginWorkflowConnectorObservationResponse {
            schema_version: schema_version(),
            request_id: request.request_id,
            started: existing.started,
            duplicate: true,
            status: existing.status,
            store_position: existing
                .settled_store_position
                .max(existing.started_store_position),
            settlement: existing.settlement,
        });
    }

    append_observation_event(
        journal,
        &intent.run_id,
        stable_observation_id("observation-started", &intent.observation_id),
        request.started_at_unix_millis,
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_TYPE,
        started.encode_to_vec(),
        &request.request_id,
    )?;
    projection.catch_up(journal)?;
    let projected = projection
        .connector_observation(&intent.observation_id)?
        .ok_or(WorkflowConnectorObservationError::NotFound)?;
    Ok(v1::BeginWorkflowConnectorObservationResponse {
        schema_version: schema_version(),
        request_id: request.request_id,
        started: projected.started,
        duplicate: false,
        status: projected.status,
        store_position: projected.started_store_position,
        settlement: None,
    })
}

pub fn settle_workflow_connector_observation(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    request: v1::SettleWorkflowConnectorObservationRequest,
) -> Result<v1::SettleWorkflowConnectorObservationResponse> {
    validate_schema_request(
        request.schema_version.as_ref(),
        &request.request_id,
        request.settled_at_unix_millis,
    )?;
    let settlement = request
        .settlement
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_settlement_missing",
        ))?;
    projection.catch_up(journal)?;
    let existing = projection
        .connector_observation(&settlement.observation_id)?
        .ok_or(WorkflowConnectorObservationError::NotFound)?;
    if existing.status != "started" {
        if existing.settlement.as_ref() == Some(&settlement) {
            return Ok(v1::SettleWorkflowConnectorObservationResponse {
                schema_version: schema_version(),
                request_id: request.request_id,
                settlement: existing.settlement,
                duplicate: true,
                status: existing.status,
                store_position: existing.settled_store_position,
            });
        }
        return Err(WorkflowConnectorObservationError::AlreadySettled);
    }
    let started = existing
        .started
        .as_ref()
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_started_missing",
        ))?;
    validate_settlement(started, &settlement, request.settled_at_unix_millis)?;
    append_observation_event(
        journal,
        &settlement.run_id,
        stable_observation_id("observation-settled", &settlement.observation_id),
        request.settled_at_unix_millis,
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_TYPE,
        settlement.encode_to_vec(),
        &request.request_id,
    )?;
    projection.catch_up(journal)?;
    let projected = projection
        .connector_observation(&settlement.observation_id)?
        .ok_or(WorkflowConnectorObservationError::NotFound)?;
    Ok(v1::SettleWorkflowConnectorObservationResponse {
        schema_version: schema_version(),
        request_id: request.request_id,
        settlement: projected.settlement,
        duplicate: false,
        status: projected.status,
        store_position: projected.settled_store_position,
    })
}

fn validate_started(value: &v1::WorkflowConnectorObservationStarted) -> Result<()> {
    let intent = value
        .intent
        .as_ref()
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_intent_missing",
        ))?;
    let event = observation_event(
        &intent.run_id,
        "validation:connector-observation-started".into(),
        0,
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_STARTED_TYPE,
        value.encode_to_vec(),
        "validation",
    );
    workflow_runtime::validate_workflow_event(&event).map_err(contract_error)
}

fn validate_settlement(
    started: &v1::WorkflowConnectorObservationStarted,
    settlement: &v1::WorkflowConnectorObservationSettled,
    settled_at_unix_millis: i64,
) -> Result<()> {
    let intent = started
        .intent
        .as_ref()
        .ok_or(WorkflowConnectorObservationError::Invalid(
            "connector_observation_intent_missing",
        ))?;
    let registration =
        started
            .registration
            .as_ref()
            .ok_or(WorkflowConnectorObservationError::Invalid(
                "connector_observation_registration_missing",
            ))?;
    if settlement.run_id != intent.run_id
        || settlement.run_token_id != intent.run_token_id
        || settlement.observation_id != intent.observation_id
        || settlement.intent_digest != started.intent_digest
        || settlement.idempotency_key != intent.idempotency_key
        || settlement
            .output
            .as_ref()
            .is_some_and(|output| output.byte_count > registration.maximum_result_bytes)
        || settlement.receipt.as_ref().is_some_and(|receipt| {
            receipt.observed_fields != intent.requested_fields
                || receipt.result_byte_count > registration.maximum_result_bytes
        })
        || (settlement.outcome == v1::WorkflowConnectorObservationOutcome::Succeeded as i32
            && settled_at_unix_millis > started.deadline_unix_millis)
    {
        return Err(WorkflowConnectorObservationError::Invalid(
            "connector_observation_settlement_mismatch",
        ));
    }
    let event = observation_event(
        &settlement.run_id,
        "validation:connector-observation-settled".into(),
        0,
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_KIND,
        WORKFLOW_CONNECTOR_OBSERVATION_SETTLED_TYPE,
        settlement.encode_to_vec(),
        "validation",
    );
    workflow_runtime::validate_workflow_event(&event).map_err(contract_error)
}

#[allow(clippy::too_many_arguments)]
fn append_observation_event(
    journal: &mut Journal,
    run_id: &str,
    event_id: String,
    occurred_at_unix_millis: i64,
    kind: &str,
    type_url: &str,
    value: Vec<u8>,
    causation_id: &str,
) -> Result<()> {
    let event = observation_event(
        run_id,
        event_id,
        occurred_at_unix_millis,
        kind,
        type_url,
        value,
        causation_id,
    );
    workflow_runtime::validate_workflow_event(&event).map_err(contract_error)?;
    journal
        .append_event(event)
        .map_err(|_| WorkflowConnectorObservationError::Invalid("connector_observation_journal"))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn observation_event(
    run_id: &str,
    event_id: String,
    occurred_at_unix_millis: i64,
    kind: &str,
    type_url: &str,
    value: Vec<u8>,
    causation_id: &str,
) -> v1::EventEnvelope {
    v1::EventEnvelope {
        schema_version: schema_version(),
        event_id,
        store_position: 0,
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        occurred_at_unix_millis,
        kind: kind.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value,
            payload_version: 1,
        }),
        provenance: Some(v1::EventProvenance {
            source_kind: "workflow-runtime".into(),
            retention_class: v1::EvidenceRetentionClass::None as i32,
            ..Default::default()
        }),
        causation_id: causation_id.into(),
        correlation_id: run_id.into(),
    }
}

fn validate_schema_request(
    schema_version: Option<&v1::SchemaVersion>,
    request_id: &str,
    timestamp: i64,
) -> Result<()> {
    if schema_version.is_none_or(|version| version.major != SCHEMA_MAJOR)
        || request_id.is_empty()
        || request_id.len() > 128
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
        || timestamp < 0
    {
        return Err(WorkflowConnectorObservationError::Invalid(
            "connector_observation_request_contract",
        ));
    }
    Ok(())
}

fn contract_error(error: WorkflowRuntimeContractError) -> WorkflowConnectorObservationError {
    match error {
        WorkflowRuntimeContractError::Invalid(code) => {
            WorkflowConnectorObservationError::Invalid(code)
        }
        WorkflowRuntimeContractError::UnsupportedKind => {
            WorkflowConnectorObservationError::Invalid("connector_observation_event_kind")
        }
    }
}

fn schema_version() -> Option<v1::SchemaVersion> {
    Some(v1::SchemaVersion {
        major: SCHEMA_MAJOR,
        minor: 0,
    })
}

fn stable_observation_id(domain: &str, observation_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.connector-observation.v1\0");
    hasher.update(domain.as_bytes());
    hasher.update([0]);
    hasher.update(observation_id.as_bytes());
    format!("{domain}:{}", hex::encode(hasher.finalize()))
}
