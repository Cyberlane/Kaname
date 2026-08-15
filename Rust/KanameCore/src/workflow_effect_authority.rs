//! Durable, provider-free admission for workflow effect proposals and grants.
//!
//! This layer can record exact local authority, but it deliberately has no
//! connector registry or dispatch interface. WFP-008B owns execution and
//! reconciliation after this contract is qualified.

use crate::{
    SCHEMA_MAJOR,
    journal::{Journal, JournalError},
    policy::approval_fingerprint,
    v1,
    workflow_projection::{WorkflowProjectionError, WorkflowRunProjection},
    workflow_runtime::{
        WORKFLOW_EFFECT_AUTHORIZED_KIND, WORKFLOW_EFFECT_AUTHORIZED_TYPE,
        WORKFLOW_EFFECT_PROPOSED_KIND, WORKFLOW_EFFECT_PROPOSED_TYPE, WorkflowRuntimeContractError,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::fmt;

#[derive(Debug)]
pub enum WorkflowEffectAuthorityError {
    Journal(JournalError),
    Projection(WorkflowProjectionError),
    Invalid(&'static str),
    NotFound,
    StaleOrMismatched,
    Expired,
    AlreadyResolved,
}

impl fmt::Display for WorkflowEffectAuthorityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Journal(error) => write!(formatter, "workflow effect journal: {error}"),
            Self::Projection(error) => write!(formatter, "workflow effect projection: {error}"),
            Self::Invalid(code) => formatter.write_str(code),
            Self::NotFound => formatter.write_str("workflow_effect_not_found"),
            Self::StaleOrMismatched => {
                formatter.write_str("workflow_effect_approval_stale_or_mismatched")
            }
            Self::Expired => formatter.write_str("workflow_effect_approval_expired"),
            Self::AlreadyResolved => formatter.write_str("workflow_effect_already_resolved"),
        }
    }
}

impl std::error::Error for WorkflowEffectAuthorityError {}

impl From<JournalError> for WorkflowEffectAuthorityError {
    fn from(value: JournalError) -> Self {
        Self::Journal(value)
    }
}

impl From<WorkflowProjectionError> for WorkflowEffectAuthorityError {
    fn from(value: WorkflowProjectionError) -> Self {
        Self::Projection(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowEffectAuthorityError>;

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowEffectAuthorityAdmission {
    pub authority: v1::WorkflowProjectedEffectAuthority,
    pub duplicate: bool,
}

pub fn propose_workflow_effect(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    proposal: v1::WorkflowEffectProposed,
    proposed_at_unix_millis: i64,
) -> Result<WorkflowEffectAuthorityAdmission> {
    projection.catch_up(journal)?;
    let intent = proposal
        .intent
        .as_ref()
        .ok_or(WorkflowEffectAuthorityError::Invalid(
            "effect_intent_missing",
        ))?;
    if let Some(existing) = projection.effect_authority(&intent.effect_id)? {
        if existing.proposal.as_ref() == Some(&proposal) {
            return Ok(WorkflowEffectAuthorityAdmission {
                authority: existing,
                duplicate: true,
            });
        }
        return Err(WorkflowEffectAuthorityError::StaleOrMismatched);
    }
    append_effect_event(
        journal,
        &intent.run_id,
        stable_effect_id(
            "effect-proposed",
            &intent.effect_id,
            &intent.idempotency_key,
        ),
        proposed_at_unix_millis,
        WORKFLOW_EFFECT_PROPOSED_KIND,
        WORKFLOW_EFFECT_PROPOSED_TYPE,
        proposal.encode_to_vec(),
        proposal
            .approval_request
            .as_ref()
            .map_or("", |approval| approval.approval_id.as_str()),
    )?;
    projection.catch_up(journal)?;
    Ok(WorkflowEffectAuthorityAdmission {
        authority: projection
            .effect_authority(&intent.effect_id)?
            .ok_or(WorkflowEffectAuthorityError::NotFound)?,
        duplicate: false,
    })
}

pub fn authorize_workflow_effect(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    effect_id: &str,
    resolution: v1::ApprovalResolution,
    authorized_at_unix_millis: i64,
) -> Result<WorkflowEffectAuthorityAdmission> {
    projection.catch_up(journal)?;
    let current = projection
        .effect_authority(effect_id)?
        .ok_or(WorkflowEffectAuthorityError::NotFound)?;
    if current.status == "authorized" {
        let authorization = current
            .authorization
            .as_ref()
            .ok_or(WorkflowEffectAuthorityError::AlreadyResolved)?;
        if authorization.resolution.as_ref() == Some(&resolution) {
            return Ok(WorkflowEffectAuthorityAdmission {
                authority: current,
                duplicate: true,
            });
        }
        return Err(WorkflowEffectAuthorityError::AlreadyResolved);
    }
    let proposal = current
        .proposal
        .as_ref()
        .ok_or(WorkflowEffectAuthorityError::StaleOrMismatched)?;
    let intent = proposal
        .intent
        .as_ref()
        .ok_or(WorkflowEffectAuthorityError::StaleOrMismatched)?;
    let preview = proposal
        .preview
        .as_ref()
        .ok_or(WorkflowEffectAuthorityError::StaleOrMismatched)?;
    let approval = proposal
        .approval_request
        .as_ref()
        .ok_or(WorkflowEffectAuthorityError::StaleOrMismatched)?;
    if approval.expires_at_unix_millis <= authorized_at_unix_millis {
        return Err(WorkflowEffectAuthorityError::Expired);
    }
    if resolution.approval_id != approval.approval_id
        || resolution.expected_fingerprint != approval.fingerprint
        || approval.fingerprint != approval_fingerprint(approval)
        || v1::ApprovalDecision::try_from(resolution.decision) != Ok(v1::ApprovalDecision::Approve)
    {
        return Err(WorkflowEffectAuthorityError::StaleOrMismatched);
    }
    let authorization = v1::WorkflowEffectAuthorized {
        run_id: intent.run_id.clone(),
        run_token_id: intent.run_token_id.clone(),
        effect_id: intent.effect_id.clone(),
        grant_id: stable_effect_id("effect-grant", &approval.approval_id, &intent.effect_id),
        resolution: Some(resolution),
        approval_fingerprint: approval.fingerprint.clone(),
        intent_digest: proposal.intent_digest.clone(),
        preview_digest: preview.preview_digest.clone(),
        destination_fingerprint: intent.destination_fingerprint.clone(),
        idempotency_key: intent.idempotency_key.clone(),
        expires_at_unix_millis: approval.expires_at_unix_millis,
    };
    append_effect_event(
        journal,
        &intent.run_id,
        stable_effect_id(
            "effect-authorized",
            &intent.effect_id,
            &approval.approval_id,
        ),
        authorized_at_unix_millis,
        WORKFLOW_EFFECT_AUTHORIZED_KIND,
        WORKFLOW_EFFECT_AUTHORIZED_TYPE,
        authorization.encode_to_vec(),
        &approval.approval_id,
    )?;
    projection.catch_up(journal)?;
    Ok(WorkflowEffectAuthorityAdmission {
        authority: projection
            .effect_authority(effect_id)?
            .ok_or(WorkflowEffectAuthorityError::NotFound)?,
        duplicate: false,
    })
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn append_effect_event(
    journal: &mut Journal,
    run_id: &str,
    event_id: String,
    occurred_at_unix_millis: i64,
    kind: &str,
    type_url: &str,
    value: Vec<u8>,
    causation_id: &str,
) -> Result<()> {
    let event = v1::EventEnvelope {
        schema_version: Some(v1::SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
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
    };
    crate::workflow_runtime::validate_workflow_event(&event).map_err(|error| match error {
        WorkflowRuntimeContractError::Invalid(code) => WorkflowEffectAuthorityError::Invalid(code),
        WorkflowRuntimeContractError::UnsupportedKind => {
            WorkflowEffectAuthorityError::Invalid("effect_event_kind_unsupported")
        }
    })?;
    journal.append_event(event)?;
    Ok(())
}

pub(crate) fn stable_effect_id(domain: &str, left: &str, right: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.effect-authority.v1\0");
    hasher.update(domain.as_bytes());
    hasher.update([0]);
    hasher.update(left.as_bytes());
    hasher.update([0]);
    hasher.update(right.as_bytes());
    format!("{domain}:{}", hex::encode(hasher.finalize()))
}
