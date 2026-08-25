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
        WORKFLOW_MAIL_EFFECT_CLASSES, WorkflowMailEffectClass, WorkflowMailEffectRequest,
        mail_effect_proposal,
    },
    workflow_projection::WorkflowRunProjection,
    workflow_runtime::{
        WORKFLOW_ATTEMPT_STARTED_KIND, WORKFLOW_ATTEMPT_STARTED_TYPE,
        WORKFLOW_EXECUTION_TOKEN_CREATED_KIND, WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
        WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_RUN_TOKEN_CREATED_TYPE,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};

const CURSOR_KEY: [u8; 32] = [0x71; 32];

#[test]
fn every_mail_kind_requires_exact_approval_and_reconciles_without_repeat_dispatch() {
    for class in WORKFLOW_MAIL_EFFECT_CLASSES {
        qualify_effect(class);
    }
}

#[test]
fn each_mail_action_names_one_kind_and_unknown_actions_name_none() {
    let mut actions = WORKFLOW_MAIL_EFFECT_CLASSES
        .map(WorkflowMailEffectClass::action)
        .to_vec();
    actions.sort_unstable();
    assert_eq!(
        actions,
        vec!["archive", "draft", "label", "mark-read", "send", "trash"]
    );
    for class in WORKFLOW_MAIL_EFFECT_CLASSES {
        assert_eq!(
            WorkflowMailEffectClass::from_action(class.action()),
            Some(class)
        );
    }
    for action in ["", "Send", "send ", "forward", "delete", "mark_read"] {
        assert_eq!(
            WorkflowMailEffectClass::from_action(action),
            None,
            "{action}"
        );
    }
}

#[test]
fn only_sending_leaves_the_device_and_only_sending_is_irreversible() {
    for class in WORKFLOW_MAIL_EFFECT_CLASSES {
        let proposal = mail_effect_proposal(mail_request(class)).unwrap();
        let preview = proposal.preview.as_ref().unwrap();
        let scope = proposal
            .approval_request
            .as_ref()
            .unwrap()
            .scope
            .as_ref()
            .unwrap();
        let action = class.action();
        let expected_egress = match class {
            WorkflowMailEffectClass::Send => "external_communication",
            WorkflowMailEffectClass::Draft => "mailbox_draft",
            _ => "mailbox_mutation",
        };
        assert_eq!(scope.egress_class, expected_egress, "{action}");
        assert_eq!(
            preview.reversible,
            class != WorkflowMailEffectClass::Send,
            "{action}"
        );
        // The approval the owner sees repeats the preview it approves.
        assert_eq!(
            proposal.approval_request.as_ref().unwrap().reversible,
            preview.reversible,
            "{action}"
        );
        assert_eq!(
            proposal.approval_request.as_ref().unwrap().consequence,
            preview.consequence,
            "{action}"
        );
        assert!(!preview.summary.is_empty(), "{action}");
    }
}

#[test]
fn each_mail_kind_earns_its_own_effect_identity_and_idempotency_key() {
    let mut identities = Vec::new();
    for class in WORKFLOW_MAIL_EFFECT_CLASSES {
        let intent = mail_effect_proposal(mail_request(class))
            .unwrap()
            .intent
            .unwrap();
        assert_eq!(intent.connector_class, "mail");
        assert_eq!(intent.action, class.action());
        identities.push((intent.effect_id, intent.idempotency_key));
    }
    let mut distinct = identities.clone();
    distinct.sort_unstable();
    distinct.dedup();
    assert_eq!(distinct.len(), identities.len());
}

#[test]
fn a_still_unknown_first_check_reconciles_applied_on_the_second_check() {
    let class = WorkflowMailEffectClass::Send;
    let action = class.action();
    let run_id = format!("run-mail-second-check-{action}");
    let token_id = format!("token-mail-second-check-{action}");
    let attempt_id = format!("attempt-mail-second-check-{action}");
    let execution_token_id = format!("execution-mail-second-check-{action}");
    let node_id = format!("node-mail-second-check-{action}");
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
        run_id,
        run_token_id: token_id,
        attempt_id,
        execution_token_id,
        node_id,
        ..mail_request(class)
    })
    .unwrap();
    let effect_id = proposal.intent.as_ref().unwrap().effect_id.clone();
    let idempotency_key = proposal.intent.as_ref().unwrap().idempotency_key.clone();
    propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    approve(&mut journal, &mut projection, &proposal, &effect_id);

    let mut connector = registered_connector(
        action,
        DeterministicEffectConnectorPlan::AmbiguousUntilSecondCheck,
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

    // The first check cannot see the remote state yet, so the authority stays
    // unknown without repeating the effect.
    let first = reconcile_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        5_000,
    )
    .unwrap();
    assert_eq!(first.authority.status, "outcome_unknown");
    assert_eq!(connector.reconciliation_count(&idempotency_key), 1);

    let second = reconcile_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        6_000,
    )
    .unwrap();
    assert_eq!(second.authority.status, "reconciled_applied");
    assert_eq!(connector.reconciliation_count(&idempotency_key), 2);
    assert_eq!(connector.dispatch_count(&idempotency_key), 1);
}

#[test]
fn a_never_sent_effect_reconciles_not_applied_without_repeat_dispatch() {
    let class = WorkflowMailEffectClass::Archive;
    let action = class.action();
    let run_id = format!("run-mail-not-applied-{action}");
    let token_id = format!("token-mail-not-applied-{action}");
    let attempt_id = format!("attempt-mail-not-applied-{action}");
    let execution_token_id = format!("execution-mail-not-applied-{action}");
    let node_id = format!("node-mail-not-applied-{action}");
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
        run_id,
        run_token_id: token_id,
        attempt_id,
        execution_token_id,
        node_id,
        ..mail_request(class)
    })
    .unwrap();
    let effect_id = proposal.intent.as_ref().unwrap().effect_id.clone();
    let idempotency_key = proposal.intent.as_ref().unwrap().idempotency_key.clone();
    propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    approve(&mut journal, &mut projection, &proposal, &effect_id);

    let mut connector = registered_connector(
        action,
        DeterministicEffectConnectorPlan::TimeoutWithoutApply,
    );
    dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        4_000,
    )
    .unwrap();
    let reconciled = reconcile_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        &effect_id,
        5_000,
    )
    .unwrap();
    assert_eq!(reconciled.authority.status, "reconciled_not_applied");
    assert_eq!(connector.dispatch_count(&idempotency_key), 1);
}

fn mail_request(class: WorkflowMailEffectClass) -> WorkflowMailEffectRequest {
    let action = class.action();
    WorkflowMailEffectRequest {
        class,
        run_id: format!("run-mail-{action}"),
        run_token_id: format!("token-mail-{action}"),
        attempt_id: format!("attempt-mail-{action}"),
        execution_token_id: format!("execution-mail-{action}"),
        node_id: format!("node-mail-{action}"),
        workflow_id: "workflow-mail-effects".into(),
        revision_id: "revision-mail-effects".into(),
        project_id: "project-mail-effects".into(),
        workspace_id: "workspace-mail-effects".into(),
        account_binding_id: "synthetic-account".into(),
        destination_fingerprint: "d".repeat(64),
        input_digest: hex::encode(Sha256::digest(action)),
        expires_at_unix_millis: 100_000,
    }
}

fn registered_connector(
    action: &str,
    plan: DeterministicEffectConnectorPlan,
) -> DeterministicWorkflowEffectConnector {
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
        plan,
    );
    connector
}

fn approve(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    proposal: &kaname_core::v1::WorkflowEffectProposed,
    effect_id: &str,
) {
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
        authorize_workflow_effect(journal, projection, effect_id, resolution, 3_000).unwrap();
    assert_eq!(authorized.authority.status, "authorized");
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
        ..mail_request(class)
    })
    .unwrap();
    let effect_id = proposal.intent.as_ref().unwrap().effect_id.clone();
    let idempotency_key = proposal.intent.as_ref().unwrap().idempotency_key.clone();
    let proposed =
        propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    assert_eq!(proposed.authority.status, "proposed");
    approve(&mut journal, &mut projection, &proposal, &effect_id);

    let mut connector =
        registered_connector(action, DeterministicEffectConnectorPlan::TimeoutAfterSend);
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
