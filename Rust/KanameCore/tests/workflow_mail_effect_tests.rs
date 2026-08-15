use kaname_core::{
    journal::Journal,
    v1::{
        ApprovalDecision, ApprovalResolution, EventEnvelope, EventProvenance,
        EvidenceRetentionClass, OpaqueTypedPayload, SchemaVersion, WorkflowAttemptStarted,
        WorkflowEffectConnectorRegistration, WorkflowExecutionTokenCreated,
        WorkflowRunTokenCreated,
    },
    workflow_effect_authority::{authorize_workflow_effect, propose_workflow_effect},
    workflow_effect_connector::{
        DeterministicEffectConnectorPlan, DeterministicWorkflowEffectConnector,
        WorkflowEffectConnectorError, dispatch_workflow_effect, reconcile_workflow_effect,
    },
    workflow_mail_effect::{
        WorkflowMailEffectClass, WorkflowMailEffectRequest, mail_effect_proposal,
    },
    workflow_projection::WorkflowRunProjection,
    workflow_runtime::{
        WORKFLOW_ATTEMPT_STARTED_KIND, WORKFLOW_ATTEMPT_STARTED_TYPE,
        WORKFLOW_EXECUTION_TOKEN_CREATED_KIND, WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
        WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_RUN_TOKEN_CREATED_TYPE,
    },
};
use prost::Message;

const CURSOR_KEY: [u8; 32] = [0x71; 32];

#[test]
fn send_and_archive_each_require_exact_approval_and_reconcile_without_repeat_dispatch() {
    for class in [
        WorkflowMailEffectClass::Send,
        WorkflowMailEffectClass::Archive,
    ] {
        qualify_effect(class);
    }
}

fn qualify_effect(class: WorkflowMailEffectClass) {
    let action = class.action();
    let run_id = format!("run-mail-{action}");
    let token_id = format!("token-mail-{action}");
    let attempt_id = format!("attempt-mail-{action}");
    let execution_token_id = format!("execution-mail-{action}");
    let node_id = format!("node-mail-{action}");
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(
        &mut journal,
        &run_id,
        &token_id,
        &attempt_id,
        &execution_token_id,
        &node_id,
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    let proposal = mail_effect_proposal(WorkflowMailEffectRequest {
        class,
        run_id: run_id.clone(),
        run_token_id: token_id,
        attempt_id,
        execution_token_id,
        node_id,
        workflow_id: "workflow-mail-effects".into(),
        revision_id: "revision-mail-effects".into(),
        project_id: "project-mail-effects".into(),
        workspace_id: "workspace-mail-effects".into(),
        account_binding_id: "synthetic-account".into(),
        destination_fingerprint: "d".repeat(64),
        input_digest: if class == WorkflowMailEffectClass::Send {
            "1".repeat(64)
        } else {
            "2".repeat(64)
        },
        expires_at_unix_millis: 100_000,
    })
    .unwrap();
    let effect_id = proposal.intent.as_ref().unwrap().effect_id.clone();
    let idempotency_key = proposal.intent.as_ref().unwrap().idempotency_key.clone();
    let proposed =
        propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    assert_eq!(proposed.authority.status, "proposed");

    let approval = proposal.approval_request.as_ref().unwrap();
    let resolution = ApprovalResolution {
        approval_id: approval.approval_id.clone(),
        decision: ApprovalDecision::Approve as i32,
        expected_fingerprint: approval.fingerprint.clone(),
        actor_id: "owner-synthetic".into(),
        device_id: "device-synthetic".into(),
        standing_rule_reference: String::new(),
    };
    let authorized =
        authorize_workflow_effect(&mut journal, &mut projection, &effect_id, resolution, 3_000)
            .unwrap();
    assert_eq!(authorized.authority.status, "authorized");

    let mut connector = DeterministicWorkflowEffectConnector::default();
    connector.register(
        WorkflowEffectConnectorRegistration {
            connector_class: "mail".into(),
            version: "1.0.0".into(),
            package_digest: "c".repeat(64),
            binding_id: "synthetic-mail-binding".into(),
            account_binding_id: "synthetic-account".into(),
            allowed_actions: vec![action.into()],
            idempotent: true,
            supports_reconciliation: true,
            registration_digest: String::new(),
        },
        DeterministicEffectConnectorPlan::TimeoutAfterSend,
    );
    let dispatched = dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        4_000,
    )
    .unwrap();
    assert_eq!(dispatched.authority.status, "outcome_unknown");
    assert_eq!(connector.dispatch_count(&idempotency_key), 1);
    assert!(matches!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            &effect_id,
            5_000,
        ),
        Err(WorkflowEffectConnectorError::ReconciliationRequired)
    ));
    let reconciled = reconcile_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        6_000,
    )
    .unwrap();
    assert_eq!(reconciled.authority.status, "reconciled_applied");
    assert_eq!(connector.dispatch_count(&idempotency_key), 1);
    assert_eq!(connector.reconciliation_count(&idempotency_key), 1);
    assert!(
        reconcile_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            &effect_id,
            7_000,
        )
        .unwrap()
        .duplicate
    );
}

fn append_active_attempt(
    journal: &mut Journal,
    run_id: &str,
    token_id: &str,
    attempt_id: &str,
    execution_token_id: &str,
    node_id: &str,
) {
    let events = [
        runtime_event(
            run_id,
            "event-mail-run-token",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: run_id.into(),
                run_token_id: token_id.into(),
                request_command_id: "command-mail-run".into(),
                workflow_id: "workflow-mail-effects".into(),
                revision_id: "revision-mail-effects".into(),
                package_digest: "a".repeat(64),
                retention_policy: None,
            },
            "command-mail-run",
            1_000,
        ),
        runtime_event(
            run_id,
            "event-mail-execution-token",
            WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
            WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
            WorkflowExecutionTokenCreated {
                run_id: run_id.into(),
                run_token_id: token_id.into(),
                execution_token_id: execution_token_id.into(),
                ..Default::default()
            },
            "event-mail-run-token",
            1_050,
        ),
        runtime_event(
            run_id,
            "event-mail-attempt",
            WORKFLOW_ATTEMPT_STARTED_KIND,
            WORKFLOW_ATTEMPT_STARTED_TYPE,
            WorkflowAttemptStarted {
                run_id: run_id.into(),
                run_token_id: token_id.into(),
                attempt_id: attempt_id.into(),
                node_id: node_id.into(),
                attempt_number: 1,
                execution_token_id: execution_token_id.into(),
            },
            "event-mail-run-token",
            1_100,
        ),
    ];
    for event in events {
        journal.append_event(event).unwrap();
    }
}

fn runtime_event<M: Message>(
    run_id: &str,
    event_id: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    causation_id: &str,
    occurred_at_unix_millis: i64,
) -> EventEnvelope {
    EventEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        event_id: event_id.into(),
        stream_id: format!("workflow-run:{run_id}"),
        stream_sequence: 0,
        store_position: 0,
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
            retention_class: EvidenceRetentionClass::None as i32,
            ..Default::default()
        }),
        causation_id: causation_id.into(),
        correlation_id: run_id.into(),
    }
}
