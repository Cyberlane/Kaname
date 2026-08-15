use kaname_core::{
    journal::{Journal, JournalError},
    open_workflow_library, open_workflow_object_store, open_workflow_scoped_storage,
    v1::{
        EventEnvelope, EventProvenance, EvidenceRetentionClass, OpaqueTypedPayload,
        PurgeWorkflowRunRequest, SchemaVersion, WorkflowRunOutcome, WorkflowRunPurgeMode,
        WorkflowRunRetentionMode, WorkflowRunRetentionPolicy, WorkflowRunSettled,
        WorkflowRunTokenCreated, WorkflowStorageValueMetadata, WorkflowValueReference,
    },
    workflow_drafts::CreateWorkflowDraft,
    workflow_object_store::{WorkflowObjectStoreQuota, WorkflowObjectStoreUsage},
    workflow_projection::WorkflowRunProjection,
    workflow_publication::PublishWorkflowRevision,
    workflow_purge::{
        WorkflowPurgeError, WorkflowPurgeFault, purge_workflow_run,
        purge_workflow_run_with_fault_for_test,
    },
    workflow_runtime::{
        WORKFLOW_RUN_PURGED_KIND, WORKFLOW_RUN_SETTLED_KIND, WORKFLOW_RUN_SETTLED_TYPE,
        WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_RUN_TOKEN_CREATED_TYPE,
    },
    workflow_storage::{
        WorkflowStorageAccessContext, WorkflowStorageNamespace, WorkflowStorageNamespaceQuota,
        WorkflowStorageScopeKind, WorkflowStorageValueInput, WorkflowStorageWriteRequest,
    },
};
use prost::Message;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs, path::Path};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x71; 32];
const RUN_ID: &str = "run-purge-proof-001";
const HISTORICAL_WORKFLOW_ID: &str = "990d4e21-b85c-7e04-975e-7cf6ba1f83b0";

#[test]
fn every_interruption_boundary_resumes_to_one_tombstone_and_no_resurrection() {
    for fault in [
        WorkflowPurgeFault::AfterTombstoneCommit,
        WorkflowPurgeFault::AfterProjection,
        WorkflowPurgeFault::AfterStorageDeletion,
        WorkflowPurgeFault::AfterJournalCompaction,
    ] {
        let temporary = tempdir().unwrap();
        let journal_path = temporary.path().join("journal.sqlite");
        let projection_path = temporary.path().join("projection.sqlite");
        let request = {
            let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
            append_settled_run(&mut journal);
            let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
            projection.catch_up(&journal).unwrap();
            purge_request(&projection)
        };

        {
            let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
            let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
            let interrupted = purge_workflow_run_with_fault_for_test(
                &mut journal,
                &mut projection,
                None,
                request.clone(),
                fault,
            );
            assert!(
                matches!(
                    interrupted,
                    Err(WorkflowPurgeError::InjectedInterruption(_))
                ),
                "fault {fault:?} returned {interrupted:?}"
            );
        }

        let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
        let (mut projection, _) =
            WorkflowRunProjection::open_or_rebuild(&projection_path, &journal).unwrap();
        let resumed =
            purge_workflow_run(&mut journal, &mut projection, None, request.clone()).unwrap();
        assert!(resumed.duplicate);
        let receipt = resumed.receipt.unwrap();
        assert_eq!(receipt.compacted_journal_event_count, 2);
        assert_eq!(journal.workflow_run_event_count(RUN_ID).unwrap(), 1);
        assert!(
            projection
                .inspect_runs_as_of(None, Some(RUN_ID), 1, request.requested_at_unix_millis)
                .unwrap()
                .is_empty()
        );
        let tombstone = projection.purge_tombstone(RUN_ID).unwrap().unwrap();
        assert_eq!(tombstone.0, receipt.purge_event_id);
        assert_eq!(tombstone.2.source_event_count, 2);
        assert!(tombstone.2.historical_revision_retained);

        let before_rebuild = projection.canonical_snapshot().unwrap();
        projection.rebuild_from_zero(&journal).unwrap();
        assert_eq!(projection.canonical_snapshot().unwrap(), before_rebuild);
        assert_eq!(projection.row_count("purge_receipts").unwrap(), 1);

        let repeated =
            purge_workflow_run(&mut journal, &mut projection, None, request.clone()).unwrap();
        assert!(repeated.duplicate);
        assert_eq!(journal.workflow_run_event_count(RUN_ID).unwrap(), 1);

        assert!(matches!(
            journal.append_event(token_event()),
            Err(JournalError::Integrity(code)) if code == "workflow_run_purged"
        ));
        let remaining = journal.event_page_after(0, 10).unwrap().events;
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].kind, WORKFLOW_RUN_PURGED_KIND);
    }
}

#[test]
fn stale_preview_and_automatic_policy_fail_before_a_tombstone_is_written() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_settled_run(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let mut stale = purge_request(&projection);
    stale.expected_preview_evidence_digest = "f".repeat(64);
    assert!(matches!(
        purge_workflow_run(&mut journal, &mut projection, None, stale),
        Err(WorkflowPurgeError::StalePreview)
    ));
    assert_eq!(journal.workflow_run_event_count(RUN_ID).unwrap(), 2);

    let mut automatic = purge_request(&projection);
    automatic.mode = WorkflowRunPurgeMode::Automatic as i32;
    assert!(matches!(
        purge_workflow_run(&mut journal, &mut projection, None, automatic),
        Err(WorkflowPurgeError::Protected(reason)) if reason == "retention_policy"
    ));
    assert_eq!(journal.workflow_run_event_count(RUN_ID).unwrap(), 2);
    assert!(projection.purge_tombstone(RUN_ID).unwrap().is_none());
}

#[test]
fn empty_job_namespace_is_deleted_and_repeated_purge_keeps_the_same_receipt() {
    let temporary = tempdir().unwrap();
    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    let access = WorkflowStorageAccessContext {
        run_id: Some(RUN_ID.into()),
        case_id: None,
        installation_id: "installation-purge-empty".into(),
        account_binding_ids: BTreeSet::new(),
    };
    let namespace = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Job,
        owner_id: RUN_ID.into(),
        installation_id: Some(access.installation_id.clone()),
    };
    storage
        .register_namespace(namespace.clone(), namespace_quota(), 100)
        .unwrap();
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_settled_run(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let request = purge_request(&projection);

    let first = purge_workflow_run(
        &mut journal,
        &mut projection,
        Some(&mut storage),
        request.clone(),
    )
    .unwrap();
    let first_receipt = first.receipt.unwrap();
    assert!(first_receipt.job_namespace_deleted);
    assert_eq!(first_receipt.deleted_storage_entry_count, 0);
    assert!(storage.usage(&access, &namespace).is_err());

    let repeated =
        purge_workflow_run(&mut journal, &mut projection, Some(&mut storage), request).unwrap();
    assert!(repeated.duplicate);
    assert_eq!(repeated.receipt.unwrap(), first_receipt);
}

#[test]
fn shared_object_survives_job_purge_through_a_case_reference() {
    let temporary = tempdir().unwrap();
    let historical_graph = temporary
        .path()
        .join("Workflows/Revisions/workflow-purge-proof/revision-purge-proof/workflow.json");
    fs::create_dir_all(historical_graph.parent().unwrap()).unwrap();
    fs::write(&historical_graph, br#"{"name":"Historical diagram"}"#).unwrap();
    let bytes = b"shared immutable workflow object";
    let quota = object_quota();
    let object_store = open_workflow_object_store(temporary.path(), quota).unwrap();
    let mut write = object_store
        .begin_write("purge-shared-object", None)
        .unwrap();
    write.write_chunk(bytes).unwrap();
    let stored = object_store.finalize(write).unwrap();

    let mut storage = open_workflow_scoped_storage(temporary.path(), quota).unwrap();
    let access = WorkflowStorageAccessContext {
        run_id: Some(RUN_ID.into()),
        case_id: Some("case-purge-proof".into()),
        installation_id: "installation-purge-proof".into(),
        account_binding_ids: BTreeSet::new(),
    };
    let job = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Job,
        owner_id: RUN_ID.into(),
        installation_id: Some(access.installation_id.clone()),
    };
    let case = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Case,
        owner_id: "case-purge-proof".into(),
        installation_id: Some(access.installation_id.clone()),
    };
    storage
        .register_namespace(job.clone(), namespace_quota(), 100)
        .unwrap();
    storage
        .register_namespace(case.clone(), namespace_quota(), 100)
        .unwrap();
    let job_receipt = storage
        .write_value(object_write_request(
            "command-write-job-shared",
            "entry-job-shared",
            "version-job-shared",
            "reference-job-shared",
            "files/shared.bin",
            access.clone(),
            job,
            &stored.manifest.digest,
            stored.manifest.byte_count,
        ))
        .unwrap();
    let case_receipt = storage
        .write_value(object_write_request(
            "command-write-case-shared",
            "entry-case-shared",
            "version-case-shared",
            "reference-case-shared",
            "files/shared.bin",
            access.clone(),
            case,
            &stored.manifest.digest,
            stored.manifest.byte_count,
        ))
        .unwrap();

    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    journal.append_event(token_event()).unwrap();
    journal
        .append_event(runtime_event(
            "event-purge-run-failed-with-object",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: RUN_ID.into(),
                run_token_id: "token-purge-proof-001".into(),
                outcome: WorkflowRunOutcome::Failed as i32,
                error_code: "fixture-failed".into(),
                error: Some(storage_value_reference(&job_receipt.handle)),
                final_emission_ids: Vec::new(),
            },
            "event-purge-token-created",
            2_000,
        ))
        .unwrap();
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let request = purge_request(&projection);
    let response =
        purge_workflow_run(&mut journal, &mut projection, Some(&mut storage), request).unwrap();
    let receipt = response.receipt.unwrap();
    assert!(receipt.job_namespace_deleted);
    assert_eq!(receipt.deleted_blob_reference_count, 1);
    assert_eq!(receipt.quarantined_object_count, 0);
    assert!(
        storage
            .inspect_handle(&access, &job_receipt.handle.handle_id)
            .is_err()
    );
    assert_eq!(
        storage
            .inspect_handle(&access, &case_receipt.handle.handle_id)
            .unwrap()
            .sha256,
        stored.manifest.digest
    );
    assert_eq!(
        object_store.usage().unwrap(),
        WorkflowObjectStoreUsage {
            object_count: 1,
            byte_count: bytes.len() as u64,
        }
    );
    assert_eq!(
        fs::read(historical_graph).unwrap(),
        br#"{"name":"Historical diagram"}"#
    );
}

#[test]
fn published_historical_diagram_still_loads_after_run_purge() {
    let temporary = tempdir().unwrap();
    let mut library = open_workflow_library(temporary.path()).unwrap();
    let workflow_source = fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Fixtures/workflow-v2/legacy-import-terminal-v1.json"),
    )
    .unwrap();
    let layout_source = br#"{"nodes":[{"nodeId":"ee3b3ec0-ead6-7897-a63f-e5ff53fdf605","x":40,"y":80},{"nodeId":"7c0afb84-421e-7656-838e-22e631841203","x":420,"y":80}]}"#.to_vec();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: HISTORICAL_WORKFLOW_ID.into(),
            package_id: "org.example.legacy-portable".into(),
            name: "Historical diagram".into(),
            summary: "Purge preservation fixture".into(),
            edit_id: "historical-purge-edit".into(),
            session_id: "historical-purge-test".into(),
            workflow_source: workflow_source.clone(),
            layout_source: layout_source.clone(),
            recorded_at_unix_millis: 10,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: HISTORICAL_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: "revision-purge-history".into(),
            registration_id: "registration-purge-history".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 20,
        })
        .unwrap();
    let before_purge = library
        .load_workflow_revision("revision-purge-history", "active")
        .unwrap();

    let run_id = "run-purge-history-001";
    let token_id = "token-purge-history-001";
    let command_id = "command-purge-history-001";
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    journal
        .append_event(runtime_event_for(
            run_id,
            "event-purge-history-token-created",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: run_id.into(),
                run_token_id: token_id.into(),
                request_command_id: command_id.into(),
                workflow_id: published.workflow_id.clone(),
                revision_id: published.revision_id.clone(),
                package_digest: published.package_digest.clone(),
                retention_policy: Some(WorkflowRunRetentionPolicy {
                    mode: WorkflowRunRetentionMode::Duration as i32,
                    days: 30,
                }),
            },
            command_id,
            1_000,
        ))
        .unwrap();
    journal
        .append_event(runtime_event_for(
            run_id,
            "event-purge-history-run-settled",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: run_id.into(),
                run_token_id: token_id.into(),
                outcome: WorkflowRunOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                final_emission_ids: Vec::new(),
            },
            "event-purge-history-token-created",
            2_000,
        ))
        .unwrap();
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let request = purge_request_for(&projection, run_id);
    let response = purge_workflow_run(&mut journal, &mut projection, None, request).unwrap();
    let tombstone = response.receipt.unwrap().tombstone.unwrap();
    assert_eq!(tombstone.workflow_id, published.workflow_id);
    assert_eq!(tombstone.revision_id, published.revision_id);
    assert_eq!(tombstone.package_digest, published.package_digest);

    let loaded = library
        .load_workflow_revision("revision-purge-history", "active")
        .unwrap();
    let workflow: Value = serde_json::from_slice(&loaded.workflow_source).unwrap();
    let layout: Value = serde_json::from_slice(&loaded.layout_source).unwrap();
    assert_eq!(workflow["graph"]["nodes"].as_array().unwrap().len(), 2);
    assert_eq!(layout["nodes"][0]["x"], 40);
    assert_eq!(loaded.workflow_source, before_purge.workflow_source);
    assert_eq!(loaded.layout_source, before_purge.layout_source);
}

#[test]
fn tombstone_and_rebuilt_projection_retain_no_deleted_inline_payload() {
    let marker = "delete-me-private-marker";
    let bytes = format!(r#"{{"private":"{marker}"}}"#).into_bytes();
    let survivor_run_id = "run-purge-survivor-001";
    let survivor_token_id = "token-purge-survivor-001";
    let survivor_bytes = br#"{"coincidental":"value-private-purge-proof"}"#.to_vec();
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    journal.append_event(token_event()).unwrap();
    journal
        .append_event(runtime_event(
            "event-purge-run-failed-with-inline",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: RUN_ID.into(),
                run_token_id: "token-purge-proof-001".into(),
                outcome: WorkflowRunOutcome::Failed as i32,
                error_code: "fixture-failed".into(),
                error: Some(WorkflowValueReference {
                    value_id: "value-private-purge-proof".into(),
                    content_type: "application/json".into(),
                    byte_count: bytes.len() as u64,
                    sha256: hex::encode(Sha256::digest(&bytes)),
                    inline_canonical_json: bytes,
                    storage_reference_id: String::new(),
                    storage: None,
                }),
                final_emission_ids: Vec::new(),
            },
            "event-purge-token-created",
            2_000,
        ))
        .unwrap();
    journal
        .append_event(token_event_for(
            survivor_run_id,
            survivor_token_id,
            "event-purge-survivor-token-created",
            "command-purge-survivor-001",
        ))
        .unwrap();
    journal
        .append_event(runtime_event_for(
            survivor_run_id,
            "event-purge-survivor-settled",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: survivor_run_id.into(),
                run_token_id: survivor_token_id.into(),
                outcome: WorkflowRunOutcome::Failed as i32,
                error_code: "fixture-failed".into(),
                error: Some(WorkflowValueReference {
                    value_id: "value-purge-survivor".into(),
                    content_type: "application/json".into(),
                    byte_count: survivor_bytes.len() as u64,
                    sha256: hex::encode(Sha256::digest(&survivor_bytes)),
                    inline_canonical_json: survivor_bytes,
                    storage_reference_id: String::new(),
                    storage: None,
                }),
                final_emission_ids: Vec::new(),
            },
            "event-purge-survivor-token-created",
            4_000,
        ))
        .unwrap();
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let request = purge_request(&projection);
    purge_workflow_run(&mut journal, &mut projection, None, request).unwrap();

    let journal_wire = journal.event_page_after(0, 10).unwrap().events[0].encode_to_vec();
    assert!(!String::from_utf8_lossy(&journal_wire).contains(marker));
    assert!(!String::from_utf8_lossy(&projection.canonical_snapshot().unwrap()).contains(marker));
    projection.rebuild_from_zero(&journal).unwrap();
    assert!(!String::from_utf8_lossy(&projection.canonical_snapshot().unwrap()).contains(marker));
}

fn purge_request(projection: &WorkflowRunProjection) -> PurgeWorkflowRunRequest {
    purge_request_for(projection, RUN_ID)
}

fn purge_request_for(projection: &WorkflowRunProjection, run_id: &str) -> PurgeWorkflowRunRequest {
    let run = projection
        .inspect_runs_as_of(None, Some(run_id), 1, 10_000)
        .unwrap()
        .pop()
        .unwrap();
    PurgeWorkflowRunRequest {
        schema_version: Some(schema_version()),
        request_id: "purge-request-proof-001".into(),
        run_id: run_id.into(),
        mode: WorkflowRunPurgeMode::Manual as i32,
        expected_preview_evidence_digest: run.purge_preview.unwrap().evidence_digest,
        requested_at_unix_millis: 10_000,
    }
}

fn append_settled_run(journal: &mut Journal) {
    journal.append_event(token_event()).unwrap();
    journal
        .append_event(runtime_event(
            "event-purge-run-settled",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: RUN_ID.into(),
                run_token_id: "token-purge-proof-001".into(),
                outcome: WorkflowRunOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                final_emission_ids: Vec::new(),
            },
            "event-purge-token-created",
            2_000,
        ))
        .unwrap();
}

fn token_event() -> EventEnvelope {
    token_event_for(
        RUN_ID,
        "token-purge-proof-001",
        "event-purge-token-created",
        "command-purge-run-001",
    )
}

fn token_event_for(
    run_id: &str,
    run_token_id: &str,
    event_id: &str,
    command_id: &str,
) -> EventEnvelope {
    runtime_event_for(
        run_id,
        event_id,
        WORKFLOW_RUN_TOKEN_CREATED_KIND,
        WORKFLOW_RUN_TOKEN_CREATED_TYPE,
        WorkflowRunTokenCreated {
            run_id: run_id.into(),
            run_token_id: run_token_id.into(),
            request_command_id: command_id.into(),
            workflow_id: "workflow-purge-proof".into(),
            revision_id: "revision-purge-proof".into(),
            package_digest: "a".repeat(64),
            retention_policy: Some(WorkflowRunRetentionPolicy {
                mode: WorkflowRunRetentionMode::Duration as i32,
                days: 30,
            }),
        },
        command_id,
        1_000,
    )
}

fn runtime_event<M: Message>(
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    occurred_at_unix_millis: i64,
) -> EventEnvelope {
    runtime_event_for(
        RUN_ID,
        event_id,
        kind,
        type_url,
        payload,
        causation_id,
        occurred_at_unix_millis,
    )
}

fn runtime_event_for<M: Message>(
    run_id: &str,
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    occurred_at_unix_millis: i64,
) -> EventEnvelope {
    EventEnvelope {
        schema_version: Some(schema_version()),
        event_id: event_id.into(),
        store_position: 0,
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        occurred_at_unix_millis,
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
            payload_version: 1,
        }),
        provenance: Some(EventProvenance {
            source_kind: "workflow-runtime".into(),
            provider_instance_id: String::new(),
            native_type: String::new(),
            native_cursor: Vec::new(),
            raw_evidence_digest: String::new(),
            retention_class: EvidenceRetentionClass::None as i32,
        }),
        causation_id: causation_id.into(),
        correlation_id: run_id.into(),
    }
}

fn schema_version() -> SchemaVersion {
    SchemaVersion { major: 1, minor: 0 }
}

fn object_quota() -> WorkflowObjectStoreQuota {
    WorkflowObjectStoreQuota {
        maximum_object_bytes: 1024 * 1024,
        maximum_total_bytes: 4 * 1024 * 1024,
        maximum_object_count: 100,
    }
}

fn namespace_quota() -> WorkflowStorageNamespaceQuota {
    WorkflowStorageNamespaceQuota {
        maximum_item_count: 100,
        maximum_total_bytes: 4 * 1024 * 1024,
        maximum_value_bytes: 1024 * 1024,
    }
}

#[allow(clippy::too_many_arguments)]
fn object_write_request(
    command_id: &str,
    entry_id: &str,
    version_id: &str,
    reference_id: &str,
    logical_key: &str,
    access: WorkflowStorageAccessContext,
    namespace: WorkflowStorageNamespace,
    digest: &str,
    byte_count: u64,
) -> WorkflowStorageWriteRequest {
    WorkflowStorageWriteRequest {
        command_id: command_id.into(),
        access,
        namespace,
        entry_id: entry_id.into(),
        version_id: version_id.into(),
        reference_id: Some(reference_id.into()),
        logical_key: logical_key.into(),
        expected_revision: 0,
        schema_ref: None,
        media_type: "application/octet-stream".into(),
        classification: "sensitive".into(),
        purpose: "file".into(),
        value: WorkflowStorageValueInput::Object {
            digest: digest.into(),
            byte_count,
        },
        created_by_attempt_id: "attempt-purge-storage".into(),
        created_at_unix_millis: 500,
    }
}

fn storage_value_reference(
    handle: &kaname_core::workflow_storage::WorkflowStorageHandle,
) -> WorkflowValueReference {
    WorkflowValueReference {
        value_id: "value-purge-shared-object".into(),
        content_type: handle.media_type.clone(),
        byte_count: handle.byte_count,
        sha256: handle.sha256.clone(),
        inline_canonical_json: Vec::new(),
        storage_reference_id: handle.handle_id.clone(),
        storage: Some(WorkflowStorageValueMetadata {
            handle_id: handle.handle_id.clone(),
            scope: "job".into(),
            logical_key: handle.logical_key.clone(),
            version_id: handle.version_id.clone(),
            revision: handle.revision,
            previous_version_id: handle.previous_version_id.clone().unwrap_or_default(),
            byte_count: handle.byte_count,
            result: "written".into(),
            source_version_id: handle.source_version_id.clone().unwrap_or_default(),
        }),
    }
}
