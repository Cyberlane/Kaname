//! Durable `effect.connector` execution against the fixture connector host.
//!
//! Every effect here crosses a deterministic in-process connector. No test
//! contacts a network, a credential store, an account, or a mail provider.

use kaname_core::{
    journal::{Journal, ReplayBasis},
    open_workflow_library,
    v1::{
        CommandEnvelope, OpaqueTypedPayload, RequestWorkflowRun, SchemaVersion, Scope,
        WorkflowEffectConnectorRegistration, WorkflowEffectProposed, WorkflowEffectReconciled,
        WorkflowEffectReconciliationOutcome, WorkflowInputBinding, WorkflowValueReference,
    },
    workflow_drafts::CreateWorkflowDraft,
    workflow_effect_connector::{AutoApprovedWorkflowEffectHost, DeterministicEffectConnectorPlan},
    workflow_executor::{self, DurableRunOutcome, WorkflowExecutionFault},
    workflow_library::WorkflowLibraryStore,
    workflow_mail_effect::WorkflowMailEffectClass,
    workflow_projection::WorkflowRunProjection,
    workflow_publication::{PublishWorkflowRevision, PublishedWorkflowRevision},
    workflow_runtime::{
        WORKFLOW_EFFECT_DISPATCH_STARTED_KIND, WORKFLOW_EFFECT_PROPOSED_KIND,
        WORKFLOW_EFFECT_RECONCILED_KIND, WORKFLOW_RUN_REQUEST_KIND, WORKFLOW_RUN_REQUEST_TYPE,
        decode_workflow_event,
    },
};
use prost::Message;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x6e; 32];
const EFFECT_WORKFLOW_ID: &str = "018f7000-0001-7000-8000-000000000001";
const CONNECTOR_PACKAGE_ID: &str = "dev.kaname.mail";
const CONNECTOR_DIGEST: &str = "3c1f2a5b8d47e6091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081";
const ACCOUNT_BINDING_ID: &str = "synthetic-account";
const DESTINATION_FINGERPRINT: &str =
    "d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a29180f7e6d5c4b3a29180f7e6d";
const SUBMITTED_AT_UNIX_MILLIS: i64 = 1_786_220_100_000;

#[test]
fn effect_connector_send_reconciles_applied() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-send-001", &published, "send");
    let mut host = effect_host("send", DeterministicEffectConnectorPlan::TimeoutAfterSend);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Succeeded);
    let authority = projected_authority(&journal, "run-effect-send-001");
    assert_eq!(authority.status, "reconciled_applied");
    assert_eq!(authority.reconciliation_count, 1);
    let intent = authority
        .proposal
        .as_ref()
        .unwrap()
        .intent
        .as_ref()
        .unwrap();
    assert_eq!(intent.connector_class, "mail");
    assert_eq!(intent.action, "send");
    assert_eq!(intent.input_digest, input_digest("send"));
    // The provider saw exactly one dispatch, and reconciliation observed the
    // applied state without repeating the effect.
    assert_eq!(host.dispatch_count(&intent.idempotency_key), 1);
    assert_eq!(host.reconciliation_count(&intent.idempotency_key), 1);
    assert_eq!(
        emitted_port_ids(&journal, "run-effect-send-001"),
        vec!["success".to_owned(), "success".to_owned()]
    );
}

#[test]
fn effect_connector_draft_archive_label_trash_and_mark_read_dispatch_and_apply() {
    for class in [
        WorkflowMailEffectClass::Draft,
        WorkflowMailEffectClass::Archive,
        WorkflowMailEffectClass::Label,
        WorkflowMailEffectClass::Trash,
        WorkflowMailEffectClass::MarkRead,
    ] {
        let action = class.action();
        let directory = tempdir().unwrap();
        let (library, published) = published_effect_library(directory.path(), action);
        let run_id = format!("run-effect-{action}-001");
        let command = effect_run_command(&run_id, &published, action);
        let mut host = effect_host(action, DeterministicEffectConnectorPlan::Succeed);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

        let result = workflow_executor::execute_with_effects(
            &mut journal,
            &library,
            &mut host,
            &command,
            SUBMITTED_AT_UNIX_MILLIS,
        )
        .unwrap();

        assert_eq!(result.outcome, DurableRunOutcome::Succeeded, "{action}");
        let authority = projected_authority(&journal, &run_id);
        assert_eq!(authority.status, "succeeded", "{action}");
        assert_eq!(authority.reconciliation_count, 0, "{action}");
        let intent = authority
            .proposal
            .as_ref()
            .unwrap()
            .intent
            .as_ref()
            .unwrap();
        assert_eq!(intent.action, action);
        assert_eq!(host.dispatch_count(&intent.idempotency_key), 1, "{action}");
        let preview = authority
            .proposal
            .as_ref()
            .unwrap()
            .preview
            .as_ref()
            .unwrap();
        // Only sending leaves the device, so every other kind stays reversible.
        assert!(preview.reversible, "{action}");
    }
}

#[test]
fn effect_connector_still_unknown_then_reconciles_on_second_check() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-second-check-001", &published, "send");
    let mut host = effect_host(
        "send",
        DeterministicEffectConnectorPlan::AmbiguousUntilSecondCheck,
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Succeeded);
    let authority = projected_authority(&journal, "run-effect-second-check-001");
    assert_eq!(authority.status, "reconciled_applied");
    assert_eq!(authority.reconciliation_count, 2);
    let outcomes = reconciliation_outcomes(&journal, "run-effect-second-check-001");
    assert_eq!(
        outcomes,
        vec![
            WorkflowEffectReconciliationOutcome::StillUnknown as i32,
            WorkflowEffectReconciliationOutcome::Applied as i32
        ]
    );
    let intent = authority
        .proposal
        .as_ref()
        .unwrap()
        .intent
        .as_ref()
        .unwrap();
    assert_eq!(host.dispatch_count(&intent.idempotency_key), 1);
}

#[test]
fn effect_connector_exhausted_unknown_routes_error_with_check_count() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-unknown-001", &published, "send");
    let mut host = effect_host("send", DeterministicEffectConnectorPlan::Ambiguous);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let authority = projected_authority(&journal, "run-effect-unknown-001");
    assert_eq!(authority.status, "outcome_unknown");
    assert_eq!(authority.reconciliation_count, 3);
    let error = error_port_value(&journal, "run-effect-unknown-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.outcome-unknown")
    );
    // The bounded check count travels to the graph so a `control.reconcile`
    // node can continue the same unknown outcome.
    assert_eq!(error.get("checks").and_then(Value::as_u64), Some(3));
    assert_eq!(
        error.get("status").and_then(Value::as_str),
        Some("outcome_unknown")
    );
    let intent = authority
        .proposal
        .as_ref()
        .unwrap()
        .intent
        .as_ref()
        .unwrap();
    assert_eq!(
        error.get("effectId").and_then(Value::as_str),
        Some(intent.effect_id.as_str())
    );
    assert_eq!(host.dispatch_count(&intent.idempotency_key), 1);
}

#[test]
fn effect_connector_reconciled_not_applied_routes_error_without_repeating_the_effect() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-not-applied-001", &published, "send");
    let mut host = effect_host(
        "send",
        DeterministicEffectConnectorPlan::TimeoutWithoutApply,
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let authority = projected_authority(&journal, "run-effect-not-applied-001");
    assert_eq!(authority.status, "reconciled_not_applied");
    assert_eq!(authority.reconciliation_count, 1);
    let error = error_port_value(&journal, "run-effect-not-applied-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.not-applied")
    );
    assert_eq!(
        error.get("status").and_then(Value::as_str),
        Some("reconciled_not_applied")
    );
    let intent = authority
        .proposal
        .as_ref()
        .unwrap()
        .intent
        .as_ref()
        .unwrap();
    // A reconciliation that proves the effect never landed still must not
    // repeat the dispatch on the owner's behalf.
    assert_eq!(host.dispatch_count(&intent.idempotency_key), 1);
}

#[test]
fn effect_connector_never_sent_dispatch_routes_error_without_reconciliation() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "label");
    let command = effect_run_command("run-effect-not-sent-001", &published, "label");
    let mut host = effect_host("label", DeterministicEffectConnectorPlan::TimeoutBeforeSend);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let authority = projected_authority(&journal, "run-effect-not-sent-001");
    assert_eq!(authority.status, "not_sent");
    assert_eq!(authority.reconciliation_count, 0);
    let error = error_port_value(&journal, "run-effect-not-sent-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.not-sent")
    );
}

#[test]
fn effect_connector_rejected_dispatch_routes_error_without_reconciliation() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-rejected-001", &published, "send");
    let mut host = effect_host("send", DeterministicEffectConnectorPlan::Reject);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let authority = projected_authority(&journal, "run-effect-rejected-001");
    assert_eq!(authority.status, "rejected");
    assert_eq!(authority.reconciliation_count, 0);
    let error = error_port_value(&journal, "run-effect-rejected-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.rejected")
    );
}

#[test]
fn effect_connector_without_a_host_cannot_reach_a_provider() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-hostless-001", &published, "send");
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let authority = projected_authority(&journal, "run-effect-hostless-001");
    assert_eq!(authority.status, "proposed");
    let error = error_port_value(&journal, "run-effect-hostless-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.not-authorized")
    );
    assert!(
        !journal_kinds(&journal, "run-effect-hostless-001")
            .contains(&WORKFLOW_EFFECT_DISPATCH_STARTED_KIND.to_owned())
    );
}

#[test]
fn interrupted_effect_dispatch_resumes_without_a_second_provider_effect() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_effect_library(directory.path(), "send");
        let command = effect_run_command("run-effect-crash-001", &published, "send");
        let mut host = effect_host("send", DeterministicEffectConnectorPlan::TimeoutAfterSend);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute_with_effects(
            &mut journal,
            &library,
            &mut host,
            &command,
            SUBMITTED_AT_UNIX_MILLIS,
        )
        .unwrap();
        run_wires(&journal, "run-effect-crash-001")
    };
    let dispatch_started_ordinal = {
        let directory = tempdir().unwrap();
        let (library, published) = published_effect_library(directory.path(), "send");
        let command = effect_run_command("run-effect-crash-001", &published, "send");
        let mut host = effect_host("send", DeterministicEffectConnectorPlan::TimeoutAfterSend);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute_with_effects(
            &mut journal,
            &library,
            &mut host,
            &command,
            SUBMITTED_AT_UNIX_MILLIS,
        )
        .unwrap();
        journal_kinds(&journal, "run-effect-crash-001")
            .iter()
            .position(|kind| kind == WORKFLOW_EFFECT_DISPATCH_STARTED_KIND)
            .unwrap()
            + 1
    };

    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let command = effect_run_command("run-effect-crash-001", &published, "send");
    let mut host = effect_host("send", DeterministicEffectConnectorPlan::TimeoutAfterSend);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let interrupted = workflow_executor::execute_with_effects_fault_for_test(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
        WorkflowExecutionFault::AfterNewEvent(dispatch_started_ordinal),
    );
    assert!(matches!(
        interrupted,
        Err(workflow_executor::WorkflowExecutionError::InjectedInterruption)
    ));

    let resumed = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(resumed.outcome, DurableRunOutcome::Succeeded);
    assert_eq!(run_wires(&journal, "run-effect-crash-001"), expected);
    let authority = projected_authority(&journal, "run-effect-crash-001");
    let intent = authority
        .proposal
        .as_ref()
        .unwrap()
        .intent
        .as_ref()
        .unwrap();
    assert_eq!(host.dispatch_count(&intent.idempotency_key), 1);
}

#[test]
fn an_input_without_a_destination_fingerprint_never_reaches_a_connector() {
    let directory = tempdir().unwrap();
    let (library, published) = published_effect_library(directory.path(), "send");
    let mut input = effect_input("send");
    input
        .as_object_mut()
        .unwrap()
        .remove("destinationFingerprint");
    let command =
        run_command_with_input("run-effect-unfingerprinted-001", &published, "send", input);
    let mut host = effect_host("send", DeterministicEffectConnectorPlan::Succeed);
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    let result = workflow_executor::execute_with_effects(
        &mut journal,
        &library,
        &mut host,
        &command,
        SUBMITTED_AT_UNIX_MILLIS,
    )
    .unwrap();

    assert_eq!(result.outcome, DurableRunOutcome::Failed);
    let error = error_port_value(&journal, "run-effect-unfingerprinted-001");
    assert_eq!(
        error.get("code").and_then(Value::as_str),
        Some("effect.input-rejected")
    );
    // Nothing was proposed, so no approval could exist for an owner to grant.
    assert!(
        !journal_kinds(&journal, "run-effect-unfingerprinted-001")
            .contains(&WORKFLOW_EFFECT_PROPOSED_KIND.to_owned())
    );
}

fn effect_host(
    action: &str,
    plan: DeterministicEffectConnectorPlan,
) -> AutoApprovedWorkflowEffectHost {
    let mut host = AutoApprovedWorkflowEffectHost::new("owner-synthetic", "device-synthetic");
    host.register(
        WorkflowEffectConnectorRegistration {
            connector_class: "mail".into(),
            version: "1.0.0".into(),
            package_digest: CONNECTOR_DIGEST.into(),
            binding_id: "synthetic-mail-binding".into(),
            account_binding_id: ACCOUNT_BINDING_ID.into(),
            allowed_actions: vec![action.into()],
            idempotent: true,
            supports_reconciliation: true,
            registration_digest: String::new(),
        },
        plan,
    );
    host
}

fn published_effect_library(
    application_support: &std::path::Path,
    action: &str,
) -> (WorkflowLibraryStore, PublishedWorkflowRevision) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: EFFECT_WORKFLOW_ID.into(),
            package_id: "dev.kaname.mail-effects".into(),
            name: "Durable mail effect".into(),
            summary: "Synthetic connector effect fixture".into(),
            edit_id: format!("edit-effect-{action}"),
            session_id: "effect-executor-tests".into(),
            workflow_source: serde_json::to_vec(&effect_workflow_source(action)).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 60,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: EFFECT_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: effect_revision_id(action),
            registration_id: format!("registration-effect-{action}"),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "connector",
                    "id": CONNECTOR_PACKAGE_ID,
                    "version": "1.0.0",
                    "digest": format!("sha256:{CONNECTOR_DIGEST}")
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 70,
        })
        .unwrap();
    (library, published)
}

fn effect_revision_id(action: &str) -> String {
    format!("revision-effect-{action}-001")
}

fn effect_workflow_source(action: &str) -> Value {
    let ids = [
        "018f7000-0002-7000-8000-000000000002",
        "018f7000-0003-7000-8000-000000000003",
        "018f7000-0004-7000-8000-000000000004",
        "018f7000-0005-7000-8000-000000000005",
    ];
    let node = |index: usize, key: &str, node_type: &str, config: Value, policy: bool| {
        let mut node = json!({
            "id": ids[index], "key": key, "name": key,
            "type": node_type, "typeVersion": 1, "config": config
        });
        if policy {
            node.as_object_mut()
                .unwrap()
                .insert("policyRefs".into(), json!({"authority": "mail-authority"}));
        }
        node
    };
    let edge = |sequence: u16, from: (usize, &str), to: (usize, &str)| {
        json!({
            "id": format!("018f7100-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": ids[from.0], "portId": from.1},
            "to": {"nodeId": ids[to.0], "portId": to.1},
            "mappingId": format!("018f7200-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    json!({
        "formatVersion": 1,
        "workflowId": EFFECT_WORKFLOW_ID,
        "packageId": "dev.kaname.mail-effects",
        "name": "Durable mail effect",
        "summary": "Synthetic connector effect fixture",
        "graph": {
            "entrypoints": [{
                "id": "018f7000-0006-7000-8000-000000000006",
                "nodeId": ids[0]
            }],
            "nodes": [
                node(0, "manual", "trigger.manual", json!({}), false),
                node(1, "effect", "effect.connector", json!({
                    "connectorClass": CONNECTOR_PACKAGE_ID,
                    "action": action,
                    "input": {"whole": true},
                    "previewContract": format!("mail.{action}.preview.v1"),
                    "reconciliationContract": format!("mail.{action}.reconcile.v1"),
                    "idempotency": "required"
                }), true),
                node(2, "complete", "terminal.complete", json!({}), false),
                node(3, "fail", "terminal.fail", json!({}), false)
            ],
            "edges": [
                edge(1, (0, "success"), (1, "input")),
                edge(2, (1, "success"), (2, "input")),
                edge(3, (1, "error"), (3, "input"))
            ]
        },
        "interfaces": {},
        "resources": {},
        "policies": {
            "mail-authority": {
                "key": "mail-authority",
                "type": "authority",
                "typeVersion": 1,
                "config": {
                    "authorityClass": "mail-effect",
                    "approval": "always",
                    "reversible": false
                }
            }
        },
        "storage": {},
        "metadata": {}
    })
}

fn effect_input(action: &str) -> Value {
    json!({
        "accountBindingId": ACCOUNT_BINDING_ID,
        "destinationFingerprint": DESTINATION_FINGERPRINT,
        "action": action,
        "conversationId": "synthetic-thread"
    })
}

fn input_digest(action: &str) -> String {
    let bytes = serde_json_canonicalizer::to_vec(&effect_input(action)).unwrap();
    hex::encode(Sha256::digest(&bytes))
}

fn effect_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    action: &str,
) -> CommandEnvelope {
    run_command_with_input(run_id, published, action, effect_input(action))
}

fn run_command_with_input(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    action: &str,
    input: Value,
) -> CommandEnvelope {
    let bytes = serde_json_canonicalizer::to_vec(&input).unwrap();
    let value = WorkflowValueReference {
        value_id: format!("value-{run_id}-input"),
        content_type: "application/json".into(),
        byte_count: bytes.len() as u64,
        sha256: hex::encode(Sha256::digest(&bytes)),
        inline_canonical_json: bytes,
        storage_reference_id: String::new(),
        storage: None,
    };
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: format!("command-{run_id}"),
        idempotency_key: format!("idempotency-{run_id}"),
        kind: WORKFLOW_RUN_REQUEST_KIND.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: WORKFLOW_RUN_REQUEST_TYPE.into(),
            content_type: "application/x-protobuf".into(),
            value: RequestWorkflowRun {
                run_id: run_id.into(),
                workflow_id: EFFECT_WORKFLOW_ID.into(),
                revision_id: effect_revision_id(action),
                package_digest: published.package_digest.clone(),
                trigger_kind: "manual".into(),
                trigger_event_id: String::new(),
                inputs: vec![WorkflowInputBinding {
                    port_id: "input".into(),
                    value: Some(value),
                }],
                installation_id: "installation-mail-001".into(),
                case_id: "case-mail-001".into(),
                episode_id: String::new(),
                episode_kind: String::new(),
                prior_episode_id: String::new(),
            }
            .encode_to_vec(),
            payload_version: 1,
        }),
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
        submitted_at_unix_millis: SUBMITTED_AT_UNIX_MILLIS,
    }
}

fn projected_authority(
    journal: &Journal,
    run_id: &str,
) -> kaname_core::v1::WorkflowProjectedEffectAuthority {
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(journal).unwrap();
    let effect_id = run_events(journal, run_id)
        .into_iter()
        .filter(|envelope| envelope.kind == WORKFLOW_EFFECT_PROPOSED_KIND)
        .map(|envelope| {
            WorkflowEffectProposed::decode(envelope.payload.unwrap().value.as_slice())
                .unwrap()
                .intent
                .unwrap()
                .effect_id
        })
        .next()
        .expect("one proposed effect");
    projection.effect_authority(&effect_id).unwrap().unwrap()
}

fn reconciliation_outcomes(journal: &Journal, run_id: &str) -> Vec<i32> {
    run_events(journal, run_id)
        .into_iter()
        .filter(|envelope| envelope.kind == WORKFLOW_EFFECT_RECONCILED_KIND)
        .map(|envelope| {
            WorkflowEffectReconciled::decode(envelope.payload.unwrap().value.as_slice())
                .unwrap()
                .outcome
        })
        .collect()
}

fn emitted_port_ids(journal: &Journal, run_id: &str) -> Vec<String> {
    run_events(journal, run_id)
        .iter()
        .filter_map(|envelope| match decode_workflow_event(envelope) {
            Ok(kaname_core::workflow_runtime::WorkflowRuntimeEvent::PortEmitted(payload)) => {
                Some(payload.port_id)
            }
            _ => None,
        })
        .collect()
}

fn error_port_value(journal: &Journal, run_id: &str) -> Value {
    let emission = run_events(journal, run_id)
        .iter()
        .filter_map(|envelope| match decode_workflow_event(envelope) {
            Ok(kaname_core::workflow_runtime::WorkflowRuntimeEvent::PortEmitted(payload))
                if payload.port_id == "error" =>
            {
                Some(payload)
            }
            _ => None,
        })
        .next()
        .expect("one error emission");
    serde_json::from_slice(&emission.value.unwrap().inline_canonical_json).unwrap()
}

fn journal_kinds(journal: &Journal, run_id: &str) -> Vec<String> {
    run_events(journal, run_id)
        .into_iter()
        .map(|envelope| envelope.kind)
        .collect()
}

fn run_events(journal: &Journal, run_id: &str) -> Vec<kaname_core::v1::EventEnvelope> {
    let page = journal
        .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
        .unwrap();
    assert_eq!(page.basis, ReplayBasis::Events);
    assert!(!page.has_more);
    page.events
}

fn run_wires(journal: &Journal, run_id: &str) -> Vec<Vec<u8>> {
    run_events(journal, run_id)
        .into_iter()
        .map(|envelope| envelope.encode_to_vec())
        .collect()
}
