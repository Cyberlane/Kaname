//! Provider-free command, queue, approval, and attention policy.
//!
//! This is deliberately below every client surface. It accepts deterministic
//! timestamps and fake effect ledgers only; Phase 1 cannot open a provider,
//! repository, account, notification, or network connection.

use crate::{
    SCHEMA_MAJOR,
    journal::{Journal, JournalError, Result},
    v1,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueItemState {
    pub item_id: String,
    pub stream_id: String,
    pub revision: u64,
    pub body: String,
    pub disposition: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalState {
    pub approval_id: String,
    pub request: v1::ApprovalRequest,
    pub fingerprint: Vec<u8>,
    pub status: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FakeEffectLedger {
    pub provider_dispatches: u64,
    pub external_action_attempts: u64,
    pub notification_receipts: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalResolutionResult {
    Approved,
    Rejected,
    Stale,
    Expired,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueueMutationResult {
    Applied(QueueItemState),
    Conflict(QueueItemState),
    Missing,
}

pub struct LocalPolicyCore {
    journal: Journal,
    approvals: BTreeMap<String, ApprovalState>,
    queues: BTreeMap<String, QueueItemState>,
    notification_receipts: BTreeSet<(String, String)>,
    command_queue_items: BTreeMap<String, String>,
    ledger: FakeEffectLedger,
}

impl LocalPolicyCore {
    pub fn new(journal: Journal) -> Self {
        Self {
            journal,
            approvals: BTreeMap::new(),
            queues: BTreeMap::new(),
            notification_receipts: BTreeSet::new(),
            command_queue_items: BTreeMap::new(),
            ledger: FakeEffectLedger::default(),
        }
    }

    pub fn journal(&self) -> &Journal {
        &self.journal
    }

    pub fn journal_mut(&mut self) -> &mut Journal {
        &mut self.journal
    }

    pub fn effect_ledger(&self) -> &FakeEffectLedger {
        &self.ledger
    }

    pub fn approval(&self, approval_id: &str) -> Option<&ApprovalState> {
        self.approvals.get(approval_id)
    }

    pub fn queue_item(&self, item_id: &str) -> Option<&QueueItemState> {
        self.queues.get(item_id)
    }

    pub fn enqueue(
        &mut self,
        command: &v1::CommandEnvelope,
        item_id: &str,
        stream_id: &str,
        body: &str,
    ) -> Result<QueueItemState> {
        if item_id.is_empty() || body.is_empty() || stream_id.is_empty() {
            return Err(JournalError::Protocol("invalid_queue_item"));
        }
        self.journal.admit_command(command)?;
        if let Some(existing_item_id) = self.command_queue_items.get(&command.command_id) {
            return self
                .queues
                .get(existing_item_id)
                .cloned()
                .ok_or_else(|| JournalError::Integrity("missing_idempotent_queue_item".into()));
        }
        let item = QueueItemState {
            item_id: item_id.to_owned(),
            stream_id: stream_id.to_owned(),
            revision: 1,
            body: body.to_owned(),
            disposition: "policy_accepted".into(),
        };
        self.append_audit_event(stream_id, "queue.enqueued", item_id, "queue.enqueued.v1")?;
        self.command_queue_items
            .insert(command.command_id.clone(), item_id.to_owned());
        self.queues.insert(item_id.to_owned(), item.clone());
        Ok(item)
    }

    pub fn edit_queue(
        &mut self,
        item_id: &str,
        expected_revision: u64,
        body: &str,
        actor_id: &str,
    ) -> Result<QueueMutationResult> {
        let Some(existing) = self.queues.get(item_id).cloned() else {
            return Ok(QueueMutationResult::Missing);
        };
        if expected_revision != existing.revision {
            self.append_audit_event(
                &existing.stream_id,
                "queue.revision_conflict",
                item_id,
                "queue.conflict.v1",
            )?;
            return Ok(QueueMutationResult::Conflict(existing));
        }
        if body.is_empty() || actor_id.is_empty() {
            return Err(JournalError::Protocol("invalid_queue_edit"));
        }
        let mut changed = existing;
        changed.revision += 1;
        changed.body = body.to_owned();
        self.append_audit_event(
            &changed.stream_id,
            "queue.edited",
            item_id,
            "queue.edited.v1",
        )?;
        self.queues.insert(item_id.to_owned(), changed.clone());
        Ok(QueueMutationResult::Applied(changed))
    }

    pub fn remove_queue(
        &mut self,
        item_id: &str,
        expected_revision: u64,
    ) -> Result<QueueMutationResult> {
        let Some(existing) = self.queues.get(item_id).cloned() else {
            return Ok(QueueMutationResult::Missing);
        };
        if expected_revision != existing.revision {
            self.append_audit_event(
                &existing.stream_id,
                "queue.revision_conflict",
                item_id,
                "queue.conflict.v1",
            )?;
            return Ok(QueueMutationResult::Conflict(existing));
        }
        let mut removed = existing;
        removed.revision += 1;
        removed.disposition = "removed_before_dispatch".into();
        self.append_audit_event(
            &removed.stream_id,
            "queue.removed",
            item_id,
            "queue.removed.v1",
        )?;
        self.queues.insert(item_id.to_owned(), removed.clone());
        Ok(QueueMutationResult::Applied(removed))
    }

    pub fn request_approval(
        &mut self,
        request: v1::ApprovalRequest,
        stream_id: &str,
    ) -> Result<ApprovalState> {
        validate_approval_request(&request)?;
        let fingerprint = approval_fingerprint(&request);
        let approval = ApprovalState {
            approval_id: request.approval_id.clone(),
            request,
            fingerprint,
            status: "pending".into(),
        };
        self.append_audit_event(
            stream_id,
            "approval.requested",
            &approval.approval_id,
            "approval.requested.v1",
        )?;
        self.approvals
            .insert(approval.approval_id.clone(), approval.clone());
        Ok(approval)
    }

    pub fn resolve_approval(
        &mut self,
        resolution: &v1::ApprovalResolution,
        now_unix_millis: i64,
        current_target_revision: &str,
        stream_id: &str,
    ) -> Result<ApprovalResolutionResult> {
        let Some(approval) = self.approvals.get(&resolution.approval_id).cloned() else {
            return Err(JournalError::Protocol("approval_not_found"));
        };
        if approval.status != "pending" {
            return Err(JournalError::Protocol("approval_not_pending"));
        }
        if approval.request.expires_at_unix_millis <= now_unix_millis {
            self.set_approval_status(&approval, "expired", stream_id, "approval.expired")?;
            return Ok(ApprovalResolutionResult::Expired);
        }
        if approval.request.target_revision != current_target_revision
            || resolution.expected_fingerprint != approval.fingerprint
            || approval.fingerprint != approval_fingerprint(&approval.request)
        {
            self.set_approval_status(&approval, "stale", stream_id, "approval.stale")?;
            return Ok(ApprovalResolutionResult::Stale);
        }
        match v1::ApprovalDecision::try_from(resolution.decision)
            .unwrap_or(v1::ApprovalDecision::Unspecified)
        {
            v1::ApprovalDecision::Approve => {
                self.set_approval_status(&approval, "approved", stream_id, "approval.approved")?;
                Ok(ApprovalResolutionResult::Approved)
            }
            v1::ApprovalDecision::Reject => {
                self.set_approval_status(&approval, "rejected", stream_id, "approval.rejected")?;
                Ok(ApprovalResolutionResult::Rejected)
            }
            _ => Err(JournalError::Protocol("invalid_approval_decision")),
        }
    }

    /// Phase 1 scope/egress gate. The fake provider only receives synthetic,
    /// in-scope work. Any account, external communication, filesystem, or
    /// network declaration is rejected before the adapter can observe it.
    pub fn authorize_fake_provider(&mut self, scope: &v1::Scope, stream_id: &str) -> Result<()> {
        let denied = !scope.account_id.is_empty()
            || !scope.destination_digest.is_empty()
            || matches!(
                scope.egress_class.as_str(),
                "filesystem" | "network" | "external_communication"
            );
        if denied {
            self.append_audit_event(stream_id, "policy.denied", "scope", "policy.denied.v1")?;
            return Err(JournalError::Protocol("scope_or_egress_denied"));
        }
        Ok(())
    }

    pub fn record_fake_provider_dispatch(
        &mut self,
        stream_id: &str,
        dispatch_id: &str,
    ) -> Result<()> {
        self.append_audit_event(stream_id, "run.starting", dispatch_id, "run.dispatch.v1")?;
        self.ledger.provider_dispatches += 1;
        Ok(())
    }

    pub fn record_notification_receipt(
        &mut self,
        attention_id: &str,
        delivery_id: &str,
        stream_id: &str,
    ) -> Result<()> {
        if self
            .notification_receipts
            .insert((attention_id.to_owned(), delivery_id.to_owned()))
        {
            self.ledger.notification_receipts += 1;
        }
        self.append_audit_event(
            stream_id,
            "notification.receipt_recorded",
            attention_id,
            "notification.receipt.v1",
        )
    }

    fn set_approval_status(
        &mut self,
        approval: &ApprovalState,
        status: &str,
        stream_id: &str,
        event_kind: &str,
    ) -> Result<()> {
        let mut changed = approval.clone();
        changed.status = status.into();
        self.append_audit_event(
            stream_id,
            event_kind,
            &approval.approval_id,
            "approval.resolution.v1",
        )?;
        self.approvals.insert(changed.approval_id.clone(), changed);
        Ok(())
    }

    fn append_audit_event(
        &mut self,
        stream_id: &str,
        kind: &str,
        causation_id: &str,
        type_url: &str,
    ) -> Result<()> {
        let next = self
            .journal
            .replay(&format!("thread:{stream_id}"), None, 1)?
            .high_water_mark
            + 1;
        let event = v1::EventEnvelope {
            schema_version: Some(v1::SchemaVersion {
                major: SCHEMA_MAJOR,
                minor: 0,
            }),
            event_id: format!("audit:{stream_id}:{next}:{kind}"),
            store_position: 0,
            stream_id: stream_id.to_owned(),
            stream_sequence: 0,
            occurred_at_unix_millis: 1_762_000_000_000 + next as i64,
            kind: kind.into(),
            payload: Some(v1::OpaqueTypedPayload {
                type_url: type_url.into(),
                content_type: "application/x-protobuf".into(),
                value: causation_id.as_bytes().to_vec(),
                payload_version: 1,
            }),
            provenance: Some(v1::EventProvenance {
                source_kind: "control_plane".into(),
                provider_instance_id: String::new(),
                native_type: String::new(),
                native_cursor: Vec::new(),
                raw_evidence_digest: String::new(),
                retention_class: v1::EvidenceRetentionClass::None as i32,
            }),
            causation_id: causation_id.into(),
            correlation_id: String::new(),
        };
        self.journal.append_event(event)?;
        Ok(())
    }
}

pub fn approval_fingerprint(request: &v1::ApprovalRequest) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.approval.fingerprint.v1\0");
    hasher.update(request.approval_payload_version.to_be_bytes());
    hasher.update(request.action_kind.as_bytes());
    hasher.update(scope_fingerprint_bytes(request.scope.as_ref()));
    hasher.update(request.target_id.as_bytes());
    hasher.update(request.target_revision.as_bytes());
    hasher.update(&request.effect_digest);
    hasher.update(request.consequence.as_bytes());
    hasher.update([u8::from(request.reversible)]);
    hasher.update(request.expires_at_unix_millis.to_be_bytes());
    hasher.update(request.policy_reference.as_bytes());
    hasher.finalize().to_vec()
}

fn scope_fingerprint_bytes(scope: Option<&v1::Scope>) -> Vec<u8> {
    let Some(scope) = scope else {
        return Vec::new();
    };
    [
        scope.project_id.as_bytes(),
        scope.workspace_id.as_bytes(),
        scope.account_id.as_bytes(),
        scope.authority_id.as_bytes(),
        scope.egress_class.as_bytes(),
        scope.destination_digest.as_bytes(),
    ]
    .into_iter()
    .flat_map(|value| value.iter().copied().chain([0]))
    .collect()
}

fn validate_approval_request(request: &v1::ApprovalRequest) -> Result<()> {
    if request.approval_id.is_empty()
        || request.action_kind.is_empty()
        || request.target_id.is_empty()
        || request.target_revision.is_empty()
        || request.expires_at_unix_millis <= 0
    {
        return Err(JournalError::Protocol("invalid_approval_request"));
    }
    Ok(())
}
