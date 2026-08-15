//! Deterministic, no-effect mailbox review over provider-neutral observations.
//!
//! This layer freezes already observed pages. It validates cursor continuity,
//! deduplicates exact messages, correlates them to conversations, records a
//! bounded retention decision, and compares classifications with a supplied
//! shadow baseline. It cannot open a mailbox or dispatch an effect.

use crate::{
    workflow_canonical::{WorkflowCanonicalError, canonicalize},
    workflow_mail::{WorkflowMailMessageEnvelope, WorkflowMailThreadEnvelope},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fmt};

const MAXIMUM_PAGES: usize = 100;
const MAXIMUM_THREADS: usize = 10_000;
const MAXIMUM_MESSAGES: usize = 50_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkflowMailReviewError {
    Empty,
    Bounds,
    PageSequence,
    CursorContinuity,
    CursorRepeated,
    AccountDrift,
    ProviderDrift,
    MessageCollision,
    Retention,
    Canonicalization,
}

impl fmt::Display for WorkflowMailReviewError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Empty => "workflow_mail_review_empty",
            Self::Bounds => "workflow_mail_review_bounds",
            Self::PageSequence => "workflow_mail_review_page_sequence",
            Self::CursorContinuity => "workflow_mail_review_cursor_continuity",
            Self::CursorRepeated => "workflow_mail_review_cursor_repeated",
            Self::AccountDrift => "workflow_mail_review_account_drift",
            Self::ProviderDrift => "workflow_mail_review_provider_drift",
            Self::MessageCollision => "workflow_mail_review_message_collision",
            Self::Retention => "workflow_mail_review_retention",
            Self::Canonicalization => "workflow_mail_review_canonicalization",
        })
    }
}

impl std::error::Error for WorkflowMailReviewError {}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailObservationPage {
    pub page_number: u32,
    pub request_cursor_fingerprint: Option<String>,
    pub next_cursor_fingerprint: Option<String>,
    pub threads: Vec<WorkflowMailThreadEnvelope>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowMailReviewRoute {
    Protected,
    Financial,
    Newsletter,
    Review,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailReviewItem {
    pub conversation_fingerprint: String,
    pub message_fingerprint: String,
    pub occurred_at_unix_millis: i64,
    pub route: WorkflowMailReviewRoute,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailShadowMismatch {
    pub message_fingerprint: String,
    pub expected: WorkflowMailReviewRoute,
    pub actual: WorkflowMailReviewRoute,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailReviewReceipt {
    pub schema_version: u32,
    pub provider_kind: String,
    pub account_binding_id: String,
    pub page_count: u64,
    pub thread_count: u64,
    pub unique_message_count: u64,
    pub duplicate_message_count: u64,
    pub proposed_effect_count: u64,
    pub observed_at_unix_millis: i64,
    pub purge_eligible_at_unix_millis: i64,
    pub items: Vec<WorkflowMailReviewItem>,
    pub shadow_mismatches: Vec<WorkflowMailShadowMismatch>,
    pub frozen_digest: String,
}

pub fn freeze_read_only_review(
    pages: Vec<WorkflowMailObservationPage>,
    shadow: &BTreeMap<String, WorkflowMailReviewRoute>,
    observed_at_unix_millis: i64,
    purge_eligible_at_unix_millis: i64,
) -> Result<WorkflowMailReviewReceipt, WorkflowMailReviewError> {
    if pages.is_empty() {
        return Err(WorkflowMailReviewError::Empty);
    }
    if pages.len() > MAXIMUM_PAGES {
        return Err(WorkflowMailReviewError::Bounds);
    }
    if observed_at_unix_millis < 0 || purge_eligible_at_unix_millis < observed_at_unix_millis {
        return Err(WorkflowMailReviewError::Retention);
    }

    let mut expected_cursor = None;
    let mut seen_cursors = BTreeMap::new();
    let mut provider_kind = None;
    let mut account_binding_id = None;
    let mut thread_count = 0usize;
    let mut duplicate_message_count = 0u64;
    let mut messages = BTreeMap::<String, (String, WorkflowMailMessageEnvelope)>::new();

    for (index, page) in pages.iter().enumerate() {
        if page.page_number as usize != index + 1 {
            return Err(WorkflowMailReviewError::PageSequence);
        }
        if page.request_cursor_fingerprint != expected_cursor {
            return Err(WorkflowMailReviewError::CursorContinuity);
        }
        if let Some(cursor) = &page.next_cursor_fingerprint
            && seen_cursors
                .insert(cursor.clone(), page.page_number)
                .is_some()
        {
            return Err(WorkflowMailReviewError::CursorRepeated);
        }
        expected_cursor = page.next_cursor_fingerprint.clone();
        thread_count = thread_count
            .checked_add(page.threads.len())
            .ok_or(WorkflowMailReviewError::Bounds)?;
        if thread_count > MAXIMUM_THREADS {
            return Err(WorkflowMailReviewError::Bounds);
        }
        for thread in &page.threads {
            match &provider_kind {
                None => provider_kind = Some(thread.provider_kind.clone()),
                Some(value) if value == &thread.provider_kind => {}
                Some(_) => return Err(WorkflowMailReviewError::ProviderDrift),
            }
            match &account_binding_id {
                None => account_binding_id = Some(thread.account_binding_id.clone()),
                Some(value) if value == &thread.account_binding_id => {}
                Some(_) => return Err(WorkflowMailReviewError::AccountDrift),
            }
            for message in &thread.messages {
                if messages.len() >= MAXIMUM_MESSAGES
                    && !messages.contains_key(&message.message_fingerprint)
                {
                    return Err(WorkflowMailReviewError::Bounds);
                }
                match messages.get(&message.message_fingerprint) {
                    Some((conversation, existing))
                        if conversation == &thread.conversation_fingerprint
                            && existing == message =>
                    {
                        duplicate_message_count += 1;
                    }
                    Some(_) => return Err(WorkflowMailReviewError::MessageCollision),
                    None => {
                        messages.insert(
                            message.message_fingerprint.clone(),
                            (thread.conversation_fingerprint.clone(), message.clone()),
                        );
                    }
                }
            }
        }
    }

    let mut items = messages
        .into_iter()
        .map(
            |(message_fingerprint, (conversation_fingerprint, message))| WorkflowMailReviewItem {
                conversation_fingerprint,
                message_fingerprint,
                occurred_at_unix_millis: message.occurred_at_unix_millis,
                route: classify(&message),
            },
        )
        .collect::<Vec<_>>();
    items.sort_by(|left, right| {
        left.occurred_at_unix_millis
            .cmp(&right.occurred_at_unix_millis)
            .then_with(|| left.message_fingerprint.cmp(&right.message_fingerprint))
    });
    let shadow_mismatches = items
        .iter()
        .filter_map(|item| {
            shadow
                .get(&item.message_fingerprint)
                .filter(|expected| **expected != item.route)
                .map(|expected| WorkflowMailShadowMismatch {
                    message_fingerprint: item.message_fingerprint.clone(),
                    expected: *expected,
                    actual: item.route,
                })
        })
        .collect::<Vec<_>>();
    let digest_input = serde_json::to_vec(&(
        &provider_kind,
        &account_binding_id,
        &items,
        &shadow_mismatches,
        observed_at_unix_millis,
        purge_eligible_at_unix_millis,
    ))
    .map_err(|_| WorkflowMailReviewError::Canonicalization)?;
    let canonical = canonicalize(&digest_input).map_err(map_canonical_error)?;
    Ok(WorkflowMailReviewReceipt {
        schema_version: 1,
        provider_kind: provider_kind.ok_or(WorkflowMailReviewError::Empty)?,
        account_binding_id: account_binding_id.ok_or(WorkflowMailReviewError::Empty)?,
        page_count: pages.len() as u64,
        thread_count: thread_count as u64,
        unique_message_count: items.len() as u64,
        duplicate_message_count,
        proposed_effect_count: 0,
        observed_at_unix_millis,
        purge_eligible_at_unix_millis,
        items,
        shadow_mismatches,
        frozen_digest: canonical.sha256,
    })
}

fn classify(message: &WorkflowMailMessageEnvelope) -> WorkflowMailReviewRoute {
    if message.resource_ids.iter().any(|value| value == "UNREAD") {
        return WorkflowMailReviewRoute::Protected;
    }
    let subject = message
        .headers
        .get("subject")
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default();
    if ["invoice", "receipt", "payment", "statement", "tax"]
        .iter()
        .any(|signal| subject.contains(signal))
    {
        return WorkflowMailReviewRoute::Financial;
    }
    if message.headers.contains_key("list-unsubscribe") || message.headers.contains_key("list-id") {
        return WorkflowMailReviewRoute::Newsletter;
    }
    WorkflowMailReviewRoute::Review
}

fn map_canonical_error(_: WorkflowCanonicalError) -> WorkflowMailReviewError {
    WorkflowMailReviewError::Canonicalization
}

pub fn observation_plan_digest(
    account_binding_id: &str,
    query_fingerprint: &str,
    maximum_pages: u32,
    maximum_messages: u32,
) -> Option<String> {
    if account_binding_id.is_empty()
        || query_fingerprint.is_empty()
        || maximum_pages == 0
        || maximum_pages as usize > MAXIMUM_PAGES
        || maximum_messages == 0
        || maximum_messages as usize > MAXIMUM_MESSAGES
    {
        return None;
    }
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.mail.observation-plan.v1\0");
    for component in [account_binding_id, query_fingerprint] {
        hasher.update(component.as_bytes());
        hasher.update([0]);
    }
    hasher.update(maximum_pages.to_be_bytes());
    hasher.update(maximum_messages.to_be_bytes());
    Some(format!("sha256:{}", hex::encode(hasher.finalize())))
}
