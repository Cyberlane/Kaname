//! Mail-specific proposal construction for the shared durable effect authority.
//!
//! This module constructs the exact intent, preview, and approval records for
//! each admitted mail effect kind. It does not authorize, dispatch, reconcile,
//! or contact a provider.

use crate::{
    policy::approval_fingerprint,
    v1::{
        ApprovalRequest, Scope, WorkflowEffectIntent, WorkflowEffectPreview, WorkflowEffectProposed,
    },
    workflow_runtime::{workflow_effect_intent_digest, workflow_effect_preview_digest},
};
use sha2::{Digest, Sha256};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowMailEffectClass {
    Send,
    Draft,
    Archive,
    Label,
    Trash,
    MarkRead,
}

/// Every mail effect kind the durable authority admits, in a stable order a
/// connector registration can enumerate.
pub const WORKFLOW_MAIL_EFFECT_CLASSES: [WorkflowMailEffectClass; 6] = [
    WorkflowMailEffectClass::Send,
    WorkflowMailEffectClass::Draft,
    WorkflowMailEffectClass::Archive,
    WorkflowMailEffectClass::Label,
    WorkflowMailEffectClass::Trash,
    WorkflowMailEffectClass::MarkRead,
];

impl WorkflowMailEffectClass {
    pub const fn action(self) -> &'static str {
        match self {
            Self::Send => "send",
            Self::Draft => "draft",
            Self::Archive => "archive",
            Self::Label => "label",
            Self::Trash => "trash",
            Self::MarkRead => "mark-read",
        }
    }

    pub fn from_action(action: &str) -> Option<Self> {
        WORKFLOW_MAIL_EFFECT_CLASSES
            .into_iter()
            .find(|class| class.action() == action)
    }

    /// The egress class the approval scope pins. Only `send` can move content
    /// off the device; every other kind mutates the already synchronised
    /// mailbox, and a local draft never leaves the account at all.
    const fn egress_class(self) -> &'static str {
        match self {
            Self::Send => "external_communication",
            Self::Draft => "mailbox_draft",
            Self::Archive | Self::Label | Self::Trash | Self::MarkRead => "mailbox_mutation",
        }
    }

    /// Whether the owner can undo the effect from the same mailbox afterwards.
    /// A sent message cannot be recalled.
    const fn reversible(self) -> bool {
        !matches!(self, Self::Send)
    }

    const fn summary(self) -> &'static str {
        match self {
            Self::Send => "Send the exact approved mail draft",
            Self::Draft => "Store the exact approved mail draft in the account",
            Self::Archive => "Archive the exact approved conversation",
            Self::Label => "Apply the exact approved label to the conversation",
            Self::Trash => "Move the exact approved conversation to trash",
            Self::MarkRead => "Mark the exact approved conversation read",
        }
    }

    const fn consequence(self) -> &'static str {
        match self {
            Self::Send => "The approved message will leave the local device",
            Self::Draft => "The approved draft will appear in the account draft folder",
            Self::Archive => "The approved conversation will leave the inbox",
            Self::Label => "The approved conversation will carry the label in the account",
            Self::Trash => "The approved conversation will move to the account trash",
            Self::MarkRead => "The approved conversation will lose its unread state",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowMailEffectRequest {
    pub class: WorkflowMailEffectClass,
    pub run_id: String,
    pub run_token_id: String,
    pub attempt_id: String,
    pub execution_token_id: String,
    pub node_id: String,
    pub workflow_id: String,
    pub revision_id: String,
    pub project_id: String,
    pub workspace_id: String,
    pub account_binding_id: String,
    pub destination_fingerprint: String,
    pub input_digest: String,
    pub expires_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkflowMailEffectError {
    InvalidIdentity,
    InvalidDigest,
    InvalidExpiry,
}

impl fmt::Display for WorkflowMailEffectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidIdentity => "workflow_mail_effect_invalid_identity",
            Self::InvalidDigest => "workflow_mail_effect_invalid_digest",
            Self::InvalidExpiry => "workflow_mail_effect_invalid_expiry",
        })
    }
}

impl std::error::Error for WorkflowMailEffectError {}

pub fn mail_effect_proposal(
    request: WorkflowMailEffectRequest,
) -> Result<WorkflowEffectProposed, WorkflowMailEffectError> {
    validate_request(&request)?;
    let identity = effect_identity(&request);
    let effect_id = format!("mail-effect-{identity}");
    let intent = WorkflowEffectIntent {
        effect_id: effect_id.clone(),
        run_id: request.run_id,
        run_token_id: request.run_token_id,
        attempt_id: request.attempt_id,
        execution_token_id: request.execution_token_id,
        node_id: request.node_id,
        workflow_id: request.workflow_id,
        revision_id: request.revision_id,
        connector_class: "mail".into(),
        action: request.class.action().into(),
        account_binding_id: request.account_binding_id,
        destination_fingerprint: request.destination_fingerprint,
        input_digest: request.input_digest,
        idempotency_key: format!("mail-idempotency-{identity}"),
    };
    let intent_digest = workflow_effect_intent_digest(&intent);
    let mut preview = WorkflowEffectPreview {
        summary: request.class.summary().into(),
        consequence: request.class.consequence().into(),
        reversible: request.class.reversible(),
        destination_fingerprint: intent.destination_fingerprint.clone(),
        preview_digest: String::new(),
    };
    preview.preview_digest = workflow_effect_preview_digest(&preview);
    let mut approval_request = ApprovalRequest {
        approval_id: format!("mail-approval-{identity}"),
        action_kind: "workflow.effect".into(),
        scope: Some(Scope {
            project_id: request.project_id,
            workspace_id: request.workspace_id,
            account_id: intent.account_binding_id.clone(),
            authority_id: String::new(),
            egress_class: request.class.egress_class().into(),
            destination_digest: intent.destination_fingerprint.clone(),
        }),
        target_id: effect_id,
        target_revision: intent.revision_id.clone(),
        effect_digest: hex::decode(&intent_digest).expect("runtime digest is hexadecimal"),
        consequence: preview.consequence.clone(),
        reversible: preview.reversible,
        expires_at_unix_millis: request.expires_at_unix_millis,
        policy_reference: "policy-mail-effect-manual-v1".into(),
        fingerprint: Vec::new(),
        approval_payload_version: 1,
    };
    approval_request.fingerprint = approval_fingerprint(&approval_request);
    Ok(WorkflowEffectProposed {
        intent: Some(intent),
        intent_digest,
        preview: Some(preview),
        approval_request: Some(approval_request),
    })
}

fn validate_request(request: &WorkflowMailEffectRequest) -> Result<(), WorkflowMailEffectError> {
    for identity in [
        &request.run_id,
        &request.run_token_id,
        &request.attempt_id,
        &request.execution_token_id,
        &request.node_id,
        &request.workflow_id,
        &request.revision_id,
        &request.project_id,
        &request.account_binding_id,
    ] {
        if !valid_identity(identity) {
            return Err(WorkflowMailEffectError::InvalidIdentity);
        }
    }
    // The approval scope admits an absent workspace, so a run outside a case
    // carries the project alone.
    if !request.workspace_id.is_empty() && !valid_identity(&request.workspace_id) {
        return Err(WorkflowMailEffectError::InvalidIdentity);
    }
    if !valid_digest(&request.destination_fingerprint) || !valid_digest(&request.input_digest) {
        return Err(WorkflowMailEffectError::InvalidDigest);
    }
    if request.expires_at_unix_millis <= 0 {
        return Err(WorkflowMailEffectError::InvalidExpiry);
    }
    Ok(())
}

fn valid_identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn effect_identity(request: &WorkflowMailEffectRequest) -> String {
    let payload = [
        "kaname.workflow.mail.effect.v1",
        request.class.action(),
        &request.run_id,
        &request.account_binding_id,
        &request.destination_fingerprint,
        &request.input_digest,
    ]
    .join("\0");
    hex::encode(Sha256::digest(payload))[..32].to_owned()
}
