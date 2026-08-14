use kaname_core::{
    journal::{Journal, JournalError},
    v1::{
        CancelWorkflowRun, CommandEnvelope, EventEnvelope, EventProvenance, EvidenceRetentionClass,
        OpaqueTypedPayload, RequestWorkflowRun, SchemaVersion, Scope, SignalWorkflowWait,
        WorkflowAttemptOutcome, WorkflowAttemptSettled, WorkflowAttemptStarted,
        WorkflowEdgeCheckpointState, WorkflowEdgeCheckpointed, WorkflowInputBinding,
        WorkflowJoinDecision, WorkflowJoinEvaluated, WorkflowMatchTraceRecorded,
        WorkflowPortEmitted, WorkflowRunCancellationRequested, WorkflowRunOutcome,
        WorkflowRunSettled, WorkflowRunTokenCreated, WorkflowValueReference,
        WorkflowWaitCorrelation, WorkflowWaitDecision, WorkflowWaitResolved,
        WorkflowWaitSignalRecorded, WorkflowWaitSubscribed,
    },
    workflow_runtime::{
        WORKFLOW_ATTEMPT_SETTLED_KIND, WORKFLOW_ATTEMPT_SETTLED_TYPE,
        WORKFLOW_ATTEMPT_STARTED_KIND, WORKFLOW_ATTEMPT_STARTED_TYPE,
        WORKFLOW_EDGE_CHECKPOINTED_KIND, WORKFLOW_EDGE_CHECKPOINTED_TYPE,
        WORKFLOW_JOIN_EVALUATED_KIND, WORKFLOW_JOIN_EVALUATED_TYPE,
        WORKFLOW_MATCH_TRACE_RECORDED_KIND, WORKFLOW_MATCH_TRACE_RECORDED_TYPE,
        WORKFLOW_PORT_EMITTED_KIND, WORKFLOW_PORT_EMITTED_TYPE, WORKFLOW_RUN_CANCEL_KIND,
        WORKFLOW_RUN_CANCEL_TYPE, WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND,
        WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE, WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE, WORKFLOW_RUN_SETTLED_KIND, WORKFLOW_RUN_SETTLED_TYPE,
        WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_RUN_TOKEN_CREATED_TYPE,
        WORKFLOW_WAIT_RESOLVED_KIND, WORKFLOW_WAIT_RESOLVED_TYPE, WORKFLOW_WAIT_SIGNAL_KIND,
        WORKFLOW_WAIT_SIGNAL_RECORDED_KIND, WORKFLOW_WAIT_SIGNAL_RECORDED_TYPE,
        WORKFLOW_WAIT_SIGNAL_TYPE, WORKFLOW_WAIT_SUBSCRIBED_KIND, WORKFLOW_WAIT_SUBSCRIBED_TYPE,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x71; 32];
const RUN_ID: &str = "run-001";
const TOKEN_ID: &str = "run-token-001";

#[test]
fn workflow_commands_are_typed_bounded_and_idempotent() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let request = request_command("command-run-001", "workflow-run-key-001");
    let first = journal.admit_command(&request).unwrap();
    let duplicate = journal.admit_command(&request).unwrap();
    assert_eq!(duplicate, first);

    let cancel = cancel_command(
        "command-cancel-001",
        "workflow-cancel-key-001",
        RUN_ID,
        TOKEN_ID,
    );
    assert_eq!(
        journal.admit_command(&cancel).unwrap().command_id,
        "command-cancel-001"
    );

    let mut reused = cancel;
    reused.command_id = "command-cancel-002".into();
    reused.idempotency_key = request.idempotency_key;
    assert!(matches!(
        journal.admit_command(&reused),
        Err(JournalError::Integrity(code)) if code == "idempotency_key_reused"
    ));
}

#[test]
fn wait_commands_and_subscription_lifecycle_are_typed_and_bounded() {
    let correlation = vec![WorkflowWaitCorrelation {
        key: "input:/caseId".into(),
        sha256: "b".repeat(64),
    }];
    let signal_value = inline_value("value-signal", br#"{"caseId":"case-42"}"#);
    let signal = command_envelope(
        "command-signal-001",
        "wait-signal-key-001",
        WORKFLOW_WAIT_SIGNAL_KIND,
        WORKFLOW_WAIT_SIGNAL_TYPE,
        SignalWorkflowWait {
            run_id: RUN_ID.into(),
            signal_id: "signal-001".into(),
            kind: "reply".into(),
            owner_kind: "workflow".into(),
            owner_id: "workflow-001".into(),
            correlation: correlation.clone(),
            value: Some(signal_value.clone()),
        },
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        journal.admit_command(&signal).unwrap().command_id,
        "command-signal-001"
    );
    for event in [
        runtime_event(
            "event-signal-001",
            WORKFLOW_WAIT_SIGNAL_RECORDED_KIND,
            WORKFLOW_WAIT_SIGNAL_RECORDED_TYPE,
            WorkflowWaitSignalRecorded {
                run_id: RUN_ID.into(),
                signal_id: "signal-001".into(),
                signal_command_id: "command-signal-001".into(),
                kind: "reply".into(),
                owner_kind: "workflow".into(),
                owner_id: "workflow-001".into(),
                correlation: correlation.clone(),
                value: Some(signal_value.clone()),
            },
            "command-signal-001",
            RUN_ID,
        ),
        runtime_event(
            "event-wait-subscribed-001",
            WORKFLOW_WAIT_SUBSCRIBED_KIND,
            WORKFLOW_WAIT_SUBSCRIBED_TYPE,
            WorkflowWaitSubscribed {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                subscription_id: "subscription-001".into(),
                wait_node_id: "wait-reply".into(),
                execution_token_id: "execution-token-001".into(),
                controller_attempt_id: "attempt-wait-001".into(),
                workflow_id: "workflow-001".into(),
                revision_id: "revision-001".into(),
                package_digest: "a".repeat(64),
                kind: "reply".into(),
                owner_kind: "workflow".into(),
                owner_id: "workflow-001".into(),
                correlation: correlation.clone(),
                input_value_id: "value-input".into(),
                input_sha256: "c".repeat(64),
                expires_at_unix_millis: 1_786_220_060_000,
            },
            "attempt-wait-001",
            RUN_ID,
        ),
        runtime_event(
            "event-wait-resolved-001",
            WORKFLOW_WAIT_RESOLVED_KIND,
            WORKFLOW_WAIT_RESOLVED_TYPE,
            WorkflowWaitResolved {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                subscription_id: "subscription-001".into(),
                decision: WorkflowWaitDecision::Resumed as i32,
                signal_id: "signal-001".into(),
                output: Some(signal_value),
                reason_code: String::new(),
            },
            "event-signal-001",
            RUN_ID,
        ),
    ] {
        journal.append_event(event).unwrap();
    }

    let mut unordered = signal;
    unordered.command_id = "command-signal-invalid".into();
    unordered.idempotency_key = "wait-signal-invalid".into();
    let mut payload =
        SignalWorkflowWait::decode(unordered.payload.as_ref().unwrap().value.as_slice()).unwrap();
    payload.correlation = vec![
        WorkflowWaitCorrelation {
            key: "input:/z".into(),
            sha256: "d".repeat(64),
        },
        WorkflowWaitCorrelation {
            key: "input:/a".into(),
            sha256: "e".repeat(64),
        },
    ];
    unordered.payload.as_mut().unwrap().value = payload.encode_to_vec();
    assert_invalid_command(&mut journal, unordered);
}

#[test]
fn every_runtime_event_round_trips_through_the_journal_after_restart() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("workflow-runtime.sqlite");
    let mut journal = Journal::open(&path, &CURSOR_KEY).unwrap();
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
                revision_id: "revision-001".into(),
                package_digest: "a".repeat(64),
            },
            "command-run-001",
            RUN_ID,
        ),
        runtime_event(
            "event-attempt-started-001",
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
            "event-attempt-started-001",
            RUN_ID,
        ),
        runtime_event(
            "event-match-trace-001",
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
        ),
        runtime_event(
            "event-attempt-settled-001",
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
        ),
        runtime_event(
            "event-run-settled-001",
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
            "event-attempt-settled-001",
            RUN_ID,
        ),
    ];
    let mut positioned_wires = Vec::new();
    for event in &events {
        positioned_wires.push(
            journal
                .append_event(event.clone())
                .unwrap()
                .event
                .encode_to_vec(),
        );
    }
    assert!(
        journal
            .append_received_wire(&positioned_wires[0])
            .unwrap()
            .duplicate
    );

    let cancel_run = "run-002";
    let cancel_token = "run-token-002";
    let cancellation = runtime_event(
        "event-cancellation-002",
        WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND,
        WORKFLOW_RUN_CANCELLATION_REQUESTED_TYPE,
        WorkflowRunCancellationRequested {
            run_id: cancel_run.into(),
            run_token_id: cancel_token.into(),
            cancel_command_id: "command-cancel-002".into(),
            reason_code: "owner-requested".into(),
        },
        "command-cancel-002",
        cancel_run,
    );
    journal.append_event(cancellation).unwrap();
    journal
        .append_event(runtime_event(
            "event-run-settled-002",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: cancel_run.into(),
                run_token_id: cancel_token.into(),
                outcome: WorkflowRunOutcome::Cancelled as i32,
                error_code: "owner-requested".into(),
                error: None,
                final_emission_ids: Vec::new(),
            },
            "event-cancellation-002",
            cancel_run,
        ))
        .unwrap();
    drop(journal);

    let reopened = Journal::open(&path, &CURSOR_KEY).unwrap();
    let replay = reopened
        .replay("thread:workflow-run:run-001", None, 100)
        .unwrap();
    assert_eq!(replay.events.len(), events.len());
    assert_eq!(
        replay
            .events
            .iter()
            .map(Message::encode_to_vec)
            .collect::<Vec<_>>(),
        positioned_wires
    );
    assert_eq!(
        replay
            .events
            .iter()
            .map(|event| event.kind.as_str())
            .collect::<Vec<_>>(),
        events
            .iter()
            .map(|event| event.kind.as_str())
            .collect::<Vec<_>>()
    );
    let settled = WorkflowRunSettled::decode(
        replay
            .events
            .last()
            .unwrap()
            .payload
            .as_ref()
            .unwrap()
            .value
            .as_slice(),
    )
    .unwrap();
    assert_eq!(settled.outcome, WorkflowRunOutcome::Succeeded as i32);

    let cancelled = reopened
        .replay("thread:workflow-run:run-002", None, 100)
        .unwrap();
    assert_eq!(cancelled.events.len(), 2);
    assert_eq!(
        cancelled.events[0].kind,
        WORKFLOW_RUN_CANCELLATION_REQUESTED_KIND
    );
    assert_eq!(cancelled.events[1].kind, WORKFLOW_RUN_SETTLED_KIND);
}

#[test]
fn malformed_runtime_contracts_fail_before_journal_mutation() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let mut missing_scope = request_command("command-invalid-001", "invalid-key-001");
    missing_scope.scope = None;
    assert_invalid_command(&mut journal, missing_scope);

    let mut wrong_type = request_command("command-invalid-002", "invalid-key-002");
    wrong_type.payload.as_mut().unwrap().type_url = WORKFLOW_RUN_CANCEL_TYPE.into();
    assert_invalid_command(&mut journal, wrong_type);

    let mut unknown_kind = request_command("command-invalid-003", "invalid-key-003");
    unknown_kind.kind = "workflow.run.unknown".into();
    assert_invalid_command(&mut journal, unknown_kind);

    let malformed_value = WorkflowValueReference {
        value_id: "bad-value".into(),
        content_type: "application/json".into(),
        byte_count: 2,
        sha256: "b".repeat(64),
        inline_canonical_json: b"{}".to_vec(),
        storage_reference_id: String::new(),
        storage: None,
    };
    let malformed_event = runtime_event(
        "event-invalid-value",
        WORKFLOW_PORT_EMITTED_KIND,
        WORKFLOW_PORT_EMITTED_TYPE,
        WorkflowPortEmitted {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            emission_id: "emission-invalid".into(),
            attempt_id: "attempt-invalid".into(),
            node_id: "node-invalid".into(),
            port_id: "success".into(),
            value: Some(malformed_value),
            execution_token_id: String::new(),
        },
        "event-attempt-invalid",
        RUN_ID,
    );
    assert_invalid_event(&mut journal, malformed_event);

    let mut wrong_stream = valid_token_event();
    wrong_stream.stream_id = "workflow-run:another-run".into();
    assert_invalid_event(&mut journal, wrong_stream);

    let mut provider_provenance = valid_token_event();
    provider_provenance
        .provenance
        .as_mut()
        .unwrap()
        .provider_instance_id = "gmail-live".into();
    assert_invalid_event(&mut journal, provider_provenance);

    let mut oversized_payload = valid_token_event();
    oversized_payload.payload.as_mut().unwrap().value = vec![0; 48 * 1024 + 1];
    assert_invalid_event(&mut journal, oversized_payload);

    let oversized_json = format!("\"{}\"", "a".repeat(32 * 1024));
    let oversized_inline = runtime_event(
        "event-oversized-inline",
        WORKFLOW_PORT_EMITTED_KIND,
        WORKFLOW_PORT_EMITTED_TYPE,
        WorkflowPortEmitted {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            emission_id: "emission-oversized".into(),
            attempt_id: "attempt-oversized".into(),
            node_id: "node-oversized".into(),
            port_id: "success".into(),
            value: Some(inline_value("oversized", oversized_json.as_bytes())),
            execution_token_id: String::new(),
        },
        "event-attempt-oversized",
        RUN_ID,
    );
    assert_invalid_event(&mut journal, oversized_inline);

    let oversized_trace = runtime_event(
        "event-oversized-trace",
        WORKFLOW_MATCH_TRACE_RECORDED_KIND,
        WORKFLOW_MATCH_TRACE_RECORDED_TYPE,
        WorkflowMatchTraceRecorded {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            attempt_id: "attempt-match".into(),
            node_id: "match".into(),
            input_value_id: "input".into(),
            evaluated_case_ids: (0..257).map(|index| format!("case-{index}")).collect(),
            matched_case_ids: Vec::new(),
            emitted_port_ids: vec!["otherwise".into()],
            trace: Some(inline_value("trace", b"{}")),
            execution_token_id: String::new(),
        },
        "event-attempt-match",
        RUN_ID,
    );
    assert_invalid_event(&mut journal, oversized_trace);

    let contradictory_join = runtime_event(
        "event-invalid-join",
        WORKFLOW_JOIN_EVALUATED_KIND,
        WORKFLOW_JOIN_EVALUATED_TYPE,
        WorkflowJoinEvaluated {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            join_node_id: "join-001".into(),
            fork_node_id: "fork-001".into(),
            resumed_execution_token_id: "execution-resumed-001".into(),
            policy: "any".into(),
            threshold: 1,
            decision: WorkflowJoinDecision::Failed as i32,
            expected_execution_token_ids: vec!["execution-left".into(), "execution-right".into()],
            arrived_execution_token_ids: vec!["execution-left".into()],
            failed_execution_token_ids: Vec::new(),
            pending_execution_token_ids: vec!["execution-right".into()],
            cancel_remaining: false,
            error_code: "join.any-unreachable".into(),
        },
        "event-fork-001",
        RUN_ID,
    );
    assert_invalid_event(&mut journal, contradictory_join);

    assert!(
        journal
            .replay("thread:workflow-run:run-001", None, 100)
            .unwrap()
            .events
            .is_empty()
    );
}

fn request_command(command_id: &str, idempotency_key: &str) -> CommandEnvelope {
    let request = RequestWorkflowRun {
        run_id: RUN_ID.into(),
        workflow_id: "workflow-001".into(),
        revision_id: "revision-001".into(),
        package_digest: "a".repeat(64),
        trigger_kind: "manual".into(),
        trigger_event_id: String::new(),
        inputs: vec![WorkflowInputBinding {
            port_id: "input".into(),
            value: Some(inline_value("value-input", br#"{"value":5}"#)),
        }],
        installation_id: String::new(),
        case_id: String::new(),
    };
    command_envelope(
        command_id,
        idempotency_key,
        WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE,
        request,
    )
}

fn cancel_command(
    command_id: &str,
    idempotency_key: &str,
    run_id: &str,
    run_token_id: &str,
) -> CommandEnvelope {
    command_envelope(
        command_id,
        idempotency_key,
        WORKFLOW_RUN_CANCEL_KIND,
        WORKFLOW_RUN_CANCEL_TYPE,
        CancelWorkflowRun {
            run_id: run_id.into(),
            run_token_id: run_token_id.into(),
            reason_code: "owner-requested".into(),
        },
    )
}

fn command_envelope<M: Message>(
    command_id: &str,
    idempotency_key: &str,
    kind: &str,
    type_url: &str,
    payload: M,
) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(schema_version()),
        command_id: command_id.into(),
        idempotency_key: idempotency_key.into(),
        kind: kind.into(),
        payload: Some(typed_payload(type_url, payload)),
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
        submitted_at_unix_millis: 1_786_220_000_000,
    }
}

fn runtime_event<M: Message>(
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    run_id: &str,
) -> EventEnvelope {
    EventEnvelope {
        schema_version: Some(schema_version()),
        event_id: event_id.into(),
        store_position: 0,
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        occurred_at_unix_millis: 1_786_220_000_000,
        kind: kind.into(),
        payload: Some(typed_payload(type_url, payload)),
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

fn valid_token_event() -> EventEnvelope {
    runtime_event(
        "event-token-valid",
        WORKFLOW_RUN_TOKEN_CREATED_KIND,
        WORKFLOW_RUN_TOKEN_CREATED_TYPE,
        WorkflowRunTokenCreated {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            request_command_id: "command-run-001".into(),
            workflow_id: "workflow-001".into(),
            revision_id: "revision-001".into(),
            package_digest: "a".repeat(64),
        },
        "command-run-001",
        RUN_ID,
    )
}

fn typed_payload<M: Message>(type_url: &str, payload: M) -> OpaqueTypedPayload {
    OpaqueTypedPayload {
        type_url: type_url.into(),
        content_type: "application/x-protobuf".into(),
        value: payload.encode_to_vec(),
        payload_version: 1,
    }
}

fn inline_value(value_id: &str, json: &[u8]) -> WorkflowValueReference {
    WorkflowValueReference {
        value_id: value_id.into(),
        content_type: "application/json".into(),
        byte_count: json.len() as u64,
        sha256: hex::encode(Sha256::digest(json)),
        inline_canonical_json: json.to_vec(),
        storage_reference_id: String::new(),
        storage: None,
    }
}

fn schema_version() -> SchemaVersion {
    SchemaVersion { major: 1, minor: 0 }
}

fn assert_invalid_command(journal: &mut Journal, command: CommandEnvelope) {
    assert!(matches!(
        journal.admit_command(&command),
        Err(JournalError::Protocol("invalid_workflow_runtime_command"))
    ));
}

fn assert_invalid_event(journal: &mut Journal, event: EventEnvelope) {
    assert!(matches!(
        journal.append_event(event),
        Err(JournalError::Protocol("invalid_workflow_runtime_event"))
    ));
}
