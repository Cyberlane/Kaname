//! Provider-neutral reply/forward draft composition with no send authority.

use crate::{
    workflow_canonical::{WorkflowCanonicalError, canonicalize},
    workflow_storage::WorkflowStorageHandle,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fmt};

const MAXIMUM_BODY_BYTES: usize = 256 * 1024;
const MAXIMUM_DESTINATIONS: usize = 100;
const MAXIMUM_ATTACHMENTS: usize = 32;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowMailDraftKind {
    Reply,
    Forward,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkflowMailDraftError {
    InvalidIdentity,
    InvalidDestination,
    InvalidSubject,
    InvalidBody,
    InvalidAttachment,
    Canonicalization,
}

impl fmt::Display for WorkflowMailDraftError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidIdentity => "workflow_mail_draft_invalid_identity",
            Self::InvalidDestination => "workflow_mail_draft_invalid_destination",
            Self::InvalidSubject => "workflow_mail_draft_invalid_subject",
            Self::InvalidBody => "workflow_mail_draft_invalid_body",
            Self::InvalidAttachment => "workflow_mail_draft_invalid_attachment",
            Self::Canonicalization => "workflow_mail_draft_canonicalization",
        })
    }
}

impl std::error::Error for WorkflowMailDraftError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowMailDraftRequest {
    pub kind: WorkflowMailDraftKind,
    pub account_binding_id: String,
    pub conversation_fingerprint: String,
    pub source_message_fingerprint: String,
    pub from: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_utf8: String,
    pub attachments: Vec<WorkflowStorageHandle>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailDraftAttachment {
    pub handle_id: String,
    pub logical_key: String,
    pub media_type: String,
    pub byte_count: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailDraftEnvelope {
    pub schema_version: u32,
    pub draft_kind: WorkflowMailDraftKind,
    pub account_binding_id: String,
    pub conversation_fingerprint: String,
    pub source_message_fingerprint: String,
    pub from: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub body_utf8: String,
    pub attachments: Vec<WorkflowMailDraftAttachment>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailDraftPreview {
    pub draft_digest: String,
    pub destination_fingerprint: String,
    pub destinations: Vec<String>,
    pub attachment_handle_ids: Vec<String>,
    pub attachment_byte_count: u64,
    pub body_byte_count: u64,
    pub send_authority: bool,
    pub external_operation_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailComposedDraft {
    pub envelope: WorkflowMailDraftEnvelope,
    pub preview: WorkflowMailDraftPreview,
}

pub fn compose_draft(
    request: WorkflowMailDraftRequest,
) -> Result<WorkflowMailComposedDraft, WorkflowMailDraftError> {
    validate_identity(&request)?;
    let from = normalize_address(&request.from)?;
    let to = normalize_destinations(request.to)?;
    let cc = normalize_destinations(request.cc)?;
    let bcc = normalize_destinations(request.bcc)?;
    if to.is_empty() && cc.is_empty() && bcc.is_empty() {
        return Err(WorkflowMailDraftError::InvalidDestination);
    }
    if to.len() + cc.len() + bcc.len() > MAXIMUM_DESTINATIONS {
        return Err(WorkflowMailDraftError::InvalidDestination);
    }
    let subject = normalized_subject(request.kind, &request.subject)?;
    if request.body_utf8.is_empty()
        || request.body_utf8.len() > MAXIMUM_BODY_BYTES
        || request.body_utf8.chars().any(|character| character == '\0')
    {
        return Err(WorkflowMailDraftError::InvalidBody);
    }
    let attachments = normalize_attachments(request.attachments)?;
    let envelope = WorkflowMailDraftEnvelope {
        schema_version: 1,
        draft_kind: request.kind,
        account_binding_id: request.account_binding_id,
        conversation_fingerprint: request.conversation_fingerprint,
        source_message_fingerprint: request.source_message_fingerprint,
        from,
        to,
        cc,
        bcc,
        subject,
        body_utf8: request.body_utf8,
        attachments,
    };
    let encoded =
        serde_json::to_vec(&envelope).map_err(|_| WorkflowMailDraftError::Canonicalization)?;
    let canonical = canonicalize(&encoded).map_err(map_canonical_error)?;
    let mut destinations = envelope
        .to
        .iter()
        .chain(&envelope.cc)
        .chain(&envelope.bcc)
        .cloned()
        .collect::<Vec<_>>();
    destinations.sort();
    destinations.dedup();
    let destination_fingerprint = fingerprint("destinations", &destinations.join("\0"));
    let attachment_handle_ids = envelope
        .attachments
        .iter()
        .map(|attachment| attachment.handle_id.clone())
        .collect::<Vec<_>>();
    let attachment_byte_count = envelope
        .attachments
        .iter()
        .try_fold(0u64, |total, attachment| {
            total.checked_add(attachment.byte_count)
        })
        .ok_or(WorkflowMailDraftError::InvalidAttachment)?;
    Ok(WorkflowMailComposedDraft {
        preview: WorkflowMailDraftPreview {
            draft_digest: canonical.sha256,
            destination_fingerprint,
            destinations,
            attachment_handle_ids,
            attachment_byte_count,
            body_byte_count: envelope.body_utf8.len() as u64,
            send_authority: false,
            external_operation_count: 0,
        },
        envelope,
    })
}

fn validate_identity(request: &WorkflowMailDraftRequest) -> Result<(), WorkflowMailDraftError> {
    for value in [
        &request.account_binding_id,
        &request.conversation_fingerprint,
        &request.source_message_fingerprint,
    ] {
        if value.is_empty() || value.len() > 512 || value.chars().any(char::is_control) {
            return Err(WorkflowMailDraftError::InvalidIdentity);
        }
    }
    Ok(())
}

fn normalize_address(value: &str) -> Result<String, WorkflowMailDraftError> {
    let value = value.trim().to_ascii_lowercase();
    let mut parts = value.split('@');
    let local = parts.next().unwrap_or_default();
    let domain = parts.next().unwrap_or_default();
    if local.is_empty()
        || domain.is_empty()
        || parts.next().is_some()
        || value.len() > 320
        || value.chars().any(char::is_whitespace)
        || !domain.contains('.')
    {
        return Err(WorkflowMailDraftError::InvalidDestination);
    }
    Ok(value)
}

fn normalize_destinations(values: Vec<String>) -> Result<Vec<String>, WorkflowMailDraftError> {
    values
        .into_iter()
        .map(|value| normalize_address(&value))
        .collect::<Result<BTreeSet<_>, _>>()
        .map(BTreeSet::into_iter)
        .map(Iterator::collect)
}

fn normalized_subject(
    kind: WorkflowMailDraftKind,
    value: &str,
) -> Result<String, WorkflowMailDraftError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 998 || value.chars().any(char::is_control) {
        return Err(WorkflowMailDraftError::InvalidSubject);
    }
    let prefix = match kind {
        WorkflowMailDraftKind::Reply => "Re:",
        WorkflowMailDraftKind::Forward => "Fwd:",
    };
    if value
        .get(..prefix.len())
        .is_some_and(|current| current.eq_ignore_ascii_case(prefix))
    {
        Ok(value.to_owned())
    } else {
        Ok(format!("{prefix} {value}"))
    }
}

fn normalize_attachments(
    values: Vec<WorkflowStorageHandle>,
) -> Result<Vec<WorkflowMailDraftAttachment>, WorkflowMailDraftError> {
    if values.len() > MAXIMUM_ATTACHMENTS {
        return Err(WorkflowMailDraftError::InvalidAttachment);
    }
    let mut seen = BTreeSet::new();
    let mut output = Vec::with_capacity(values.len());
    for value in values {
        if !seen.insert(value.handle_id.clone())
            || value.value_kind != "object"
            || value.byte_count == 0
            || value.sha256.len() != 64
        {
            return Err(WorkflowMailDraftError::InvalidAttachment);
        }
        output.push(WorkflowMailDraftAttachment {
            handle_id: value.handle_id,
            logical_key: value.logical_key,
            media_type: value.media_type,
            byte_count: value.byte_count,
            sha256: value.sha256,
        });
    }
    output.sort_by(|left, right| left.handle_id.cmp(&right.handle_id));
    Ok(output)
}

fn fingerprint(domain: &str, value: &str) -> String {
    let payload = ["kaname.workflow.mail.draft.v1", domain, value].join("\0");
    format!("sha256:{}", hex::encode(Sha256::digest(payload)))
}

fn map_canonical_error(_: WorkflowCanonicalError) -> WorkflowMailDraftError {
    WorkflowMailDraftError::Canonicalization
}
