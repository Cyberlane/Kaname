use kaname_core::{
    journal::Journal,
    v1::{
        EventEnvelope, EventProvenance, EvidenceRetentionClass, OpaqueTypedPayload, SchemaVersion,
        WorkflowAttemptOutcome, WorkflowAttemptSettled, WorkflowAttemptStarted,
        WorkflowEdgeCheckpointState, WorkflowEdgeCheckpointed, WorkflowMatchTraceRecorded,
        WorkflowPortEmitted, WorkflowRunCancellationRequested, WorkflowRunOutcome,
        WorkflowRunRetentionMode, WorkflowRunRetentionPolicy, WorkflowRunSettled,
        WorkflowRunTokenCreated, WorkflowValueReference,
    },
    workflow_projection::{
        WorkflowProjectionError, WorkflowProjectionFault, WorkflowRunProjection,
    },
    workflow_runtime::{
        WORKFLOW_ATTEMPT_SETTLED_KIND, WORKFLOW_ATTEMPT_SETTLED_TYPE,
        WORKFLOW_ATTEMPT_STARTED_KIND, WORKFLOW_ATTEMPT_STARTED_TYPE,
        WORKFLOW_EDGE_CHECKPOINTED_KIND, WORKFLOW_EDGE_CHECKPOINTED_TYPE,
        WORKFLOW_MATCH_TRACE_RECORDED_KIND, WORKFLOW_MATCH_TRACE_RECORDED_TYPE,
        WORKFLOW_PORT_EMITTED_KIND, WORKFLOW_PORT_EMITTED_TYPE,
        WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND, WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE,
        WORKFLOW_RUN_SETTLED_KIND, WORKFLOW_RUN_SETTLED_TYPE, WORKFLOW_RUN_TOKEN_CREATED_KIND,
        WORKFLOW_RUN_TOKEN_CREATED_TYPE,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x42; 32];
const RUN_ID: &str = "run-projection-001";
const TOKEN_ID: &str = "run-token-projection-001";

#[test]
fn replay_twice_and_rebuild_from_zero_are_byte_identical() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_complete_corpus(&mut journal);

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    let first = projection.catch_up(&journal).unwrap();
    assert_eq!(first.previous_high_water_mark, 0);
    assert_eq!(first.high_water_mark, first.journal_high_water_mark);
    assert_eq!(first.projected_event_count, 12);
    assert_eq!(projection.row_count("runs").unwrap(), 2);
    assert_eq!(projection.row_count("attempts").unwrap(), 2);
    assert_eq!(projection.row_count("nodes").unwrap(), 2);
    assert_eq!(projection.row_count("emissions").unwrap(), 1);
    assert_eq!(projection.row_count("edges").unwrap(), 1);
    assert_eq!(projection.row_count("matches").unwrap(), 1);
    assert_eq!(projection.row_count("values").unwrap(), 2);
    let expected = projection.canonical_snapshot().unwrap();

    projection.rewind_checkpoint_for_test(0).unwrap();
    let second = projection.catch_up(&journal).unwrap();
    assert_eq!(second.scanned_event_count, 13);
    assert_eq!(second.projected_event_count, 0);
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);

    let third = projection.catch_up(&journal).unwrap();
    assert_eq!(third.scanned_event_count, 0);

    projection.rebuild_from_zero(&journal).unwrap();
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
}

#[test]
fn persisted_projection_resumes_after_a_batch_and_rolls_back_mid_batch() {
    let directory = tempdir().unwrap();
    let journal_path = directory.path().join("journal.sqlite");
    let projection_path = directory.path().join("run-projection.sqlite");
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    append_complete_corpus(&mut journal);

    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
    let first_batch = projection.catch_up_batch(&journal, 4).unwrap();
    assert_eq!(first_batch.scanned_event_count, 4);
    assert!(first_batch.has_more);
    let checkpoint = projection.high_water_mark().unwrap();
    let before_interruption = projection.canonical_snapshot().unwrap();
    drop(projection);

    let mut reopened = WorkflowRunProjection::open(&projection_path).unwrap();
    assert_eq!(reopened.high_water_mark().unwrap(), checkpoint);
    assert!(matches!(
        reopened.catch_up_batch_with_fault_for_test(
            &journal,
            4,
            WorkflowProjectionFault::AfterScannedEvent(2),
        ),
        Err(WorkflowProjectionError::InjectedInterruption)
    ));
    assert_eq!(reopened.high_water_mark().unwrap(), checkpoint);
    assert_eq!(reopened.canonical_snapshot().unwrap(), before_interruption);
    reopened.catch_up(&journal).unwrap();

    let mut rebuilt = WorkflowRunProjection::open_in_memory().unwrap();
    rebuilt.catch_up(&journal).unwrap();
    assert_eq!(
        reopened.canonical_snapshot().unwrap(),
        rebuilt.canonical_snapshot().unwrap()
    );
}

#[test]
fn version_one_projection_migrates_storage_lineage_columns_in_place() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("workflow-projection.sqlite");
    {
        let projection = WorkflowRunProjection::open(&path).unwrap();
        assert_eq!(projection.high_water_mark().unwrap(), 0);
    }
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "ALTER TABLE workflow_values DROP COLUMN storage_source_version_id;
             ALTER TABLE workflow_values DROP COLUMN storage_result;
             ALTER TABLE workflow_values DROP COLUMN storage_previous_version_id;
             ALTER TABLE workflow_values DROP COLUMN storage_revision;
             ALTER TABLE workflow_values DROP COLUMN storage_version_id;
             ALTER TABLE workflow_values DROP COLUMN storage_logical_key;
             ALTER TABLE workflow_values DROP COLUMN storage_scope;
             ALTER TABLE workflow_values DROP COLUMN storage_handle_id;
             PRAGMA user_version = 1;",
        )
        .unwrap();
    drop(connection);

    let projection = WorkflowRunProjection::open(&path).unwrap();
    assert_eq!(projection.high_water_mark().unwrap(), 0);
    projection.integrity_check().unwrap();
}

#[test]
fn version_thirteen_projection_adds_effect_authority_without_rebuild() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("workflow-projection.sqlite");
    {
        let projection = WorkflowRunProjection::open(&path).unwrap();
        assert_eq!(projection.high_water_mark().unwrap(), 0);
    }
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "DROP TABLE workflow_effect_authorities;
             PRAGMA user_version = 13;",
        )
        .unwrap();
    drop(connection);

    let projection = WorkflowRunProjection::open(&path).unwrap();
    assert_eq!(projection.row_count("effect_authorities").unwrap(), 0);
    projection.integrity_check().unwrap();
}

#[test]
fn corrupt_logical_projection_is_detected_and_rebuilt_from_the_journal() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_complete_corpus(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let expected = projection.canonical_snapshot().unwrap();

    projection.corrupt_first_run_for_test().unwrap();
    assert!(matches!(
        projection.integrity_check(),
        Err(WorkflowProjectionError::Integrity(code)) if code == "state_digest_mismatch"
    ));
    assert!(projection.verify_or_rebuild(&journal).unwrap());
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
}

#[test]
fn physically_corrupt_projection_is_quarantined_before_rebuild() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("run-projection.sqlite");
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_complete_corpus(&mut journal);
    let expected = {
        let mut projection = WorkflowRunProjection::open(&path).unwrap();
        projection.catch_up(&journal).unwrap();
        projection.canonical_snapshot().unwrap()
    };

    std::fs::write(&path, b"not-a-sqlite-projection").unwrap();
    let (projection, rebuilt) = WorkflowRunProjection::open_or_rebuild(&path, &journal).unwrap();
    assert!(rebuilt);
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
    assert!(
        directory
            .path()
            .join("run-projection.sqlite.corrupt-01")
            .is_file()
    );
}

#[test]
fn invalid_lifecycle_rolls_back_the_entire_projection_batch() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    journal
        .append_event(runtime_event(
            "event-token-invalid",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                request_command_id: "command-invalid".into(),
                workflow_id: "workflow-invalid".into(),
                revision_id: "revision-invalid".into(),
                package_digest: "e".repeat(64),
                retention_policy: None,
            },
            "command-invalid",
            RUN_ID,
            1,
        ))
        .unwrap();
    journal
        .append_event(runtime_event(
            "event-settle-without-start",
            WORKFLOW_ATTEMPT_SETTLED_KIND,
            WORKFLOW_ATTEMPT_SETTLED_TYPE,
            WorkflowAttemptSettled {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-missing".into(),
                node_id: "node-missing".into(),
                attempt_number: 1,
                outcome: WorkflowAttemptOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                emission_ids: Vec::new(),
                execution_token_id: String::new(),
            },
            "event-token-invalid",
            RUN_ID,
            2,
        ))
        .unwrap();

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    assert!(matches!(
        projection.catch_up(&journal),
        Err(WorkflowProjectionError::Lifecycle(code)) if code == "attempt_missing"
    ));
    assert_eq!(projection.high_water_mark().unwrap(), 0);
    assert_eq!(projection.row_count("runs").unwrap(), 0);
    assert_eq!(projection.row_count("events").unwrap(), 0);
    projection.integrity_check().unwrap();
}

#[test]
fn inspection_returns_revision_pinned_grouped_evidence_and_explains_absence() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_complete_corpus(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();

    let recent = projection
        .inspect_runs(Some("workflow-001"), None, 10)
        .unwrap();
    assert_eq!(recent.len(), 2);
    assert_eq!(recent[0].run_id, "run-projection-002");
    assert_eq!(recent[1].revision_id, "revision-006");

    let run = projection
        .inspect_runs_as_of(None, Some(RUN_ID), 1, 1_080)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(run.status, "succeeded");
    assert_eq!(run.attempts.len(), 2);
    assert_eq!(run.nodes.len(), 2);
    assert_eq!(run.emissions.len(), 1);
    assert_eq!(
        run.emissions[0]
            .value
            .as_ref()
            .unwrap()
            .inline_canonical_json,
        br#"{"route":5}"#
    );
    assert_eq!(run.edges[0].target_node_id, "complete");
    assert_eq!(run.match_traces[0].matched_case_ids, ["case-five"]);
    assert_eq!(run.events.len(), 9);
    assert_eq!(run.events[0].kind, WORKFLOW_RUN_TOKEN_CREATED_KIND);
    let policy = run.retention_policy.as_ref().unwrap();
    assert_eq!(
        policy.mode,
        WorkflowRunRetentionMode::DeleteAfterSuccess as i32
    );
    assert_eq!(policy.days, 0);
    let preview = run.purge_preview.as_ref().unwrap();
    assert!(preview.manual_eligible);
    assert!(preview.automatic_eligible);
    assert_eq!(preview.automatic_eligible_at_unix_millis, 1_080);
    assert_eq!(preview.affected_attempt_ids.len(), 2);
    assert_eq!(preview.affected_value_ids.len(), 2);
    assert!(preview.affected_value_bytes > 0);
    assert_eq!(preview.evidence_digest.len(), 64);
    assert!(
        projection
            .inspect_runs(None, Some("purged-run"), 1)
            .unwrap()
            .is_empty()
    );
    assert!(matches!(
        projection.inspect_runs(None, None, 0),
        Err(WorkflowProjectionError::Integrity(code)) if code == "inspection_limit_out_of_bounds"
    ));
}

fn append_complete_corpus(journal: &mut Journal) {
    journal
        .append_event(EventEnvelope {
            schema_version: Some(schema_version()),
            event_id: "event-unrelated".into(),
            stream_id: "thread:projection-fixture".into(),
            stream_sequence: 0,
            store_position: 0,
            occurred_at_unix_millis: 900,
            kind: "task.queued".into(),
            payload: None,
            correlation_id: "projection-fixture".into(),
            causation_id: "command-unrelated".into(),
            provenance: None,
        })
        .unwrap();

    let output = inline_value("value-output", br#"{"route":5}"#);
    let trace = inline_value(
        "value-match-trace",
        br#"{"evaluated":["case-five"],"matched":["case-five"]}"#,
    );
    let events = vec![
        runtime_event(
            "event-token-001",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                request_command_id: "command-run-001".into(),
                workflow_id: "workflow-001".into(),
                revision_id: "revision-006".into(),
                package_digest: "a".repeat(64),
                retention_policy: Some(WorkflowRunRetentionPolicy {
                    mode: WorkflowRunRetentionMode::DeleteAfterSuccess as i32,
                    days: 0,
                }),
            },
            "command-run-001",
            RUN_ID,
            1_000,
        ),
        runtime_event(
            "event-attempt-start-001",
            WORKFLOW_ATTEMPT_STARTED_KIND,
            WORKFLOW_ATTEMPT_STARTED_TYPE,
            WorkflowAttemptStarted {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-match-001".into(),
                node_id: "match-route".into(),
                attempt_number: 1,
                execution_token_id: String::new(),
            },
            "event-token-001",
            RUN_ID,
            1_010,
        ),
        runtime_event(
            "event-port-001",
            WORKFLOW_PORT_EMITTED_KIND,
            WORKFLOW_PORT_EMITTED_TYPE,
            WorkflowPortEmitted {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                emission_id: "emission-route-five".into(),
                attempt_id: "attempt-match-001".into(),
                node_id: "match-route".into(),
                port_id: "case-five".into(),
                value: Some(output),
                execution_token_id: String::new(),
            },
            "event-attempt-start-001",
            RUN_ID,
            1_020,
        ),
        runtime_event(
            "event-match-001",
            WORKFLOW_MATCH_TRACE_RECORDED_KIND,
            WORKFLOW_MATCH_TRACE_RECORDED_TYPE,
            WorkflowMatchTraceRecorded {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-match-001".into(),
                node_id: "match-route".into(),
                input_value_id: "value-input".into(),
                evaluated_case_ids: vec!["case-five".into()],
                matched_case_ids: vec!["case-five".into()],
                emitted_port_ids: vec!["case-five".into()],
                trace: Some(trace),
                execution_token_id: String::new(),
            },
            "event-port-001",
            RUN_ID,
            1_030,
        ),
        runtime_event(
            "event-edge-001",
            WORKFLOW_EDGE_CHECKPOINTED_KIND,
            WORKFLOW_EDGE_CHECKPOINTED_TYPE,
            WorkflowEdgeCheckpointed {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                edge_id: "edge-match-complete".into(),
                emission_id: "emission-route-five".into(),
                target_node_id: "complete".into(),
                target_port_id: "input".into(),
                state: WorkflowEdgeCheckpointState::Admitted as i32,
                execution_token_id: String::new(),
            },
            "event-port-001",
            RUN_ID,
            1_040,
        ),
        runtime_event(
            "event-attempt-settle-001",
            WORKFLOW_ATTEMPT_SETTLED_KIND,
            WORKFLOW_ATTEMPT_SETTLED_TYPE,
            WorkflowAttemptSettled {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-match-001".into(),
                node_id: "match-route".into(),
                attempt_number: 1,
                outcome: WorkflowAttemptOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                emission_ids: vec!["emission-route-five".into()],
                execution_token_id: String::new(),
            },
            "event-edge-001",
            RUN_ID,
            1_050,
        ),
        runtime_event(
            "event-attempt-start-002",
            WORKFLOW_ATTEMPT_STARTED_KIND,
            WORKFLOW_ATTEMPT_STARTED_TYPE,
            WorkflowAttemptStarted {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-complete-001".into(),
                node_id: "complete".into(),
                attempt_number: 1,
                execution_token_id: String::new(),
            },
            "event-attempt-settle-001",
            RUN_ID,
            1_060,
        ),
        runtime_event(
            "event-attempt-settle-002",
            WORKFLOW_ATTEMPT_SETTLED_KIND,
            WORKFLOW_ATTEMPT_SETTLED_TYPE,
            WorkflowAttemptSettled {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: "attempt-complete-001".into(),
                node_id: "complete".into(),
                attempt_number: 1,
                outcome: WorkflowAttemptOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                emission_ids: Vec::new(),
                execution_token_id: String::new(),
            },
            "event-attempt-start-002",
            RUN_ID,
            1_070,
        ),
        runtime_event(
            "event-run-settle-001",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                outcome: WorkflowRunOutcome::Succeeded as i32,
                error_code: String::new(),
                error: None,
                final_emission_ids: vec!["emission-route-five".into()],
            },
            "event-attempt-settle-002",
            RUN_ID,
            1_080,
        ),
        runtime_event(
            "event-token-002",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: "run-projection-002".into(),
                run_token_id: "run-token-projection-002".into(),
                request_command_id: "command-run-002".into(),
                workflow_id: "workflow-001".into(),
                revision_id: "revision-006".into(),
                package_digest: "a".repeat(64),
                retention_policy: None,
            },
            "command-run-002",
            "run-projection-002",
            2_000,
        ),
        runtime_event(
            "event-cancel-002",
            WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND,
            WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE,
            WorkflowRunCancellationRequested {
                run_id: "run-projection-002".into(),
                run_token_id: "run-token-projection-002".into(),
                cancel_command_id: "command-cancel-002".into(),
                reason_code: "owner-requested".into(),
            },
            "command-cancel-002",
            "run-projection-002",
            2_010,
        ),
        runtime_event(
            "event-run-settle-002",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: "run-projection-002".into(),
                run_token_id: "run-token-projection-002".into(),
                outcome: WorkflowRunOutcome::Cancelled as i32,
                error_code: "owner-requested".into(),
                error: None,
                final_emission_ids: Vec::new(),
            },
            "event-cancel-002",
            "run-projection-002",
            2_020,
        ),
    ];
    for event in events {
        journal.append_event(event).unwrap();
    }
}

fn runtime_event<M: Message>(
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    run_id: &str,
    occurred_at_unix_millis: i64,
) -> EventEnvelope {
    EventEnvelope {
        schema_version: Some(schema_version()),
        event_id: event_id.into(),
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        store_position: 0,
        occurred_at_unix_millis,
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: type_url.into(),
            value: payload.encode_to_vec(),
            content_type: "application/x-protobuf".into(),
            payload_version: 1,
        }),
        correlation_id: run_id.into(),
        causation_id: causation_id.into(),
        provenance: Some(EventProvenance {
            source_kind: "workflow-runtime".into(),
            provider_instance_id: String::new(),
            native_type: String::new(),
            native_cursor: Vec::new(),
            raw_evidence_digest: String::new(),
            retention_class: EvidenceRetentionClass::None as i32,
        }),
    }
}

fn inline_value(value_id: &str, bytes: &[u8]) -> WorkflowValueReference {
    WorkflowValueReference {
        value_id: value_id.into(),
        content_type: "application/json".into(),
        byte_count: bytes.len() as u64,
        sha256: hex::encode(Sha256::digest(bytes)),
        inline_canonical_json: bytes.to_vec(),
        storage_reference_id: String::new(),
        storage: None,
    }
}

fn schema_version() -> SchemaVersion {
    SchemaVersion { major: 1, minor: 0 }
}
