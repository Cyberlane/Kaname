//! Provider-neutral workflow mail envelopes.
//!
//! Provider adapters may supply synthetic or installation-private identifiers,
//! but durable workflow values retain only scoped fingerprints and explicitly
//! selected metadata. Message bodies, attachment bytes, credentials, provider
//! receipts, and remote mutation authority are outside this contract.

use crate::workflow_canonical::{WorkflowCanonicalError, WorkflowCanonicalReport, canonicalize};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
};

const MAXIMUM_FIXTURE_BYTES: usize = 512 * 1024;
const MAXIMUM_MESSAGES: usize = 1_000;
const MAXIMUM_ATTACHMENTS_PER_MESSAGE: usize = 256;
const MAXIMUM_HEADER_BYTES: usize = 64 * 1024;
const MAXIMUM_ATTACHMENT_BYTES: u64 = 1_099_511_627_776;

const ALLOWED_HEADERS: &[&str] = &[
    "cc",
    "date",
    "from",
    "in-reply-to",
    "list-id",
    "list-unsubscribe",
    "list-unsubscribe-post",
    "message-id",
    "references",
    "reply-to",
    "subject",
    "to",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkflowMailError {
    InputOutOfBounds,
    InvalidJson,
    InvalidProviderKind,
    InvalidBinding,
    InvalidConversation,
    InvalidMessage,
    DuplicateMessage,
    InvalidTimestamp,
    InvalidHeader,
    HeadersOutOfBounds,
    InvalidResource,
    InvalidAttachment,
    DuplicateAttachment,
    Canonicalization,
}

impl fmt::Display for WorkflowMailError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InputOutOfBounds => "workflow_mail_input_out_of_bounds",
            Self::InvalidJson => "workflow_mail_invalid_json",
            Self::InvalidProviderKind => "workflow_mail_invalid_provider_kind",
            Self::InvalidBinding => "workflow_mail_invalid_binding",
            Self::InvalidConversation => "workflow_mail_invalid_conversation",
            Self::InvalidMessage => "workflow_mail_invalid_message",
            Self::DuplicateMessage => "workflow_mail_duplicate_message",
            Self::InvalidTimestamp => "workflow_mail_invalid_timestamp",
            Self::InvalidHeader => "workflow_mail_invalid_header",
            Self::HeadersOutOfBounds => "workflow_mail_headers_out_of_bounds",
            Self::InvalidResource => "workflow_mail_invalid_resource",
            Self::InvalidAttachment => "workflow_mail_invalid_attachment",
            Self::DuplicateAttachment => "workflow_mail_duplicate_attachment",
            Self::Canonicalization => "workflow_mail_canonicalization_failed",
        })
    }
}

impl std::error::Error for WorkflowMailError {}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFixture {
    pub schema_version: u32,
    pub provider_kind: String,
    pub account_binding_id: String,
    pub conversation_id: String,
    pub cursor: Option<String>,
    pub messages: Vec<WorkflowMailFixtureMessage>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFixtureMessage {
    pub id: String,
    pub conversation_id: String,
    pub occurred_at_unix_millis: i64,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub resource_ids: Vec<String>,
    #[serde(default)]
    pub attachments: Vec<WorkflowMailFixtureAttachment>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFixtureAttachment {
    pub id: String,
    pub filename: String,
    pub media_type: String,
    pub byte_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailThreadEnvelope {
    pub schema_version: u32,
    pub provider_kind: String,
    pub account_binding_id: String,
    pub conversation_fingerprint: String,
    pub cursor_fingerprint: Option<String>,
    pub messages: Vec<WorkflowMailMessageEnvelope>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailMessageEnvelope {
    pub message_fingerprint: String,
    pub occurred_at_unix_millis: i64,
    pub headers: BTreeMap<String, String>,
    pub resource_ids: Vec<String>,
    pub attachments: Vec<WorkflowMailAttachmentEnvelope>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailAttachmentEnvelope {
    pub attachment_fingerprint: String,
    pub filename: String,
    pub media_type: String,
    pub byte_count: u64,
}

pub fn normalize_fixture_json(
    input: &[u8],
) -> Result<WorkflowMailThreadEnvelope, WorkflowMailError> {
    if input.is_empty() || input.len() > MAXIMUM_FIXTURE_BYTES {
        return Err(WorkflowMailError::InputOutOfBounds);
    }
    let fixture: WorkflowMailFixture =
        serde_json::from_slice(input).map_err(|_| WorkflowMailError::InvalidJson)?;
    normalize_fixture(fixture)
}

pub fn normalize_fixture(
    fixture: WorkflowMailFixture,
) -> Result<WorkflowMailThreadEnvelope, WorkflowMailError> {
    if fixture.schema_version != 1 {
        return Err(WorkflowMailError::InvalidJson);
    }
    validate_token(&fixture.provider_kind, MailTokenKind::Provider)?;
    validate_token(&fixture.account_binding_id, MailTokenKind::Binding)?;
    validate_opaque(
        &fixture.conversation_id,
        512,
        WorkflowMailError::InvalidConversation,
    )?;
    if fixture.messages.is_empty() || fixture.messages.len() > MAXIMUM_MESSAGES {
        return Err(WorkflowMailError::InvalidMessage);
    }

    let conversation_fingerprint = scoped_fingerprint(
        "conversation",
        &fixture.provider_kind,
        &fixture.account_binding_id,
        &fixture.conversation_id,
    );
    let cursor_fingerprint = fixture
        .cursor
        .as_deref()
        .filter(|value| !value.is_empty())
        .map(|cursor| {
            validate_opaque(cursor, 1_024, WorkflowMailError::InvalidConversation)?;
            Ok(scoped_fingerprint(
                "cursor",
                &fixture.provider_kind,
                &fixture.account_binding_id,
                cursor,
            ))
        })
        .transpose()
        .map_err(|_: WorkflowMailError| WorkflowMailError::InvalidConversation)?;

    let mut seen_messages = BTreeSet::new();
    let mut messages = Vec::with_capacity(fixture.messages.len());
    for message in fixture.messages {
        if message.conversation_id != fixture.conversation_id {
            return Err(WorkflowMailError::InvalidConversation);
        }
        validate_opaque(&message.id, 512, WorkflowMailError::InvalidMessage)?;
        if !seen_messages.insert(message.id.clone()) {
            return Err(WorkflowMailError::DuplicateMessage);
        }
        if message.occurred_at_unix_millis < 0 {
            return Err(WorkflowMailError::InvalidTimestamp);
        }
        let headers = normalize_headers(message.headers)?;
        let resource_ids = normalize_resources(message.resource_ids)?;
        let attachments = normalize_attachments(
            &fixture.provider_kind,
            &fixture.account_binding_id,
            &message.id,
            message.attachments,
        )?;
        messages.push(WorkflowMailMessageEnvelope {
            message_fingerprint: scoped_fingerprint(
                "message",
                &fixture.provider_kind,
                &fixture.account_binding_id,
                &message.id,
            ),
            occurred_at_unix_millis: message.occurred_at_unix_millis,
            headers,
            resource_ids,
            attachments,
        });
    }
    messages.sort_by(|left, right| {
        left.occurred_at_unix_millis
            .cmp(&right.occurred_at_unix_millis)
            .then_with(|| left.message_fingerprint.cmp(&right.message_fingerprint))
    });
    Ok(WorkflowMailThreadEnvelope {
        schema_version: 1,
        provider_kind: fixture.provider_kind,
        account_binding_id: fixture.account_binding_id,
        conversation_fingerprint,
        cursor_fingerprint,
        messages,
    })
}

pub fn canonical_envelope(
    envelope: &WorkflowMailThreadEnvelope,
) -> Result<WorkflowCanonicalReport, WorkflowMailError> {
    let encoded = serde_json::to_vec(envelope).map_err(|_| WorkflowMailError::Canonicalization)?;
    canonicalize(&encoded).map_err(|_: WorkflowCanonicalError| WorkflowMailError::Canonicalization)
}

fn normalize_headers(
    headers: BTreeMap<String, String>,
) -> Result<BTreeMap<String, String>, WorkflowMailError> {
    let mut normalized = BTreeMap::new();
    let mut byte_count = 0usize;
    for (name, value) in headers {
        let name = name.trim().to_ascii_lowercase();
        if !ALLOWED_HEADERS.contains(&name.as_str()) {
            return Err(WorkflowMailError::InvalidHeader);
        }
        let value = value.trim().to_owned();
        validate_opaque(&value, 8_192, WorkflowMailError::InvalidHeader)?;
        byte_count = byte_count
            .saturating_add(name.len())
            .saturating_add(value.len());
        if byte_count > MAXIMUM_HEADER_BYTES || normalized.insert(name, value).is_some() {
            return Err(WorkflowMailError::HeadersOutOfBounds);
        }
    }
    Ok(normalized)
}

fn normalize_resources(values: Vec<String>) -> Result<Vec<String>, WorkflowMailError> {
    let mut resources = BTreeSet::new();
    for value in values {
        validate_opaque(&value, 512, WorkflowMailError::InvalidResource)?;
        resources.insert(value);
    }
    Ok(resources.into_iter().collect())
}

fn normalize_attachments(
    provider_kind: &str,
    account_binding_id: &str,
    message_id: &str,
    values: Vec<WorkflowMailFixtureAttachment>,
) -> Result<Vec<WorkflowMailAttachmentEnvelope>, WorkflowMailError> {
    if values.len() > MAXIMUM_ATTACHMENTS_PER_MESSAGE {
        return Err(WorkflowMailError::InvalidAttachment);
    }
    let mut seen = BTreeSet::new();
    let mut output = Vec::with_capacity(values.len());
    for value in values {
        validate_opaque(&value.id, 512, WorkflowMailError::InvalidAttachment)?;
        if !seen.insert(value.id.clone()) {
            return Err(WorkflowMailError::DuplicateAttachment);
        }
        validate_opaque(&value.filename, 255, WorkflowMailError::InvalidAttachment)?;
        if value.media_type.is_empty()
            || value.media_type.len() > 255
            || !value.media_type.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'+' | b'-' | b'.')
            })
            || value.byte_count > MAXIMUM_ATTACHMENT_BYTES
        {
            return Err(WorkflowMailError::InvalidAttachment);
        }
        output.push(WorkflowMailAttachmentEnvelope {
            attachment_fingerprint: scoped_fingerprint(
                "attachment",
                provider_kind,
                account_binding_id,
                &format!("{message_id}\0{}", value.id),
            ),
            filename: value.filename,
            media_type: value.media_type,
            byte_count: value.byte_count,
        });
    }
    output.sort_by(|left, right| {
        left.attachment_fingerprint
            .cmp(&right.attachment_fingerprint)
    });
    Ok(output)
}

#[derive(Clone, Copy)]
enum MailTokenKind {
    Provider,
    Binding,
}

fn validate_token(value: &str, kind: MailTokenKind) -> Result<(), WorkflowMailError> {
    let error = match kind {
        MailTokenKind::Provider => WorkflowMailError::InvalidProviderKind,
        MailTokenKind::Binding => WorkflowMailError::InvalidBinding,
    };
    if value.is_empty() || value.len() > 128 {
        return Err(error);
    }
    for byte in value.bytes() {
        let allowed = match kind {
            MailTokenKind::Provider => {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'-')
            }
            MailTokenKind::Binding => {
                byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':')
            }
        };
        if !allowed {
            return Err(error);
        }
    }
    Ok(())
}

fn validate_opaque(
    value: &str,
    maximum: usize,
    error: WorkflowMailError,
) -> Result<(), WorkflowMailError> {
    if !(1..=maximum).contains(&value.len()) {
        return Err(error);
    }
    for character in value.chars() {
        if character.is_control() {
            return Err(error);
        }
    }
    Ok(())
}

fn scoped_fingerprint(domain: &str, provider: &str, binding: &str, value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.mail.v1\0");
    for component in [domain, provider, binding, value] {
        hasher.update(component.as_bytes());
        hasher.update([0]);
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}
