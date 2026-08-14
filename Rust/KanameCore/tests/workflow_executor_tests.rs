use kaname_core::{
    journal::{Journal, ReplayBasis},
    open_workflow_library, open_workflow_scoped_storage,
    v1::{
        CancelWorkflowRun, CommandEnvelope, OpaqueTypedPayload, RequestWorkflowRun, SchemaVersion,
        Scope, WorkflowInputBinding, WorkflowRunTokenCreated, WorkflowValueReference,
    },
    workflow_drafts::CreateWorkflowDraft,
    workflow_executor::{
        self, DurableRunOutcome, WorkflowExecutionError, WorkflowExecutionFault,
        WorkflowStorageExecutionAuthority,
    },
    workflow_object_store::WorkflowObjectStoreQuota,
    workflow_projection::WorkflowRunProjection,
    workflow_publication::{PublishWorkflowRevision, PublishedWorkflowRevision},
    workflow_runtime::{
        WORKFLOW_RUN_CANCEL_KIND, WORKFLOW_RUN_CANCEL_TYPE, WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE, WORKFLOW_RUN_TOKEN_CREATED_KIND,
    },
    workflow_storage::{
        WorkflowStorageAccessContext, WorkflowStorageNamespace, WorkflowStorageScopeKind,
    },
};
use prost::Message;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x5c; 32];
const WORKFLOW_ID: &str = "018f5000-0001-7000-8000-000000000001";
const MANUAL_ID: &str = "018f5000-0002-7000-8000-000000000002";
const VALIDATE_ID: &str = "018f5000-0003-7000-8000-000000000003";
const MATCH_ID: &str = "018f5000-0004-7000-8000-000000000004";
const COMPLETE_MATCH_ID: &str = "018f5000-0005-7000-8000-000000000005";
const COMPLETE_OTHERWISE_ID: &str = "018f5000-0006-7000-8000-000000000006";
const FAIL_VALIDATE_ID: &str = "018f5000-0007-7000-8000-000000000007";
const FAIL_MATCH_ID: &str = "018f5000-0008-7000-8000-000000000008";
const CASE_FIVE_ID: &str = "018f5000-0009-7000-8000-000000000009";
const OTHERWISE_ID: &str = "018f5000-0010-7000-8000-000000000010";
const REVISION_ID: &str = "revision-minimal-001";
const STORAGE_WORKFLOW_ID: &str = "018f5300-0001-7000-8000-000000000001";
const STORAGE_REVISION_ID: &str = "revision-storage-001";

#[test]
fn immutable_minimal_graph_takes_success_and_validation_failure_paths() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let immutable_before = library
        .load_workflow_revision(REVISION_ID, "active")
        .unwrap();

    let mut success_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let success_command = run_command("run-success-001", &published, json!({"route": 5}));
    let success =
        workflow_executor::execute(&mut success_journal, &library, &success_command).unwrap();
    assert_eq!(success.outcome, DurableRunOutcome::Succeeded);
    assert_eq!(success.event_count, 17);
    let mut success_projection = WorkflowRunProjection::open_in_memory().unwrap();
    success_projection.catch_up(&success_journal).unwrap();
    assert_eq!(success_projection.row_count("runs").unwrap(), 1);
    assert_eq!(success_projection.row_count("attempts").unwrap(), 4);
    assert_eq!(success_projection.row_count("nodes").unwrap(), 4);
    assert_eq!(success_projection.row_count("emissions").unwrap(), 3);
    assert_eq!(success_projection.row_count("edges").unwrap(), 3);
    assert_eq!(success_projection.row_count("matches").unwrap(), 1);

    let mut otherwise_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let otherwise_command = run_command("run-otherwise-001", &published, json!({"route": 8}));
    assert_eq!(
        workflow_executor::execute(&mut otherwise_journal, &library, &otherwise_command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut otherwise_projection = WorkflowRunProjection::open_in_memory().unwrap();
    otherwise_projection.catch_up(&otherwise_journal).unwrap();
    assert_eq!(otherwise_projection.row_count("matches").unwrap(), 1);
    assert_eq!(otherwise_projection.row_count("attempts").unwrap(), 4);

    let mut failure_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let failure_command = run_command("run-failure-001", &published, json!({}));
    let failure =
        workflow_executor::execute(&mut failure_journal, &library, &failure_command).unwrap();
    assert_eq!(failure.outcome, DurableRunOutcome::Failed);
    assert_eq!(failure.event_count, 12);
    let mut failure_projection = WorkflowRunProjection::open_in_memory().unwrap();
    failure_projection.catch_up(&failure_journal).unwrap();
    assert_eq!(failure_projection.row_count("attempts").unwrap(), 3);
    assert_eq!(failure_projection.row_count("emissions").unwrap(), 2);
    assert_eq!(failure_projection.row_count("matches").unwrap(), 0);

    let immutable_after = library
        .load_workflow_revision(REVISION_ID, "active")
        .unwrap();
    assert_eq!(immutable_after, immutable_before);
}

#[test]
fn every_event_boundary_resumes_to_the_exact_same_journal_without_duplicates() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let command = run_command("run-crash-proof-001", &published, json!({"route": 5}));

    let expected = {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(result.outcome, DurableRunOutcome::Succeeded);
        run_wires(&journal, "run-crash-proof-001")
    };
    assert_eq!(expected.len(), 17);

    for boundary in 1..=expected.len() {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        let resumed = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(resumed.outcome, DurableRunOutcome::Succeeded);
        assert_eq!(run_wires(&journal, "run-crash-proof-001"), expected);

        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("attempts").unwrap(), 4);
        assert_eq!(projection.row_count("emissions").unwrap(), 3);
        assert_eq!(projection.row_count("events").unwrap(), 17);
    }
}

#[test]
fn cancellation_is_idempotent_terminal_and_inspectable_after_restart() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let command = run_command("run-cancel-001", &published, json!({"route": 5}));
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute_with_fault_for_test(
            &mut journal,
            &library,
            &command,
            WorkflowExecutionFault::AfterNewEvent(2),
        ),
        Err(WorkflowExecutionError::InjectedInterruption)
    ));
    let token = run_token(&journal, "run-cancel-001");
    let cancellation = cancel_command("run-cancel-001", &token.run_token_id);
    let first = workflow_executor::request_cancellation(&mut journal, &cancellation).unwrap();
    assert!(!first.duplicate);
    let duplicate = workflow_executor::request_cancellation(&mut journal, &cancellation).unwrap();
    assert!(duplicate.duplicate);

    let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
    assert_eq!(result.outcome, DurableRunOutcome::Cancelled);
    let settled_wires = run_wires(&journal, "run-cancel-001");
    assert_eq!(settled_wires.len(), 5);
    assert_eq!(
        workflow_executor::execute(&mut journal, &library, &command)
            .unwrap()
            .event_count,
        settled_wires.len()
    );
    assert_eq!(run_wires(&journal, "run-cancel-001"), settled_wires);

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("runs").unwrap(), 1);
    assert_eq!(projection.row_count("attempts").unwrap(), 1);
    assert_eq!(projection.row_count("emissions").unwrap(), 0);
    assert_eq!(projection.row_count("events").unwrap(), 5);
}

#[test]
fn unsupported_storage_input_and_revision_pin_drift_create_no_runtime_event() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());

    let mut storage_command = run_command("run-storage-001", &published, json!({"route": 5}));
    let mut storage_request =
        RequestWorkflowRun::decode(storage_command.payload.as_ref().unwrap().value.as_slice())
            .unwrap();
    storage_request.inputs[0].value = Some(WorkflowValueReference {
        value_id: "value-storage-input".into(),
        content_type: "application/json".into(),
        byte_count: 12,
        sha256: "a".repeat(64),
        inline_canonical_json: Vec::new(),
        storage_reference_id: "object-storage-001".into(),
        storage: None,
    });
    storage_command.payload.as_mut().unwrap().value = storage_request.encode_to_vec();
    let mut storage_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute(&mut storage_journal, &library, &storage_command),
        Err(WorkflowExecutionError::Unsupported(code))
            if code == "single_inline_manual_input_required"
    ));
    assert_eq!(
        storage_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );

    let mut drifted = run_command("run-drift-001", &published, json!({"route": 5}));
    let mut drifted_request =
        RequestWorkflowRun::decode(drifted.payload.as_ref().unwrap().value.as_slice()).unwrap();
    drifted_request.package_digest = "f".repeat(64);
    drifted.payload.as_mut().unwrap().value = drifted_request.encode_to_vec();
    let mut drifted_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute(&mut drifted_journal, &library, &drifted),
        Err(WorkflowExecutionError::Integrity(code)) if code == "revision_pin_mismatch"
    ));
    assert_eq!(
        drifted_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );
}

#[test]
fn storage_nodes_write_compare_read_list_and_delete_with_inspectable_lineage() {
    let directory = tempdir().unwrap();
    let (library, published) = published_storage_library(directory.path());
    let mut storage = open_workflow_scoped_storage(
        directory.path(),
        WorkflowObjectStoreQuota {
            maximum_object_bytes: 1024 * 1024,
            maximum_total_bytes: 4 * 1024 * 1024,
            maximum_object_count: 100,
        },
    )
    .unwrap();
    let command = storage_run_command(
        "run-storage-nodes-001",
        &published,
        json!({"draft": {"text": "hello"}}),
    );
    let mut denied_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute_with_storage(
            &mut denied_journal,
            &library,
            &mut storage,
            &WorkflowStorageExecutionAuthority {
                installation_id: "installation-other".into(),
                case_id: None,
            },
            &command,
        ),
        Err(WorkflowExecutionError::InvalidCommand(
            "storage_authority_mismatch"
        ))
    ));
    assert_eq!(
        denied_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let result = workflow_executor::execute_with_storage(
        &mut journal,
        &library,
        &mut storage,
        &storage_authority(),
        &command,
    )
    .unwrap();
    assert_eq!(result.outcome, DurableRunOutcome::Succeeded);

    let access = WorkflowStorageAccessContext {
        run_id: Some("run-storage-nodes-001".into()),
        case_id: None,
        installation_id: "installation-storage-001".into(),
        account_binding_ids: Default::default(),
    };
    let namespace = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Job,
        owner_id: "run-storage-nodes-001".into(),
        installation_id: Some("installation-storage-001".into()),
    };
    assert!(matches!(
        storage.list_current(&access, &namespace, None, 10),
        Ok(handles) if handles.is_empty()
    ));

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let run = projection
        .inspect_runs(None, Some("run-storage-nodes-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let storage_values = run
        .emissions
        .iter()
        .filter_map(|emission| emission.value.as_ref()?.storage.as_ref())
        .collect::<Vec<_>>();
    assert_eq!(
        storage_values
            .iter()
            .map(|metadata| metadata.result.as_str())
            .collect::<Vec<_>>(),
        ["written", "written", "read", "listed", "deleted"]
    );
    assert_eq!(storage_values[0].revision, 1);
    assert_eq!(storage_values[1].revision, 2);
    assert_eq!(
        storage_values[1].previous_version_id,
        storage_values[0].version_id
    );
    assert_eq!(storage_values[2].version_id, storage_values[1].version_id);
    assert_eq!(storage_values[4].revision, 2);
    for metadata in storage_values {
        assert_eq!(metadata.scope, "job");
        assert_eq!(metadata.logical_key, "draft");
        assert!(!metadata.handle_id.contains('/'));
    }

    let duplicate = workflow_executor::execute_with_storage(
        &mut journal,
        &library,
        &mut storage,
        &storage_authority(),
        &command,
    )
    .unwrap();
    assert_eq!(duplicate.event_count, result.event_count);
}

#[test]
fn storage_node_receipts_resume_at_every_event_boundary_without_repeating_mutations() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_storage_library(directory.path());
        let mut storage = test_scoped_storage(directory.path());
        let command = storage_run_command(
            "run-storage-crash-001",
            &published,
            json!({"draft": {"text": "hello"}}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute_with_storage(
            &mut journal,
            &library,
            &mut storage,
            &storage_authority(),
            &command,
        )
        .unwrap();
        run_wires(&journal, "run-storage-crash-001")
    };

    for boundary in 1..=expected.len() {
        let directory = tempdir().unwrap();
        let (library, published) = published_storage_library(directory.path());
        let mut storage = test_scoped_storage(directory.path());
        let command = storage_run_command(
            "run-storage-crash-001",
            &published,
            json!({"draft": {"text": "hello"}}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_storage_fault_for_test(
                &mut journal,
                &library,
                &mut storage,
                &storage_authority(),
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        workflow_executor::execute_with_storage(
            &mut journal,
            &library,
            &mut storage,
            &storage_authority(),
            &command,
        )
        .unwrap();
        assert_eq!(run_wires(&journal, "run-storage-crash-001"), expected);
        assert_eq!(
            storage
                .usage(
                    &WorkflowStorageAccessContext {
                        run_id: Some("run-storage-crash-001".into()),
                        case_id: None,
                        installation_id: "installation-storage-001".into(),
                        account_binding_ids: Default::default(),
                    },
                    &WorkflowStorageNamespace {
                        kind: WorkflowStorageScopeKind::Job,
                        owner_id: "run-storage-crash-001".into(),
                        installation_id: Some("installation-storage-001".into()),
                    },
                )
                .unwrap()
                .version_count,
            2
        );
    }
}

fn published_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: WORKFLOW_ID.into(),
            package_id: "dev.kaname.minimal-runtime".into(),
            name: "Minimal durable runtime".into(),
            summary: "Synthetic manual validate Match terminal fixture".into(),
            edit_id: "edit-minimal-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&workflow_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 10,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: REVISION_ID.into(),
            registration_id: "registration-minimal-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&json!({
                "bundleVersion": 1,
                "schemas": [{
                    "id": "dev.kaname.minimal-input/v1",
                    "schema": {
                        "$schema": "https://json-schema.org/draft/2020-12/schema",
                        "type": "object",
                        "required": ["route"],
                        "properties": {
                            "route": {"type": ["number", "string"]}
                        },
                        "additionalProperties": false
                    }
                }]
            }))
            .unwrap(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 20,
        })
        .unwrap();
    (library, published)
}

fn published_storage_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: STORAGE_WORKFLOW_ID.into(),
            package_id: "dev.kaname.storage-runtime".into(),
            name: "Scoped storage runtime".into(),
            summary: "Synthetic path-free storage node fixture".into(),
            edit_id: "edit-storage-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&storage_workflow_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 30,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: STORAGE_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: STORAGE_REVISION_ID.into(),
            registration_id: "registration-storage-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 40,
        })
        .unwrap();
    (library, published)
}

fn test_scoped_storage(
    application_support: &std::path::Path,
) -> kaname_core::workflow_storage::WorkflowScopedStorage {
    open_workflow_scoped_storage(
        application_support,
        WorkflowObjectStoreQuota {
            maximum_object_bytes: 1024 * 1024,
            maximum_total_bytes: 4 * 1024 * 1024,
            maximum_object_count: 100,
        },
    )
    .unwrap()
}

fn storage_authority() -> WorkflowStorageExecutionAuthority {
    WorkflowStorageExecutionAuthority {
        installation_id: "installation-storage-001".into(),
        case_id: None,
    }
}

fn storage_workflow_source() -> Value {
    let ids = [
        "018f5300-0002-7000-8000-000000000002",
        "018f5300-0003-7000-8000-000000000003",
        "018f5300-0004-7000-8000-000000000004",
        "018f5300-0005-7000-8000-000000000005",
        "018f5300-0006-7000-8000-000000000006",
        "018f5300-0007-7000-8000-000000000007",
        "018f5300-0008-7000-8000-000000000008",
        "018f5300-0009-7000-8000-000000000009",
    ];
    let node = |index: usize, key: &str, node_type: &str, config: Value| {
        json!({
            "id": ids[index], "key": key, "name": key,
            "type": node_type, "typeVersion": 1, "config": config
        })
    };
    let edge = |sequence: u16, from: (usize, &str), to: (usize, &str)| {
        json!({
            "id": format!("018f5400-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": ids[from.0], "portId": from.1},
            "to": {"nodeId": ids[to.0], "portId": to.1},
            "mappingId": format!("018f5500-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    json!({
        "formatVersion": 1,
        "workflowId": STORAGE_WORKFLOW_ID,
        "packageId": "dev.kaname.storage-runtime",
        "name": "Scoped storage runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5300-0010-7000-8000-000000000010",
                "nodeId": ids[0]
            }],
            "nodes": [
                node(0, "manual", "trigger.manual", json!({})),
                node(1, "write-initial", "storage.write", json!({
                    "scope": "job", "key": "draft",
                    "value": {"root": "input", "pointer": "/draft"},
                    "conflictPolicy": "fail"
                })),
                node(2, "write-cas", "storage.write", json!({
                    "scope": "job", "key": "draft",
                    "value": {"root": "input", "pointer": ""},
                    "conflictPolicy": "compare-and-swap", "expectedRevision": 1
                })),
                node(3, "read", "storage.read", json!({
                    "operation": "read", "scope": "job", "key": "draft", "required": true
                })),
                node(4, "list", "storage.read", json!({
                    "operation": "list", "scope": "job", "key": "draft", "limit": 10
                })),
                node(5, "delete", "storage.write", json!({
                    "operation": "delete-reference", "scope": "job", "key": "draft",
                    "conflictPolicy": "compare-and-swap", "expectedRevision": 2
                })),
                node(6, "complete", "terminal.complete", json!({})),
                node(7, "fail", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(1, (0, "success"), (1, "input")),
                edge(2, (1, "success"), (2, "input")),
                edge(3, (2, "success"), (3, "input")),
                edge(4, (3, "success"), (4, "input")),
                edge(5, (4, "success"), (5, "input")),
                edge(6, (5, "success"), (6, "input")),
                edge(7, (1, "error"), (7, "input")),
                edge(8, (2, "error"), (7, "input")),
                edge(9, (3, "error"), (7, "input")),
                edge(10, (4, "error"), (7, "input")),
                edge(11, (5, "error"), (7, "input"))
            ]
        },
        "interfaces": {}, "resources": {}, "policies": {},
        "storage": {
            "draft": {
                "key": "draft", "scope": "job", "kind": "value",
                "schemaRef": "dev.kaname.storage/draft-v1",
                "maximumBytes": 65536, "classification": "private"
            }
        },
        "metadata": {}
    })
}

fn storage_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    input: Value,
) -> CommandEnvelope {
    let mut envelope = run_command(run_id, published, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.workflow_id = STORAGE_WORKFLOW_ID.into();
    request.revision_id = STORAGE_REVISION_ID.into();
    request.installation_id = "installation-storage-001".into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

fn workflow_source() -> Value {
    let node = |id: &str, key: &str, node_type: &str, config: Value| {
        json!({
            "id": id,
            "key": key,
            "name": key,
            "type": node_type,
            "typeVersion": 1,
            "config": config
        })
    };
    let edge = |sequence: u16, from: (&str, &str), to: (&str, &str)| {
        json!({
            "id": format!("018f5100-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": from.0, "portId": from.1},
            "to": {"nodeId": to.0, "portId": to.1},
            "mappingId": format!("018f5200-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    let case_port = format!("case-{CASE_FIVE_ID}");
    let otherwise_port = format!("case-{OTHERWISE_ID}");
    json!({
        "formatVersion": 1,
        "workflowId": WORKFLOW_ID,
        "packageId": "dev.kaname.minimal-runtime",
        "name": "Minimal durable runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5000-0011-7000-8000-000000000011",
                "nodeId": MANUAL_ID
            }],
            "nodes": [
                node(MANUAL_ID, "manual", "trigger.manual", json!({})),
                node(VALIDATE_ID, "validate", "data.validate", json!({
                    "schemaRef": "dev.kaname.minimal-input/v1"
                })),
                node(MATCH_ID, "match", "control.match", json!({
                    "value": {"root": "input", "pointer": ""},
                    "hitPolicy": "first",
                    "cases": [{
                        "id": CASE_FIVE_ID,
                        "key": "five",
                        "label": "Route five",
                        "when": {"compare": {
                            "left": {"root": "value", "pointer": "/route"},
                            "operator": "equal",
                            "right": {"literal": {"type": "number", "value": 5}}
                        }}
                    }],
                    "otherwise": {
                        "id": OTHERWISE_ID,
                        "key": "otherwise",
                        "label": "Otherwise"
                    }
                })),
                node(COMPLETE_MATCH_ID, "complete-five", "terminal.complete", json!({})),
                node(COMPLETE_OTHERWISE_ID, "complete-otherwise", "terminal.complete", json!({})),
                node(FAIL_VALIDATE_ID, "fail-validation", "terminal.fail", json!({})),
                node(FAIL_MATCH_ID, "fail-match", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(1, (MANUAL_ID, "success"), (VALIDATE_ID, "input")),
                edge(2, (VALIDATE_ID, "success"), (MATCH_ID, "input")),
                edge(3, (VALIDATE_ID, "error"), (FAIL_VALIDATE_ID, "input")),
                edge(4, (MATCH_ID, &case_port), (COMPLETE_MATCH_ID, "input")),
                edge(5, (MATCH_ID, &otherwise_port), (COMPLETE_OTHERWISE_ID, "input")),
                edge(6, (MATCH_ID, "error"), (FAIL_MATCH_ID, "input"))
            ]
        },
        "interfaces": {},
        "resources": {},
        "policies": {},
        "storage": {},
        "metadata": {}
    })
}

fn run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    input: Value,
) -> CommandEnvelope {
    let value = inline_value(&format!("value-{run_id}-input"), input);
    command(
        &format!("command-{run_id}"),
        &format!("idempotency-{run_id}"),
        WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE,
        RequestWorkflowRun {
            run_id: run_id.into(),
            workflow_id: WORKFLOW_ID.into(),
            revision_id: REVISION_ID.into(),
            package_digest: published.package_digest.clone(),
            trigger_kind: "manual".into(),
            trigger_event_id: String::new(),
            inputs: vec![WorkflowInputBinding {
                port_id: "input".into(),
                value: Some(value),
            }],
            installation_id: String::new(),
            case_id: String::new(),
        },
        1_786_220_100_000,
    )
}

fn cancel_command(run_id: &str, token_id: &str) -> CommandEnvelope {
    command(
        &format!("command-{run_id}-cancel"),
        &format!("idempotency-{run_id}-cancel"),
        WORKFLOW_RUN_CANCEL_KIND,
        WORKFLOW_RUN_CANCEL_TYPE,
        CancelWorkflowRun {
            run_id: run_id.into(),
            run_token_id: token_id.into(),
            reason_code: "owner-requested".into(),
        },
        1_786_220_100_100,
    )
}

fn command<M: Message>(
    command_id: &str,
    idempotency_key: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    submitted_at_unix_millis: i64,
) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: command_id.into(),
        idempotency_key: idempotency_key.into(),
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
            payload_version: 1,
        }),
        scope: Some(Scope {
            project_id: "project-kaname".into(),
            workspace_id: "workspace-local".into(),
            account_id: String::new(),
            authority_id: String::new(),
            egress_class: String::new(),
            destination_digest: String::new(),
        }),
        actor_id: "local-owner".into(),
        expected_revision: 0,
        submitted_at_unix_millis,
    }
}

fn inline_value(value_id: &str, value: Value) -> WorkflowValueReference {
    let bytes = serde_json_canonicalizer::to_vec(&value).unwrap();
    WorkflowValueReference {
        value_id: value_id.into(),
        content_type: "application/json".into(),
        byte_count: bytes.len() as u64,
        sha256: hex::encode(Sha256::digest(&bytes)),
        inline_canonical_json: bytes,
        storage_reference_id: String::new(),
        storage: None,
    }
}

fn run_wires(journal: &Journal, run_id: &str) -> Vec<Vec<u8>> {
    let page = journal
        .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
        .unwrap();
    assert_eq!(page.basis, ReplayBasis::Events);
    assert!(!page.has_more);
    page.events
        .into_iter()
        .map(|event| event.encode_to_vec())
        .collect()
}

fn run_token(journal: &Journal, run_id: &str) -> WorkflowRunTokenCreated {
    let page = journal
        .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
        .unwrap();
    let event = page
        .events
        .into_iter()
        .find(|event| event.kind == WORKFLOW_RUN_TOKEN_CREATED_KIND)
        .unwrap();
    WorkflowRunTokenCreated::decode(event.payload.unwrap().value.as_slice()).unwrap()
}
