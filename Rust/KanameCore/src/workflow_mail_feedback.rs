//! Deterministic synthetic feedback-case qualification.
//!
//! The fixture state machine proves routing, result attachment capture, a reply
//! wait, a correction episode, and cumulative context without a mail provider.
//! Durable wait/case execution itself is covered by the workflow executor.

use crate::workflow_canonical::{WorkflowCanonicalError, canonicalize};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeSet, fmt};

const MAXIMUM_FIXTURE_BYTES: usize = 256 * 1024;
const MAXIMUM_EVENTS: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkflowMailFeedbackError {
    InputBounds,
    InvalidJson,
    InvalidIdentity,
    InvalidSequence,
    CorrelationMismatch,
    DuplicateEvent,
    MissingAttachment,
    Canonicalization,
}

impl fmt::Display for WorkflowMailFeedbackError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InputBounds => "workflow_mail_feedback_input_bounds",
            Self::InvalidJson => "workflow_mail_feedback_invalid_json",
            Self::InvalidIdentity => "workflow_mail_feedback_invalid_identity",
            Self::InvalidSequence => "workflow_mail_feedback_invalid_sequence",
            Self::CorrelationMismatch => "workflow_mail_feedback_correlation_mismatch",
            Self::DuplicateEvent => "workflow_mail_feedback_duplicate_event",
            Self::MissingAttachment => "workflow_mail_feedback_missing_attachment",
            Self::Canonicalization => "workflow_mail_feedback_canonicalization",
        })
    }
}

impl std::error::Error for WorkflowMailFeedbackError {}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFeedbackFixture {
    pub schema_version: u32,
    pub case_id: String,
    pub expected_sender_fingerprint: String,
    pub events: Vec<WorkflowMailFeedbackEvent>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum WorkflowMailFeedbackEvent {
    Request {
        event_id: String,
        message_fingerprint: String,
        sender_fingerprint: String,
        request: String,
    },
    Result {
        event_id: String,
        in_reply_to_message_fingerprint: String,
        attachment: WorkflowMailFeedbackAttachment,
    },
    Reply {
        event_id: String,
        message_fingerprint: String,
        sender_fingerprint: String,
        in_reply_to_message_fingerprint: String,
        correction: String,
    },
    CorrectionResult {
        event_id: String,
        in_reply_to_message_fingerprint: String,
        attachment: WorkflowMailFeedbackAttachment,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFeedbackAttachment {
    pub handle_id: String,
    pub filename: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFeedbackEpisode {
    pub episode_id: String,
    pub intent: String,
    pub source_message_fingerprint: String,
    pub prior_episode_ids: Vec<String>,
    pub request: String,
    pub result_attachment: WorkflowMailFeedbackAttachment,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailFeedbackReceipt {
    pub schema_version: u32,
    pub case_id: String,
    pub route: String,
    pub wait_count: u64,
    pub episodes: Vec<WorkflowMailFeedbackEpisode>,
    pub cumulative_context_digest: String,
    pub external_operation_count: u64,
}

pub fn qualify_synthetic_feedback_json(
    input: &[u8],
) -> Result<WorkflowMailFeedbackReceipt, WorkflowMailFeedbackError> {
    if !(1..=MAXIMUM_FIXTURE_BYTES).contains(&input.len()) {
        return Err(WorkflowMailFeedbackError::InputBounds);
    }
    let mut decoder = serde_json::Deserializer::from_slice(input);
    let fixture = WorkflowMailFeedbackFixture::deserialize(&mut decoder)
        .map_err(|_| WorkflowMailFeedbackError::InvalidJson)?;
    decoder
        .end()
        .map_err(|_| WorkflowMailFeedbackError::InvalidJson)?;
    qualify_synthetic_feedback(fixture)
}

pub fn qualify_synthetic_feedback(
    fixture: WorkflowMailFeedbackFixture,
) -> Result<WorkflowMailFeedbackReceipt, WorkflowMailFeedbackError> {
    if fixture.schema_version != 1
        || !valid_identifier(&fixture.case_id)
        || !valid_fingerprint(&fixture.expected_sender_fingerprint)
        || fixture.events.len() != 4
        || fixture.events.len() > MAXIMUM_EVENTS
    {
        return Err(WorkflowMailFeedbackError::InvalidIdentity);
    }
    let mut event_ids = BTreeSet::new();
    for event in &fixture.events {
        let event_id = match event {
            WorkflowMailFeedbackEvent::Request { event_id, .. }
            | WorkflowMailFeedbackEvent::Result { event_id, .. }
            | WorkflowMailFeedbackEvent::Reply { event_id, .. }
            | WorkflowMailFeedbackEvent::CorrectionResult { event_id, .. } => event_id,
        };
        if !valid_identifier(event_id) || !event_ids.insert(event_id) {
            return Err(WorkflowMailFeedbackError::DuplicateEvent);
        }
    }

    let (initial_message, initial_request) = match &fixture.events[0] {
        WorkflowMailFeedbackEvent::Request {
            message_fingerprint,
            sender_fingerprint,
            request,
            ..
        } if sender_fingerprint == &fixture.expected_sender_fingerprint
            && valid_fingerprint(message_fingerprint)
            && valid_text(request) =>
        {
            (message_fingerprint.clone(), request.clone())
        }
        WorkflowMailFeedbackEvent::Request { .. } => {
            return Err(WorkflowMailFeedbackError::CorrelationMismatch);
        }
        _ => return Err(WorkflowMailFeedbackError::InvalidSequence),
    };
    let initial_attachment = match &fixture.events[1] {
        WorkflowMailFeedbackEvent::Result {
            in_reply_to_message_fingerprint,
            attachment,
            ..
        } if in_reply_to_message_fingerprint == &initial_message => {
            validate_attachment(attachment)?;
            attachment.clone()
        }
        WorkflowMailFeedbackEvent::Result { .. } => {
            return Err(WorkflowMailFeedbackError::CorrelationMismatch);
        }
        _ => return Err(WorkflowMailFeedbackError::InvalidSequence),
    };
    let (correction_message, correction) = match &fixture.events[2] {
        WorkflowMailFeedbackEvent::Reply {
            message_fingerprint,
            sender_fingerprint,
            in_reply_to_message_fingerprint,
            correction,
            ..
        } if sender_fingerprint == &fixture.expected_sender_fingerprint
            && in_reply_to_message_fingerprint == &initial_message
            && valid_fingerprint(message_fingerprint)
            && valid_text(correction) =>
        {
            (message_fingerprint.clone(), correction.clone())
        }
        WorkflowMailFeedbackEvent::Reply { .. } => {
            return Err(WorkflowMailFeedbackError::CorrelationMismatch);
        }
        _ => return Err(WorkflowMailFeedbackError::InvalidSequence),
    };
    let correction_attachment = match &fixture.events[3] {
        WorkflowMailFeedbackEvent::CorrectionResult {
            in_reply_to_message_fingerprint,
            attachment,
            ..
        } if in_reply_to_message_fingerprint == &correction_message => {
            validate_attachment(attachment)?;
            attachment.clone()
        }
        WorkflowMailFeedbackEvent::CorrectionResult { .. } => {
            return Err(WorkflowMailFeedbackError::CorrelationMismatch);
        }
        _ => return Err(WorkflowMailFeedbackError::InvalidSequence),
    };

    let initial_episode_id = format!("{}-initial", fixture.case_id);
    let episodes = vec![
        WorkflowMailFeedbackEpisode {
            episode_id: initial_episode_id.clone(),
            intent: "initial".into(),
            source_message_fingerprint: initial_message,
            prior_episode_ids: Vec::new(),
            request: initial_request,
            result_attachment: initial_attachment,
        },
        WorkflowMailFeedbackEpisode {
            episode_id: format!("{}-correction-1", fixture.case_id),
            intent: "correction".into(),
            source_message_fingerprint: correction_message,
            prior_episode_ids: vec![initial_episode_id],
            request: correction,
            result_attachment: correction_attachment,
        },
    ];
    let encoded =
        serde_json::to_vec(&episodes).map_err(|_| WorkflowMailFeedbackError::Canonicalization)?;
    let context = canonicalize(&encoded).map_err(map_canonical_error)?;
    Ok(WorkflowMailFeedbackReceipt {
        schema_version: 1,
        case_id: fixture.case_id,
        route: "simplykay_feedback".into(),
        wait_count: 2,
        episodes,
        cumulative_context_digest: format!("sha256:{}", context.sha256),
        external_operation_count: 0,
    })
}

fn validate_attachment(
    attachment: &WorkflowMailFeedbackAttachment,
) -> Result<(), WorkflowMailFeedbackError> {
    if !valid_identifier(&attachment.handle_id)
        || attachment.filename.is_empty()
        || attachment.filename.len() > 255
        || attachment.filename.chars().any(char::is_control)
        || !valid_digest(&attachment.sha256)
    {
        return Err(WorkflowMailFeedbackError::MissingAttachment);
    }
    Ok(())
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_fingerprint(value: &str) -> bool {
    value.starts_with("sha256:") && value.len() > "sha256:".len()
}

fn valid_digest(value: &str) -> bool {
    let value = value.strip_prefix("sha256:").unwrap_or(value);
    if value.len() != 64 {
        return false;
    }
    for byte in value.bytes() {
        match byte {
            b'0'..=b'9' | b'a'..=b'f' => {}
            _ => return false,
        }
    }
    true
}

fn valid_text(value: &str) -> bool {
    !value.is_empty() && value.len() <= 8_192 && !value.chars().any(char::is_control)
}

fn map_canonical_error(_: WorkflowCanonicalError) -> WorkflowMailFeedbackError {
    WorkflowMailFeedbackError::Canonicalization
}
