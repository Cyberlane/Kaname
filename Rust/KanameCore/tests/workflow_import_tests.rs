use kaname_core::{
    open_workflow_library,
    workflow_drafts::{CreateWorkflowDraft, SaveWorkflowDraft},
    workflow_import::{ImportFrozenWorkflowDraft, ImportFrozenWorkspace},
    workflow_library::WorkflowLibraryError,
    workflow_publication::PublishWorkflowRevision,
    workflow_versions::{WorkflowExecutionSupport, WorkflowPortfolioState},
};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::fs;
use tempfile::tempdir;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[test]
fn frozen_workspace_import_is_sorted_read_only_and_idempotent() {
    let directory = tempdir().unwrap();
    let source = br#"{"version":26,"unchanged":"legacy-workspace"}"#.to_vec();
    let before = source.clone();
    let request = import_request(&source);
    let mut store = open_workflow_library(directory.path()).unwrap();

    let first = store.import_frozen_workspace(request.clone()).unwrap();
    assert_eq!(source, before);
    assert_eq!(first.outcome, "blocked");
    assert!(!first.duplicate);
    assert_eq!(
        first
            .workflows
            .iter()
            .map(|item| item.workflow_id.as_str())
            .collect::<Vec<_>>(),
        vec!["workflow-a", "workflow-b"]
    );
    assert!(!first.workflows[0].blocked);
    assert!(first.workflows[1].blocked);

    let portfolio = store.workflow_portfolio("active").unwrap();
    assert_eq!(portfolio.len(), 2);
    assert!(portfolio.iter().all(|item| {
        item.state == WorkflowPortfolioState::Draft
            && item.has_draft
            && item.execution_support == Some(WorkflowExecutionSupport::Unsupported)
    }));
    let frozen = store.load_draft("workflow-a").unwrap();
    assert_eq!(frozen.state, "unsupported");
    assert!(matches!(
        store.save_draft(SaveWorkflowDraft {
            workflow_id: "workflow-a".into(),
            expected_head_sequence: 0,
            edit_id: "edit-after-import".into(),
            session_id: "fixture".into(),
            workflow_source: workflow_source("workflow-a", "dev.kaname.a", "A", "Alpha"),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 101,
        }),
        Err(WorkflowLibraryError::InvalidDraft("draft_read_only"))
    ));
    assert!(matches!(
        store.publish_revision(PublishWorkflowRevision {
            workflow_id: "workflow-a".into(),
            expected_draft_sequence: 0,
            revision_id: "revision-imported".into(),
            registration_id: "registration-imported".into(),
            release_version: "0.0.0-imported".into(),
            schema_bundle_json: b"{}".to_vec(),
            dependency_lock_json: b"{}".to_vec(),
            configuration_contract_json: b"{}".to_vec(),
            published_at_unix_millis: 102,
        }),
        Err(WorkflowLibraryError::InvalidDraft("draft_not_publishable"))
    ));

    let second = store.import_frozen_workspace(request).unwrap();
    assert!(second.duplicate);
    assert_eq!(second.outcome, first.outcome);
    assert_eq!(second.comparison_digest, first.comparison_digest);
    assert_eq!(second.workflows, first.workflows);

    let connection = Connection::open(
        directory
            .path()
            .join("Workflows")
            .join("workflow-library.sqlite"),
    )
    .unwrap();
    let receipt_count: i64 = connection
        .query_row("SELECT COUNT(*) FROM import_receipts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(receipt_count, 1);

    #[cfg(unix)]
    {
        let import_root = directory
            .path()
            .join("Workflows")
            .join("Imports")
            .join(source_digest(&source));
        assert_eq!(
            fs::metadata(&import_root).unwrap().permissions().mode() & 0o777,
            0o500
        );
        assert_eq!(
            fs::metadata(import_root.join("receipt.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o400
        );
    }
}

#[test]
fn duplicate_import_fails_closed_if_frozen_comparison_evidence_changes() {
    let directory = tempdir().unwrap();
    let source = b"frozen-workspace".to_vec();
    let request = import_request(&source);
    let mut store = open_workflow_library(directory.path()).unwrap();
    store.import_frozen_workspace(request.clone()).unwrap();
    let comparison = directory
        .path()
        .join("Workflows")
        .join("Imports")
        .join(source_digest(&source))
        .join("comparison-workflow-a.json");
    #[cfg(unix)]
    fs::set_permissions(&comparison, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&comparison, b"{}").unwrap();

    assert!(matches!(
        store.import_frozen_workspace(request),
        Err(WorkflowLibraryError::ImportConflict(code)) if code == "comparison_bundle"
    ));
}

#[test]
fn malformed_or_ambiguous_imports_create_no_library_identity() {
    let directory = tempdir().unwrap();
    let source = b"frozen-workspace".to_vec();
    let mut request = import_request(&source);
    request.drafts[0].workflow_source =
        workflow_source("different-workflow", "dev.kaname.a", "A", "Alpha");
    let mut store = open_workflow_library(directory.path()).unwrap();
    assert!(matches!(
        store.import_frozen_workspace(request),
        Err(WorkflowLibraryError::InvalidImport("workflow_identity"))
    ));
    assert!(store.workflow_portfolio("active").unwrap().is_empty());

    let mut duplicate = import_request(&source);
    duplicate.drafts[1].workflow_id = duplicate.drafts[0].workflow_id.clone();
    assert!(matches!(
        store.import_frozen_workspace(duplicate),
        Err(WorkflowLibraryError::InvalidImport(
            "workflow_identity" | "duplicate_workflow_id"
        ))
    ));
    assert!(store.workflow_portfolio("active").unwrap().is_empty());

    let mut duplicate_package = import_request(&source);
    duplicate_package.drafts[1].package_id = duplicate_package.drafts[0].package_id.clone();
    duplicate_package.drafts[1].workflow_source =
        workflow_source("workflow-a", "dev.kaname.b", "A", "Alpha");
    assert!(matches!(
        store.import_frozen_workspace(duplicate_package),
        Err(WorkflowLibraryError::InvalidImport("duplicate_package_id"))
    ));
    assert!(store.workflow_portfolio("active").unwrap().is_empty());
}

#[test]
fn import_never_freezes_an_existing_editable_draft() {
    let directory = tempdir().unwrap();
    let source = b"frozen-workspace".to_vec();
    let request = import_request(&source);
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(CreateWorkflowDraft {
            workflow_id: "workflow-a".into(),
            package_id: "dev.kaname.a".into(),
            name: "A".into(),
            summary: "Alpha".into(),
            edit_id: "existing-edit".into(),
            session_id: "existing-session".into(),
            workflow_source: workflow_source("workflow-a", "dev.kaname.a", "A", "Alpha"),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 50,
        })
        .unwrap();

    assert!(matches!(
        store.import_frozen_workspace(request),
        Err(WorkflowLibraryError::ImportConflict(code)) if code == "existing_draft_changed"
    ));
    assert_eq!(store.load_draft("workflow-a").unwrap().state, "editable");
    assert!(
        !directory
            .path()
            .join("Workflows")
            .join("Imports")
            .join(source_digest(&source))
            .exists()
    );

    let package_directory = tempdir().unwrap();
    let mut package_store = open_workflow_library(package_directory.path()).unwrap();
    package_store
        .create_draft(CreateWorkflowDraft {
            workflow_id: "existing-workflow".into(),
            package_id: "dev.kaname.a".into(),
            name: "Existing".into(),
            summary: "Existing package owner".into(),
            edit_id: "existing-package-edit".into(),
            session_id: "existing-session".into(),
            workflow_source: workflow_source(
                "existing-workflow",
                "dev.kaname.a",
                "Existing",
                "Existing package owner",
            ),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 50,
        })
        .unwrap();
    assert!(matches!(
        package_store.import_frozen_workspace(import_request(&source)),
        Err(WorkflowLibraryError::ImportConflict(code)) if code == "existing_package_changed"
    ));
    assert_eq!(
        package_store.load_draft("existing-workflow").unwrap().state,
        "editable"
    );
}

#[test]
fn import_recovers_an_exact_bundle_and_drafts_when_receipt_commit_was_interrupted() {
    let directory = tempdir().unwrap();
    let source = b"frozen-workspace".to_vec();
    let request = import_request(&source);
    let mut store = open_workflow_library(directory.path()).unwrap();
    store.import_frozen_workspace(request.clone()).unwrap();
    let connection = Connection::open(
        directory
            .path()
            .join("Workflows")
            .join("workflow-library.sqlite"),
    )
    .unwrap();
    connection
        .execute("DELETE FROM import_receipts", [])
        .unwrap();
    drop(connection);

    let recovered = store.import_frozen_workspace(request).unwrap();
    assert!(!recovered.duplicate);
    assert_eq!(recovered.outcome, "blocked");
    assert!(
        recovered
            .workflows
            .iter()
            .all(|item| store.load_draft(&item.workflow_id).unwrap().state == "unsupported")
    );
}

#[test]
fn receipt_identity_cannot_be_reused_for_another_snapshot() {
    let directory = tempdir().unwrap();
    let first = import_request(b"frozen-workspace-one");
    let mut second = import_request(b"frozen-workspace-two");
    second.receipt_id = first.receipt_id.clone();
    let mut store = open_workflow_library(directory.path()).unwrap();
    store.import_frozen_workspace(first).unwrap();

    assert!(matches!(
        store.import_frozen_workspace(second),
        Err(WorkflowLibraryError::ImportConflict(code)) if code == "receipt_identity"
    ));
}

fn import_request(source: &[u8]) -> ImportFrozenWorkspace {
    let digest = source_digest(source);
    ImportFrozenWorkspace {
        receipt_id: format!("workspace-{}", &digest[..24]),
        source_digest: digest.clone(),
        imported_at_unix_millis: 100,
        drafts: vec![
            imported_draft("workflow-b", "dev.kaname.b", "B", "Beta", &digest, true),
            imported_draft("workflow-a", "dev.kaname.a", "A", "Alpha", &digest, false),
        ],
    }
}

fn imported_draft(
    workflow_id: &str,
    package_id: &str,
    name: &str,
    summary: &str,
    workspace_digest: &str,
    blocked: bool,
) -> ImportFrozenWorkflowDraft {
    ImportFrozenWorkflowDraft {
        workflow_id: workflow_id.into(),
        package_id: package_id.into(),
        name: name.into(),
        summary: summary.into(),
        workflow_source: workflow_source(workflow_id, package_id, name, summary),
        layout_source: br#"{"nodes":[]}"#.to_vec(),
        comparison_source: format!(
            "{{\"blocking\":{blocked},\"losses\":[],\"workflowId\":\"{workflow_id}\",\"workspaceSourceDigest\":\"{workspace_digest}\"}}"
        )
        .into_bytes(),
        blocked,
    }
}

fn workflow_source(workflow_id: &str, package_id: &str, name: &str, summary: &str) -> Vec<u8> {
    format!(
        "{{\"formatVersion\":1,\"graph\":{{\"edges\":[],\"entrypoints\":[],\"nodes\":[]}},\"interfaces\":{{}},\"metadata\":{{\"legacyImport\":true,\"readOnly\":true}},\"name\":\"{name}\",\"packageId\":\"{package_id}\",\"policies\":{{}},\"resources\":{{}},\"storage\":{{}},\"summary\":\"{summary}\",\"workflowId\":\"{workflow_id}\"}}"
    )
    .into_bytes()
}

fn source_digest(source: &[u8]) -> String {
    hex::encode(Sha256::digest(source))
}
