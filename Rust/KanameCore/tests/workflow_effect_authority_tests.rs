use kaname_core::{
    journal::Journal,
    policy::approval_fingerprint,
    v1::{
        ApprovalDecision, ApprovalRequest, ApprovalResolution, EventEnvelope, EventProvenance,
        EvidenceRetentionClass, OpaqueTypedPayload, SchemaVersion, Scope, WorkflowAttemptStarted,
        WorkflowEffectConnectorRegistration, WorkflowEffectIntent, WorkflowEffectPreview,
        WorkflowEffectProposed, WorkflowExecutionTokenCreated, WorkflowRunTokenCreated,
    },
    workflow_effect_authority::{
        WorkflowEffectAuthorityError, authorize_workflow_effect, propose_workflow_effect,
    },
    workflow_effect_connector::{
        DeterministicEffectConnectorPlan, DeterministicWorkflowEffectConnector,
        WorkflowEffectConnector, WorkflowEffectConnectorError, WorkflowEffectConnectorRequest,
        dispatch_workflow_effect, reconcile_workflow_effect,
    },
    workflow_projection::WorkflowRunProjection,
    workflow_runtime::{
        WORKFLOW_ATTEMPT_STARTED_KIND, WORKFLOW_ATTEMPT_STARTED_TYPE,
        WORKFLOW_EXECUTION_TOKEN_CREATED_KIND, WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
        WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_RUN_TOKEN_CREATED_TYPE,
        workflow_effect_intent_digest, workflow_effect_preview_digest,
    },
};
use prost::Message;
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x68; 32];
const RUN_ID: &str = "run-effect-authority";
const TOKEN_ID: &str = "token-effect-authority";
const ATTEMPT_ID: &str = "attempt-effect-authority";
const NODE_ID: &str = "send-effect";
const EXECUTION_TOKEN_ID: &str = "execution-effect-authority";

#[test]
fn exact_approval_is_durable_idempotent_and_rebuildable_without_dispatch() {
    let directory = tempdir().unwrap();
    let journal_path = directory.path().join("journal.sqlite");
    let projection_path = directory.path().join("projection.sqlite");
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
    let proposal = proposal("effect-one", "idempotency-effect-one", 5_000);

    let proposed =
        propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    assert!(!proposed.duplicate);
    assert_eq!(proposed.authority.status, "proposed");
    assert_eq!(projection.row_count("effect_authorities").unwrap(), 1);

    let duplicate =
        propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    assert!(duplicate.duplicate);
    assert_eq!(projection.row_count("effect_authorities").unwrap(), 1);

    let approval = proposal.approval_request.as_ref().unwrap();
    let resolution = resolution(approval, approval.fingerprint.clone());
    let authorized = authorize_workflow_effect(
        &mut journal,
        &mut projection,
        "effect-one",
        resolution.clone(),
        3_000,
    )
    .unwrap();
    assert!(!authorized.duplicate);
    assert_eq!(authorized.authority.status, "authorized");
    assert!(authorized.authority.authorization.is_some());
    assert_eq!(
        projection.inspect_runs(None, Some(RUN_ID), 1).unwrap()[0]
            .purge_preview
            .as_ref()
            .unwrap()
            .affected_effect_ids,
        ["effect-one"]
    );
    assert!(
        authorize_workflow_effect(
            &mut journal,
            &mut projection,
            "effect-one",
            resolution,
            3_000,
        )
        .unwrap()
        .duplicate
    );

    let expected = projection.canonical_snapshot().unwrap();
    drop(projection);
    drop(journal);
    let journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    let mut reopened = WorkflowRunProjection::open(&projection_path).unwrap();
    reopened.catch_up(&journal).unwrap();
    assert_eq!(reopened.canonical_snapshot().unwrap(), expected);
    reopened.rebuild_from_zero(&journal).unwrap();
    assert_eq!(reopened.canonical_snapshot().unwrap(), expected);
}

#[test]
fn mismatched_and_expired_approvals_fail_before_journal_mutation() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    let proposal = proposal("effect-two", "idempotency-effect-two", 4_000);
    propose_workflow_effect(&mut journal, &mut projection, proposal.clone(), 2_000).unwrap();
    let before = journal.event_page_after(0, 100).unwrap().high_water_mark;
    let approval = proposal.approval_request.as_ref().unwrap();

    let mismatched = resolution(approval, vec![0x7f; 32]);
    assert!(matches!(
        authorize_workflow_effect(
            &mut journal,
            &mut projection,
            "effect-two",
            mismatched,
            3_000,
        ),
        Err(WorkflowEffectAuthorityError::StaleOrMismatched)
    ));
    assert_eq!(
        journal.event_page_after(0, 100).unwrap().high_water_mark,
        before
    );
    assert_eq!(
        projection
            .effect_authority("effect-two")
            .unwrap()
            .unwrap()
            .status,
        "proposed"
    );

    let exact = resolution(approval, approval.fingerprint.clone());
    assert!(matches!(
        authorize_workflow_effect(&mut journal, &mut projection, "effect-two", exact, 4_000,),
        Err(WorkflowEffectAuthorityError::Expired)
    ));
    assert_eq!(
        journal.event_page_after(0, 100).unwrap().high_water_mark,
        before
    );
}

#[test]
fn changed_intent_cannot_reuse_effect_or_idempotency_identity() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    let original = proposal("effect-three", "idempotency-effect-three", 5_000);
    propose_workflow_effect(&mut journal, &mut projection, original.clone(), 2_000).unwrap();

    let mut changed = original;
    let intent = changed.intent.as_mut().unwrap();
    intent.action = "archive".into();
    changed.intent_digest = workflow_effect_intent_digest(intent);
    let approval = changed.approval_request.as_mut().unwrap();
    approval.effect_digest = hex::decode(&changed.intent_digest).unwrap();
    approval.fingerprint = approval_fingerprint(approval);
    assert!(matches!(
        propose_workflow_effect(&mut journal, &mut projection, changed, 2_100),
        Err(WorkflowEffectAuthorityError::StaleOrMismatched)
    ));
    assert_eq!(projection.row_count("effect_authorities").unwrap(), 1);
}

#[test]
fn successful_dispatch_is_idempotent_across_duplicate_requests_and_restart() {
    let directory = tempdir().unwrap();
    let journal_path = directory.path().join("journal.sqlite");
    let projection_path = directory.path().join("projection.sqlite");
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
    let effect = proposal("effect-success", "idempotency-success", 100_000);
    authorize(&mut journal, &mut projection, effect, 2_000, 3_000);
    let mut connector = connector(DeterministicEffectConnectorPlan::Succeed);

    let dispatched = dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-success",
        4_000,
    )
    .unwrap();
    assert!(!dispatched.duplicate);
    assert_eq!(dispatched.authority.status, "succeeded");
    assert_eq!(connector.dispatch_count("idempotency-success"), 1);
    let connector_request = WorkflowEffectConnectorRequest {
        proposal: dispatched.authority.proposal.clone().unwrap(),
        authorization: dispatched.authority.authorization.clone().unwrap(),
        dispatch: dispatched.authority.dispatch_started.clone().unwrap(),
        prior_receipt: dispatched
            .authority
            .dispatch_settled
            .as_ref()
            .and_then(|value| value.receipt.clone()),
    };
    let _ = connector.dispatch(&connector_request);
    assert_eq!(connector.dispatch_count("idempotency-success"), 1);

    let duplicate = dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-success",
        5_000,
    )
    .unwrap();
    assert!(duplicate.duplicate);
    assert_eq!(connector.dispatch_count("idempotency-success"), 1);
    let expected = projection.canonical_snapshot().unwrap();
    drop(projection);
    drop(journal);

    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    let mut projection = WorkflowRunProjection::open(&projection_path).unwrap();
    let after_restart = dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-success",
        6_000,
    )
    .unwrap();
    assert!(after_restart.duplicate);
    assert_eq!(connector.dispatch_count("idempotency-success"), 1);
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
    projection.rebuild_from_zero(&journal).unwrap();
    assert_eq!(projection.canonical_snapshot().unwrap(), expected);
}

#[test]
fn rejection_and_timeout_before_send_are_known_non_applied_outcomes() {
    for (effect_id, idempotency_key, plan, expected_status, expected_error) in [
        (
            "effect-rejected",
            "idempotency-rejected",
            DeterministicEffectConnectorPlan::Reject,
            "rejected",
            "connector.rejected",
        ),
        (
            "effect-timeout-before",
            "idempotency-timeout-before",
            DeterministicEffectConnectorPlan::TimeoutBeforeSend,
            "not_sent",
            "connector.timeout_before_send",
        ),
    ] {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        append_active_attempt(&mut journal);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        authorize(
            &mut journal,
            &mut projection,
            proposal(effect_id, idempotency_key, 100_000),
            2_000,
            3_000,
        );
        let mut connector = connector(plan);
        let result = dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            effect_id,
            4_000,
        )
        .unwrap();
        assert_eq!(result.authority.status, expected_status);
        assert_eq!(
            result
                .authority
                .dispatch_settled
                .as_ref()
                .unwrap()
                .error_code,
            expected_error
        );
        assert_eq!(connector.dispatch_count(idempotency_key), 1);
        assert!(matches!(
            reconcile_workflow_effect(
                &mut journal,
                &mut projection,
                &mut connector,
                effect_id,
                70_000,
            ),
            Err(WorkflowEffectConnectorError::NotReconcilable)
        ));
    }
}

#[test]
fn timeout_after_send_can_only_reconcile_and_never_dispatch_again() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    authorize(
        &mut journal,
        &mut projection,
        proposal("effect-timeout-after", "idempotency-timeout-after", 100_000),
        2_000,
        3_000,
    );
    let mut connector = connector(DeterministicEffectConnectorPlan::TimeoutAfterSend);
    let dispatched = dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-timeout-after",
        4_000,
    )
    .unwrap();
    assert_eq!(dispatched.authority.status, "outcome_unknown");
    assert_eq!(connector.dispatch_count("idempotency-timeout-after"), 1);
    assert!(matches!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-timeout-after",
            65_000,
        ),
        Err(WorkflowEffectConnectorError::ReconciliationRequired)
    ));
    assert_eq!(connector.dispatch_count("idempotency-timeout-after"), 1);

    let reconciled = reconcile_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-timeout-after",
        70_000,
    )
    .unwrap();
    assert_eq!(reconciled.authority.status, "reconciled_applied");
    assert_eq!(reconciled.authority.reconciliation_count, 1);
    assert_eq!(connector.dispatch_count("idempotency-timeout-after"), 1);
    assert_eq!(
        connector.reconciliation_count("idempotency-timeout-after"),
        1
    );
    assert!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-timeout-after",
            80_000,
        )
        .unwrap()
        .duplicate
    );
    assert!(
        reconcile_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-timeout-after",
            80_000,
        )
        .unwrap()
        .duplicate
    );
    assert_eq!(connector.dispatch_count("idempotency-timeout-after"), 1);
    assert_eq!(
        connector.reconciliation_count("idempotency-timeout-after"),
        1
    );
}

#[test]
fn ambiguous_outcome_remains_blocked_and_records_each_reconciliation_observation() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    authorize(
        &mut journal,
        &mut projection,
        proposal("effect-ambiguous", "idempotency-ambiguous", 100_000),
        2_000,
        3_000,
    );
    let mut connector = connector(DeterministicEffectConnectorPlan::Ambiguous);
    dispatch_workflow_effect(
        &mut journal,
        &mut projection,
        &mut connector,
        "effect-ambiguous",
        4_000,
    )
    .unwrap();
    for (ordinal, at) in [(1, 5_000), (2, 6_000)] {
        let result = reconcile_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-ambiguous",
            at,
        )
        .unwrap();
        assert_eq!(result.authority.status, "outcome_unknown");
        assert_eq!(result.authority.reconciliation_count, ordinal);
    }
    assert!(matches!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-ambiguous",
            7_000,
        ),
        Err(WorkflowEffectConnectorError::ReconciliationRequired)
    ));
    assert_eq!(connector.dispatch_count("idempotency-ambiguous"), 1);
    assert_eq!(connector.reconciliation_count("idempotency-ambiguous"), 2);
}

#[test]
fn stale_authority_and_registration_drift_fail_before_dispatch_mutation() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    authorize(
        &mut journal,
        &mut projection,
        proposal("effect-stale", "idempotency-stale", 5_000),
        2_000,
        3_000,
    );
    let before = journal.event_page_after(0, 100).unwrap().high_water_mark;
    let mut connector = connector(DeterministicEffectConnectorPlan::Succeed);
    assert!(matches!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-stale",
            5_000,
        ),
        Err(WorkflowEffectConnectorError::AuthorityExpired)
    ));
    assert_eq!(
        journal.event_page_after(0, 100).unwrap().high_water_mark,
        before
    );
    assert_eq!(connector.dispatch_count("idempotency-stale"), 0);

    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    append_active_attempt(&mut journal);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    authorize(
        &mut journal,
        &mut projection,
        proposal("effect-drift", "idempotency-drift", 100_000),
        2_000,
        3_000,
    );
    let before = journal.event_page_after(0, 100).unwrap().high_water_mark;
    let mut drifted = connector_registration();
    drifted.allowed_actions = vec!["archive".into()];
    let mut connector = DeterministicWorkflowEffectConnector::default();
    connector.register(drifted, DeterministicEffectConnectorPlan::Succeed);
    assert!(matches!(
        dispatch_workflow_effect(
            &mut journal,
            &mut projection,
            &mut connector,
            "effect-drift",
            4_000,
        ),
        Err(WorkflowEffectConnectorError::RegistrationMismatch)
    ));
    assert_eq!(
        journal.event_page_after(0, 100).unwrap().high_water_mark,
        before
    );
    assert_eq!(connector.dispatch_count("idempotency-drift"), 0);
}

fn authorize(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    proposal: WorkflowEffectProposed,
    proposed_at_unix_millis: i64,
    authorized_at_unix_millis: i64,
) {
    let effect_id = proposal.intent.as_ref().unwrap().effect_id.clone();
    let approval = proposal.approval_request.as_ref().unwrap().clone();
    propose_workflow_effect(journal, projection, proposal, proposed_at_unix_millis).unwrap();
    authorize_workflow_effect(
        journal,
        projection,
        &effect_id,
        resolution(&approval, approval.fingerprint.clone()),
        authorized_at_unix_millis,
    )
    .unwrap();
}

fn connector(plan: DeterministicEffectConnectorPlan) -> DeterministicWorkflowEffectConnector {
    let mut connector = DeterministicWorkflowEffectConnector::default();
    connector.register(connector_registration(), plan);
    connector
}

fn connector_registration() -> WorkflowEffectConnectorRegistration {
    WorkflowEffectConnectorRegistration {
        connector_class: "mail".into(),
        version: "1.0.0".into(),
        package_digest: "c".repeat(64),
        binding_id: "binding-installation-mail-primary".into(),
        account_binding_id: "binding-mail-primary".into(),
        allowed_actions: vec!["send".into()],
        idempotent: true,
        supports_reconciliation: true,
        registration_digest: String::new(),
    }
}

fn proposal(effect_id: &str, idempotency_key: &str, expires: i64) -> WorkflowEffectProposed {
    let intent = WorkflowEffectIntent {
        effect_id: effect_id.into(),
        run_id: RUN_ID.into(),
        run_token_id: TOKEN_ID.into(),
        attempt_id: ATTEMPT_ID.into(),
        execution_token_id: EXECUTION_TOKEN_ID.into(),
        node_id: NODE_ID.into(),
        workflow_id: "workflow-effect-authority".into(),
        revision_id: "revision-effect-authority".into(),
        connector_class: "mail".into(),
        action: "send".into(),
        account_binding_id: "binding-mail-primary".into(),
        destination_fingerprint: "d".repeat(64),
        input_digest: "1".repeat(64),
        idempotency_key: idempotency_key.into(),
    };
    let intent_digest = workflow_effect_intent_digest(&intent);
    let mut preview = WorkflowEffectPreview {
        summary: "Send the prepared message".into(),
        consequence: "A message will leave the local device".into(),
        reversible: false,
        destination_fingerprint: intent.destination_fingerprint.clone(),
        preview_digest: String::new(),
    };
    preview.preview_digest = workflow_effect_preview_digest(&preview);
    let mut approval = ApprovalRequest {
        approval_id: format!("approval-{effect_id}"),
        action_kind: "workflow.effect".into(),
        scope: Some(Scope {
            project_id: "project-effect-authority".into(),
            workspace_id: "workspace-effect-authority".into(),
            account_id: intent.account_binding_id.clone(),
            authority_id: String::new(),
            egress_class: "external_communication".into(),
            destination_digest: intent.destination_fingerprint.clone(),
        }),
        target_id: effect_id.into(),
        target_revision: intent.revision_id.clone(),
        effect_digest: hex::decode(&intent_digest).unwrap(),
        consequence: preview.consequence.clone(),
        reversible: preview.reversible,
        expires_at_unix_millis: expires,
        policy_reference: "policy-effect-manual-v1".into(),
        fingerprint: Vec::new(),
        approval_payload_version: 1,
    };
    approval.fingerprint = approval_fingerprint(&approval);
    WorkflowEffectProposed {
        intent: Some(intent),
        intent_digest,
        preview: Some(preview),
        approval_request: Some(approval),
    }
}

fn resolution(approval: &ApprovalRequest, fingerprint: Vec<u8>) -> ApprovalResolution {
    ApprovalResolution {
        approval_id: approval.approval_id.clone(),
        decision: ApprovalDecision::Approve as i32,
        expected_fingerprint: fingerprint,
        actor_id: "owner-local".into(),
        device_id: "device-local".into(),
        standing_rule_reference: String::new(),
    }
}

fn append_active_attempt(journal: &mut Journal) {
    for event in [
        runtime_event(
            "event-effect-run-token",
            WORKFLOW_RUN_TOKEN_CREATED_KIND,
            WORKFLOW_RUN_TOKEN_CREATED_TYPE,
            WorkflowRunTokenCreated {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                request_command_id: "command-effect-run".into(),
                workflow_id: "workflow-effect-authority".into(),
                revision_id: "revision-effect-authority".into(),
                package_digest: "a".repeat(64),
                retention_policy: None,
            },
            "command-effect-run",
            1_000,
        ),
        runtime_event(
            "event-effect-execution-token",
            WORKFLOW_EXECUTION_TOKEN_CREATED_KIND,
            WORKFLOW_EXECUTION_TOKEN_CREATED_TYPE,
            WorkflowExecutionTokenCreated {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                execution_token_id: EXECUTION_TOKEN_ID.into(),
                ..Default::default()
            },
            "event-effect-run-token",
            1_050,
        ),
        runtime_event(
            "event-effect-attempt-start",
            WORKFLOW_ATTEMPT_STARTED_KIND,
            WORKFLOW_ATTEMPT_STARTED_TYPE,
            WorkflowAttemptStarted {
                run_id: RUN_ID.into(),
                run_token_id: TOKEN_ID.into(),
                attempt_id: ATTEMPT_ID.into(),
                node_id: NODE_ID.into(),
                attempt_number: 1,
                execution_token_id: EXECUTION_TOKEN_ID.into(),
            },
            "event-effect-run-token",
            1_100,
        ),
    ] {
        journal.append_event(event).unwrap();
    }
}

fn runtime_event<M: Message>(
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
        stream_id: format!("workflow-run:{RUN_ID}"),
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
        correlation_id: RUN_ID.into(),
    }
}
