use kaname_core::{
    open_workflow_library,
    workflow_drafts::{
        CreateWorkflowDraft, MAXIMUM_DRAFT_CHANGES_BEFORE_COMPACTION, SaveWorkflowDraft,
        WorkflowDraftFault,
    },
    workflow_library::WorkflowLibraryError,
};
use serde_json::Value;
use std::{collections::BTreeSet, fs, path::Path};
use tempfile::tempdir;

fn workflow_source(name: &str, nodes: &[(&str, &str)]) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "formatVersion": 1,
        "name": name,
        "graph": {
            "nodes": nodes.iter().map(|(id, label)| serde_json::json!({
                "id": id,
                "name": label,
                "type": "data.map",
                "typeVersion": 1,
                "config": {}
            })).collect::<Vec<_>>(),
            "edges": []
        }
    }))
    .unwrap()
}

fn layout_source(nodes: &[(&str, i64, i64)]) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "nodes": nodes.iter().map(|(id, x, y)| serde_json::json!({
            "nodeId": id,
            "x": x,
            "y": y
        })).collect::<Vec<_>>()
    }))
    .unwrap()
}

fn initial_request(workflow: Vec<u8>, layout: Vec<u8>) -> CreateWorkflowDraft {
    CreateWorkflowDraft {
        workflow_id: "workflow-draft-one".into(),
        package_id: "dev.kaname.workflow-draft-one".into(),
        name: "Draft one".into(),
        summary: "Synthetic draft persistence fixture".into(),
        edit_id: "edit-initial".into(),
        session_id: "session-one".into(),
        workflow_source: workflow,
        layout_source: layout,
        recorded_at_unix_millis: 1,
    }
}

fn save_request(
    expected: i64,
    edit: &str,
    workflow: Vec<u8>,
    layout: Vec<u8>,
) -> SaveWorkflowDraft {
    SaveWorkflowDraft {
        workflow_id: "workflow-draft-one".into(),
        expected_head_sequence: expected,
        edit_id: edit.into(),
        session_id: "session-one".into(),
        workflow_source: workflow,
        layout_source: layout,
        recorded_at_unix_millis: expected + 2,
    }
}

#[test]
fn draft_sources_survive_reopen_with_exact_bytes_and_private_layout() {
    let directory = tempdir().unwrap();
    let workflow = workflow_source("Initial", &[("node-a", "Start")]);
    let layout = layout_source(&[("node-a", 40, 80)]);
    let mut store = open_workflow_library(directory.path()).unwrap();
    let created = store
        .create_draft(initial_request(workflow.clone(), layout.clone()))
        .unwrap();
    assert_eq!(created.head_sequence, 0);
    assert_eq!(created.workflow_source, workflow);
    assert_eq!(created.layout_source, layout);
    drop(store);

    let mut reopened = open_workflow_library(directory.path()).unwrap();
    let loaded = reopened.load_draft("workflow-draft-one").unwrap();
    assert_eq!(loaded, created);
    let root = draft_root(directory.path());
    assert!(
        root.join("Checkpoints/00000000000000000000/workflow.json")
            .is_file()
    );
    assert!(
        root.join("Checkpoints/00000000000000000000/layout.json")
            .is_file()
    );
}

#[test]
fn simultaneous_edit_tokens_conflict_and_same_edit_retry_is_idempotent() {
    let directory = tempdir().unwrap();
    let mut creator = open_workflow_library(directory.path()).unwrap();
    creator
        .create_draft(initial_request(
            workflow_source("Initial", &[("node-a", "Start")]),
            layout_source(&[("node-a", 0, 0)]),
        ))
        .unwrap();
    drop(creator);

    let first_request = save_request(
        0,
        "edit-first",
        workflow_source("First writer", &[("node-a", "Start")]),
        layout_source(&[("node-a", 100, 0)]),
    );
    let second_request = save_request(
        0,
        "edit-second",
        workflow_source("Second writer", &[("node-a", "Start")]),
        layout_source(&[("node-a", 200, 0)]),
    );
    let mut first = open_workflow_library(directory.path()).unwrap();
    let mut second = open_workflow_library(directory.path()).unwrap();
    let saved = first.save_draft(first_request.clone()).unwrap();
    assert_eq!(saved.snapshot.head_sequence, 1);
    assert!(!saved.duplicate);
    assert!(matches!(
        second.save_draft(second_request),
        Err(WorkflowLibraryError::DraftConflict {
            expected: 0,
            actual: 1
        })
    ));

    let duplicate = first.save_draft(first_request).unwrap();
    assert!(duplicate.duplicate);
    assert_eq!(duplicate.snapshot.head_sequence, 1);
}

#[test]
fn crash_after_change_file_is_adopted_once_after_reopen() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(initial_request(
            workflow_source("Initial", &[("node-a", "Start")]),
            layout_source(&[("node-a", 0, 0)]),
        ))
        .unwrap();
    let changed_workflow = workflow_source("Recovered", &[("node-a", "Start")]);
    let changed_layout = layout_source(&[("node-a", 320, 40)]);
    assert!(matches!(
        store.save_draft_with_fault_for_test(
            save_request(
                0,
                "edit-before-crash",
                changed_workflow.clone(),
                changed_layout.clone()
            ),
            WorkflowDraftFault::AfterChangeFileBeforeDatabaseCommit,
        ),
        Err(WorkflowLibraryError::InjectedDraftInterruption)
    ));
    drop(store);

    let mut reopened = open_workflow_library(directory.path()).unwrap();
    let recovered = reopened.load_draft("workflow-draft-one").unwrap();
    assert_eq!(recovered.head_sequence, 1);
    assert_eq!(recovered.workflow_source, changed_workflow);
    assert_eq!(recovered.layout_source, changed_layout);
    assert!(recovered.recovered_interrupted_edit);
    assert!(
        !reopened
            .load_draft("workflow-draft-one")
            .unwrap()
            .recovered_interrupted_edit
    );
}

#[test]
fn corrupt_latest_change_is_quarantined_and_last_verified_edit_reopens() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(initial_request(
            workflow_source("Initial", &[("node-a", "Start")]),
            layout_source(&[("node-a", 0, 0)]),
        ))
        .unwrap();
    let verified_workflow = workflow_source("Verified", &[("node-a", "Start")]);
    let verified_layout = layout_source(&[("node-a", 10, 10)]);
    store
        .save_draft(save_request(
            0,
            "edit-verified",
            verified_workflow.clone(),
            verified_layout.clone(),
        ))
        .unwrap();
    store
        .save_draft(save_request(
            1,
            "edit-corrupt",
            workflow_source("Will corrupt", &[("node-a", "Start")]),
            layout_source(&[("node-a", 20, 20)]),
        ))
        .unwrap();
    drop(store);
    fs::write(
        draft_root(directory.path()).join("Changes/00000000000000000002.json"),
        b"corrupt change bytes",
    )
    .unwrap();

    let mut reopened = open_workflow_library(directory.path()).unwrap();
    let repaired = reopened.load_draft("workflow-draft-one").unwrap();
    assert_eq!(repaired.head_sequence, 1);
    assert_eq!(repaired.workflow_source, verified_workflow);
    assert_eq!(repaired.layout_source, verified_layout);
    assert_eq!(repaired.state, "recovery-required");
    assert!(repaired.recovered_corrupt_tail);
    assert!(has_quarantined_change(
        directory.path(),
        "00000000000000000002.json"
    ));
}

#[test]
fn change_history_compacts_to_a_bounded_reopenable_window() {
    let directory = tempdir().unwrap();
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(initial_request(
            workflow_source("Version 0", &[("node-a", "Start")]),
            layout_source(&[("node-a", 0, 0)]),
        ))
        .unwrap();
    for sequence in 1..=70 {
        store
            .save_draft(save_request(
                sequence - 1,
                &format!("edit-{sequence}"),
                workflow_source(&format!("Version {sequence}"), &[("node-a", "Start")]),
                layout_source(&[("node-a", sequence, sequence * 2)]),
            ))
            .unwrap();
    }

    let current = store.load_draft("workflow-draft-one").unwrap();
    let retained = store
        .retained_draft_sequences("workflow-draft-one")
        .unwrap();
    assert_eq!(current.head_sequence, 70);
    assert!(
        current.head_sequence - current.checkpoint_sequence
            <= MAXIMUM_DRAFT_CHANGES_BEFORE_COMPACTION
    );
    assert_eq!(retained.first(), Some(&current.checkpoint_sequence));
    assert_eq!(retained.last(), Some(&70));
    assert!(matches!(
        store.load_draft_at("workflow-draft-one", current.checkpoint_sequence - 1),
        Err(WorkflowLibraryError::InvalidDraft("sequence_not_retained"))
    ));
    let checkpoint = store
        .load_draft_at("workflow-draft-one", current.checkpoint_sequence)
        .unwrap();
    assert!(
        String::from_utf8(checkpoint.workflow_source)
            .unwrap()
            .contains(&format!("Version {}", current.checkpoint_sequence))
    );
    drop(store);

    let mut reopened = open_workflow_library(directory.path()).unwrap();
    assert_eq!(reopened.load_draft("workflow-draft-one").unwrap(), current);
    assert!(checkpoint_directory_count(directory.path()) <= 2);
}

#[test]
fn canvas_outline_and_source_read_the_same_persisted_graph_and_layout() {
    let directory = tempdir().unwrap();
    let workflow = workflow_source(
        "Converged",
        &[("node-a", "Receive"), ("node-b", "Classify")],
    );
    let layout = layout_source(&[("node-a", 40, 80), ("node-b", 420, 80)]);
    let mut store = open_workflow_library(directory.path()).unwrap();
    store
        .create_draft(initial_request(workflow.clone(), layout.clone()))
        .unwrap();
    let persisted = store.load_draft("workflow-draft-one").unwrap();

    let source_workflow: Value = serde_json::from_slice(&persisted.workflow_source).unwrap();
    let source_layout: Value = serde_json::from_slice(&persisted.layout_source).unwrap();
    let outline_ids = source_workflow["graph"]["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["id"].as_str().unwrap().to_owned())
        .collect::<BTreeSet<_>>();
    let canvas_ids = source_layout["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["nodeId"].as_str().unwrap().to_owned())
        .collect::<BTreeSet<_>>();
    assert_eq!(outline_ids, canvas_ids);
    assert_eq!(persisted.workflow_source, workflow);
    assert_eq!(persisted.layout_source, layout);
}

fn draft_root(application_support: &Path) -> std::path::PathBuf {
    application_support.join("Workflows/Drafts/workflow-draft-one")
}

fn has_quarantined_change(application_support: &Path, name: &str) -> bool {
    let recovery = application_support.join("Workflows/Recovery/Drafts/workflow-draft-one");
    fs::read_dir(recovery)
        .unwrap()
        .filter_map(|entry| entry.ok())
        .any(|entry| entry.path().join(name).is_file())
}

fn checkpoint_directory_count(application_support: &Path) -> usize {
    fs::read_dir(draft_root(application_support).join("Checkpoints"))
        .unwrap()
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_dir())
        .count()
}
