use kaname_core::{
    journal::Journal,
    v1::{
        BeginWorkflowConnectorObservationRequest, EventEnvelope, EventProvenance,
        EvidenceRetentionClass, OpaqueTypedPayload, SchemaVersion,
        SettleWorkflowConnectorObservationRequest, WorkflowConnectorObservationIntent,
        WorkflowConnectorObservationOutcome, WorkflowConnectorObservationReceipt,
        WorkflowConnectorObservationRegistration, WorkflowConnectorObservationSettled,
        WorkflowRunOutcome, WorkflowRunSettled, WorkflowRunTokenCreated, WorkflowValueReference,
    },
    workflow_connector_observation::{
        WorkflowConnectorObservationError, begin_workflow_connector_observation,
        settle_workflow_connector_observation,
    },
    workflow_projection::WorkflowRunProjection,
    workflow_runtime::{
        WORKFLOW_RUN_SETTLED_KIND, WORKFLOW_RUN_SETTLED_TYPE, WORKFLOW_RUN_TOKEN_CREATED_KIND,
        WORKFLOW_RUN_TOKEN_CREATED_TYPE, workflow_connector_observation_registration_digest,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x81; 32];
const RUN_ID: &str = "run-connector-observation";
const TOKEN_ID: &str = "token-connector-observation";

#[test]
fn read_only_observation_is_restart_safe_idempotent_and_rebuildable() {
    let directory = tempdir().unwrap();
    let journal_path = directory.path().join("journal.sqlite");
    let projection_path = directory.path().join("projection.sqlite");
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    append_active_run(&mut journal);
    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();

    let started = begin_workflow_connector_observation(
        &mut journal,
        &mut projection,
        begin_request("begin-one"),
    )
    .unwrap();
    assert!(!started.duplicate);
    assert_eq!(started.status, "started");
    assert_eq!(projection.row_count("connector_observations").unwrap(), 1);

    drop(projection);
    drop(journal);
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
    let resumed = begin_workflow_connector_observation(
        &mut journal,
        &mut projection,
        begin_request("begin-after-restart"),
    )
    .unwrap();
    assert!(resumed.duplicate);
    assert_eq!(resumed.status, "started");

    let settled = settle_workflow_connector_observation(
        &mut journal,
        &mut projection,
        settle_request("settle-one"),
    )
    .unwrap();
    assert!(!settled.duplicate);
    assert_eq!(settled.status, "succeeded");
    assert_eq!(
        settled
            .settlement
            .as_ref()
            .unwrap()
            .receipt
            .as_ref()
            .unwrap()
            .observed_fields,
        requested_fields()
    );

    assert!(
        settle_workflow_connector_observation(
            &mut journal,
            &mut projection,
            settle_request("settle-duplicate"),
        )
        .unwrap()
        .duplicate
    );
    let terminal_begin = begin_workflow_connector_observation(
        &mut journal,
        &mut projection,
        begin_request("begin-terminal"),
    )
    .unwrap();
    assert!(terminal_begin.duplicate);
    assert_eq!(terminal_begin.status, "succeeded");

    let expected = projection.canonical_snapshot().unwrap();
    projection.rebuild_from_zero(&journal).unwrap();
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
    let inspected =
        &projection.inspect_runs(None, Some(RUN_ID), 1).unwrap()[0].connector_observations[0];
    assert_eq!(inspected.status, "succeeded");
    assert!(inspected.settlement.is_some());
}

#[test]
fn identity_drift_and_excluded_fields_fail_before_journal_mutation() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_run(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    begin_workflow_connector_observation(
        &mut journal,
        &mut projection,
        begin_request("begin-original"),
    )
    .unwrap();
    let before = journal.event_page_after(0, 100).unwrap().high_water_mark;

    let mut changed = begin_request("begin-changed");
    changed.intent.as_mut().unwrap().target_fingerprint = "9".repeat(64);
    assert!(matches!(
        begin_workflow_connector_observation(&mut journal, &mut projection, changed),
        Err(WorkflowConnectorObservationError::Invalid(
            "connector_observation_identity_reuse"
        ))
    ));

    let mut excluded = begin_request("begin-body");
    excluded.intent.as_mut().unwrap().observation_id = "observation-body".into();
    excluded.intent.as_mut().unwrap().idempotency_key = "observation-body".into();
    excluded.intent.as_mut().unwrap().requested_fields = vec!["body".into()];
    excluded.registration.as_mut().unwrap().allowed_fields = vec!["body".into()];
    excluded.registration.as_mut().unwrap().registration_digest = String::new();
    let registration = excluded.registration.as_mut().unwrap();
    registration.registration_digest =
        workflow_connector_observation_registration_digest(registration);
    assert!(matches!(
        begin_workflow_connector_observation(&mut journal, &mut projection, excluded),
        Err(WorkflowConnectorObservationError::Invalid(
            "connector_observation_requested_fields"
        ))
    ));
    assert_eq!(
        journal.event_page_after(0, 100).unwrap().high_water_mark,
        before
    );
}

#[test]
fn run_cannot_settle_while_a_connector_observation_is_in_flight() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_run(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    begin_workflow_connector_observation(
        &mut journal,
        &mut projection,
        begin_request("begin-before-run-settlement"),
    )
    .unwrap();
    journal
        .append_event(runtime_event(
            "event-observation-run-settled-too-early",
            WORKFLOW_RUN_SETTLED_KIND,
            WORKFLOW_RUN_SETTLED_TYPE,
            WorkflowRunSettled {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                outcome: WorkflowRunOutcome::Succeeded as i32,
                final_emission_ids: Vec::new(),
                error_code: String::new(),
                error: None,
            },
        ))
        .unwrap();

    assert!(matches!(
        projection.catch_up(&journal),
        Err(kaname_core::workflow_projection::WorkflowProjectionError::Lifecycle(code))
            if code == "run_has_active_connector_observations"
    ));
}

fn begin_request(request_id: &str) -> BeginWorkflowConnectorObservationRequest {
    BeginWorkflowConnectorObservationRequest {
        schema_version: schema_version(),
        request_id: request_id.into(),
        intent: Some(WorkflowConnectorObservationIntent {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            observation_id: "observation-mail-metadata".into(),
            connector_class: "kaname.mail".into(),
            account_binding_id: "binding-mail-qualification".into(),
            operation: "read.metadata".into(),
            target_fingerprint: "7".repeat(64),
            idempotency_key: "observation-mail-metadata".into(),
            requested_fields: requested_fields(),
            request: Some(value(
                "observation-request",
                br#"{"accountBinding":"binding-mail-qualification","target":"opaque-thread"}"#,
            )),
        }),
        registration: Some(registration()),
        started_at_unix_millis: 2_000,
    }
}

fn settle_request(request_id: &str) -> SettleWorkflowConnectorObservationRequest {
    let output = value(
        "observation-output",
        br#"{"cursor":"105","messages":[{"headers":{"Date":"Today","From":"sender@example.test"},"id":"opaque-message","labels":["INBOX"]}],"target":"opaque-thread"}"#,
    );
    SettleWorkflowConnectorObservationRequest {
        schema_version: schema_version(),
        request_id: request_id.into(),
        settlement: Some(WorkflowConnectorObservationSettled {
            run_id: RUN_ID.into(),
            run_token_id: TOKEN_ID.into(),
            observation_id: "observation-mail-metadata".into(),
            intent_digest:
                kaname_core::workflow_runtime::workflow_connector_observation_intent_digest(
                    begin_request("digest").intent.as_ref().unwrap(),
                ),
            outcome: WorkflowConnectorObservationOutcome::Succeeded as i32,
            output: Some(output.clone()),
            error_code: String::new(),
            error: None,
            receipt: Some(WorkflowConnectorObservationReceipt {
                receipt_id: "receipt-mail-metadata".into(),
                evidence_digest: output.sha256.clone(),
                observed_fields: requested_fields(),
                item_count: 1,
                result_byte_count: output.byte_count,
            }),
            elapsed_milliseconds: 25,
            idempotency_key: "observation-mail-metadata".into(),
        }),
        settled_at_unix_millis: 2_025,
    }
}

fn registration() -> WorkflowConnectorObservationRegistration {
    let mut registration = WorkflowConnectorObservationRegistration {
        connector_class: "kaname.mail".into(),
        account_binding_id: "binding-mail-qualification".into(),
        binding_id: "binding-installation-mail-qualification".into(),
        connector_version: "1.0.0".into(),
        installation_digest: "8".repeat(64),
        allowed_operations: vec!["read.metadata".into()],
        allowed_fields: requested_fields(),
        maximum_result_bytes: 32 * 1_024,
        registration_digest: String::new(),
    };
    registration.registration_digest =
        workflow_connector_observation_registration_digest(&registration);
    registration
}

fn requested_fields() -> Vec<String> {
    vec![
        "headers.date".into(),
        "headers.from".into(),
        "labels".into(),
        "metadata".into(),
    ]
}

fn value(id: &str, bytes: &[u8]) -> WorkflowValueReference {
    WorkflowValueReference {
        value_id: id.into(),
        content_type: "application/json".into(),
        byte_count: bytes.len() as u64,
        sha256: hex::encode(Sha256::digest(bytes)),
        inline_canonical_json: bytes.to_vec(),
        ..Default::default()
    }
}

fn append_active_run(journal: &mut Journal) {
    journal
        .append_event(runtime_event(
            "event-observation-run-token",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                request_command_id: "command-observation-run".into(),
                workflow_id: "workflow-observation-qualification".into(),
                revision_id: "revision-observation-qualification".into(),
                package_digest: "a".repeat(64),
                retention_policy: None,
            },
        ))
        .unwrap();
}

fn runtime_event<M: Message>(
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
) -> EventEnvelope {
    EventEnvelope {
        schema_version: schema_version(),
        event_id: event_id.into(),
        stream_id: format!("workflow-run:{RUN_ID}"),
        occurred_at_unix_millis: 1_000,
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
            payload_version: 1,
        }),
        provenance: Some(EventProvenance {
            source_kind: "workflow-runtime".into(),
            retention_class: EvidenceRetentionClass::None as i32,
            ..Default::default()
        }),
        causation_id: "command-observation-run".into(),
        correlation_id: RUN_ID.into(),
        ..Default::default()
    }
}

fn schema_version() -> Option<SchemaVersion> {
    Some(SchemaVersion { major: 1, minor: 0 })
}
