use kaname_core::{
    journal::{Journal, JournalError},
    policy::{
        ApprovalResolutionResult, LocalPolicyCore, QueueMutationResult, approval_fingerprint,
    },
    v1::{
        ApprovalDecision, ApprovalRequest, ApprovalResolution, CommandEnvelope, OpaqueTypedPayload,
        SchemaVersion, Scope,
    },
};

const CURSOR_KEY: [u8; 32] = [0x71; 32];
const STREAM_ID: &str = "thread:policy-test";

fn core() -> LocalPolicyCore {
    LocalPolicyCore::new(Journal::open_in_memory(&CURSOR_KEY).unwrap())
}

fn command(id: &str, key: &str) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: id.into(),
        idempotency_key: key.into(),
        kind: "intent.enqueue".into(),
        payload: Some(OpaqueTypedPayload {
            type_url: "kaname.command.enqueue.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: b"synthetic".to_vec(),
            payload_version: 1,
        }),
        scope: None,
        actor_id: "fixture".into(),
        expected_revision: 0,
        submitted_at_unix_millis: 1_762_000_000_000,
    }
}

fn approval(target_revision: &str) -> ApprovalRequest {
    ApprovalRequest {
        approval_id: "approval-1".into(),
        action_kind: "fake.provider.dispatch".into(),
        scope: Some(Scope {
            project_id: "project-fixture".into(),
            workspace_id: "workspace-fixture".into(),
            account_id: String::new(),
            authority_id: "mac-fixture".into(),
            egress_class: "none".into(),
            destination_digest: String::new(),
        }),
        target_id: "target-fixture".into(),
        target_revision: target_revision.into(),
        effect_digest: b"effect-fixture".to_vec(),
        consequence: "synthetic effect only".into(),
        reversible: true,
        expires_at_unix_millis: 1_762_000_010_000,
        policy_reference: "fixture-policy".into(),
        fingerprint: Vec::new(),
        approval_payload_version: 1,
    }
}

#[test]
fn duplicate_enqueue_creates_one_queue_item_and_one_audit_record() {
    let mut core = core();
    let first = core
        .enqueue(
            &command("command-1", "key-1"),
            "queue-1",
            STREAM_ID,
            "first message",
        )
        .unwrap();
    let retried = core
        .enqueue(
            &command("command-1", "key-1"),
            "queue-1",
            STREAM_ID,
            "first message",
        )
        .unwrap();
    assert_eq!(first, retried);
    assert_eq!(core.queue_item("queue-1").unwrap().revision, 1);
    assert_eq!(
        core.journal()
            .replay(&format!("thread:{STREAM_ID}"), None, 20)
            .unwrap()
            .events
            .len(),
        1
    );
}

#[test]
fn stale_approval_never_records_an_external_effect() {
    let mut core = core();
    let request = approval("revision-1");
    let state = core.request_approval(request.clone(), STREAM_ID).unwrap();
    let result = core
        .resolve_approval(
            &ApprovalResolution {
                approval_id: request.approval_id.clone(),
                decision: ApprovalDecision::Approve as i32,
                expected_fingerprint: state.fingerprint,
                actor_id: "fixture".into(),
                device_id: "mac-fixture".into(),
                standing_rule_reference: String::new(),
            },
            1_762_000_001_000,
            "revision-2",
            STREAM_ID,
        )
        .unwrap();
    assert_eq!(result, ApprovalResolutionResult::Stale);
    assert_eq!(core.approval("approval-1").unwrap().status, "stale");
    assert_eq!(core.effect_ledger().external_action_attempts, 0);
}

#[test]
fn current_fingerprinted_approval_records_only_approval_state_in_phase_one() {
    let mut core = core();
    let request = approval("revision-1");
    let fingerprint = approval_fingerprint(&request);
    core.request_approval(request.clone(), STREAM_ID).unwrap();
    let result = core
        .resolve_approval(
            &ApprovalResolution {
                approval_id: request.approval_id,
                decision: ApprovalDecision::Approve as i32,
                expected_fingerprint: fingerprint,
                actor_id: "fixture".into(),
                device_id: "mac-fixture".into(),
                standing_rule_reference: String::new(),
            },
            1_762_000_001_000,
            "revision-1",
            STREAM_ID,
        )
        .unwrap();
    assert_eq!(result, ApprovalResolutionResult::Approved);
    assert_eq!(core.approval("approval-1").unwrap().status, "approved");
    assert_eq!(core.effect_ledger().external_action_attempts, 0);
}

#[test]
fn stale_queue_edit_is_visible_and_does_not_overwrite_current_content() {
    let mut core = core();
    core.enqueue(
        &command("command-1", "key-1"),
        "queue-1",
        STREAM_ID,
        "initial",
    )
    .unwrap();
    let mac_edit = core.edit_queue("queue-1", 1, "mac current", "mac").unwrap();
    assert!(matches!(mac_edit, QueueMutationResult::Applied(_)));
    let phone_edit = core
        .edit_queue("queue-1", 1, "phone stale", "phone")
        .unwrap();
    assert!(matches!(phone_edit, QueueMutationResult::Conflict(_)));
    assert_eq!(core.queue_item("queue-1").unwrap().body, "mac current");
    assert_eq!(core.queue_item("queue-1").unwrap().revision, 2);
}

#[test]
fn scope_and_egress_denial_happens_before_fake_provider_dispatch() {
    let mut core = core();
    let scope = Scope {
        project_id: "project-fixture".into(),
        workspace_id: "workspace-fixture".into(),
        account_id: "excluded-account".into(),
        authority_id: "mac-fixture".into(),
        egress_class: "external_communication".into(),
        destination_digest: "digest".into(),
    };
    assert!(matches!(
        core.authorize_fake_provider(&scope, STREAM_ID),
        Err(JournalError::Protocol("scope_or_egress_denied"))
    ));
    assert_eq!(core.effect_ledger().provider_dispatches, 0);
}

#[test]
fn duplicate_notification_receipts_do_not_change_underlying_attention_truth() {
    let mut core = core();
    core.record_notification_receipt("attention-1", "delivery-1", STREAM_ID)
        .unwrap();
    core.record_notification_receipt("attention-1", "delivery-1", STREAM_ID)
        .unwrap();
    assert_eq!(core.effect_ledger().notification_receipts, 1);
    assert_eq!(
        core.journal()
            .rebuild_thread_projection(&format!("thread:{STREAM_ID}"))
            .unwrap()
            .task_state,
        "not_started"
    );
}
