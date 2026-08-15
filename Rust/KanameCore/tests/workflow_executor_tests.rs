use kaname_core::{
    journal::{Journal, ReplayBasis},
    open_workflow_library, open_workflow_scoped_storage,
    v1::{
        CancelWorkflowRun, CommandEnvelope, OpaqueTypedPayload, RequestWorkflowRun, SchemaVersion,
        Scope, SignalWorkflowWait, WorkflowInputBinding, WorkflowRunTokenCreated,
        WorkflowStorageValueMetadata, WorkflowValueReference, WorkflowWaitCorrelation,
    },
    workflow_capabilities::{
        DeterministicCapabilityPlan, DeterministicWorkflowCapabilityHost,
        WorkflowCapabilityArtifactHandle, WorkflowCapabilityDefinition, WorkflowCapabilityLog,
        WorkflowCapabilityValue,
    },
    workflow_drafts::{CreateWorkflowDraft, SaveWorkflowDraft},
    workflow_executor::{
        self, DurableRunOutcome, WorkflowExecutionError, WorkflowExecutionFault,
        WorkflowStorageExecutionAuthority,
    },
    workflow_llm::{
        DeterministicLlmPlan, DeterministicWorkflowLlmProvider, WorkflowLlmProviderDefinition,
        WorkflowLlmProviderResponseMessage, WorkflowLlmProviderToolCall,
        WorkflowLlmProviderToolDefinition, WorkflowLlmProviderToolResult, WorkflowLlmProviderTrace,
        WorkflowLlmProviderUsage,
    },
    workflow_object_store::WorkflowObjectStoreQuota,
    workflow_projection::WorkflowRunProjection,
    workflow_publication::{PublishWorkflowRevision, PublishedWorkflowRevision},
    workflow_runtime::{
        WORKFLOW_CAPABILITY_ATTEMPT_STARTED_KIND, WORKFLOW_LLM_ATTEMPT_STARTED_KIND,
        WORKFLOW_RUN_CANCEL_KIND, WORKFLOW_RUN_CANCEL_TYPE, WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE, WORKFLOW_RUN_TOKEN_CREATED_KIND, WORKFLOW_WAIT_SIGNAL_KIND,
        WORKFLOW_WAIT_SIGNAL_TYPE,
    },
    workflow_storage::{
        WorkflowStorageAccessContext, WorkflowStorageNamespace, WorkflowStorageScopeKind,
    },
};
use prost::Message;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x5c; 32];
const WORKFLOW_ID: &str = "018f5000-0001-7000-8000-000000000001";
const MANUAL_ID: &str = "018f5000-0002-7000-8000-000000000002";
const VALIDATE_ID: &str = "018f5000-0003-7000-8000-000000000003";
const MATCH_ID: &str = "018f5000-0004-7000-8000-000000000004";
const COMPLETE_MATCH_ID: &str = "018f5000-0005-7000-8000-000000000005";
const COMPLETE_OTHERWISE_ID: &str = "018f5000-0006-7000-8000-000000000006";
const FAIL_VALIDATE_ID: &str = "018f5000-0007-7000-8000-000000000007";
const FAIL_MATCH_ID: &str = "018f5000-0008-7000-8000-000000000008";
const CASE_FIVE_ID: &str = "018f5000-0009-7000-8000-000000000009";
const OTHERWISE_ID: &str = "018f5000-0010-7000-8000-000000000010";
const REVISION_ID: &str = "revision-minimal-001";
const STORAGE_WORKFLOW_ID: &str = "018f5300-0001-7000-8000-000000000001";
const STORAGE_REVISION_ID: &str = "revision-storage-001";
const PARALLEL_WORKFLOW_ID: &str = "018f5600-0001-7000-8000-000000000001";
const PARALLEL_REVISION_ID: &str = "revision-parallel-001";
const ITERATION_WORKFLOW_ID: &str = "018f5900-0001-7000-8000-000000000001";
const ITERATION_REVISION_ID: &str = "revision-iteration-001";
const RETRY_WORKFLOW_ID: &str = "018f5c00-0001-7000-8000-000000000001";
const RETRY_REVISION_ID: &str = "revision-retry-001";
const WAIT_WORKFLOW_ID: &str = "018f6000-0001-7000-8000-000000000001";
const WAIT_REVISION_ID: &str = "revision-wait-001";
const CASE_WORKFLOW_ID: &str = "018f6300-0001-7000-8000-000000000001";
const CASE_REVISION_ID: &str = "revision-case-001";
const SUBFLOW_CHILD_WORKFLOW_ID: &str = "018f6600-0001-7000-8000-000000000001";
const SUBFLOW_CHILD_REVISION_ID: &str = "revision-subflow-child-001";
const SUBFLOW_PARENT_WORKFLOW_ID: &str = "018f6700-0001-7000-8000-000000000001";
const SUBFLOW_PARENT_REVISION_ID: &str = "revision-subflow-parent-001";
const CAPABILITY_WORKFLOW_ID: &str = "018f6900-0001-7000-8000-000000000001";
const CAPABILITY_REVISION_ID: &str = "revision-capability-001";
const CAPABILITY_NODE_ID: &str = "018f6900-0003-7000-8000-000000000003";
const CAPABILITY_ID: &str = "dev.kaname.synthetic-capability";
const CAPABILITY_DIGEST: &str = "7f4a9e4a2bcf75d0f6b3178c30ec24047be25884a662111e77a02b179704cad8";
const LLM_WORKFLOW_ID: &str = "018f6b00-0001-7000-8000-000000000001";
const LLM_REVISION_ID: &str = "revision-llm-001";
const LLM_NODE_ID: &str = "018f6b00-0003-7000-8000-000000000003";

#[test]
fn typed_capability_attempt_records_contract_logs_receipt_and_is_crash_exact() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_capability_library(directory.path());
        let command = control_run_command(
            "run-capability-success-001",
            &published,
            CAPABILITY_WORKFLOW_ID,
            CAPABILITY_REVISION_ID,
            json!({"text": "hello"}),
        );
        let mut host = capability_host(DeterministicCapabilityPlan::Succeed {
            output: WorkflowCapabilityValue::Json(json!({"normalized": "HELLO"})),
            artifacts: vec![synthetic_capability_artifact()],
            logs: vec![
                WorkflowCapabilityLog {
                    level: "info".into(),
                    message: "Read /Users/example/private-input".into(),
                    offset_milliseconds: 2,
                },
                WorkflowCapabilityLog {
                    level: "warning".into(),
                    message: "password=must-not-survive".into(),
                    offset_milliseconds: 4,
                },
            ],
            elapsed_milliseconds: 5,
        });
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute_with_capabilities(
                &mut journal,
                &library,
                &mut host,
                &command,
            )
            .unwrap()
            .outcome,
            DurableRunOutcome::Succeeded
        );
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("capability_attempts").unwrap(), 1);
        let run = projection
            .inspect_runs(None, Some("run-capability-success-001"), 1)
            .unwrap()
            .pop()
            .unwrap();
        let capability = &run.capability_attempts[0];
        assert_eq!(capability.node_id, CAPABILITY_NODE_ID);
        assert_eq!(capability.capability_id, CAPABILITY_ID);
        assert_eq!(capability.version, "1.0.0");
        assert_eq!(capability.package_digest, CAPABILITY_DIGEST);
        assert_eq!(capability.status, "settled");
        assert_eq!(capability.outcome, "succeeded");
        assert_eq!(capability.elapsed_milliseconds, 5);
        assert_eq!(capability.idempotency_key, capability.invocation_id);
        assert!(capability.receipt_id.starts_with("receipt-"));
        assert_eq!(capability.logs.len(), 2);
        assert_eq!(capability.artifact_outputs.len(), 1);
        assert_eq!(capability.artifact_outputs[0].role, "normalized-document");
        assert_eq!(
            capability.artifact_outputs[0]
                .value
                .as_ref()
                .unwrap()
                .storage_reference_id,
            "handle-capability-output-001"
        );
        assert_eq!(capability.logs[0].message, "Read [redacted-path]");
        assert_eq!(
            capability.logs[1].message,
            "[redacted sensitive capability evidence]"
        );
        assert_eq!(host.invocation_count(&capability.invocation_id), 1);
        run_wires(&journal, "run-capability-success-001")
    };

    for boundary in 1..=expected.len() {
        let directory = tempdir().unwrap();
        let (library, published) = published_capability_library(directory.path());
        let command = control_run_command(
            "run-capability-success-001",
            &published,
            CAPABILITY_WORKFLOW_ID,
            CAPABILITY_REVISION_ID,
            json!({"text": "hello"}),
        );
        let mut host = capability_host(DeterministicCapabilityPlan::Succeed {
            output: WorkflowCapabilityValue::Json(json!({"normalized": "HELLO"})),
            artifacts: vec![synthetic_capability_artifact()],
            logs: vec![
                WorkflowCapabilityLog {
                    level: "info".into(),
                    message: "Read /Users/example/private-input".into(),
                    offset_milliseconds: 2,
                },
                WorkflowCapabilityLog {
                    level: "warning".into(),
                    message: "password=must-not-survive".into(),
                    offset_milliseconds: 4,
                },
            ],
            elapsed_milliseconds: 5,
        });
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_capabilities_fault_for_test(
                &mut journal,
                &library,
                &mut host,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute_with_capabilities(
                &mut journal,
                &library,
                &mut host,
                &command,
            )
            .unwrap()
            .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(run_wires(&journal, "run-capability-success-001"), expected);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        let invocation_id = projection
            .inspect_runs(None, Some("run-capability-success-001"), 1)
            .unwrap()[0]
            .capability_attempts[0]
            .invocation_id
            .clone();
        assert_eq!(host.invocation_count(&invocation_id), 1);
    }
}

#[test]
fn capability_validation_timeout_malformed_and_crash_are_typed_failures() {
    let scenarios = [
        (
            "run-capability-timeout-001",
            DeterministicCapabilityPlan::TimeOut {
                logs: Vec::new(),
                elapsed_milliseconds: 100,
            },
            "timed_out",
            "capability.timeout",
        ),
        (
            "run-capability-malformed-001",
            DeterministicCapabilityPlan::Malformed {
                summary: "No structured result was returned.".into(),
                logs: Vec::new(),
                elapsed_milliseconds: 3,
            },
            "malformed_result",
            "capability.malformed-result",
        ),
        (
            "run-capability-crashed-001",
            DeterministicCapabilityPlan::Crash {
                summary: "The isolated worker exited.".into(),
                logs: Vec::new(),
                elapsed_milliseconds: 2,
            },
            "crashed",
            "capability.crashed",
        ),
        (
            "run-capability-output-invalid-001",
            DeterministicCapabilityPlan::Succeed {
                output: WorkflowCapabilityValue::Json(json!({"wrong": true})),
                artifacts: Vec::new(),
                logs: Vec::new(),
                elapsed_milliseconds: 1,
            },
            "output_validation_failed",
            "capability.output-validation-failed",
        ),
    ];
    for (run_id, plan, expected_outcome, expected_error) in scenarios {
        let directory = tempdir().unwrap();
        let (library, published) = published_capability_library(directory.path());
        let command = control_run_command(
            run_id,
            &published,
            CAPABILITY_WORKFLOW_ID,
            CAPABILITY_REVISION_ID,
            json!({"text": "hello"}),
        );
        let mut host = capability_host(plan);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute_with_capabilities(
                &mut journal,
                &library,
                &mut host,
                &command,
            )
            .unwrap()
            .outcome,
            DurableRunOutcome::Failed
        );
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        let run = projection
            .inspect_runs(None, Some(run_id), 1)
            .unwrap()
            .pop()
            .unwrap();
        assert_eq!(run.capability_attempts[0].outcome, expected_outcome);
        assert_eq!(run.capability_attempts[0].error_code, expected_error);
        assert!(run.capability_attempts[0].error.is_some());
    }

    let directory = tempdir().unwrap();
    let (library, published) = published_capability_library(directory.path());
    let command = control_run_command(
        "run-capability-input-invalid-001",
        &published,
        CAPABILITY_WORKFLOW_ID,
        CAPABILITY_REVISION_ID,
        json!({"wrong": true}),
    );
    let mut host = capability_host(DeterministicCapabilityPlan::Succeed {
        output: WorkflowCapabilityValue::Json(json!({"normalized": "unused"})),
        artifacts: Vec::new(),
        logs: Vec::new(),
        elapsed_milliseconds: 1,
    });
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_with_capabilities(&mut journal, &library, &mut host, &command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Failed
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let capability = &projection
        .inspect_runs(None, Some("run-capability-input-invalid-001"), 1)
        .unwrap()[0]
        .capability_attempts[0];
    assert_eq!(capability.outcome, "input_validation_failed");
    assert_eq!(capability.error_code, "capability.input-validation-failed");
    assert_eq!(host.invocation_count(&capability.invocation_id), 0);
}

#[test]
fn cancellation_settles_a_started_capability_without_invoking_the_host() {
    let directory = tempdir().unwrap();
    let (library, published) = published_capability_library(directory.path());
    let command = control_run_command(
        "run-capability-cancel-001",
        &published,
        CAPABILITY_WORKFLOW_ID,
        CAPABILITY_REVISION_ID,
        json!({"text": "hello"}),
    );
    let mut host = capability_host(DeterministicCapabilityPlan::Succeed {
        output: WorkflowCapabilityValue::Json(json!({"normalized": "unused"})),
        artifacts: Vec::new(),
        logs: Vec::new(),
        elapsed_milliseconds: 1,
    });
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    loop {
        assert!(matches!(
            workflow_executor::execute_with_capabilities_fault_for_test(
                &mut journal,
                &library,
                &mut host,
                &command,
                WorkflowExecutionFault::AfterNewEvent(1),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        let page = journal
            .replay("thread:workflow-run:run-capability-cancel-001", None, 500)
            .unwrap();
        if page
            .events
            .iter()
            .any(|event| event.kind == WORKFLOW_CAPABILITY_ATTEMPT_STARTED_KIND)
        {
            break;
        }
    }
    let token = run_token(&journal, "run-capability-cancel-001");
    workflow_executor::request_cancellation(
        &mut journal,
        &cancel_command("run-capability-cancel-001", &token.run_token_id),
    )
    .unwrap();
    assert_eq!(
        workflow_executor::execute_with_capabilities(&mut journal, &library, &mut host, &command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Cancelled
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let capability = &projection
        .inspect_runs(None, Some("run-capability-cancel-001"), 1)
        .unwrap()[0]
        .capability_attempts[0];
    assert_eq!(capability.outcome, "cancelled");
    assert_eq!(host.invocation_count(&capability.invocation_id), 0);
}

#[test]
fn unregistered_capability_is_rejected_before_command_admission() {
    let directory = tempdir().unwrap();
    let (library, published) = published_capability_library(directory.path());
    let command = control_run_command(
        "run-capability-unregistered-001",
        &published,
        CAPABILITY_WORKFLOW_ID,
        CAPABILITY_REVISION_ID,
        json!({"text": "hello"}),
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();

    assert!(matches!(
        workflow_executor::execute(&mut journal, &library, &command),
        Err(WorkflowExecutionError::Unsupported(code))
            if code == "capability_not_registered"
    ));
    assert_eq!(journal.event_page_after(0, 10).unwrap().high_water_mark, 0);
}

#[test]
fn inspectable_llm_context_is_redacted_bounded_and_crash_exact() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_llm_library(directory.path(), "job", 32_768);
        let command = control_run_command(
            "run-llm-success-001",
            &published,
            LLM_WORKFLOW_ID,
            LLM_REVISION_ID,
            json!({
                "request": "Summarize /Users/example/private/source.docx",
                "password": "must-not-survive",
                "authorization": "Bearer must-not-survive"
            }),
        );
        let mut provider = llm_provider(DeterministicLlmPlan::Succeed {
            output: json!({"summary": "Safe result"}),
            elapsed_milliseconds: 7,
        });
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &command,)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("llm_attempts").unwrap(), 1);
        let run = projection
            .inspect_runs(None, Some("run-llm-success-001"), 1)
            .unwrap()
            .pop()
            .unwrap();
        let llm = &run.llm_attempts[0];
        assert_eq!(llm.node_id, LLM_NODE_ID);
        assert_eq!(llm.status, "settled");
        assert_eq!(llm.outcome, "succeeded");
        assert_eq!(llm.settings.as_ref().unwrap().model_id, "synthetic-model");
        assert_eq!(llm.messages.len(), 3);
        assert_eq!(llm.messages[0].role, "system");
        assert_eq!(llm.messages[1].role, "developer");
        assert_eq!(llm.messages[2].role, "user");
        assert!(llm.compilation_report.as_ref().unwrap().redaction_count >= 3);
        assert_eq!(llm.idempotency_key, llm.invocation_id);
        assert!(llm.receipt_id.starts_with("receipt-"));
        for content in llm
            .context_groups
            .iter()
            .filter_map(|group| group.content.as_ref())
            .map(|value| String::from_utf8_lossy(&value.inline_canonical_json))
        {
            assert!(!content.contains("/Users/"));
            assert!(!content.contains("must-not-survive"));
        }
        assert_eq!(provider.invocation_count(&llm.invocation_id), 1);
        (
            run_wires(&journal, "run-llm-success-001"),
            llm.context_digest.clone(),
        )
    };

    for boundary in 1..=expected.0.len() {
        let directory = tempdir().unwrap();
        let (library, published) = published_llm_library(directory.path(), "job", 32_768);
        let command = control_run_command(
            "run-llm-success-001",
            &published,
            LLM_WORKFLOW_ID,
            LLM_REVISION_ID,
            json!({
                "request": "Summarize /Users/example/private/source.docx",
                "password": "must-not-survive",
                "authorization": "Bearer must-not-survive"
            }),
        );
        let mut provider = llm_provider(DeterministicLlmPlan::Succeed {
            output: json!({"summary": "Safe result"}),
            elapsed_milliseconds: 7,
        });
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_llm_fault_for_test(
                &mut journal,
                &library,
                &mut provider,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &command,)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(run_wires(&journal, "run-llm-success-001"), expected.0);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        let llm = &projection
            .inspect_runs(None, Some("run-llm-success-001"), 1)
            .unwrap()[0]
            .llm_attempts[0];
        assert_eq!(llm.context_digest, expected.1);
        assert_eq!(provider.invocation_count(&llm.invocation_id), 1);
    }
}

#[test]
fn llm_tool_calls_responses_usage_and_large_payload_summaries_are_inspectable() {
    let directory = tempdir().unwrap();
    let (library, published) = published_llm_tool_library(directory.path());
    let command = control_run_command(
        "run-llm-tools-001",
        &published,
        LLM_WORKFLOW_ID,
        LLM_REVISION_ID,
        json!({"request": "Use the admitted synthetic search tool"}),
    );
    let mut provider = llm_tool_provider();
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let run = projection
        .inspect_runs(None, Some("run-llm-tools-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let llm = &run.llm_attempts[0];
    assert_eq!(llm.tool_definitions.len(), 1);
    assert_eq!(llm.tool_definitions[0].tool_id, "synthetic.search");
    assert_eq!(llm.tool_calls.len(), 2);
    assert_eq!(llm.tool_calls[0].status, "succeeded");
    assert!(llm.tool_calls[0].output.is_some());
    assert_eq!(llm.tool_calls[1].status, "failed");
    assert_eq!(llm.tool_calls[1].error_code, "tool.synthetic-failure");
    assert!(llm.tool_calls[1].error.is_some());
    assert_eq!(llm.response_messages.len(), 2);
    let summarized = llm.response_messages[0].content.as_ref().unwrap();
    assert!(
        String::from_utf8_lossy(&summarized.inline_canonical_json).contains("\"summarized\":true")
    );
    let usage = llm.usage.as_ref().unwrap();
    assert_eq!(usage.total_tokens, 170);
    assert_eq!(usage.tool_call_count, 2);
    assert_eq!(usage.total_cost_micros, 235);
    assert_eq!(llm.validation.as_ref().unwrap().status, "succeeded");
    assert_eq!(
        llm.provider_receipt.as_ref().unwrap().request_id,
        "provider-request-tools-001"
    );
    assert!(llm.output.is_some());
}

#[test]
fn llm_case_context_retains_prior_episode_identity_and_reports_truncation() {
    let directory = tempdir().unwrap();
    let (library, published) = published_llm_library(directory.path(), "case", 1_200);
    let initial = llm_case_run_command(
        "run-llm-case-initial",
        &published,
        "episode-llm-initial",
        "initial",
        "",
        "email-llm-initial",
        json!({"request": "x".repeat(5_000)}),
    );
    let correction = llm_case_run_command(
        "run-llm-case-correction",
        &published,
        "episode-llm-correction",
        "correction",
        "episode-llm-initial",
        "email-llm-correction",
        json!({"request": "Please make the requested correction"}),
    );
    let mut provider = llm_provider(DeterministicLlmPlan::Succeed {
        output: json!({"summary": "Revised result"}),
        elapsed_milliseconds: 3,
    });
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &initial).unwrap();
    assert_eq!(
        workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &correction,)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let correction = projection
        .inspect_runs(None, Some("run-llm-case-correction"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let llm = &correction.llm_attempts[0];
    assert_eq!(llm.prior_episode_ids, ["episode-llm-initial"]);
    assert!(
        llm.context_groups
            .iter()
            .any(|group| group.kind == "prior_case_episodes"
                && group.source_episode_ids == ["episode-llm-initial"])
    );
    let report = llm.compilation_report.as_ref().unwrap();
    assert!(report.retained_byte_count <= 1_200);
    assert!(!report.truncated_group_ids.is_empty() || !report.dropped_group_ids.is_empty());
}

#[test]
fn llm_failures_are_typed_and_an_unregistered_provider_admits_nothing() {
    for (run_id, plan, expected_outcome, expected_error) in [
        (
            "run-llm-timeout",
            DeterministicLlmPlan::TimeOut {
                elapsed_milliseconds: 100,
            },
            "timed_out",
            "llm.timeout",
        ),
        (
            "run-llm-malformed",
            DeterministicLlmPlan::Malformed {
                summary: "No structured result was returned.".into(),
                elapsed_milliseconds: 2,
            },
            "malformed_result",
            "llm.malformed-result",
        ),
        (
            "run-llm-crashed",
            DeterministicLlmPlan::Crash {
                summary: "The isolated model worker exited.".into(),
                elapsed_milliseconds: 1,
            },
            "crashed",
            "llm.crashed",
        ),
        (
            "run-llm-output-invalid",
            DeterministicLlmPlan::Succeed {
                output: json!({"wrong": true}),
                elapsed_milliseconds: 1,
            },
            "output_validation_failed",
            "llm.output-validation-failed",
        ),
        (
            "run-llm-private-output",
            DeterministicLlmPlan::Succeed {
                output: json!({"summary": "Read /Users/example/private/source.docx"}),
                elapsed_milliseconds: 1,
            },
            "malformed_result",
            "llm.private-output-rejected",
        ),
    ] {
        let directory = tempdir().unwrap();
        let (library, published) = published_llm_library(directory.path(), "job", 32_768);
        let command = control_run_command(
            run_id,
            &published,
            LLM_WORKFLOW_ID,
            LLM_REVISION_ID,
            json!({"request": "Summarize"}),
        );
        let mut provider = llm_provider(plan);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &command,)
                .unwrap()
                .outcome,
            DurableRunOutcome::Failed
        );
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        let llm = &projection.inspect_runs(None, Some(run_id), 1).unwrap()[0].llm_attempts[0];
        assert_eq!(llm.outcome, expected_outcome);
        assert_eq!(llm.error_code, expected_error);
        assert!(llm.error.is_some());
    }

    let directory = tempdir().unwrap();
    let (library, published) = published_llm_library(directory.path(), "job", 32_768);
    let command = control_run_command(
        "run-llm-unregistered",
        &published,
        LLM_WORKFLOW_ID,
        LLM_REVISION_ID,
        json!({"request": "Summarize"}),
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute(&mut journal, &library, &command),
        Err(WorkflowExecutionError::Unsupported(code)) if code == "llm_provider_not_registered"
    ));
    assert_eq!(journal.event_page_after(0, 10).unwrap().high_water_mark, 0);
}

#[test]
fn cancellation_settles_compiled_llm_context_without_invoking_the_provider() {
    let directory = tempdir().unwrap();
    let (library, published) = published_llm_library(directory.path(), "job", 32_768);
    let command = control_run_command(
        "run-llm-cancel",
        &published,
        LLM_WORKFLOW_ID,
        LLM_REVISION_ID,
        json!({"request": "Summarize"}),
    );
    let mut provider = llm_provider(DeterministicLlmPlan::Succeed {
        output: json!({"summary": "unused"}),
        elapsed_milliseconds: 1,
    });
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    loop {
        assert!(matches!(
            workflow_executor::execute_with_llm_fault_for_test(
                &mut journal,
                &library,
                &mut provider,
                &command,
                WorkflowExecutionFault::AfterNewEvent(1),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        if journal
            .replay("thread:workflow-run:run-llm-cancel", None, 500)
            .unwrap()
            .events
            .iter()
            .any(|event| event.kind == WORKFLOW_LLM_ATTEMPT_STARTED_KIND)
        {
            break;
        }
    }
    let token = run_token(&journal, "run-llm-cancel");
    workflow_executor::request_cancellation(
        &mut journal,
        &cancel_command("run-llm-cancel", &token.run_token_id),
    )
    .unwrap();
    assert_eq!(
        workflow_executor::execute_with_llm(&mut journal, &library, &mut provider, &command,)
            .unwrap()
            .outcome,
        DurableRunOutcome::Cancelled
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let llm = &projection
        .inspect_runs(None, Some("run-llm-cancel"), 1)
        .unwrap()[0]
        .llm_attempts[0];
    assert_eq!(llm.outcome, "cancelled");
    assert_eq!(provider.invocation_count(&llm.invocation_id), 0);
}

#[test]
fn bounded_iteration_limits_concurrency_collects_failures_and_is_crash_exact() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_iteration_library(directory.path(), "collect");
        let command = control_run_command(
            "run-iteration-001",
            &published,
            ITERATION_WORKFLOW_ID,
            ITERATION_REVISION_ID,
            json!({"items": [1, "invalid", 3]}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(result.outcome, DurableRunOutcome::Succeeded);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("iterations").unwrap(), 1);
        let run = projection
            .inspect_runs(None, Some("run-iteration-001"), 1)
            .unwrap()
            .pop()
            .unwrap();
        let iteration = &run.iterations[0];
        assert_eq!(iteration.item_count, 3);
        assert_eq!(iteration.maximum_items, 4);
        assert_eq!(iteration.maximum_concurrency, 2);
        assert_eq!(iteration.decision, "succeeded");
        assert_eq!(iteration.succeeded_execution_token_ids.len(), 2);
        assert_eq!(iteration.failed_execution_token_ids.len(), 1);
        assert!(iteration.pending_execution_token_ids.is_empty());
        assert_eq!(
            run.execution_tokens
                .iter()
                .filter(|token| !token.iteration_node_id.is_empty())
                .count(),
            3
        );
        run_wires(&journal, "run-iteration-001")
    };

    for boundary in 1..=expected.len() {
        let directory = tempdir().unwrap();
        let (library, published) = published_iteration_library(directory.path(), "collect");
        let command = control_run_command(
            "run-iteration-001",
            &published,
            ITERATION_WORKFLOW_ID,
            ITERATION_REVISION_ID,
            json!({"items": [1, "invalid", 3]}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(run_wires(&journal, "run-iteration-001"), expected);
    }
}

#[test]
fn fail_fast_iteration_records_pending_partition_and_cancels_remaining_items() {
    let directory = tempdir().unwrap();
    let (library, published) = published_iteration_library(directory.path(), "fail-fast");
    let command = control_run_command(
        "run-iteration-fail-fast-001",
        &published,
        ITERATION_WORKFLOW_ID,
        ITERATION_REVISION_ID,
        json!({"items": [1, "invalid", 3]}),
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            command.submitted_at_unix_millis,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Failed
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let run = projection
        .inspect_runs(None, Some("run-iteration-fail-fast-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let iteration = &run.iterations[0];
    assert_eq!(iteration.decision, "failed");
    assert_eq!(iteration.succeeded_execution_token_ids.len(), 1);
    assert_eq!(iteration.failed_execution_token_ids.len(), 1);
    assert_eq!(iteration.pending_execution_token_ids.len(), 1);
    assert!(run.execution_tokens.iter().any(|token| {
        iteration
            .pending_execution_token_ids
            .contains(&token.execution_token_id)
            && token.outcome == "cancelled"
    }));
}

#[test]
fn retry_deadline_and_attempt_counter_survive_restart_before_exhaustion() {
    let directory = tempdir().unwrap();
    let (library, published) = published_retry_library(directory.path());
    let command = control_run_command(
        "run-retry-001",
        &published,
        RETRY_WORKFLOW_ID,
        RETRY_REVISION_ID,
        json!({}),
    );
    let started_at = command.submitted_at_unix_millis;
    let deadline = started_at + 1_000;
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let waiting =
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, started_at)
            .unwrap();
    assert_eq!(waiting.outcome, DurableRunOutcome::Waiting);
    assert_eq!(waiting.next_attempt_at_unix_millis, Some(deadline));
    let waiting_wires = run_wires(&journal, "run-retry-001");

    let still_waiting =
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, deadline - 1)
            .unwrap();
    assert_eq!(still_waiting.outcome, DurableRunOutcome::Waiting);
    assert_eq!(still_waiting.next_attempt_at_unix_millis, Some(deadline));
    assert_eq!(run_wires(&journal, "run-retry-001"), waiting_wires);

    let settled =
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, deadline)
            .unwrap();
    assert_eq!(settled.outcome, DurableRunOutcome::Failed);
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("retries").unwrap(), 2);
    let run = projection
        .inspect_runs(None, Some("run-retry-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(
        run.attempts
            .iter()
            .filter(|attempt| attempt.node_id == "018f5c00-0003-7000-8000-000000000003")
            .map(|attempt| attempt.attempt_number)
            .collect::<Vec<_>>(),
        [1, 2]
    );
    assert_eq!(run.retries[0].decision, "scheduled");
    assert_eq!(run.retries[0].eligible_at_unix_millis, deadline);
    assert_eq!(run.retries[0].next_attempt_number, 2);
    assert_eq!(run.retries[1].decision, "exhausted");
    assert_eq!(run.retries[1].next_attempt_number, 3);
}

#[test]
fn durable_timer_wait_survives_restart_and_resumes_at_its_exact_deadline() {
    let directory = tempdir().unwrap();
    let (library, published) = published_wait_library(directory.path(), "timer");
    let command = control_run_command(
        "run-wait-timer-001",
        &published,
        WAIT_WORKFLOW_ID,
        WAIT_REVISION_ID,
        json!({"caseId": "case-42"}),
    );
    let started_at = command.submitted_at_unix_millis;
    let deadline = started_at + 5_000;
    let journal_path = directory.path().join("wait-runtime.sqlite");
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    let waiting =
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, started_at)
            .unwrap();
    assert_eq!(waiting.outcome, DurableRunOutcome::Waiting);
    assert_eq!(waiting.next_attempt_at_unix_millis, Some(deadline));
    let before = run_wires(&journal, "run-wait-timer-001");
    drop(journal);
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, deadline - 1,)
            .unwrap()
            .outcome,
        DurableRunOutcome::Waiting
    );
    assert_eq!(run_wires(&journal, "run-wait-timer-001"), before);
    assert_eq!(
        workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, deadline)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let run = projection
        .inspect_runs(None, Some("run-wait-timer-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(run.waits.len(), 1);
    assert_eq!(run.waits[0].kind, "timer");
    assert_eq!(run.waits[0].decision, "resumed");
    assert_eq!(run.waits[0].expires_at_unix_millis, deadline);
}

#[test]
fn wait_signal_before_subscription_is_correlated_once_and_projected() {
    let directory = tempdir().unwrap();
    let (library, published) = published_wait_library(directory.path(), "reply");
    let run_id = "run-wait-early-reply-001";
    let command = control_run_command(
        run_id,
        &published,
        WAIT_WORKFLOW_ID,
        WAIT_REVISION_ID,
        json!({"caseId": "case-42"}),
    );
    let signal = wait_signal_command(
        run_id,
        "signal-early-001",
        "reply",
        "case-42",
        1_786_220_099_900,
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(
        !workflow_executor::record_wait_signal(&mut journal, &signal)
            .unwrap()
            .duplicate
    );
    assert!(
        workflow_executor::record_wait_signal(&mut journal, &signal)
            .unwrap()
            .duplicate
    );
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            command.submitted_at_unix_millis + 300,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("wait_signals").unwrap(), 1);
    assert_eq!(projection.row_count("waits").unwrap(), 1);
    let run = projection
        .inspect_runs(None, Some(run_id), 1)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(run.wait_signals[0].signal_id, "signal-early-001");
    assert_eq!(run.waits[0].resolving_signal_id, "signal-early-001");
    assert_eq!(run.waits[0].revision_id, WAIT_REVISION_ID);
    assert_eq!(run.waits[0].package_digest, published.package_digest);
}

#[test]
fn wrong_correlation_cannot_resume_wait_and_exact_reply_does() {
    let directory = tempdir().unwrap();
    let (library, published) = published_wait_library(directory.path(), "event");
    let run_id = "run-wait-correlation-001";
    let command = control_run_command(
        run_id,
        &published,
        WAIT_WORKFLOW_ID,
        WAIT_REVISION_ID,
        json!({"caseId": "case-42"}),
    );
    let deadline = command.submitted_at_unix_millis + 5_000;
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            command.submitted_at_unix_millis,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Waiting
    );
    let wrong = wait_signal_command(
        run_id,
        "signal-wrong-001",
        "event",
        "case-99",
        command.submitted_at_unix_millis + 100,
    );
    workflow_executor::record_wait_signal(&mut journal, &wrong).unwrap();
    let still_waiting = workflow_executor::execute_at_unix_millis(
        &mut journal,
        &library,
        &command,
        command.submitted_at_unix_millis + 200,
    )
    .unwrap();
    assert_eq!(still_waiting.outcome, DurableRunOutcome::Waiting);
    assert_eq!(still_waiting.next_attempt_at_unix_millis, Some(deadline));

    let exact = wait_signal_command(
        run_id,
        "signal-exact-001",
        "event",
        "case-42",
        command.submitted_at_unix_millis + 300,
    );
    workflow_executor::record_wait_signal(&mut journal, &exact).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            command.submitted_at_unix_millis + 300,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Succeeded
    );
}

#[test]
fn reply_wait_expiry_and_cancellation_are_durable_terminal_decisions() {
    for (run_id, cancel, expected_decision, expected_outcome) in [
        (
            "run-wait-expiry-001",
            false,
            "expired",
            DurableRunOutcome::Succeeded,
        ),
        (
            "run-wait-cancel-001",
            true,
            "cancelled",
            DurableRunOutcome::Cancelled,
        ),
    ] {
        let directory = tempdir().unwrap();
        let (library, published) = published_wait_library(directory.path(), "reply");
        let command = control_run_command(
            run_id,
            &published,
            WAIT_WORKFLOW_ID,
            WAIT_REVISION_ID,
            json!({"caseId": "case-42"}),
        );
        let deadline = command.submitted_at_unix_millis + 5_000;
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute_at_unix_millis(
                &mut journal,
                &library,
                &command,
                command.submitted_at_unix_millis,
            )
            .unwrap()
            .outcome,
            DurableRunOutcome::Waiting
        );
        let outcome = if cancel {
            let token = run_token(&journal, run_id);
            workflow_executor::request_cancellation(
                &mut journal,
                &cancel_command(run_id, &token.run_token_id),
            )
            .unwrap();
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .outcome
        } else {
            workflow_executor::execute_at_unix_millis(&mut journal, &library, &command, deadline)
                .unwrap()
                .outcome
        };
        assert_eq!(outcome, expected_outcome);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        let run = projection
            .inspect_runs(None, Some(run_id), 1)
            .unwrap()
            .pop()
            .unwrap();
        assert_eq!(run.waits[0].decision, expected_decision);
        assert_ne!(run.waits[0].resolved_store_position, 0);
    }
}

#[test]
fn related_case_episodes_compile_prior_context_without_mutating_history() {
    let directory = tempdir().unwrap();
    let (library, published) = published_case_library(directory.path());
    let journal_path = directory.path().join("case-runtime.sqlite");
    let initial = case_run_command(
        "run-case-initial-001",
        &published,
        "episode-initial-001",
        "initial",
        "",
        "email-initial-001",
        json!({
            "message": "Create the first attachment",
            "threadId": "thread-kay-42",
            "changes": []
        }),
    );
    let initial_context = {
        let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &initial)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("cases").unwrap(), 1);
        assert_eq!(projection.row_count("episodes").unwrap(), 1);
        let run = projection
            .inspect_runs(None, Some("run-case-initial-001"), 1)
            .unwrap()
            .pop()
            .unwrap();
        let episode = run.episode.unwrap();
        assert_eq!(episode.ordinal, 1);
        assert_eq!(episode.kind, "initial");
        assert!(episode.source_episode_ids.is_empty());
        let context = episode.compiled_context.unwrap().inline_canonical_json;
        let decoded: Value = serde_json::from_slice(&context).unwrap();
        assert_eq!(decoded["priorEpisodes"], json!([]));
        context
    };

    let correction = case_run_command(
        "run-case-correction-001",
        &published,
        "episode-correction-001",
        "correction",
        "episode-initial-001",
        "email-correction-001",
        json!({
            "message": "Use DOCX rather than PDF",
            "threadId": "thread-kay-42",
            "changes": [{"path": "/format", "from": "PDF", "to": "DOCX"}]
        }),
    );
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute(&mut journal, &library, &correction)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("cases").unwrap(), 1);
    assert_eq!(projection.row_count("episodes").unwrap(), 2);
    let original = projection
        .inspect_runs(None, Some("run-case-initial-001"), 1)
        .unwrap()
        .pop()
        .unwrap()
        .episode
        .unwrap();
    assert_eq!(
        original.compiled_context.unwrap().inline_canonical_json,
        initial_context
    );
    let related = projection
        .inspect_runs(None, Some("run-case-correction-001"), 1)
        .unwrap()
        .pop()
        .unwrap()
        .episode
        .unwrap();
    assert_eq!(related.ordinal, 2);
    assert_eq!(related.prior_episode_id, "episode-initial-001");
    assert_eq!(related.source_episode_ids, ["episode-initial-001"]);
    let context: Value =
        serde_json::from_slice(&related.compiled_context.unwrap().inline_canonical_json).unwrap();
    assert_eq!(
        context["priorEpisodes"][0]["inputs"][0]["value"]["inline"]["message"],
        "Create the first attachment"
    );
    assert_eq!(context["priorEpisodes"][0]["revisionId"], CASE_REVISION_ID);
    assert_eq!(
        context["currentEpisode"]["inputs"][0]["value"]["inline"]["changes"][0]["to"],
        "DOCX"
    );
    assert!(
        !context["priorEpisodes"][0]["outputs"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let stale = case_run_command(
        "run-case-stale-001",
        &published,
        "episode-stale-001",
        "correction",
        "episode-initial-001",
        "email-stale-001",
        json!({"message": "stale correction"}),
    );
    assert!(matches!(
        workflow_executor::execute(&mut journal, &library, &stale),
        Err(WorkflowExecutionError::Lifecycle(code)) if code == "case_prior_episode_mismatch"
    ));
    assert!(run_wires(&journal, "run-case-stale-001").is_empty());
}

#[test]
fn synthetic_email_reply_wait_starts_a_correction_run_with_prior_attachment_context() {
    let directory = tempdir().unwrap();
    let (library, published) = published_wait_library(directory.path(), "reply");
    let journal_path = directory.path().join("feedback-case.sqlite");
    let initial = case_wait_run_command(
        "run-feedback-initial",
        &published,
        "episode-feedback-initial",
        "initial",
        "",
        "email-feedback-initial",
        json!({
            "caseId": "case-feedback-42",
            "intent": "initial",
            "message": "Create the monthly attachment"
        }),
    );
    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &initial,
            initial.submitted_at_unix_millis,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Waiting
    );
    drop(journal);

    let mut journal = Journal::open(&journal_path, &CURSOR_KEY).unwrap();
    let delivery = case_wait_signal_command(
        "run-feedback-initial",
        "signal-feedback-delivery",
        "case-feedback-42",
        json!({
            "caseId": "case-feedback-42",
            "message": "Delivered result",
            "attachment": {"name": "report-v1.docx", "sha256": "a"}
        }),
        initial.submitted_at_unix_millis + 100,
    );
    workflow_executor::record_wait_signal(&mut journal, &delivery).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &initial,
            initial.submitted_at_unix_millis + 100,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Succeeded
    );

    let correction = case_wait_run_command(
        "run-feedback-correction",
        &published,
        "episode-feedback-correction",
        "correction",
        "episode-feedback-initial",
        "email-feedback-correction",
        json!({
            "caseId": "case-feedback-42",
            "intent": "correction",
            "message": "Change the chart colour to blue"
        }),
    );
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &correction,
            correction.submitted_at_unix_millis,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Waiting
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let episode = projection
        .inspect_runs(None, Some("run-feedback-correction"), 1)
        .unwrap()
        .pop()
        .unwrap()
        .episode
        .unwrap();
    let context: Value =
        serde_json::from_slice(&episode.compiled_context.unwrap().inline_canonical_json).unwrap();
    let outputs = context["priorEpisodes"][0]["outputs"].as_array().unwrap();
    assert!(
        outputs
            .iter()
            .any(|output| { output["value"]["inline"]["attachment"]["name"] == "report-v1.docx" })
    );
    assert_eq!(
        context["currentEpisode"]["inputs"][0]["value"]["inline"]["message"],
        "Change the chart colour to blue"
    );
    assert_eq!(episode.source_episode_ids, ["episode-feedback-initial"]);
}

#[test]
fn correction_episode_resumes_at_every_new_journal_boundary_with_identical_context() {
    let directory = tempdir().unwrap();
    let (library, published) = published_case_library(directory.path());
    let initial = case_run_command(
        "run-case-boundary-initial",
        &published,
        "episode-case-boundary-initial",
        "initial",
        "",
        "email-case-boundary-initial",
        json!({"message": "Initial request"}),
    );
    let correction = case_run_command(
        "run-case-boundary-correction",
        &published,
        "episode-case-boundary-correction",
        "correction",
        "episode-case-boundary-initial",
        "email-case-boundary-correction",
        json!({"message": "Corrected request"}),
    );
    let expected = {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute(&mut journal, &library, &initial).unwrap();
        workflow_executor::execute(&mut journal, &library, &correction).unwrap();
        run_wires(&journal, "run-case-boundary-correction")
    };
    for boundary in 1..=expected.len() {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute(&mut journal, &library, &initial).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &correction,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &correction)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(
            run_wires(&journal, "run-case-boundary-correction"),
            expected
        );
    }
}

#[test]
fn pinned_subflow_runs_as_a_child_and_survives_later_child_publication() {
    let directory = tempdir().unwrap();
    let (mut library, child_v1, parent) = published_subflow_library(directory.path());
    let child_v2 = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: "revision-subflow-child-002".into(),
            registration_id: "registration-subflow-child-002".into(),
            release_version: "2.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 120,
        })
        .unwrap();
    assert_ne!(child_v1.package_digest, child_v2.package_digest);

    let command = control_run_command(
        "run-subflow-parent-001",
        &parent,
        SUBFLOW_PARENT_WORKFLOW_ID,
        SUBFLOW_PARENT_REVISION_ID,
        json!({"message": "keep the original child pin"}),
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute(&mut journal, &library, &command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("subflows").unwrap(), 1);
    let parent_run = projection
        .inspect_runs(None, Some("run-subflow-parent-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let invocation = parent_run.subflows.first().unwrap();
    assert_eq!(invocation.status, "settled");
    assert_eq!(invocation.outcome, "succeeded");
    assert_eq!(invocation.child_revision_id, SUBFLOW_CHILD_REVISION_ID);
    assert_eq!(invocation.child_package_digest, child_v1.package_digest);
    assert_ne!(invocation.child_package_digest, child_v2.package_digest);
    assert_eq!(
        invocation.output.as_ref().unwrap().inline_canonical_json,
        invocation.input.as_ref().unwrap().inline_canonical_json
    );
    let child_run = projection
        .inspect_runs(None, Some(&invocation.child_run_id), 1)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(child_run.revision_id, SUBFLOW_CHILD_REVISION_ID);
    assert_eq!(child_run.package_digest, child_v1.package_digest);
}

#[test]
fn subflow_nodes_share_the_parent_job_storage_boundary() {
    let directory = tempdir().unwrap();
    let (library, parent) = published_subflow_storage_library(directory.path());
    let mut storage = test_scoped_storage(directory.path());
    let mut command = control_run_command(
        "run-subflow-storage-parent",
        &parent,
        SUBFLOW_PARENT_WORKFLOW_ID,
        SUBFLOW_PARENT_REVISION_ID,
        json!({"draft": {"message": "shared across the whole job"}}),
    );
    let mut request =
        RequestWorkflowRun::decode(command.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.installation_id = "installation-storage-001".into();
    command.payload.as_mut().unwrap().value = request.encode_to_vec();

    assert_eq!(
        workflow_executor::execute_with_storage(
            &mut Journal::open_in_memory(&CURSOR_KEY).unwrap(),
            &library,
            &mut storage,
            &storage_authority(),
            &command,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Succeeded
    );

    let parent_access = WorkflowStorageAccessContext {
        run_id: Some("run-subflow-storage-parent".into()),
        case_id: None,
        installation_id: "installation-storage-001".into(),
        account_binding_ids: Default::default(),
    };
    let namespace = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Job,
        owner_id: "run-subflow-storage-parent".into(),
        installation_id: Some("installation-storage-001".into()),
    };
    let handles = storage
        .list_current(&parent_access, &namespace, Some("shared-draft"), 10)
        .unwrap();
    assert_eq!(handles.len(), 1);
    assert_eq!(handles[0].logical_key, "shared-draft");
}

#[test]
fn pinned_subflow_parent_is_crash_exact_at_every_parent_boundary() {
    let directory = tempdir().unwrap();
    let (library, _, parent) = published_subflow_library(directory.path());
    let command = control_run_command(
        "run-subflow-crash-001",
        &parent,
        SUBFLOW_PARENT_WORKFLOW_ID,
        SUBFLOW_PARENT_REVISION_ID,
        json!({"message": "resume the exact child"}),
    );
    let expected = {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute(&mut journal, &library, &command).unwrap();
        run_wires(&journal, "run-subflow-crash-001")
    };
    for boundary in 1..=expected.len() {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(run_wires(&journal, "run-subflow-crash-001"), expected);
    }
}

#[test]
fn cancelling_a_parent_cascades_to_its_waiting_child_and_records_both_outcomes() {
    let directory = tempdir().unwrap();
    let (mut library, _, _) = published_subflow_library(directory.path());
    library
        .save_draft(SaveWorkflowDraft {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_head_sequence: 0,
            edit_id: "edit-subflow-wait-child".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&subflow_wait_child_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 150,
        })
        .unwrap();
    let child = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_draft_sequence: 1,
            revision_id: "revision-subflow-wait-child".into(),
            registration_id: "registration-subflow-wait-child".into(),
            release_version: "2.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 151,
        })
        .unwrap();
    library
        .save_draft(SaveWorkflowDraft {
            workflow_id: SUBFLOW_PARENT_WORKFLOW_ID.into(),
            expected_head_sequence: 0,
            edit_id: "edit-subflow-wait-parent".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&subflow_parent_source(&format!(
                "sha256:{}",
                child.package_digest
            )))
            .unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 152,
        })
        .unwrap();
    let parent = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_PARENT_WORKFLOW_ID.into(),
            expected_draft_sequence: 1,
            revision_id: "revision-subflow-wait-parent".into(),
            registration_id: "registration-subflow-wait-parent".into(),
            release_version: "2.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "subflow",
                    "id": "dev.kaname.subflow-child",
                    "digest": format!("sha256:{}", child.package_digest)
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 153,
        })
        .unwrap();
    let command = control_run_command(
        "run-subflow-cancel-parent",
        &parent,
        SUBFLOW_PARENT_WORKFLOW_ID,
        "revision-subflow-wait-parent",
        json!({"caseId": "case-cancel"}),
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            1_786_220_100_000,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Waiting
    );
    let token = run_token(&journal, "run-subflow-cancel-parent");
    workflow_executor::request_cancellation(
        &mut journal,
        &cancel_command("run-subflow-cancel-parent", &token.run_token_id),
    )
    .unwrap();
    assert_eq!(
        workflow_executor::execute_at_unix_millis(
            &mut journal,
            &library,
            &command,
            1_786_220_100_100,
        )
        .unwrap()
        .outcome,
        DurableRunOutcome::Cancelled
    );

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let parent_run = projection
        .inspect_runs(None, Some("run-subflow-cancel-parent"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let invocation = parent_run.subflows.first().unwrap();
    assert_eq!(invocation.status, "settled");
    assert_eq!(invocation.outcome, "cancelled");
    let child_run = projection
        .inspect_runs(None, Some(&invocation.child_run_id), 1)
        .unwrap()
        .pop()
        .unwrap();
    assert_eq!(child_run.outcome, "cancelled");
}

#[test]
fn subflow_publication_rejects_incompatible_interfaces_and_package_cycles() {
    let incompatible_directory = tempdir().unwrap();
    let (mut incompatible_library, child, _) =
        published_subflow_library(incompatible_directory.path());
    let mut incompatible_child = subflow_child_source();
    incompatible_child["workflowId"] = json!("018f6800-0001-7000-8000-000000000001");
    incompatible_child["packageId"] = json!("dev.kaname.incompatible-child");
    incompatible_child["interfaces"]["start"] = json!([subflow_interface()[0].clone()]);
    incompatible_library
        .create_draft(CreateWorkflowDraft {
            workflow_id: "018f6800-0001-7000-8000-000000000001".into(),
            package_id: "dev.kaname.incompatible-child".into(),
            name: "Incompatible child".into(),
            summary: "Missing its required success interface".into(),
            edit_id: "edit-incompatible-child".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&incompatible_child).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 130,
        })
        .unwrap();
    let incompatible_revision = incompatible_library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: "018f6800-0001-7000-8000-000000000001".into(),
            expected_draft_sequence: 0,
            revision_id: "revision-incompatible-child".into(),
            registration_id: "registration-incompatible-child".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 131,
        })
        .unwrap();
    let incompatible_digest = format!("sha256:{}", incompatible_revision.package_digest);
    let mut incompatible_parent = subflow_parent_source(&incompatible_digest);
    incompatible_parent["workflowId"] = json!("018f6900-0001-7000-8000-000000000001");
    incompatible_parent["packageId"] = json!("dev.kaname.incompatible-parent");
    incompatible_parent["graph"]["nodes"][1]["config"]["packageId"] =
        json!("dev.kaname.incompatible-child");
    incompatible_library
        .create_draft(CreateWorkflowDraft {
            workflow_id: "018f6900-0001-7000-8000-000000000001".into(),
            package_id: "dev.kaname.incompatible-parent".into(),
            name: "Incompatible parent".into(),
            summary: "Must fail closed at publication".into(),
            edit_id: "edit-incompatible-parent".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&incompatible_parent).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 132,
        })
        .unwrap();
    assert!(matches!(
        incompatible_library.publish_revision(PublishWorkflowRevision {
            workflow_id: "018f6900-0001-7000-8000-000000000001".into(),
            expected_draft_sequence: 0,
            revision_id: "revision-incompatible-parent".into(),
            registration_id: "registration-incompatible-parent".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "subflow",
                    "id": "dev.kaname.incompatible-child",
                    "digest": incompatible_digest
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 133,
        }),
        Err(kaname_core::workflow_library::WorkflowLibraryError::WorkflowCompilationFailed(codes))
            if codes == ["dependency.subflow.interface-incompatible"]
    ));
    assert_ne!(child.package_digest, incompatible_revision.package_digest);

    let cycle_directory = tempdir().unwrap();
    let (mut cycle_library, child_a, parent_b) = published_subflow_library(cycle_directory.path());
    let parent_b_digest = format!("sha256:{}", parent_b.package_digest);
    let mut child_a_v2_source = subflow_parent_source(&parent_b_digest);
    child_a_v2_source["workflowId"] = json!(SUBFLOW_CHILD_WORKFLOW_ID);
    child_a_v2_source["packageId"] = json!("dev.kaname.subflow-child");
    child_a_v2_source["graph"]["nodes"][1]["config"]["packageId"] =
        json!("dev.kaname.subflow-parent");
    cycle_library
        .save_draft(SaveWorkflowDraft {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_head_sequence: 0,
            edit_id: "edit-subflow-cycle-a2".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&child_a_v2_source).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 140,
        })
        .unwrap();
    assert!(matches!(
        cycle_library.publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_draft_sequence: 1,
            revision_id: "revision-subflow-cycle-a2".into(),
            registration_id: "registration-subflow-cycle-a2".into(),
            release_version: "2.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "subflow",
                    "id": "dev.kaname.subflow-parent",
                    "digest": parent_b_digest
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 141,
        }),
        Err(kaname_core::workflow_library::WorkflowLibraryError::WorkflowCompilationFailed(codes))
            if codes == ["dependency.subflow.cycle"]
    ));
    assert_eq!(
        cycle_library
            .load_workflow_revision_by_package_digest(
                "dev.kaname.subflow-child",
                &child_a.package_digest,
            )
            .unwrap()
            .summary
            .revision_id,
        SUBFLOW_CHILD_REVISION_ID
    );
}

#[test]
fn durable_parallel_tokens_apply_all_any_and_quorum_deterministically() {
    for (policy, quorum, fail_right, cancel_remaining, expected) in [
        ("all", None, false, false, DurableRunOutcome::Succeeded),
        ("all", None, true, false, DurableRunOutcome::Failed),
        ("any", None, true, true, DurableRunOutcome::Succeeded),
        ("quorum", Some(1), true, true, DurableRunOutcome::Succeeded),
        ("quorum", Some(2), true, false, DurableRunOutcome::Failed),
    ] {
        let directory = tempdir().unwrap();
        let (library, published) = published_parallel_library(
            directory.path(),
            policy,
            quorum,
            fail_right,
            cancel_remaining,
        );
        let run_id = format!("run-parallel-{policy}-{}-{fail_right}", quorum.unwrap_or(0));
        let command = parallel_run_command(&run_id, &published);
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(result.outcome, expected, "{policy} {quorum:?} {fail_right}");
        let wires = run_wires(&journal, &run_id);
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .event_count,
            wires.len()
        );
        assert_eq!(run_wires(&journal, &run_id), wires);
        let events = journal
            .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
            .unwrap()
            .events;
        let runtime = events
            .iter()
            .map(|event| kaname_core::workflow_runtime::decode_workflow_event(event).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            runtime
                .iter()
                .filter(|event| matches!(
                    event,
                    kaname_core::workflow_runtime::WorkflowRuntimeEvent::JoinEvaluated(_)
                ))
                .count(),
            1
        );
        assert_eq!(
            runtime
                .iter()
                .filter(|event| matches!(
                    event,
                    kaname_core::workflow_runtime::WorkflowRuntimeEvent::ExecutionTokenCreated(_)
                ))
                .count(),
            4
        );
        let join = runtime
            .iter()
            .find_map(|event| match event {
                kaname_core::workflow_runtime::WorkflowRuntimeEvent::JoinEvaluated(value) => {
                    Some(value)
                }
                _ => None,
            })
            .unwrap();
        assert_eq!(join.policy, policy);
        assert_eq!(join.expected_execution_token_ids.len(), 2);
        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("tokens").unwrap(), 4);
        assert_eq!(projection.row_count("joins").unwrap(), 1);
        let inspected = projection
            .inspect_runs(Some(PARALLEL_WORKFLOW_ID), Some(&run_id), 1)
            .unwrap()
            .pop()
            .unwrap();
        assert_eq!(inspected.execution_tokens.len(), 4);
        assert_eq!(inspected.joins.len(), 1);
        assert!(
            inspected
                .attempts
                .iter()
                .all(|attempt| !attempt.execution_token_id.is_empty())
        );
        assert!(
            inspected
                .edges
                .iter()
                .all(|edge| !edge.execution_token_id.is_empty())
        );
        if fail_right && policy == "all" {
            assert_eq!(
                join.decision,
                kaname_core::v1::WorkflowJoinDecision::Failed as i32
            );
            assert_eq!(join.failed_execution_token_ids.len(), 1);
        }
        if fail_right
            && matches!(policy, "any" | "quorum")
            && expected == DurableRunOutcome::Succeeded
        {
            assert_eq!(
                join.decision,
                kaname_core::v1::WorkflowJoinDecision::Succeeded as i32
            );
            assert_eq!(join.arrived_execution_token_ids.len(), 1);
            assert_eq!(join.pending_execution_token_ids.len(), 1);
        }
    }
}

#[test]
fn parallel_run_resumes_at_every_token_fork_and_join_boundary() {
    let directory = tempdir().unwrap();
    let (library, published) =
        published_parallel_library(directory.path(), "quorum", Some(2), false, false);
    let command = parallel_run_command("run-parallel-crash-001", &published);
    let expected = {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        run_wires(&journal, "run-parallel-crash-001")
    };
    for boundary in 1..=expected.len() {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        assert_eq!(
            workflow_executor::execute(&mut journal, &library, &command)
                .unwrap()
                .outcome,
            DurableRunOutcome::Succeeded
        );
        assert_eq!(run_wires(&journal, "run-parallel-crash-001"), expected);
    }
}

#[test]
fn immutable_minimal_graph_takes_success_and_validation_failure_paths() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let immutable_before = library
        .load_workflow_revision(REVISION_ID, "active")
        .unwrap();

    let mut success_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let success_command = run_command("run-success-001", &published, json!({"route": 5}));
    let success =
        workflow_executor::execute(&mut success_journal, &library, &success_command).unwrap();
    assert_eq!(success.outcome, DurableRunOutcome::Succeeded);
    assert_eq!(success.event_count, 19);
    let mut success_projection = WorkflowRunProjection::open_in_memory().unwrap();
    success_projection.catch_up(&success_journal).unwrap();
    assert_eq!(success_projection.row_count("runs").unwrap(), 1);
    assert_eq!(success_projection.row_count("attempts").unwrap(), 4);
    assert_eq!(success_projection.row_count("nodes").unwrap(), 4);
    assert_eq!(success_projection.row_count("emissions").unwrap(), 3);
    assert_eq!(success_projection.row_count("edges").unwrap(), 3);
    assert_eq!(success_projection.row_count("matches").unwrap(), 1);

    let mut otherwise_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let otherwise_command = run_command("run-otherwise-001", &published, json!({"route": 8}));
    assert_eq!(
        workflow_executor::execute(&mut otherwise_journal, &library, &otherwise_command)
            .unwrap()
            .outcome,
        DurableRunOutcome::Succeeded
    );
    let mut otherwise_projection = WorkflowRunProjection::open_in_memory().unwrap();
    otherwise_projection.catch_up(&otherwise_journal).unwrap();
    assert_eq!(otherwise_projection.row_count("matches").unwrap(), 1);
    assert_eq!(otherwise_projection.row_count("attempts").unwrap(), 4);

    let mut failure_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let failure_command = run_command("run-failure-001", &published, json!({}));
    let failure =
        workflow_executor::execute(&mut failure_journal, &library, &failure_command).unwrap();
    assert_eq!(failure.outcome, DurableRunOutcome::Failed);
    assert_eq!(failure.event_count, 14);
    let mut failure_projection = WorkflowRunProjection::open_in_memory().unwrap();
    failure_projection.catch_up(&failure_journal).unwrap();
    assert_eq!(failure_projection.row_count("attempts").unwrap(), 3);
    assert_eq!(failure_projection.row_count("emissions").unwrap(), 2);
    assert_eq!(failure_projection.row_count("matches").unwrap(), 0);

    let immutable_after = library
        .load_workflow_revision(REVISION_ID, "active")
        .unwrap();
    assert_eq!(immutable_after, immutable_before);
}

#[test]
fn every_event_boundary_resumes_to_the_exact_same_journal_without_duplicates() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let command = run_command("run-crash-proof-001", &published, json!({"route": 5}));

    let expected = {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(result.outcome, DurableRunOutcome::Succeeded);
        run_wires(&journal, "run-crash-proof-001")
    };
    assert_eq!(expected.len(), 19);

    for boundary in 1..=expected.len() {
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_fault_for_test(
                &mut journal,
                &library,
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        let resumed = workflow_executor::execute(&mut journal, &library, &command).unwrap();
        assert_eq!(resumed.outcome, DurableRunOutcome::Succeeded);
        assert_eq!(run_wires(&journal, "run-crash-proof-001"), expected);

        let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
        projection.catch_up(&journal).unwrap();
        assert_eq!(projection.row_count("attempts").unwrap(), 4);
        assert_eq!(projection.row_count("emissions").unwrap(), 3);
        assert_eq!(projection.row_count("events").unwrap(), 19);
    }
}

#[test]
fn cancellation_is_idempotent_terminal_and_inspectable_after_restart() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());
    let command = run_command("run-cancel-001", &published, json!({"route": 5}));
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute_with_fault_for_test(
            &mut journal,
            &library,
            &command,
            WorkflowExecutionFault::AfterNewEvent(3),
        ),
        Err(WorkflowExecutionError::InjectedInterruption)
    ));
    let token = run_token(&journal, "run-cancel-001");
    let cancellation = cancel_command("run-cancel-001", &token.run_token_id);
    let first = workflow_executor::request_cancellation(&mut journal, &cancellation).unwrap();
    assert!(!first.duplicate);
    let duplicate = workflow_executor::request_cancellation(&mut journal, &cancellation).unwrap();
    assert!(duplicate.duplicate);

    let result = workflow_executor::execute(&mut journal, &library, &command).unwrap();
    assert_eq!(result.outcome, DurableRunOutcome::Cancelled);
    let settled_wires = run_wires(&journal, "run-cancel-001");
    assert_eq!(settled_wires.len(), 7);
    assert_eq!(
        workflow_executor::execute(&mut journal, &library, &command)
            .unwrap()
            .event_count,
        settled_wires.len()
    );
    assert_eq!(run_wires(&journal, "run-cancel-001"), settled_wires);

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    assert_eq!(projection.row_count("runs").unwrap(), 1);
    assert_eq!(projection.row_count("attempts").unwrap(), 1);
    assert_eq!(projection.row_count("emissions").unwrap(), 0);
    assert_eq!(projection.row_count("events").unwrap(), 7);
}

#[test]
fn unsupported_storage_input_and_revision_pin_drift_create_no_runtime_event() {
    let directory = tempdir().unwrap();
    let (library, published) = published_library(directory.path());

    let mut storage_command = run_command("run-storage-001", &published, json!({"route": 5}));
    let mut storage_request =
        RequestWorkflowRun::decode(storage_command.payload.as_ref().unwrap().value.as_slice())
            .unwrap();
    storage_request.inputs[0].value = Some(WorkflowValueReference {
        value_id: "value-storage-input".into(),
        content_type: "application/json".into(),
        byte_count: 12,
        sha256: "a".repeat(64),
        inline_canonical_json: Vec::new(),
        storage_reference_id: "object-storage-001".into(),
        storage: None,
    });
    storage_command.payload.as_mut().unwrap().value = storage_request.encode_to_vec();
    let mut storage_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute(&mut storage_journal, &library, &storage_command),
        Err(WorkflowExecutionError::Unsupported(code))
            if code == "single_inline_manual_input_required"
    ));
    assert_eq!(
        storage_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );

    let mut drifted = run_command("run-drift-001", &published, json!({"route": 5}));
    let mut drifted_request =
        RequestWorkflowRun::decode(drifted.payload.as_ref().unwrap().value.as_slice()).unwrap();
    drifted_request.package_digest = "f".repeat(64);
    drifted.payload.as_mut().unwrap().value = drifted_request.encode_to_vec();
    let mut drifted_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute(&mut drifted_journal, &library, &drifted),
        Err(WorkflowExecutionError::Integrity(code)) if code == "revision_pin_mismatch"
    ));
    assert_eq!(
        drifted_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );
}

#[test]
fn storage_nodes_write_compare_read_list_and_delete_with_inspectable_lineage() {
    let directory = tempdir().unwrap();
    let (library, published) = published_storage_library(directory.path());
    let mut storage = open_workflow_scoped_storage(
        directory.path(),
        WorkflowObjectStoreQuota {
            maximum_object_bytes: 1024 * 1024,
            maximum_total_bytes: 4 * 1024 * 1024,
            maximum_object_count: 100,
        },
    )
    .unwrap();
    let command = storage_run_command(
        "run-storage-nodes-001",
        &published,
        json!({"draft": {"text": "hello"}}),
    );
    let mut denied_journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    assert!(matches!(
        workflow_executor::execute_with_storage(
            &mut denied_journal,
            &library,
            &mut storage,
            &WorkflowStorageExecutionAuthority {
                installation_id: "installation-other".into(),
                case_id: None,
            },
            &command,
        ),
        Err(WorkflowExecutionError::InvalidCommand(
            "storage_authority_mismatch"
        ))
    ));
    assert_eq!(
        denied_journal
            .event_page_after(0, 10)
            .unwrap()
            .high_water_mark,
        0
    );
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let result = workflow_executor::execute_with_storage(
        &mut journal,
        &library,
        &mut storage,
        &storage_authority(),
        &command,
    )
    .unwrap();
    assert_eq!(result.outcome, DurableRunOutcome::Succeeded);

    let access = WorkflowStorageAccessContext {
        run_id: Some("run-storage-nodes-001".into()),
        case_id: None,
        installation_id: "installation-storage-001".into(),
        account_binding_ids: Default::default(),
    };
    let namespace = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Job,
        owner_id: "run-storage-nodes-001".into(),
        installation_id: Some("installation-storage-001".into()),
    };
    assert!(matches!(
        storage.list_current(&access, &namespace, None, 10),
        Ok(handles) if handles.is_empty()
    ));
    let workflow_namespace = WorkflowStorageNamespace {
        kind: WorkflowStorageScopeKind::Installation,
        owner_id: "installation-storage-001".into(),
        installation_id: Some("installation-storage-001".into()),
    };
    let promoted = storage
        .list_current(&access, &workflow_namespace, None, 10)
        .unwrap();
    assert_eq!(promoted.len(), 1);
    assert_eq!(promoted[0].logical_key, "latest-draft");
    assert!(promoted[0].source_version_id.is_some());

    let mut projection = WorkflowRunProjection::open_in_memory().unwrap();
    projection.catch_up(&journal).unwrap();
    let run = projection
        .inspect_runs(None, Some("run-storage-nodes-001"), 1)
        .unwrap()
        .pop()
        .unwrap();
    let storage_values = run
        .emissions
        .iter()
        .filter_map(|emission| emission.value.as_ref()?.storage.as_ref())
        .collect::<Vec<_>>();
    assert_eq!(
        storage_values
            .iter()
            .map(|metadata| metadata.result.as_str())
            .collect::<Vec<_>>(),
        [
            "written", "written", "read", "listed", "deleted", "promoted"
        ]
    );
    assert_eq!(storage_values[0].revision, 1);
    assert_eq!(storage_values[1].revision, 2);
    assert_eq!(
        storage_values[1].previous_version_id,
        storage_values[0].version_id
    );
    assert_eq!(storage_values[2].version_id, storage_values[1].version_id);
    assert_eq!(storage_values[4].revision, 2);
    assert_eq!(storage_values[5].scope, "workflow");
    assert_eq!(
        storage_values[5].source_version_id,
        storage_values[4].version_id
    );
    for metadata in &storage_values[..5] {
        assert_eq!(metadata.scope, "job");
        assert_eq!(metadata.logical_key, "draft");
        assert!(!metadata.handle_id.contains('/'));
    }

    let duplicate = workflow_executor::execute_with_storage(
        &mut journal,
        &library,
        &mut storage,
        &storage_authority(),
        &command,
    )
    .unwrap();
    assert_eq!(duplicate.event_count, result.event_count);
}

#[test]
fn storage_node_receipts_resume_at_every_event_boundary_without_repeating_mutations() {
    let expected = {
        let directory = tempdir().unwrap();
        let (library, published) = published_storage_library(directory.path());
        let mut storage = test_scoped_storage(directory.path());
        let command = storage_run_command(
            "run-storage-crash-001",
            &published,
            json!({"draft": {"text": "hello"}}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        workflow_executor::execute_with_storage(
            &mut journal,
            &library,
            &mut storage,
            &storage_authority(),
            &command,
        )
        .unwrap();
        run_wires(&journal, "run-storage-crash-001")
    };

    for boundary in 1..=expected.len() {
        let directory = tempdir().unwrap();
        let (library, published) = published_storage_library(directory.path());
        let mut storage = test_scoped_storage(directory.path());
        let command = storage_run_command(
            "run-storage-crash-001",
            &published,
            json!({"draft": {"text": "hello"}}),
        );
        let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
        assert!(matches!(
            workflow_executor::execute_with_storage_fault_for_test(
                &mut journal,
                &library,
                &mut storage,
                &storage_authority(),
                &command,
                WorkflowExecutionFault::AfterNewEvent(boundary),
            ),
            Err(WorkflowExecutionError::InjectedInterruption)
        ));
        workflow_executor::execute_with_storage(
            &mut journal,
            &library,
            &mut storage,
            &storage_authority(),
            &command,
        )
        .unwrap();
        assert_eq!(run_wires(&journal, "run-storage-crash-001"), expected);
        assert_eq!(
            storage
                .usage(
                    &WorkflowStorageAccessContext {
                        run_id: Some("run-storage-crash-001".into()),
                        case_id: None,
                        installation_id: "installation-storage-001".into(),
                        account_binding_ids: Default::default(),
                    },
                    &WorkflowStorageNamespace {
                        kind: WorkflowStorageScopeKind::Job,
                        owner_id: "run-storage-crash-001".into(),
                        installation_id: Some("installation-storage-001".into()),
                    },
                )
                .unwrap()
                .version_count,
            2
        );
        assert_eq!(
            storage
                .usage(
                    &WorkflowStorageAccessContext {
                        run_id: Some("run-storage-crash-001".into()),
                        case_id: None,
                        installation_id: "installation-storage-001".into(),
                        account_binding_ids: Default::default(),
                    },
                    &WorkflowStorageNamespace {
                        kind: WorkflowStorageScopeKind::Installation,
                        owner_id: "installation-storage-001".into(),
                        installation_id: Some("installation-storage-001".into()),
                    },
                )
                .unwrap()
                .version_count,
            1
        );
    }
}

fn published_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: WORKFLOW_ID.into(),
            package_id: "dev.kaname.minimal-runtime".into(),
            name: "Minimal durable runtime".into(),
            summary: "Synthetic manual validate Match terminal fixture".into(),
            edit_id: "edit-minimal-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&workflow_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 10,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: REVISION_ID.into(),
            registration_id: "registration-minimal-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&json!({
                "bundleVersion": 1,
                "schemas": [{
                    "id": "dev.kaname.minimal-input/v1",
                    "schema": {
                        "$schema": "https://json-schema.org/draft/2020-12/schema",
                        "type": "object",
                        "required": ["route"],
                        "properties": {
                            "route": {"type": ["number", "string"]}
                        },
                        "additionalProperties": false
                    }
                }]
            }))
            .unwrap(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 20,
        })
        .unwrap();
    (library, published)
}

fn published_parallel_library(
    application_support: &std::path::Path,
    policy: &str,
    quorum: Option<u32>,
    fail_right: bool,
    cancel_remaining: bool,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: PARALLEL_WORKFLOW_ID.into(),
            package_id: "dev.kaname.parallel-runtime".into(),
            name: "Durable parallel runtime".into(),
            summary: "Synthetic fork and join fixture".into(),
            edit_id: "edit-parallel-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&parallel_workflow_source(
                policy,
                quorum,
                fail_right,
                cancel_remaining,
            ))
            .unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 50,
        })
        .unwrap();
    let schema_bundle = json!({
        "bundleVersion": 1,
        "schemas": [
            {"id": "dev.kaname.parallel/pass-v1", "schema": {"type": "object"}},
            {"id": "dev.kaname.parallel/right-v1", "schema": if fail_right {
                json!({"type": "object", "required": ["right"]})
            } else {
                json!({"type": "object"})
            }}
        ]
    });
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: PARALLEL_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: PARALLEL_REVISION_ID.into(),
            registration_id: "registration-parallel-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&schema_bundle).unwrap(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 60,
        })
        .unwrap();
    (library, published)
}

fn published_iteration_library(
    application_support: &std::path::Path,
    failure_policy: &str,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    publish_control_library(
        application_support,
        ITERATION_WORKFLOW_ID,
        ITERATION_REVISION_ID,
        "dev.kaname.iteration-runtime",
        iteration_workflow_source(failure_policy),
        json!({
            "bundleVersion": 1,
            "schemas": [{
                "id": "dev.kaname.iteration/item-v1",
                "schema": {"type": "integer"}
            }]
        }),
    )
}

fn published_retry_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    publish_control_library(
        application_support,
        RETRY_WORKFLOW_ID,
        RETRY_REVISION_ID,
        "dev.kaname.retry-runtime",
        retry_workflow_source(),
        json!({
            "bundleVersion": 1,
            "schemas": [{
                "id": "dev.kaname.retry/always-fails-v1",
                "schema": {
                    "type": "object",
                    "required": ["required"],
                    "properties": {"required": {"const": true}}
                }
            }]
        }),
    )
}

fn published_wait_library(
    application_support: &std::path::Path,
    kind: &str,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    publish_control_library(
        application_support,
        WAIT_WORKFLOW_ID,
        WAIT_REVISION_ID,
        "dev.kaname.wait-runtime",
        wait_workflow_source(kind),
        json!({"bundleVersion": 1, "schemas": []}),
    )
}

fn published_case_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    publish_control_library(
        application_support,
        CASE_WORKFLOW_ID,
        CASE_REVISION_ID,
        "dev.kaname.case-runtime",
        case_workflow_source(),
        json!({"bundleVersion": 1, "schemas": []}),
    )
}

fn published_subflow_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
    PublishedWorkflowRevision,
) {
    publish_subflow_pair(
        application_support,
        subflow_child_source(),
        subflow_parent_source,
    )
}

fn published_subflow_storage_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let (library, _, parent) = publish_subflow_pair(
        application_support,
        subflow_storage_child_source(),
        subflow_storage_parent_source,
    );
    (library, parent)
}

fn published_capability_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: CAPABILITY_WORKFLOW_ID.into(),
            package_id: "dev.kaname.capability-runtime".into(),
            name: "Typed capability runtime".into(),
            summary: "Synthetic version-pinned capability fixture".into(),
            edit_id: "edit-capability-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&capability_workflow_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 120,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: CAPABILITY_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: CAPABILITY_REVISION_ID.into(),
            registration_id: "registration-capability-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&json!({
                "bundleVersion": 1,
                "schemas": [{
                    "id": "dev.kaname.capability/output-v1",
                    "schema": capability_output_schema()
                }]
            }))
            .unwrap(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "capability",
                    "id": CAPABILITY_ID,
                    "version": "1.0.0",
                    "digest": format!("sha256:{CAPABILITY_DIGEST}")
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 130,
        })
        .unwrap();
    (library, published)
}

fn capability_host(plan: DeterministicCapabilityPlan) -> DeterministicWorkflowCapabilityHost {
    let mut host = DeterministicWorkflowCapabilityHost::default();
    host.register(
        WorkflowCapabilityDefinition {
            capability_id: CAPABILITY_ID.into(),
            version: "1.0.0".into(),
            package_digest: CAPABILITY_DIGEST.into(),
            configuration_schema: json!({
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "required": ["mode"],
                "properties": {"mode": {"const": "strict"}},
                "additionalProperties": false
            }),
            input_schema: json!({
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "required": ["text"],
                "properties": {"text": {"type": "string"}},
                "additionalProperties": false
            }),
            output_schema: capability_output_schema(),
            timeout_milliseconds: 100,
            deterministic: true,
            idempotent: true,
        },
        plan,
    );
    host
}

fn capability_output_schema() -> Value {
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["normalized"],
        "properties": {"normalized": {"type": "string"}},
        "additionalProperties": false
    })
}

fn capability_workflow_source() -> Value {
    let ids = [
        "018f6900-0002-7000-8000-000000000002",
        CAPABILITY_NODE_ID,
        "018f6900-0004-7000-8000-000000000004",
        "018f6900-0005-7000-8000-000000000005",
    ];
    control_graph_source(
        CAPABILITY_WORKFLOW_ID,
        "dev.kaname.capability-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "normalize",
                "compute.capability",
                json!({
                    "capabilityId": CAPABILITY_ID,
                    "version": "1.0.0",
                    "input": {"whole": true},
                    "configuration": {"mode": "strict"},
                    "outputSchemaRef": "dev.kaname.capability/output-v1"
                }),
            ),
            ("complete", "terminal.complete", json!({})),
            ("fail", "terminal.fail", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
            ((1, "error"), (3, "input")),
        ],
    )
}

fn published_llm_library(
    application_support: &std::path::Path,
    conversation_scope: &str,
    maximum_context_bytes: u64,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: LLM_WORKFLOW_ID.into(),
            package_id: "dev.kaname.llm-runtime".into(),
            name: "Inspectable LLM runtime".into(),
            summary: "Synthetic bounded and redacted LLM context fixture".into(),
            edit_id: "edit-llm-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&llm_workflow_source(
                conversation_scope,
                maximum_context_bytes,
            ))
            .unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 140,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: LLM_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: LLM_REVISION_ID.into(),
            registration_id: "registration-llm-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&json!({
                "bundleVersion": 1,
                "schemas": [{
                    "id": "dev.kaname.llm/output-v1",
                    "schema": {
                        "$schema": "https://json-schema.org/draft/2020-12/schema",
                        "type": "object",
                        "required": ["summary"],
                        "properties": {"summary": {"type": "string"}},
                        "additionalProperties": false
                    }
                }]
            }))
            .unwrap(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 150,
        })
        .unwrap();
    (library, published)
}

fn llm_provider(plan: DeterministicLlmPlan) -> DeterministicWorkflowLlmProvider {
    let mut provider = DeterministicWorkflowLlmProvider::default();
    provider.register(
        WorkflowLlmProviderDefinition {
            provider_id: "synthetic-provider".into(),
            model_id: "synthetic-model".into(),
            model_revision: "revision-2026-08-15".into(),
            model_class: "reasoning".into(),
            timeout_milliseconds: 100,
            maximum_context_bytes: 49_152,
            idempotent: true,
            tools: Vec::new(),
        },
        plan,
    );
    provider
}

fn published_llm_tool_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut source = llm_workflow_source("job", 32_768);
    *source
        .pointer_mut("/graph/nodes/1/config/tools")
        .expect("LLM tool configuration") = json!(["synthetic.search"]);
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: LLM_WORKFLOW_ID.into(),
            package_id: "dev.kaname.llm-runtime".into(),
            name: "Inspectable LLM tool runtime".into(),
            summary: "Synthetic bounded LLM tool evidence fixture".into(),
            edit_id: "edit-llm-tools-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&source).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 140,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: LLM_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: LLM_REVISION_ID.into(),
            registration_id: "registration-llm-tools-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&json!({
                "bundleVersion": 1,
                "schemas": [
                    {
                        "id": "dev.kaname.llm/output-v1",
                        "schema": {
                            "$schema": "https://json-schema.org/draft/2020-12/schema",
                            "type": "object",
                            "required": ["summary"],
                            "properties": {"summary": {"type": "string"}},
                            "additionalProperties": false
                        }
                    },
                    {
                        "id": "dev.kaname.tool/search-input-v1",
                        "schema": {
                            "$schema": "https://json-schema.org/draft/2020-12/schema",
                            "type": "object",
                            "required": ["query"],
                            "properties": {"query": {"type": "string"}},
                            "additionalProperties": false
                        }
                    },
                    {
                        "id": "dev.kaname.tool/search-output-v1",
                        "schema": {
                            "$schema": "https://json-schema.org/draft/2020-12/schema",
                            "type": "object",
                            "required": ["hits"],
                            "properties": {"hits": {"type": "array"}},
                            "additionalProperties": false
                        }
                    }
                ]
            }))
            .unwrap(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "tool",
                    "id": "synthetic.search",
                    "version": "1.0.0",
                    "digest": "a".repeat(64)
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 150,
        })
        .unwrap();
    (library, published)
}

fn llm_tool_provider() -> DeterministicWorkflowLlmProvider {
    let input_schema = json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["query"],
        "properties": {"query": {"type": "string"}},
        "additionalProperties": false
    });
    let output_schema = json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["hits"],
        "properties": {"hits": {"type": "array"}},
        "additionalProperties": false
    });
    let mut provider = DeterministicWorkflowLlmProvider::default();
    provider.register(
        WorkflowLlmProviderDefinition {
            provider_id: "synthetic-provider".into(),
            model_id: "synthetic-model".into(),
            model_revision: "revision-2026-08-15".into(),
            model_class: "reasoning".into(),
            timeout_milliseconds: 100,
            maximum_context_bytes: 49_152,
            idempotent: true,
            tools: vec![WorkflowLlmProviderToolDefinition {
                tool_id: "synthetic.search".into(),
                version: "1.0.0".into(),
                package_digest: "a".repeat(64),
                description: "Search the bounded synthetic fixture".into(),
                input_schema_ref: "dev.kaname.tool/search-input-v1".into(),
                input_schema,
                output_schema_ref: "dev.kaname.tool/search-output-v1".into(),
                output_schema,
            }],
        },
        DeterministicLlmPlan::Succeed {
            output: json!({"summary": "Safe result with inspected tools"}),
            elapsed_milliseconds: 11,
        },
    );
    provider.register_trace(
        "reasoning",
        WorkflowLlmProviderTrace {
            request_id: "provider-request-tools-001".into(),
            response_id: "provider-response-tools-001".into(),
            receipt_metadata: json!({"region": "synthetic"}),
            tool_calls: vec![
                WorkflowLlmProviderToolCall {
                    call_id: "call-search-001".into(),
                    tool_id: "synthetic.search".into(),
                    input: json!({"query": "bounded evidence"}),
                    result: WorkflowLlmProviderToolResult::Succeeded(json!({
                        "hits": [{"title": "Local result"}]
                    })),
                    duration_milliseconds: 3,
                },
                WorkflowLlmProviderToolCall {
                    call_id: "call-search-002".into(),
                    tool_id: "synthetic.search".into(),
                    input: json!({"query": "failed evidence"}),
                    result: WorkflowLlmProviderToolResult::Failed {
                        code: "tool.synthetic-failure".into(),
                        error: json!({"message": "Synthetic bounded failure"}),
                    },
                    duration_milliseconds: 2,
                },
            ],
            response_messages: vec![
                WorkflowLlmProviderResponseMessage {
                    message_id: "response-message-tool-001".into(),
                    role: "tool".into(),
                    kind: "tool_result".into(),
                    summary: "Large tool payload retained as a bounded summary".into(),
                    content: json!({"payload": "x".repeat(30_000)}),
                    tool_call_id: Some("call-search-001".into()),
                },
                WorkflowLlmProviderResponseMessage {
                    message_id: "response-message-final-001".into(),
                    role: "assistant".into(),
                    kind: "final".into(),
                    summary: "Final structured response".into(),
                    content: json!({"summary": "Safe result with inspected tools"}),
                    tool_call_id: None,
                },
            ],
            usage: WorkflowLlmProviderUsage {
                input_tokens: 120,
                cached_input_tokens: 20,
                output_tokens: 40,
                reasoning_tokens: 10,
                cost_currency: "USD".into(),
                input_cost_micros: 120,
                output_cost_micros: 80,
                reasoning_cost_micros: 10,
                tool_cost_micros: 25,
            },
        },
    );
    provider
}

fn llm_workflow_source(conversation_scope: &str, maximum_context_bytes: u64) -> Value {
    let ids = [
        "018f6b00-0002-7000-8000-000000000002",
        LLM_NODE_ID,
        "018f6b00-0004-7000-8000-000000000004",
        "018f6b00-0005-7000-8000-000000000005",
    ];
    let context = if conversation_scope == "case" {
        json!([{"root": "case", "pointer": ""}])
    } else {
        json!([])
    };
    control_graph_source(
        LLM_WORKFLOW_ID,
        "dev.kaname.llm-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "summarize",
                "compute.llm",
                json!({
                    "modelClass": "reasoning",
                    "instructions": "Return a concise summary using only the recorded context.",
                    "prompt": {"whole": true},
                    "context": context,
                    "tools": [],
                    "outputSchemaRef": "dev.kaname.llm/output-v1",
                    "conversationScope": conversation_scope,
                    "reasoningEffort": "medium",
                    "temperatureMilli": 200,
                    "maximumContextBytes": maximum_context_bytes,
                    "maximumOutputTokens": 512
                }),
            ),
            ("complete", "terminal.complete", json!({})),
            ("fail", "terminal.fail", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
            ((1, "error"), (3, "input")),
        ],
    )
}

fn publish_subflow_pair(
    application_support: &std::path::Path,
    child_source: Value,
    parent_source: fn(&str) -> Value,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            package_id: "dev.kaname.subflow-child".into(),
            name: "Pinned child".into(),
            summary: "Synthetic child with a stable data interface".into(),
            edit_id: "edit-subflow-child-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&child_source).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 90,
        })
        .unwrap();
    let child = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_CHILD_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: SUBFLOW_CHILD_REVISION_ID.into(),
            registration_id: "registration-subflow-child-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 100,
        })
        .unwrap();
    let digest = format!("sha256:{}", child.package_digest);
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: SUBFLOW_PARENT_WORKFLOW_ID.into(),
            package_id: "dev.kaname.subflow-parent".into(),
            name: "Pinned parent".into(),
            summary: "Synthetic parent pinned to one child revision".into(),
            edit_id: "edit-subflow-parent-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&parent_source(&digest)).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 101,
        })
        .unwrap();
    let parent = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: SUBFLOW_PARENT_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: SUBFLOW_PARENT_REVISION_ID.into(),
            registration_id: "registration-subflow-parent-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: serde_json::to_vec(&json!({
                "lockVersion": 1,
                "dependencies": [{
                    "kind": "subflow",
                    "id": "dev.kaname.subflow-child",
                    "digest": digest
                }]
            }))
            .unwrap(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 110,
        })
        .unwrap();
    (library, child, parent)
}

fn publish_control_library(
    application_support: &std::path::Path,
    workflow_id: &str,
    revision_id: &str,
    package_id: &str,
    source: Value,
    schema_bundle: Value,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: workflow_id.into(),
            package_id: package_id.into(),
            name: "Bounded control runtime".into(),
            summary: "Synthetic bounded iteration or retry fixture".into(),
            edit_id: format!("edit-{revision_id}"),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&source).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 70,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: workflow_id.into(),
            expected_draft_sequence: 0,
            revision_id: revision_id.into(),
            registration_id: format!("registration-{revision_id}"),
            release_version: "1.0.0".into(),
            schema_bundle_json: serde_json::to_vec(&schema_bundle).unwrap(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 80,
        })
        .unwrap();
    (library, published)
}

fn published_storage_library(
    application_support: &std::path::Path,
) -> (
    kaname_core::workflow_library::WorkflowLibraryStore,
    PublishedWorkflowRevision,
) {
    let mut library = open_workflow_library(application_support).unwrap();
    library
        .create_draft(CreateWorkflowDraft {
            workflow_id: STORAGE_WORKFLOW_ID.into(),
            package_id: "dev.kaname.storage-runtime".into(),
            name: "Scoped storage runtime".into(),
            summary: "Synthetic path-free storage node fixture".into(),
            edit_id: "edit-storage-001".into(),
            session_id: "executor-tests".into(),
            workflow_source: serde_json::to_vec(&storage_workflow_source()).unwrap(),
            layout_source: br#"{"nodes":[]}"#.to_vec(),
            recorded_at_unix_millis: 30,
        })
        .unwrap();
    let published = library
        .publish_revision(PublishWorkflowRevision {
            workflow_id: STORAGE_WORKFLOW_ID.into(),
            expected_draft_sequence: 0,
            revision_id: STORAGE_REVISION_ID.into(),
            registration_id: "registration-storage-001".into(),
            release_version: "1.0.0".into(),
            schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
            published_at_unix_millis: 40,
        })
        .unwrap();
    (library, published)
}

fn test_scoped_storage(
    application_support: &std::path::Path,
) -> kaname_core::workflow_storage::WorkflowScopedStorage {
    open_workflow_scoped_storage(
        application_support,
        WorkflowObjectStoreQuota {
            maximum_object_bytes: 1024 * 1024,
            maximum_total_bytes: 4 * 1024 * 1024,
            maximum_object_count: 100,
        },
    )
    .unwrap()
}

fn storage_authority() -> WorkflowStorageExecutionAuthority {
    WorkflowStorageExecutionAuthority {
        installation_id: "installation-storage-001".into(),
        case_id: None,
    }
}

fn iteration_workflow_source(failure_policy: &str) -> Value {
    let ids = [
        "018f5900-0002-7000-8000-000000000002",
        "018f5900-0003-7000-8000-000000000003",
        "018f5900-0004-7000-8000-000000000004",
        "018f5900-0005-7000-8000-000000000005",
        "018f5900-0006-7000-8000-000000000006",
    ];
    control_graph_source(
        ITERATION_WORKFLOW_ID,
        "dev.kaname.iteration-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "for-each",
                "control.for-each",
                json!({
                    "items": {"root": "input", "pointer": "/items"},
                    "as": "item",
                    "maximumItems": 4,
                    "maximumConcurrency": 2,
                    "failurePolicy": failure_policy
                }),
            ),
            (
                "validate-item",
                "data.validate",
                json!({
                    "schemaRef": "dev.kaname.iteration/item-v1"
                }),
            ),
            ("complete", "terminal.complete", json!({})),
            ("fail", "terminal.fail", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "item"), (2, "input")),
            ((2, "success"), (1, "item-success")),
            ((2, "error"), (1, "item-error")),
            ((1, "success"), (3, "input")),
            ((1, "error"), (4, "input")),
        ],
    )
}

fn retry_workflow_source() -> Value {
    let ids = [
        "018f5c00-0002-7000-8000-000000000002",
        "018f5c00-0003-7000-8000-000000000003",
        "018f5c00-0004-7000-8000-000000000004",
        "018f5c00-0005-7000-8000-000000000005",
        "018f5c00-0006-7000-8000-000000000006",
    ];
    control_graph_source(
        RETRY_WORKFLOW_ID,
        "dev.kaname.retry-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "validate",
                "data.validate",
                json!({
                    "schemaRef": "dev.kaname.retry/always-fails-v1"
                }),
            ),
            (
                "retry",
                "control.retry",
                json!({
                    "maximumAttempts": 2,
                    "retryOn": ["validation.failed"],
                    "backoff": {
                        "mode": "fixed",
                        "initialSeconds": 1.0,
                        "maximumSeconds": 1.0,
                        "jitter": "none"
                    }
                }),
            ),
            ("complete", "terminal.complete", json!({})),
            ("fail", "terminal.fail", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (3, "input")),
            ((1, "error"), (2, "error")),
            ((2, "retry"), (1, "input")),
            ((2, "exhausted"), (4, "input")),
            ((2, "unknown"), (4, "input")),
        ],
    )
}

fn wait_workflow_source(kind: &str) -> Value {
    let ids = [
        "018f6000-0002-7000-8000-000000000002",
        "018f6000-0003-7000-8000-000000000003",
        "018f6000-0004-7000-8000-000000000004",
        "018f6000-0005-7000-8000-000000000005",
    ];
    control_graph_source(
        WAIT_WORKFLOW_ID,
        "dev.kaname.wait-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "wait",
                "control.wait",
                json!({
                    "kind": kind,
                    "correlation": [{"root": "input", "pointer": "/caseId"}],
                    "expirySeconds": 5
                }),
            ),
            ("complete-resumed", "terminal.complete", json!({})),
            ("complete-expired", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "resumed"), (2, "input")),
            ((1, "expired"), (3, "input")),
        ],
    )
}

fn case_workflow_source() -> Value {
    let ids = [
        "018f6300-0002-7000-8000-000000000002",
        "018f6300-0003-7000-8000-000000000003",
        "018f6300-0004-7000-8000-000000000004",
    ];
    control_graph_source(
        CASE_WORKFLOW_ID,
        "dev.kaname.case-runtime",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            ("compile-case-context", "data.case-context", json!({})),
            ("complete", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
        ],
    )
}

fn subflow_child_source() -> Value {
    let ids = [
        "018f6600-0002-7000-8000-000000000002",
        "018f6600-0003-7000-8000-000000000003",
    ];
    let mut source = control_graph_source(
        SUBFLOW_CHILD_WORKFLOW_ID,
        "dev.kaname.subflow-child",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            ("complete", "terminal.complete", json!({})),
        ],
        vec![((0, "success"), (1, "input"))],
    );
    source["graph"]["entrypoints"][0]["key"] = json!("start");
    source["interfaces"] = json!({"start": subflow_interface()});
    source
}

fn subflow_wait_child_source() -> Value {
    let ids = [
        "018f6610-0002-7000-8000-000000000002",
        "018f6610-0003-7000-8000-000000000003",
        "018f6610-0004-7000-8000-000000000004",
        "018f6610-0005-7000-8000-000000000005",
    ];
    let mut source = control_graph_source(
        SUBFLOW_CHILD_WORKFLOW_ID,
        "dev.kaname.subflow-child",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "wait",
                "control.wait",
                json!({
                    "kind": "reply",
                    "correlation": [{"root": "input", "pointer": "/caseId"}],
                    "expirySeconds": 5
                }),
            ),
            ("complete-resumed", "terminal.complete", json!({})),
            ("complete-expired", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "resumed"), (2, "input")),
            ((1, "expired"), (3, "input")),
        ],
    );
    source["graph"]["entrypoints"][0]["key"] = json!("start");
    source["interfaces"] = json!({"start": subflow_interface()});
    source
}

fn subflow_parent_source(child_digest: &str) -> Value {
    let ids = [
        "018f6700-0002-7000-8000-000000000002",
        "018f6700-0003-7000-8000-000000000003",
        "018f6700-0004-7000-8000-000000000004",
    ];
    let mut source = control_graph_source(
        SUBFLOW_PARENT_WORKFLOW_ID,
        "dev.kaname.subflow-parent",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "child",
                "control.subflow",
                json!({
                    "packageId": "dev.kaname.subflow-child",
                    "revisionDigest": child_digest,
                    "entrypoint": "start",
                    "input": {"whole": true}
                }),
            ),
            ("complete", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
        ],
    );
    source["graph"]["entrypoints"][0]["key"] = json!("start");
    source["interfaces"] = json!({"start": subflow_interface()});
    source
}

fn subflow_storage_child_source() -> Value {
    let ids = [
        "018f6620-0002-7000-8000-000000000002",
        "018f6620-0003-7000-8000-000000000003",
        "018f6620-0004-7000-8000-000000000004",
    ];
    let mut source = control_graph_source(
        SUBFLOW_CHILD_WORKFLOW_ID,
        "dev.kaname.subflow-child",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "write-shared-draft",
                "storage.write",
                json!({
                    "scope": "job",
                    "key": "shared-draft",
                    "value": {"root": "input", "pointer": "/draft"},
                    "conflictPolicy": "fail"
                }),
            ),
            ("complete", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
        ],
    );
    source["graph"]["entrypoints"][0]["key"] = json!("start");
    source["interfaces"] = json!({"start": subflow_interface()});
    source["storage"] = json!({
        "shared-draft": {
            "key": "shared-draft",
            "scope": "job",
            "kind": "value",
            "schemaRef": "dev.kaname.storage/draft-v1",
            "maximumBytes": 65536,
            "classification": "private"
        }
    });
    source
}

fn subflow_storage_parent_source(child_digest: &str) -> Value {
    let ids = [
        "018f6720-0002-7000-8000-000000000002",
        "018f6720-0003-7000-8000-000000000003",
        "018f6720-0004-7000-8000-000000000004",
        "018f6720-0005-7000-8000-000000000005",
    ];
    let mut source = control_graph_source(
        SUBFLOW_PARENT_WORKFLOW_ID,
        "dev.kaname.subflow-parent",
        &ids,
        vec![
            ("manual", "trigger.manual", json!({})),
            (
                "child",
                "control.subflow",
                json!({
                    "packageId": "dev.kaname.subflow-child",
                    "revisionDigest": child_digest,
                    "entrypoint": "start",
                    "input": {"whole": true}
                }),
            ),
            (
                "read-shared-draft",
                "storage.read",
                json!({
                    "operation": "read",
                    "scope": "job",
                    "key": "shared-draft",
                    "required": true
                }),
            ),
            ("complete", "terminal.complete", json!({})),
        ],
        vec![
            ((0, "success"), (1, "input")),
            ((1, "success"), (2, "input")),
            ((2, "success"), (3, "input")),
        ],
    );
    source["graph"]["entrypoints"][0]["key"] = json!("start");
    source["interfaces"] = json!({"start": subflow_interface()});
    source["storage"] = json!({
        "shared-draft": {
            "key": "shared-draft",
            "scope": "job",
            "kind": "value",
            "schemaRef": "dev.kaname.storage/draft-v1",
            "maximumBytes": 65536,
            "classification": "private"
        }
    });
    source
}

fn subflow_interface() -> Value {
    json!([
        {
            "id": "input",
            "key": "input",
            "label": "Input",
            "direction": "input",
            "cardinality": "one",
            "schemaRef": "dev.kaname.workflow.data/v1",
            "required": true
        },
        {
            "id": "success",
            "key": "success",
            "label": "Success",
            "direction": "output",
            "cardinality": "one",
            "schemaRef": "dev.kaname.workflow.data/v1",
            "required": true
        }
    ])
}

type ControlEdge<'a> = ((usize, &'a str), (usize, &'a str));

fn control_graph_source(
    workflow_id: &str,
    package_id: &str,
    ids: &[&str],
    nodes: Vec<(&str, &str, Value)>,
    edges: Vec<ControlEdge<'_>>,
) -> Value {
    let nodes = nodes
        .into_iter()
        .enumerate()
        .map(|(index, (key, node_type, config))| {
            json!({
                "id": ids[index], "key": key, "name": key,
                "type": node_type, "typeVersion": 1, "config": config
            })
        })
        .collect::<Vec<_>>();
    let edges = edges
        .into_iter()
        .enumerate()
        .map(|(index, (from, to))| {
            let sequence = index + 1;
            json!({
                "id": format!("018f5d00-{sequence:04}-7000-8000-{sequence:012}"),
                "from": {"nodeId": ids[from.0], "portId": from.1},
                "to": {"nodeId": ids[to.0], "portId": to.1},
                "mappingId": format!("018f5e00-{sequence:04}-7000-8000-{sequence:012}"),
                "mapping": {"whole": true}
            })
        })
        .collect::<Vec<_>>();
    json!({
        "formatVersion": 1,
        "workflowId": workflow_id,
        "packageId": package_id,
        "name": "Bounded control runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5f00-0001-7000-8000-000000000001",
                "nodeId": ids[0]
            }],
            "nodes": nodes,
            "edges": edges
        },
        "interfaces": {}, "resources": {}, "policies": {}, "storage": {}, "metadata": {}
    })
}

fn storage_workflow_source() -> Value {
    let ids = [
        "018f5300-0002-7000-8000-000000000002",
        "018f5300-0003-7000-8000-000000000003",
        "018f5300-0004-7000-8000-000000000004",
        "018f5300-0005-7000-8000-000000000005",
        "018f5300-0006-7000-8000-000000000006",
        "018f5300-0007-7000-8000-000000000007",
        "018f5300-0008-7000-8000-000000000008",
        "018f5300-0009-7000-8000-000000000009",
        "018f5300-0011-7000-8000-000000000011",
    ];
    let node = |index: usize, key: &str, node_type: &str, config: Value| {
        json!({
            "id": ids[index], "key": key, "name": key,
            "type": node_type, "typeVersion": 1, "config": config
        })
    };
    let edge = |sequence: u16, from: (usize, &str), to: (usize, &str)| {
        json!({
            "id": format!("018f5400-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": ids[from.0], "portId": from.1},
            "to": {"nodeId": ids[to.0], "portId": to.1},
            "mappingId": format!("018f5500-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    json!({
        "formatVersion": 1,
        "workflowId": STORAGE_WORKFLOW_ID,
        "packageId": "dev.kaname.storage-runtime",
        "name": "Scoped storage runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5300-0012-7000-8000-000000000012",
                "nodeId": ids[0]
            }],
            "nodes": [
                node(0, "manual", "trigger.manual", json!({})),
                node(1, "write-initial", "storage.write", json!({
                    "scope": "job", "key": "draft",
                    "value": {"root": "input", "pointer": "/draft"},
                    "conflictPolicy": "fail"
                })),
                node(2, "write-cas", "storage.write", json!({
                    "scope": "job", "key": "draft",
                    "value": {"root": "input", "pointer": ""},
                    "conflictPolicy": "compare-and-swap", "expectedRevision": 1
                })),
                node(3, "read", "storage.read", json!({
                    "operation": "read", "scope": "job", "key": "draft", "required": true
                })),
                node(4, "list", "storage.read", json!({
                    "operation": "list", "scope": "job", "key": "draft", "limit": 10
                })),
                node(5, "delete", "storage.write", json!({
                    "operation": "delete-reference", "scope": "job", "key": "draft",
                    "conflictPolicy": "compare-and-swap", "expectedRevision": 2
                })),
                node(6, "promote", "storage.promote", json!({
                    "from": "job", "to": "workflow",
                    "sourceKey": "draft", "destinationKey": "latest-draft",
                    "conflictPolicy": "fail"
                })),
                node(7, "complete", "terminal.complete", json!({})),
                node(8, "fail", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(1, (0, "success"), (1, "input")),
                edge(2, (1, "success"), (2, "input")),
                edge(3, (2, "success"), (3, "input")),
                edge(4, (3, "success"), (4, "input")),
                edge(5, (4, "success"), (5, "input")),
                edge(6, (5, "success"), (6, "input")),
                edge(7, (6, "success"), (7, "input")),
                edge(8, (1, "error"), (8, "input")),
                edge(9, (2, "error"), (8, "input")),
                edge(10, (3, "error"), (8, "input")),
                edge(11, (4, "error"), (8, "input")),
                edge(12, (5, "error"), (8, "input")),
                edge(13, (6, "error"), (8, "input"))
            ]
        },
        "interfaces": {}, "resources": {}, "policies": {},
        "storage": {
            "draft": {
                "key": "draft", "scope": "job", "kind": "value",
                "schemaRef": "dev.kaname.storage/draft-v1",
                "maximumBytes": 65536, "classification": "private"
            },
            "latest-draft": {
                "key": "latest-draft", "scope": "workflow", "kind": "value",
                "schemaRef": "dev.kaname.storage/draft-v1",
                "maximumBytes": 65536, "classification": "private",
                "conflictPolicy": "fail"
            }
        },
        "metadata": {}
    })
}

fn parallel_workflow_source(
    policy: &str,
    quorum: Option<u32>,
    fail_right: bool,
    cancel_remaining: bool,
) -> Value {
    let ids = [
        "018f5600-0002-7000-8000-000000000002",
        "018f5600-0003-7000-8000-000000000003",
        "018f5600-0004-7000-8000-000000000004",
        "018f5600-0005-7000-8000-000000000005",
        "018f5600-0006-7000-8000-000000000006",
        "018f5600-0007-7000-8000-000000000007",
        "018f5600-0008-7000-8000-000000000008",
        "018f5600-0009-7000-8000-000000000009",
        "018f5600-0010-7000-8000-000000000010",
    ];
    let left_branch_id = "018f5600-0011-7000-8000-000000000011";
    let right_branch_id = "018f5600-0012-7000-8000-000000000012";
    let node = |index: usize, key: &str, node_type: &str, config: Value| {
        json!({
            "id": ids[index], "key": key, "name": key,
            "type": node_type, "typeVersion": 1, "config": config
        })
    };
    let edge = |sequence: u16, from: (usize, String), to: (usize, &str)| {
        json!({
            "id": format!("018f5700-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": ids[from.0], "portId": from.1},
            "to": {"nodeId": ids[to.0], "portId": to.1},
            "mappingId": format!("018f5800-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    let mut join_config = json!({
        "policy": policy,
        "cancelRemaining": cancel_remaining
    });
    if let Some(quorum) = quorum {
        join_config["quorum"] = json!(quorum);
    }
    json!({
        "formatVersion": 1,
        "workflowId": PARALLEL_WORKFLOW_ID,
        "packageId": "dev.kaname.parallel-runtime",
        "name": "Durable parallel runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5600-0013-7000-8000-000000000013",
                "nodeId": ids[0]
            }],
            "nodes": [
                node(0, "manual", "trigger.manual", json!({})),
                node(1, "fork", "control.parallel", json!({"branches": [
                    {"id": left_branch_id, "key": "left", "label": "Left"},
                    {"id": right_branch_id, "key": "right", "label": "Right"}
                ]})),
                node(2, "left", "data.validate", json!({"schemaRef": "dev.kaname.parallel/pass-v1"})),
                node(3, "right", "data.validate", json!({"schemaRef": if fail_right { "dev.kaname.parallel/right-v1" } else { "dev.kaname.parallel/pass-v1" }})),
                node(4, "join", "control.join", join_config),
                node(5, "complete", "terminal.complete", json!({})),
                node(6, "fail-left", "terminal.fail", json!({})),
                node(7, "fail-right", "terminal.fail", json!({})),
                node(8, "fail-join", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(1, (0, "success".into()), (1, "input")),
                edge(2, (1, format!("case-{left_branch_id}")), (2, "input")),
                edge(3, (1, format!("case-{right_branch_id}")), (3, "input")),
                edge(4, (2, "success".into()), (4, "branches")),
                edge(5, (2, "error".into()), (6, "input")),
                edge(6, (3, "success".into()), (4, "branches")),
                edge(7, (3, "error".into()), (7, "input")),
                edge(8, (4, "success".into()), (5, "input")),
                edge(9, (4, "error".into()), (8, "input"))
            ]
        },
        "interfaces": {}, "resources": {}, "policies": {}, "storage": {}, "metadata": {}
    })
}

fn parallel_run_command(run_id: &str, published: &PublishedWorkflowRevision) -> CommandEnvelope {
    let mut envelope = run_command(run_id, published, json!({"value": "synthetic"}));
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.workflow_id = PARALLEL_WORKFLOW_ID.into();
    request.revision_id = PARALLEL_REVISION_ID.into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

fn control_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    workflow_id: &str,
    revision_id: &str,
    input: Value,
) -> CommandEnvelope {
    let mut envelope = run_command(run_id, published, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.workflow_id = workflow_id.into();
    request.revision_id = revision_id.into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

#[allow(clippy::too_many_arguments)]
fn case_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    episode_id: &str,
    episode_kind: &str,
    prior_episode_id: &str,
    trigger_event_id: &str,
    input: Value,
) -> CommandEnvelope {
    let mut envelope =
        control_run_command(run_id, published, CASE_WORKFLOW_ID, CASE_REVISION_ID, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.installation_id = "installation-kay-001".into();
    request.case_id = "case-kay-42".into();
    request.episode_id = episode_id.into();
    request.episode_kind = episode_kind.into();
    request.prior_episode_id = prior_episode_id.into();
    request.trigger_kind = "email.received".into();
    request.trigger_event_id = trigger_event_id.into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

#[allow(clippy::too_many_arguments)]
fn llm_case_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    episode_id: &str,
    episode_kind: &str,
    prior_episode_id: &str,
    trigger_event_id: &str,
    input: Value,
) -> CommandEnvelope {
    let mut envelope =
        control_run_command(run_id, published, LLM_WORKFLOW_ID, LLM_REVISION_ID, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.installation_id = "installation-llm-kay-001".into();
    request.case_id = "case-llm-kay-42".into();
    request.episode_id = episode_id.into();
    request.episode_kind = episode_kind.into();
    request.prior_episode_id = prior_episode_id.into();
    request.trigger_kind = "email.received".into();
    request.trigger_event_id = trigger_event_id.into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

#[allow(clippy::too_many_arguments)]
fn case_wait_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    episode_id: &str,
    episode_kind: &str,
    prior_episode_id: &str,
    trigger_event_id: &str,
    input: Value,
) -> CommandEnvelope {
    let mut envelope =
        control_run_command(run_id, published, WAIT_WORKFLOW_ID, WAIT_REVISION_ID, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.installation_id = "installation-feedback-001".into();
    request.case_id = "case-feedback-42".into();
    request.episode_id = episode_id.into();
    request.episode_kind = episode_kind.into();
    request.prior_episode_id = prior_episode_id.into();
    request.trigger_kind = "email.received".into();
    request.trigger_event_id = trigger_event_id.into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

fn storage_run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    input: Value,
) -> CommandEnvelope {
    let mut envelope = run_command(run_id, published, input);
    let mut request =
        RequestWorkflowRun::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    request.workflow_id = STORAGE_WORKFLOW_ID.into();
    request.revision_id = STORAGE_REVISION_ID.into();
    request.installation_id = "installation-storage-001".into();
    envelope.payload.as_mut().unwrap().value = request.encode_to_vec();
    envelope
}

fn workflow_source() -> Value {
    let node = |id: &str, key: &str, node_type: &str, config: Value| {
        json!({
            "id": id,
            "key": key,
            "name": key,
            "type": node_type,
            "typeVersion": 1,
            "config": config
        })
    };
    let edge = |sequence: u16, from: (&str, &str), to: (&str, &str)| {
        json!({
            "id": format!("018f5100-{sequence:04}-7000-8000-{sequence:012}"),
            "from": {"nodeId": from.0, "portId": from.1},
            "to": {"nodeId": to.0, "portId": to.1},
            "mappingId": format!("018f5200-{sequence:04}-7000-8000-{sequence:012}"),
            "mapping": {"whole": true}
        })
    };
    let case_port = format!("case-{CASE_FIVE_ID}");
    let otherwise_port = format!("case-{OTHERWISE_ID}");
    json!({
        "formatVersion": 1,
        "workflowId": WORKFLOW_ID,
        "packageId": "dev.kaname.minimal-runtime",
        "name": "Minimal durable runtime",
        "summary": "Synthetic and effect free",
        "graph": {
            "entrypoints": [{
                "id": "018f5000-0011-7000-8000-000000000011",
                "nodeId": MANUAL_ID
            }],
            "nodes": [
                node(MANUAL_ID, "manual", "trigger.manual", json!({})),
                node(VALIDATE_ID, "validate", "data.validate", json!({
                    "schemaRef": "dev.kaname.minimal-input/v1"
                })),
                node(MATCH_ID, "match", "control.match", json!({
                    "value": {"root": "input", "pointer": ""},
                    "hitPolicy": "first",
                    "cases": [{
                        "id": CASE_FIVE_ID,
                        "key": "five",
                        "label": "Route five",
                        "when": {"compare": {
                            "left": {"root": "value", "pointer": "/route"},
                            "operator": "equal",
                            "right": {"literal": {"type": "number", "value": 5}}
                        }}
                    }],
                    "otherwise": {
                        "id": OTHERWISE_ID,
                        "key": "otherwise",
                        "label": "Otherwise"
                    }
                })),
                node(COMPLETE_MATCH_ID, "complete-five", "terminal.complete", json!({})),
                node(COMPLETE_OTHERWISE_ID, "complete-otherwise", "terminal.complete", json!({})),
                node(FAIL_VALIDATE_ID, "fail-validation", "terminal.fail", json!({})),
                node(FAIL_MATCH_ID, "fail-match", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(1, (MANUAL_ID, "success"), (VALIDATE_ID, "input")),
                edge(2, (VALIDATE_ID, "success"), (MATCH_ID, "input")),
                edge(3, (VALIDATE_ID, "error"), (FAIL_VALIDATE_ID, "input")),
                edge(4, (MATCH_ID, &case_port), (COMPLETE_MATCH_ID, "input")),
                edge(5, (MATCH_ID, &otherwise_port), (COMPLETE_OTHERWISE_ID, "input")),
                edge(6, (MATCH_ID, "error"), (FAIL_MATCH_ID, "input"))
            ]
        },
        "interfaces": {},
        "resources": {},
        "policies": {},
        "storage": {},
        "metadata": {}
    })
}

fn run_command(
    run_id: &str,
    published: &PublishedWorkflowRevision,
    input: Value,
) -> CommandEnvelope {
    let value = inline_value(&format!("value-{run_id}-input"), input);
    command(
        &format!("command-{run_id}"),
        &format!("idempotency-{run_id}"),
        WORKFLOW_RUN_REQUEST_KIND,
        WORKFLOW_RUN_REQUEST_TYPE,
        RequestWorkflowRun {
            run_id: run_id.into(),
            workflow_id: WORKFLOW_ID.into(),
            revision_id: REVISION_ID.into(),
            package_digest: published.package_digest.clone(),
            trigger_kind: "manual".into(),
            trigger_event_id: String::new(),
            inputs: vec![WorkflowInputBinding {
                port_id: "input".into(),
                value: Some(value),
            }],
            installation_id: String::new(),
            case_id: String::new(),
            episode_id: String::new(),
            episode_kind: String::new(),
            prior_episode_id: String::new(),
        },
        1_786_220_100_000,
    )
}

fn cancel_command(run_id: &str, token_id: &str) -> CommandEnvelope {
    command(
        &format!("command-{run_id}-cancel"),
        &format!("idempotency-{run_id}-cancel"),
        WORKFLOW_RUN_CANCEL_KIND,
        WORKFLOW_RUN_CANCEL_TYPE,
        CancelWorkflowRun {
            run_id: run_id.into(),
            run_token_id: token_id.into(),
            reason_code: "owner-requested".into(),
        },
        1_786_220_100_100,
    )
}

fn wait_signal_command(
    run_id: &str,
    signal_id: &str,
    kind: &str,
    case_id: &str,
    submitted_at_unix_millis: i64,
) -> CommandEnvelope {
    let correlation_value = serde_json_canonicalizer::to_vec(&json!(case_id)).unwrap();
    command(
        &format!("command-{signal_id}"),
        &format!("idempotency-{signal_id}"),
        WORKFLOW_WAIT_SIGNAL_KIND,
        WORKFLOW_WAIT_SIGNAL_TYPE,
        SignalWorkflowWait {
            run_id: run_id.into(),
            signal_id: signal_id.into(),
            kind: kind.into(),
            owner_kind: "workflow".into(),
            owner_id: WAIT_WORKFLOW_ID.into(),
            correlation: vec![WorkflowWaitCorrelation {
                key: "input:/caseId".into(),
                sha256: hex::encode(Sha256::digest(&correlation_value)),
            }],
            value: Some(inline_value(
                &format!("value-{signal_id}"),
                json!({"caseId": case_id, "signalId": signal_id}),
            )),
        },
        submitted_at_unix_millis,
    )
}

fn case_wait_signal_command(
    run_id: &str,
    signal_id: &str,
    case_id: &str,
    value: Value,
    submitted_at_unix_millis: i64,
) -> CommandEnvelope {
    let mut envelope = wait_signal_command(
        run_id,
        signal_id,
        "reply",
        case_id,
        submitted_at_unix_millis,
    );
    let mut signal =
        SignalWorkflowWait::decode(envelope.payload.as_ref().unwrap().value.as_slice()).unwrap();
    signal.owner_kind = "case".into();
    signal.owner_id = case_id.into();
    signal.value = Some(inline_value(&format!("value-{signal_id}"), value));
    envelope.payload.as_mut().unwrap().value = signal.encode_to_vec();
    envelope
}

fn command<M: Message>(
    command_id: &str,
    idempotency_key: &str,
    kind: &str,
    type_url: &str,
    payload: M,
    submitted_at_unix_millis: i64,
) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: command_id.into(),
        idempotency_key: idempotency_key.into(),
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: type_url.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
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
        submitted_at_unix_millis,
    }
}

fn inline_value(value_id: &str, value: Value) -> WorkflowValueReference {
    let bytes = serde_json_canonicalizer::to_vec(&value).unwrap();
    WorkflowValueReference {
        value_id: value_id.into(),
        content_type: "application/json".into(),
        byte_count: bytes.len() as u64,
        sha256: hex::encode(Sha256::digest(&bytes)),
        inline_canonical_json: bytes,
        storage_reference_id: String::new(),
        storage: None,
    }
}

fn synthetic_capability_artifact() -> WorkflowCapabilityArtifactHandle {
    WorkflowCapabilityArtifactHandle {
        role: "normalized-document".into(),
        value: WorkflowValueReference {
            value_id: "value-capability-artifact-001".into(),
            content_type: "application/pdf".into(),
            byte_count: 24,
            sha256: "b76f7f891e5416c00bb710aa8945a5ca73232a31c8d86b16f148268323c8aef8".into(),
            inline_canonical_json: Vec::new(),
            storage_reference_id: "handle-capability-output-001".into(),
            storage: Some(WorkflowStorageValueMetadata {
                handle_id: "handle-capability-output-001".into(),
                scope: "job".into(),
                logical_key: "outputs/normalized.pdf".into(),
                version_id: "version-capability-output-001".into(),
                revision: 1,
                previous_version_id: String::new(),
                byte_count: 24,
                result: "written".into(),
                source_version_id: String::new(),
            }),
        },
    }
}

fn run_wires(journal: &Journal, run_id: &str) -> Vec<Vec<u8>> {
    let page = journal
        .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
        .unwrap();
    assert_eq!(page.basis, ReplayBasis::Events);
    assert!(!page.has_more);
    page.events
        .into_iter()
        .map(|event| event.encode_to_vec())
        .collect()
}

fn run_token(journal: &Journal, run_id: &str) -> WorkflowRunTokenCreated {
    let page = journal
        .replay(&format!("thread:workflow-run:{run_id}"), None, 500)
        .unwrap();
    let event = page
        .events
        .into_iter()
        .find(|event| event.kind == WORKFLOW_RUN_TOKEN_CREATED_KIND)
        .unwrap();
    WorkflowRunTokenCreated::decode(event.payload.unwrap().value.as_slice()).unwrap()
}
