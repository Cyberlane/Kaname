use kaname_core::{
    open_workflow_library,
    workflow_drafts::{CreateWorkflowDraft, SaveWorkflowDraft},
    workflow_library::{WorkflowLibraryError, WorkflowLibraryStore},
    workflow_publication::{PublishWorkflowRevision, WorkflowPublicationFault},
};
use rusqlite::Connection;
use serde_json::Value;
use std::{fs, path::Path};
use tempfile::tempdir;

const WORKFLOW_ID: &str = "990d4e21-b85c-7e04-975e-7cf6ba1f83b0";

fn fixture_workflow() -> Vec<u8> {
    fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Fixtures/workflow-v2/legacy-import-terminal-v1.json"),
    )
    .unwrap()
}

fn fixture_layout() -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "nodes": [
            {
                "nodeId": "ee3b3ec0-ead6-7897-a63f-e5ff53fdf605",
                "x": 40,
                "y": 80
            },
            {
                "nodeId": "7c0afb84-421e-7656-838e-22e631841203",
                "x": 420,
                "y": 80
            }
        ]
    }))
    .unwrap()
}

fn create_draft(store: &mut WorkflowLibraryStore) {
    store
        .create_draft(CreateWorkflowDraft {
            workflow_id: WORKFLOW_ID.into(),
            package_id: "org.example.legacy-portable".into(),
            name: "Portable legacy workflow".into(),
            summary: "Synthetic publication fixture".into(),
            edit_id: "initial-edit".into(),
            session_id: "publication-test".into(),
            workflow_source: fixture_workflow(),
            layout_source: fixture_layout(),
            recorded_at_unix_millis: 10,
        })
        .unwrap();
}

fn publish_request(revision_id: &str, registration_id: &str) -> PublishWorkflowRevision {
    PublishWorkflowRevision {
        workflow_id: WORKFLOW_ID.into(),
        expected_draft_sequence: 0,
        revision_id: revision_id.into(),
        registration_id: registration_id.into(),
        release_version: "1.0.0".into(),
        schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
        dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
        configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
        published_at_unix_millis: 20,
    }
}

#[test]
fn publish_writes_verified_immutable_bundle_without_activation_or_draft_mutation() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    create_draft(&mut store);
    let draft_before = store.load_draft(WORKFLOW_ID).unwrap();
    let published = store
        .publish_revision(publish_request("revision-one", "registration-one"))
        .unwrap();
    assert_eq!(published.revision_number, 1);
    assert!(!published.duplicate);
    assert_eq!(
        store.verify_published_revision("revision-one").unwrap(),
        published
    );
    assert_eq!(store.load_draft(WORKFLOW_ID).unwrap(), draft_before);

    let bundle = directory
        .path()
        .join("Workflows")
        .join(&published.bundle_relative_path);
    let manifest: Value =
        serde_json::from_slice(&fs::read(bundle.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["revisionNumber"], 1);
    assert_eq!(manifest["files"].as_array().unwrap().len(), 7);
    for name in [
        "workflow.json",
        "layout.json",
        "compiled.json",
        "lock.json",
        "schemas/bundle.json",
        "schemas/configuration.json",
        "validation.json",
        "manifest.json",
    ] {
        assert!(bundle.join(name).is_file(), "{name}");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(bundle.join("workflow.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
        assert_eq!(
            fs::metadata(&bundle).unwrap().permissions().mode() & 0o777,
            0o500
        );
    }
    assert_eq!(table_count(directory.path(), "activation_aliases"), 0);
    assert_eq!(table_count(directory.path(), "workflow_revisions"), 1);
}

#[test]
fn every_publication_crash_boundary_recovers_to_zero_or_one_valid_revision() {
    let faults = [
        WorkflowPublicationFault::BeforeStagingWrite,
        WorkflowPublicationFault::AfterStagingWriteBeforeFsync,
        WorkflowPublicationFault::AfterStagingFsyncBeforeRename,
        WorkflowPublicationFault::AfterRenameBeforeRegistration,
        WorkflowPublicationFault::AfterRegistrationCommit,
    ];
    for (index, fault) in faults.into_iter().enumerate() {
        let directory = tempdir().unwrap();
        let mut store = open_workflow_library(directory.path()).unwrap();
        create_draft(&mut store);
        let revision_id = format!("revision-fault-{index}");
        let registration_id = format!("registration-fault-{index}");
        let request = publish_request(&revision_id, &registration_id);
        assert!(matches!(
            store.publish_revision_with_fault_for_test(request.clone(), fault),
            Err(WorkflowLibraryError::InjectedPublicationInterruption(_))
        ));
        let committed_before_retry = table_count(directory.path(), "workflow_revisions");
        assert_eq!(
            committed_before_retry,
            usize::from(fault == WorkflowPublicationFault::AfterRegistrationCommit)
        );
        drop(store);

        let mut reopened = open_workflow_library(directory.path()).unwrap();
        let recovered = reopened.publish_revision(request).unwrap();
        assert_eq!(recovered.revision_number, 1);
        assert_eq!(table_count(directory.path(), "workflow_revisions"), 1);
        reopened.verify_published_revision(&revision_id).unwrap();
        if fault == WorkflowPublicationFault::AfterRegistrationCommit {
            assert!(recovered.duplicate);
        }
    }
}

#[test]
fn partial_staging_bundle_is_quarantined_before_clean_retry() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    create_draft(&mut store);
    let request = publish_request("revision-partial", "registration-partial");
    assert!(matches!(
        store.publish_revision_with_fault_for_test(
            request.clone(),
            WorkflowPublicationFault::AfterStagingWriteBeforeFsync,
        ),
        Err(WorkflowLibraryError::InjectedPublicationInterruption(_))
    ));
    let staging = directory.path().join(format!(
        "Workflows/Staging/Revisions/{WORKFLOW_ID}-1-revision-partial.staging"
    ));
    fs::remove_file(staging.join("compiled.json")).unwrap();

    let published = store.publish_revision(request).unwrap();
    store
        .verify_published_revision(&published.revision_id)
        .unwrap();
    let recovery = directory.path().join("Workflows/Recovery/Revisions");
    assert_eq!(
        fs::read_dir(recovery)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .count(),
        1
    );
}

#[test]
fn invalid_draft_never_creates_staging_revision_or_registration() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(CreateWorkflowDraft {
            workflow_id: "invalid-workflow".into(),
            package_id: "dev.kaname.invalid".into(),
            name: "Invalid".into(),
            summary: String::new(),
            edit_id: "initial-edit".into(),
            session_id: "publication-test".into(),
            workflow_source: br#"{"formatVersion":1}"#.to_vec(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 1,
        })
        .unwrap();
    let mut request = publish_request("revision-invalid", "registration-invalid");
    request.workflow_id = "invalid-workflow".into();
    assert!(matches!(
        store.publish_revision(request),
        Err(WorkflowLibraryError::WorkflowCompilationFailed(_))
    ));
    assert_eq!(table_count(directory.path(), "workflow_revisions"), 0);
    assert!(
        !directory
            .path()
            .join("Workflows/Staging/Revisions")
            .exists()
    );
}

#[test]
fn later_publication_cannot_change_an_earlier_revision() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    create_draft(&mut store);
    let first = store
        .publish_revision(publish_request("revision-one", "registration-one"))
        .unwrap();
    let first_bundle = directory
        .path()
        .join("Workflows")
        .join(&first.bundle_relative_path);
    let first_snapshot = bundle_snapshot(&first_bundle);

    let mut changed_workflow: Value = serde_json::from_slice(&fixture_workflow()).unwrap();
    changed_workflow["summary"] = Value::String("Published as revision two".into());
    store
        .save_draft(SaveWorkflowDraft {
            workflow_id: WORKFLOW_ID.into(),
            expected_head_sequence: 0,
            edit_id: "second-edit".into(),
            session_id: "publication-test".into(),
            workflow_source: serde_json::to_vec(&changed_workflow).unwrap(),
            layout_source: fixture_layout(),
            recorded_at_unix_millis: 30,
        })
        .unwrap();
    let mut request = publish_request("revision-two", "registration-two");
    request.expected_draft_sequence = 1;
    request.release_version = "1.1.0".into();
    request.published_at_unix_millis = 40;
    let second = store.publish_revision(request).unwrap();

    assert_eq!(second.revision_number, 2);
    assert_ne!(first.package_digest, second.package_digest);
    assert_eq!(bundle_snapshot(&first_bundle), first_snapshot);
    assert_eq!(
        store.verify_published_revision("revision-one").unwrap(),
        first
    );
    assert_eq!(table_count(directory.path(), "workflow_revisions"), 2);
}

#[test]
fn reused_revision_identity_or_tampered_bundle_is_rejected() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    create_draft(&mut store);
    let published = store
        .publish_revision(publish_request("revision-one", "registration-one"))
        .unwrap();
    let mut changed_retry = publish_request("revision-one", "different-registration");
    changed_retry.published_at_unix_millis = 21;
    assert!(matches!(
        store.publish_revision(changed_retry),
        Err(WorkflowLibraryError::PublicationConflict(ref code))
            if code == "revision_identity_reused"
    ));

    let workflow_path = directory
        .path()
        .join("Workflows")
        .join(&published.bundle_relative_path)
        .join("workflow.json");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&workflow_path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fs::write(&workflow_path, b"{}\n").unwrap();
    assert!(matches!(
        store.verify_published_revision("revision-one"),
        Err(WorkflowLibraryError::InvalidRevisionBundle(ref code))
            if code == "file_digest_mismatch"
    ));
}

fn bundle_snapshot(directory: &Path) -> Vec<(String, Vec<u8>)> {
    let mut pending = vec![directory.to_path_buf()];
    let mut snapshot = Vec::new();
    while let Some(current) = pending.pop() {
        for entry in fs::read_dir(current).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else {
                snapshot.push((
                    path.strip_prefix(directory)
                        .unwrap()
                        .to_string_lossy()
                        .to_string(),
                    fs::read(path).unwrap(),
                ));
            }
        }
    }
    snapshot.sort_by(|left, right| left.0.cmp(&right.0));
    snapshot
}

fn table_count(application_support: &Path, table: &str) -> usize {
    assert!(matches!(table, "activation_aliases" | "workflow_revisions"));
    let connection =
        Connection::open(application_support.join("Workflows/workflow-library.sqlite")).unwrap();
    connection
        .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap() as usize
}
