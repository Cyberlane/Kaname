//! Restart-safe workflow-run deletion orchestration.
//!
//! The durable purge tombstone is committed before projection, scoped storage,
//! object, or journal payload cleanup. Every later phase is idempotent, so an
//! interrupted purge can resume without retaining deleted payloads in its
//! receipt or resurrecting them during projection rebuild.

use crate::{
    SCHEMA_MAJOR,
    journal::{Journal, JournalError},
    v1,
    workflow_object_store::WorkflowObjectGarbageCollectionReceipt,
    workflow_projection::{WorkflowProjectionError, WorkflowRunProjection},
    workflow_runtime::{WORKFLOW_RUN_PURGED_KIND, WORKFLOW_RUN_PURGED_TYPE},
    workflow_storage::{
        WorkflowScopedStorage, WorkflowStorageAccessContext, WorkflowStorageDeleteJobReceipt,
        WorkflowStorageDeleteJobRequest, WorkflowStorageError, WorkflowStorageNamespace,
        WorkflowStorageScopeKind,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fmt};

#[derive(Debug)]
pub enum WorkflowPurgeError {
    Journal(JournalError),
    Projection(WorkflowProjectionError),
    Storage(WorkflowStorageError),
    NotFound,
    Protected(String),
    StalePreview,
    IdentityMismatch,
    InjectedInterruption(&'static str),
}

impl fmt::Display for WorkflowPurgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Journal(error) => write!(formatter, "workflow purge journal: {error}"),
            Self::Projection(error) => write!(formatter, "workflow purge projection: {error}"),
            Self::Storage(error) => write!(formatter, "workflow purge storage: {error}"),
            Self::NotFound => formatter.write_str("workflow_run_not_found"),
            Self::Protected(reason) => write!(formatter, "workflow_run_protected: {reason}"),
            Self::StalePreview => formatter.write_str("workflow_purge_preview_stale"),
            Self::IdentityMismatch => formatter.write_str("workflow_purge_identity_mismatch"),
            Self::InjectedInterruption(boundary) => {
                write!(formatter, "workflow_purge_interrupted: {boundary}")
            }
        }
    }
}

impl std::error::Error for WorkflowPurgeError {}

impl From<JournalError> for WorkflowPurgeError {
    fn from(value: JournalError) -> Self {
        Self::Journal(value)
    }
}

impl From<WorkflowProjectionError> for WorkflowPurgeError {
    fn from(value: WorkflowProjectionError) -> Self {
        Self::Projection(value)
    }
}

impl From<WorkflowStorageError> for WorkflowPurgeError {
    fn from(value: WorkflowStorageError) -> Self {
        Self::Storage(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowPurgeError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowPurgeFault {
    AfterTombstoneCommit,
    AfterProjection,
    AfterStorageDeletion,
    AfterJournalCompaction,
}

pub fn purge_workflow_run(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    storage: Option<&mut WorkflowScopedStorage>,
    request: v1::PurgeWorkflowRunRequest,
) -> Result<v1::PurgeWorkflowRunResponse> {
    purge_workflow_run_inner(journal, projection, storage, request, None)
}

#[doc(hidden)]
pub fn purge_workflow_run_with_fault_for_test(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    storage: Option<&mut WorkflowScopedStorage>,
    request: v1::PurgeWorkflowRunRequest,
    fault: WorkflowPurgeFault,
) -> Result<v1::PurgeWorkflowRunResponse> {
    purge_workflow_run_inner(journal, projection, storage, request, Some(fault))
}

fn purge_workflow_run_inner(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    storage: Option<&mut WorkflowScopedStorage>,
    request: v1::PurgeWorkflowRunRequest,
    fault: Option<WorkflowPurgeFault>,
) -> Result<v1::PurgeWorkflowRunResponse> {
    projection.catch_up(journal)?;
    let existing = projection.purge_tombstone(&request.run_id)?;
    let duplicate = existing.is_some();
    let (purge_event_id, purge_store_position, tombstone) = if let Some(existing) = existing {
        verify_request_matches_tombstone(&request, &existing.2)?;
        existing
    } else {
        let run = projection
            .inspect_runs_as_of(
                None,
                Some(&request.run_id),
                1,
                request.requested_at_unix_millis,
            )?
            .pop()
            .ok_or(WorkflowPurgeError::NotFound)?;
        let preview = run
            .purge_preview
            .as_ref()
            .ok_or(WorkflowPurgeError::IdentityMismatch)?;
        if preview.evidence_digest != request.expected_preview_evidence_digest {
            return Err(WorkflowPurgeError::StalePreview);
        }
        let mode = v1::WorkflowRunPurgeMode::try_from(request.mode)
            .map_err(|_| WorkflowPurgeError::IdentityMismatch)?;
        let eligible = match mode {
            v1::WorkflowRunPurgeMode::Manual => preview.manual_eligible,
            v1::WorkflowRunPurgeMode::Automatic => preview.automatic_eligible,
            v1::WorkflowRunPurgeMode::Unspecified => false,
        };
        if !eligible {
            let reason = if preview.protected_reason.is_empty() {
                "retention_policy".into()
            } else {
                preview.protected_reason.clone()
            };
            return Err(WorkflowPurgeError::Protected(reason));
        }
        let source_event_count = journal.workflow_run_event_count(&request.run_id)?;
        if source_event_count != run.events.len() as u64 || source_event_count == 0 {
            return Err(WorkflowPurgeError::IdentityMismatch);
        }
        let installation_id = storage
            .as_deref()
            .map(|storage| storage.job_namespace_installation_id(&run.run_id))
            .transpose()?
            .flatten()
            .unwrap_or_default();
        if !preview.affected_file_handle_ids.is_empty() && installation_id.is_empty() {
            return Err(WorkflowPurgeError::IdentityMismatch);
        }
        let tombstone = v1::WorkflowRunPurged {
            run_id: run.run_id.clone(),
            purge_command_id: request.request_id.clone(),
            workflow_id: run.workflow_id,
            revision_id: run.revision_id,
            package_digest: run.package_digest,
            mode: request.mode,
            preview_evidence_digest: preview.evidence_digest.clone(),
            source_first_store_position: run.first_store_position,
            source_last_store_position: run.last_store_position,
            source_event_count,
            affected_attempt_count: preview.affected_attempt_ids.len() as u64,
            affected_value_count: preview.affected_value_ids.len() as u64,
            affected_file_handle_count: preview.affected_file_handle_ids.len() as u64,
            retained_promoted_handle_ids: preview.retained_promoted_handle_ids.clone(),
            affected_value_bytes: preview.affected_value_bytes,
            installation_id,
            historical_revision_retained: true,
            affected_effect_authority_count: preview.affected_effect_ids.len() as u64,
        };
        let purge_event_id = purge_event_id(&request.request_id, &request.run_id);
        let appended = journal.append_event(v1::EventEnvelope {
            schema_version: Some(v1::SchemaVersion {
                major: SCHEMA_MAJOR,
                minor: 0,
            }),
            event_id: purge_event_id.clone(),
            store_position: 0,
            stream_id: format!("workflow-run:{}", request.run_id),
            stream_sequence: 0,
            occurred_at_unix_millis: request.requested_at_unix_millis,
            kind: WORKFLOW_RUN_PURGED_KIND.into(),
            payload: Some(v1::OpaqueTypedPayload {
                type_url: WORKFLOW_RUN_PURGED_TYPE.into(),
                content_type: "application/x-protobuf".into(),
                value: tombstone.encode_to_vec(),
                payload_version: 1,
            }),
            provenance: Some(v1::EventProvenance {
                source_kind: "workflow-runtime".into(),
                provider_instance_id: String::new(),
                native_type: String::new(),
                native_cursor: Vec::new(),
                raw_evidence_digest: String::new(),
                retention_class: v1::EvidenceRetentionClass::None as i32,
            }),
            causation_id: request.request_id.clone(),
            correlation_id: request.run_id.clone(),
        })?;
        if fault == Some(WorkflowPurgeFault::AfterTombstoneCommit) {
            return Err(WorkflowPurgeError::InjectedInterruption(
                "after_tombstone_commit",
            ));
        }
        projection.catch_up(journal)?;
        if fault == Some(WorkflowPurgeFault::AfterProjection) {
            return Err(WorkflowPurgeError::InjectedInterruption("after_projection"));
        }
        (purge_event_id, appended.store_position, tombstone)
    };

    // A restart may encounter a durable tombstone that the disposable
    // projection has not consumed yet.
    projection.catch_up(journal)?;

    let (job_receipt, object_receipt) = if !tombstone.installation_id.is_empty() {
        let storage = storage.ok_or(WorkflowPurgeError::IdentityMismatch)?;
        let job_receipt = storage.delete_job(WorkflowStorageDeleteJobRequest {
            command_id: storage_purge_command_id(&tombstone.purge_command_id, &tombstone.run_id),
            access: WorkflowStorageAccessContext {
                run_id: Some(tombstone.run_id.clone()),
                case_id: None,
                installation_id: tombstone.installation_id.clone(),
                account_binding_ids: BTreeSet::new(),
            },
            namespace: WorkflowStorageNamespace {
                kind: WorkflowStorageScopeKind::Job,
                owner_id: tombstone.run_id.clone(),
                installation_id: Some(tombstone.installation_id.clone()),
            },
            deleted_at_unix_millis: request.requested_at_unix_millis,
        })?;
        let object_receipt = storage.collect_orphaned_objects()?;
        (Some(job_receipt), Some(object_receipt))
    } else {
        (None, None)
    };
    if fault == Some(WorkflowPurgeFault::AfterStorageDeletion) {
        return Err(WorkflowPurgeError::InjectedInterruption(
            "after_storage_deletion",
        ));
    }

    let compaction = journal.compact_workflow_run(&tombstone.run_id, &purge_event_id)?;
    if compaction.compacted_event_count != tombstone.source_event_count && !compaction.duplicate {
        return Err(WorkflowPurgeError::IdentityMismatch);
    }
    if fault == Some(WorkflowPurgeFault::AfterJournalCompaction) {
        return Err(WorkflowPurgeError::InjectedInterruption(
            "after_journal_compaction",
        ));
    }

    Ok(v1::PurgeWorkflowRunResponse {
        schema_version: Some(v1::SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
        request_id: request.request_id,
        receipt: Some(purge_receipt(
            purge_event_id,
            purge_store_position,
            tombstone.clone(),
            tombstone.source_event_count,
            job_receipt.as_ref(),
            object_receipt.as_ref(),
        )),
        duplicate,
        projection_high_water_mark: projection.high_water_mark()?,
    })
}

fn verify_request_matches_tombstone(
    request: &v1::PurgeWorkflowRunRequest,
    tombstone: &v1::WorkflowRunPurged,
) -> Result<()> {
    if request.request_id != tombstone.purge_command_id
        || request.run_id != tombstone.run_id
        || request.mode != tombstone.mode
        || request.expected_preview_evidence_digest != tombstone.preview_evidence_digest
    {
        return Err(WorkflowPurgeError::IdentityMismatch);
    }
    Ok(())
}

fn purge_receipt(
    purge_event_id: String,
    purge_store_position: u64,
    tombstone: v1::WorkflowRunPurged,
    compacted_journal_event_count: u64,
    job: Option<&WorkflowStorageDeleteJobReceipt>,
    objects: Option<&WorkflowObjectGarbageCollectionReceipt>,
) -> v1::WorkflowRunPurgeReceipt {
    v1::WorkflowRunPurgeReceipt {
        purge_event_id,
        purge_store_position,
        tombstone: Some(tombstone),
        compacted_journal_event_count,
        job_namespace_deleted: job.is_some(),
        deleted_storage_entry_count: job.map_or(0, |receipt| receipt.entry_count),
        deleted_storage_version_count: job.map_or(0, |receipt| receipt.version_count),
        deleted_blob_reference_count: job.map_or(0, |receipt| receipt.blob_reference_count),
        quarantined_object_count: objects.map_or(0, |receipt| receipt.quarantined_object_count),
        quarantined_object_bytes: objects.map_or(0, |receipt| receipt.quarantined_byte_count),
    }
}

fn purge_event_id(command_id: &str, run_id: &str) -> String {
    stable_purge_id("purge-event", command_id, run_id)
}

fn storage_purge_command_id(command_id: &str, run_id: &str) -> String {
    stable_purge_id("purge-storage", command_id, run_id)
}

fn stable_purge_id(prefix: &str, command_id: &str, run_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.purge.v1\0");
    hasher.update(prefix.as_bytes());
    hasher.update([0]);
    hasher.update(command_id.as_bytes());
    hasher.update([0]);
    hasher.update(run_id.as_bytes());
    format!("{prefix}-{}", &hex::encode(hasher.finalize())[..48])
}
