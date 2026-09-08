use kaname_core::{
    fake_provider::{embedded_scenarios, run_scenario, run_scenario_at_path, scale_fixture},
    journal::{Journal, ReplayBasis as JournalReplayBasis},
    mobile::{EnrollmentAdmission, SyncAdmission},
    open_workflow_library, open_workflow_scoped_storage,
    policy::{ApprovalResolutionResult, LocalPolicyCore, approval_fingerprint},
    v1::{self, EventEnvelope},
    workflow_canonical, workflow_compiler,
    workflow_connector_observation::{
        begin_workflow_connector_observation, settle_workflow_connector_observation,
    },
    workflow_import::{ImportFrozenWorkflowDraft, ImportFrozenWorkspace},
    workflow_object_store::WorkflowObjectStoreQuota,
    workflow_projection::WorkflowRunProjection,
    workflow_purge::purge_workflow_run,
    workflow_schema::{self, WorkflowSchemaCheckRequest},
    workflow_versions::{
        SetWorkflowActivation, WorkflowExecutionSupport, WorkflowPortfolioState,
        WorkflowRevisionComparison as StoredWorkflowRevisionComparison,
        WorkflowRevisionContent as StoredWorkflowRevisionContent,
        WorkflowRevisionSummary as StoredWorkflowRevisionSummary,
    },
};
use prost::Message;
use serde::{Deserialize, Serialize};
use std::io::Read;

const CURSOR_KEY: [u8; 32] = [0x42; 32];

#[derive(Serialize)]
struct ScaleReport {
    fixture_id: String,
    event_count: usize,
    first_event_id: String,
    last_event_id: String,
}

#[derive(Deserialize, Serialize)]
struct EventAppendReport {
    event_id: String,
    stream_id: String,
    store_position: u64,
    stream_sequence: u64,
    duplicate: bool,
}

fn main() {
    let result = match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [operation, fixture_id] if operation == "scenario" => scenario(fixture_id),
        [operation, fixture_id, journal_path] if operation == "scenario-store" => {
            scenario_store(fixture_id, journal_path)
        }
        [operation, journal_path] if operation == "append-event" => append_event(journal_path),
        [operation, journal_path] if operation == "authorize-action" => {
            authorize_action(journal_path)
        }
        [operation, journal_path] if operation == "record-review" => record_review(journal_path),
        [operation, journal_path] if operation == "replay" => replay(journal_path),
        [operation, journal_path] if operation == "mobile-propose" => {
            mobile_propose(journal_path)
        }
        [operation, journal_path] if operation == "mobile-decide" => mobile_decide(journal_path),
        [operation, journal_path, recipient_device_id, recipient_key_id]
            if operation == "mobile-admit" =>
        {
            mobile_admit(journal_path, recipient_device_id, recipient_key_id)
        }
        [operation, fixture_id] if operation == "scale" => scale(fixture_id),
        [operation] if operation == "workflow-schema-check" => workflow_schema_check(),
        [operation] if operation == "workflow-canonicalize" => workflow_canonicalize(),
        [operation] if operation == "workflow-compile" => workflow_compile(),
        [operation, application_support] if operation == "workflow-library-query" => {
            workflow_library_query(application_support)
        }
        [operation, application_support] if operation == "workflow-library-activate" => {
            workflow_library_activate(application_support)
        }
        [operation, application_support] if operation == "workflow-library-import-frozen" => {
            workflow_library_import_frozen(application_support)
        }
        [operation, journal_path, projection_path] if operation == "workflow-run-inspect" => {
            workflow_run_inspect(journal_path, projection_path)
        }
        [operation, journal_path, projection_path]
            if operation == "workflow-connector-observation-begin" =>
        {
            workflow_connector_observation_begin(journal_path, projection_path)
        }
        [operation, journal_path, projection_path]
            if operation == "workflow-connector-observation-settle" =>
        {
            workflow_connector_observation_settle(journal_path, projection_path)
        }
        [operation, journal_path, projection_path, application_support]
            if operation == "workflow-run-purge" =>
        {
            workflow_run_purge(journal_path, projection_path, application_support)
        }
        [operation, journal_path, projection_path, application_support]
            if operation == "workflow-run-start" =>
        {
            workflow_run_start(journal_path, projection_path, application_support)
        }
        [operation, journal_path, projection_path] if operation == "workflow-effect-authorize" => {
            workflow_effect_authorize(journal_path, projection_path)
        }
        [operation, journal_path, projection_path, application_support]
            if operation == "workflow-schedule-tick" =>
        {
            workflow_schedule_tick(journal_path, projection_path, application_support)
        }
        [operation, _journal_path, application_support] if operation == "workflow-library-publish" => {
            workflow_library_publish(application_support)
        }
        [operation, _journal_path] if operation == "workflow-node-availability" => {
            workflow_node_availability()
        }
        [operation, journal_path, projection_path, application_support]
            if operation == "workflow-event-fanout" =>
        {
            workflow_event_fanout(journal_path, projection_path, application_support)
        }
        _ => Err("usage: kaname-local-core scenario <F-01..F-14> | scenario-store <F-01..F-14> <journal-path> | append-event <journal-path> < event-envelope.bin | authorize-action <journal-path> < approval-command.bin | record-review <journal-path> < command-envelope.bin | replay <journal-path> < replay-request.bin | mobile-propose <journal-path> < enrollment-challenge.bin | mobile-decide <journal-path> < enrollment-decision.bin | mobile-admit <journal-path> <recipient-device-id> <recipient-key-id> < encrypted-envelope.bin | scale <S-01..S-04> | workflow-schema-check < request.json | workflow-canonicalize < value.json | workflow-compile < compile-request.bin | workflow-library-query <application-support-root> < query-request.bin | workflow-library-activate <application-support-root> < activation-request.bin | workflow-library-import-frozen <application-support-root> < import-request.bin | workflow-run-inspect <journal-path> <projection-path> < query.bin | workflow-connector-observation-begin <journal-path> <projection-path> < request.bin | workflow-connector-observation-settle <journal-path> <projection-path> < request.bin | workflow-run-purge <journal-path> <projection-path> <application-support-root> < request.bin | workflow-run-start <journal-path> <projection-path> <application-support-root> < request.json | workflow-effect-authorize <journal-path> <projection-path> < request.json | workflow-schedule-tick <journal-path> <projection-path> <application-support-root> | workflow-library-publish <journal-path> <application-support-root> < request.json | workflow-event-fanout <journal-path> <projection-path> <application-support-root> < request.json | workflow-node-availability <journal-path> < request.json".to_owned()),
    };
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("kaname-local-core: {error}");
            std::process::exit(64);
        }
    }
}

#[derive(Deserialize)]
struct WorkflowRunStartRequest {
    request_id: String,
    #[serde(default)]
    run_id: String,
    workflow_id: String,
    revision_id: String,
    #[serde(default)]
    inputs: serde_json::Map<String, serde_json::Value>,
}

#[derive(Serialize)]
struct WorkflowRunStartResponse {
    request_id: String,
    run_id: String,
    run_token_id: String,
    outcome: String,
    event_count: usize,
    next_attempt_at_unix_millis: Option<i64>,
    llm_host: String,
    capability_host: String,
    effect_host: String,
}

/// Starts (or resumes) a durable run of an active, executable revision from a
/// small JSON request and returns the settled or waiting outcome. This is the
/// first desktop-callable path into the Rust executor.
fn workflow_run_start(
    journal_path: &str,
    projection_path: &str,
    application_support: &str,
) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let wire = read_standard_input()?;
    let request: WorkflowRunStartRequest =
        serde_json::from_slice(&wire).map_err(|_| "workflow_run_start_rejected".to_owned())?;
    if request.request_id.is_empty()
        || request.workflow_id.is_empty()
        || request.revision_id.is_empty()
    {
        return Err("workflow_run_start_rejected".to_owned());
    }
    let store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let revision = store
        .load_workflow_revision(&request.revision_id, "active")
        .map_err(|error| format!("workflow_revision_unavailable:{error:?}"))?;
    if revision.summary.workflow_id != request.workflow_id {
        return Err("workflow_run_start_rejected:revision_workflow_mismatch".to_owned());
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default();
    let run_id = if request.run_id.is_empty() {
        format!("run-{}", &request.request_id)
    } else {
        request.run_id.clone()
    };
    let inputs = request
        .inputs
        .iter()
        .map(|(port_id, value)| {
            let bytes = serde_json_canonicalizer::to_vec(value).unwrap_or_default();
            v1::WorkflowInputBinding {
                port_id: port_id.clone(),
                value: Some(v1::WorkflowValueReference {
                    value_id: format!("value-{run_id}-{port_id}"),
                    content_type: "application/json".into(),
                    byte_count: bytes.len() as u64,
                    sha256: hex::encode(Sha256::digest(&bytes)),
                    inline_canonical_json: bytes,
                    ..Default::default()
                }),
            }
        })
        .collect();
    let payload = v1::RequestWorkflowRun {
        run_id: run_id.clone(),
        workflow_id: request.workflow_id.clone(),
        revision_id: request.revision_id.clone(),
        package_digest: revision.summary.package_digest.clone(),
        trigger_kind: "manual".into(),
        trigger_event_id: String::new(),
        inputs,
        // Effect and storage nodes need a stable installation identity; the
        // desktop has exactly one installation per workflow.
        installation_id: format!("installation-{}", request.workflow_id),
        case_id: format!("case-{run_id}"),
        episode_id: String::new(),
        episode_kind: String::new(),
        prior_episode_id: String::new(),
    };
    // Recovery reuses the admitted wire, not a fabricated timestamp or a
    // reconstructed request that loses the original trigger input.
    let envelope = v1::CommandEnvelope {
        schema_version: Some(v1::SchemaVersion {
            major: kaname_core::SCHEMA_MAJOR,
            minor: 0,
        }),
        command_id: format!("command-{run_id}"),
        idempotency_key: format!("idempotency-{run_id}"),
        kind: kaname_core::workflow_runtime::WORKFLOW_RUN_REQUEST_KIND.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: kaname_core::workflow_runtime::WORKFLOW_RUN_REQUEST_TYPE.into(),
            content_type: "application/x-protobuf".into(),
            value: payload.encode_to_vec(),
            payload_version: 1,
        }),
        scope: Some(v1::Scope {
            project_id: "project-kaname".into(),
            workspace_id: "workspace-local".into(),
            account_id: String::new(),
            authority_id: String::new(),
            egress_class: String::new(),
            destination_digest: String::new(),
        }),
        actor_id: "local-owner".into(),
        expected_revision: 0,
        submitted_at_unix_millis: now,
    };
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let original = kaname_core::workflow_executor::admitted_run_command(&journal, &run_id)
        .map_err(|_| "workflow_run_command_unavailable".to_owned())?
        .or(journal
            .admitted_command(&envelope.command_id)
            .map_err(|_| "workflow_run_command_unavailable".to_owned())?);
    let envelope = match original {
        Some(original) => {
            let original_payload = original
                .payload
                .as_ref()
                .ok_or("workflow_run_original_payload_missing")?;
            let original_run = v1::RequestWorkflowRun::decode(original_payload.value.as_slice())
                .map_err(|_| "workflow_run_original_payload_malformed")?;
            if original_run.run_id != run_id
                || original_run.workflow_id != request.workflow_id
                || original_run.revision_id != request.revision_id
                || (!request.inputs.is_empty() && original_run.inputs != payload.inputs)
            {
                return Err("workflow_run_resume_mismatch".into());
            }
            original
        }
        None => envelope,
    };
    // Use the process LLM host when the service configured one; otherwise the
    // executor rejects compute.llm graphs before a run token exists.
    let mut llm = kaname_core::workflow_llm::ProcessWorkflowLlmProvider::from_environment();
    let llm_host = if llm.is_available() {
        format!("available:{}", llm.registered_model_classes().join(","))
    } else {
        format!(
            "unavailable:{}",
            llm.unavailable_reason().unwrap_or("unknown")
        )
    };
    let mut capabilities =
        kaname_core::workflow_capabilities::ProcessWorkflowCapabilityHost::from_environment();
    let capability_host = if capabilities.is_available() {
        format!("available:{}", capabilities.registered_capabilities().len())
    } else {
        format!(
            "unavailable:{}",
            capabilities.unavailable_reason().unwrap_or("unknown")
        )
    };
    let mut effects =
        kaname_core::workflow_effect_process::ProcessWorkflowEffectHost::from_environment(
            journal_path,
            projection_path,
            CURSOR_KEY,
        );
    let effect_host = if effects.is_available() {
        format!("available:{}", effects.registered_connectors().len())
    } else {
        format!(
            "unavailable:{}",
            effects.unavailable_reason().unwrap_or("unknown")
        )
    };
    let result = kaname_core::workflow_executor::execute_with_hosts(
        &mut journal,
        &store,
        &mut capabilities,
        &mut llm,
        &mut effects,
        &envelope,
    )
    .map_err(|error| format!("workflow_run_start_failed:{error:?}"))?;
    // Keep the projection warm so Run history shows the run immediately.
    let _ = WorkflowRunProjection::open_or_rebuild(projection_path, &journal);
    let response = WorkflowRunStartResponse {
        request_id: request.request_id,
        run_id: result.run_id,
        run_token_id: result.run_token_id,
        outcome: format!("{:?}", result.outcome).to_lowercase(),
        event_count: result.event_count,
        next_attempt_at_unix_millis: result.next_attempt_at_unix_millis,
        llm_host,
        capability_host,
        effect_host,
    };
    let json =
        serde_json::to_vec(&response).map_err(|_| "workflow_run_start_encode_failed".to_owned())?;
    Ok(hex::encode(json))
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct WorkflowSchedule {
    workflow_id: String,
    interval_seconds: i64,
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default)]
    last_scheduled_for_unix_millis: i64,
    #[serde(default)]
    last_run_id: String,
    #[serde(default)]
    last_outcome: String,
}

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct WorkflowScheduleFile {
    #[serde(default)]
    schedules: Vec<WorkflowSchedule>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowScheduleTickResponse {
    checked: usize,
    admitted: Vec<String>,
    skipped: Vec<String>,
    errors: Vec<String>,
}

/// Fires due interval schedules for active, executable revisions whose
/// entrypoint is `trigger.schedule`. The schedule cadence is host state kept in
/// `Workflows/schedules.json`; the executor derives the run identity from the
/// scheduled instant, so a repeated tick over the same instant appends nothing.
fn workflow_schedule_tick(
    journal_path: &str,
    projection_path: &str,
    application_support: &str,
) -> Result<String, String> {
    let schedules_path = std::path::Path::new(application_support)
        .join("Workflows")
        .join("schedules.json");
    let mut file: WorkflowScheduleFile = std::fs::read(&schedules_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let mut response = WorkflowScheduleTickResponse {
        checked: file.schedules.len(),
        admitted: Vec::new(),
        skipped: Vec::new(),
        errors: Vec::new(),
    };
    if file.schedules.is_empty() {
        return serde_json::to_vec(&response)
            .map(hex::encode)
            .map_err(|_| "workflow_schedule_tick_encode_failed".to_owned());
    }
    let store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let portfolio = store
        .workflow_portfolio("active")
        .map_err(|_| "workflow_portfolio_unavailable".to_owned())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default();
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let mut llm = kaname_core::workflow_llm::ProcessWorkflowLlmProvider::from_environment();
    let mut capabilities =
        kaname_core::workflow_capabilities::ProcessWorkflowCapabilityHost::from_environment();
    let mut effects =
        kaname_core::workflow_effect_process::ProcessWorkflowEffectHost::from_environment(
            journal_path,
            projection_path,
            CURSOR_KEY,
        );
    let mut changed = false;
    for schedule in file.schedules.iter_mut() {
        if !schedule.enabled || schedule.interval_seconds < 60 {
            response
                .skipped
                .push(format!("{}:disabled", schedule.workflow_id));
            continue;
        }
        let Some(item) = portfolio
            .iter()
            .find(|item| item.workflow_id == schedule.workflow_id)
        else {
            response
                .skipped
                .push(format!("{}:not_in_portfolio", schedule.workflow_id));
            continue;
        };
        let Some(revision_id) = item.active_revision_id.clone() else {
            response
                .skipped
                .push(format!("{}:no_active_revision", schedule.workflow_id));
            continue;
        };
        let revision = match store.load_workflow_revision(&revision_id, "active") {
            Ok(revision) => revision,
            Err(error) => {
                response
                    .errors
                    .push(format!("{}:{error:?}", schedule.workflow_id));
                continue;
            }
        };
        let compiled: serde_json::Value = match serde_json::from_slice(&revision.compiled_source) {
            Ok(value) => value,
            Err(_) => {
                response
                    .errors
                    .push(format!("{}:compiled_unreadable", schedule.workflow_id));
                continue;
            }
        };
        let entry_node_id = compiled["entrypoints"][0]["nodeId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let is_schedule_entry = compiled["nodes"]
            .as_array()
            .map(|nodes| {
                nodes.iter().any(|node| {
                    node["id"].as_str() == Some(entry_node_id.as_str())
                        && node["type"].as_str() == Some("trigger.schedule")
                })
            })
            .unwrap_or(false);
        if !is_schedule_entry {
            response
                .skipped
                .push(format!("{}:entrypoint_not_schedule", schedule.workflow_id));
            continue;
        }
        let interval_millis = schedule.interval_seconds * 1_000;
        // First tick anchors the cadence at now; later ticks catch up one
        // occurrence per tick so a long sleep does not fan out into a burst.
        let due = if schedule.last_scheduled_for_unix_millis <= 0 {
            now
        } else {
            schedule.last_scheduled_for_unix_millis + interval_millis
        };
        if due > now {
            response
                .skipped
                .push(format!("{}:not_due", schedule.workflow_id));
            continue;
        }
        let scheduled_for = if now - due > interval_millis {
            now - ((now - due) % interval_millis)
        } else {
            due
        };
        let empty_input =
            serde_json_canonicalizer::to_vec(&serde_json::json!({})).unwrap_or_default();
        let binding = kaname_core::workflow_executor::WorkflowTriggerRunBinding {
            workflow_id: schedule.workflow_id.clone(),
            revision_id: revision_id.clone(),
            package_digest: revision.summary.package_digest.clone(),
            installation_id: format!("installation-{}", schedule.workflow_id),
            case_id: format!("case-{}-{scheduled_for}", schedule.workflow_id),
            input: v1::WorkflowValueReference {
                value_id: format!("value-schedule-{}-{scheduled_for}", schedule.workflow_id),
                content_type: "application/json".into(),
                byte_count: empty_input.len() as u64,
                sha256: {
                    use sha2::Digest as _;
                    hex::encode(sha2::Sha256::digest(&empty_input))
                },
                inline_canonical_json: empty_input,
                ..Default::default()
            },
            scope: v1::Scope {
                project_id: "project-kaname".into(),
                workspace_id: "workspace-local".into(),
                account_id: String::new(),
                authority_id: String::new(),
                egress_class: String::new(),
                destination_digest: String::new(),
            },
            actor_id: "kaname-scheduler".into(),
            observed_at_unix_millis: now,
        };
        let trigger = kaname_core::workflow_executor::WorkflowScheduleTrigger {
            scheduled_for_unix_millis: scheduled_for,
            misfire_grace_millis: interval_millis,
        };
        match kaname_core::workflow_executor::execute_schedule_trigger_with_hosts(
            &mut journal,
            &store,
            &binding,
            &trigger,
            &mut capabilities,
            &mut llm,
            &mut effects,
        ) {
            Ok(receipt) => {
                schedule.last_scheduled_for_unix_millis = scheduled_for;
                schedule.last_run_id = receipt.run_id.clone();
                schedule.last_outcome = receipt
                    .result
                    .as_ref()
                    .map(|result| format!("{:?}", result.outcome).to_lowercase())
                    .unwrap_or_else(|| "misfired".into());
                changed = true;
                response.admitted.push(format!(
                    "{}:{}:{}",
                    schedule.workflow_id, receipt.run_id, schedule.last_outcome
                ));
            }
            Err(error) => {
                schedule.last_scheduled_for_unix_millis = scheduled_for;
                schedule.last_outcome = format!("error:{error:?}");
                changed = true;
                response
                    .errors
                    .push(format!("{}:{error:?}", schedule.workflow_id));
            }
        }
    }
    if changed {
        if let Ok(bytes) = serde_json::to_vec_pretty(&file) {
            let _ = std::fs::write(&schedules_path, bytes);
        }
    }
    let _ = WorkflowRunProjection::open_or_rebuild(projection_path, &journal);
    serde_json::to_vec(&response)
        .map(hex::encode)
        .map_err(|_| "workflow_schedule_tick_encode_failed".to_owned())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowEventFanoutRequest {
    request_id: String,
    event_contract: String,
    event_id: String,
    #[serde(default)]
    contract_key: String,
    #[serde(default)]
    input: serde_json::Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowEventFanoutReceipt {
    workflow_id: String,
    revision_id: String,
    run_id: String,
    admission: String,
    outcome: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowEventFanoutResponse {
    request_id: String,
    matched: usize,
    receipts: Vec<WorkflowEventFanoutReceipt>,
    errors: Vec<String>,
}

/// Offers one external event to every active, executable revision whose
/// entrypoint is `trigger.event` with a matching event contract. The executor
/// deduplicates by event ID or contract key, so re-offering the same event
/// appends nothing.
fn workflow_event_fanout(
    journal_path: &str,
    projection_path: &str,
    application_support: &str,
) -> Result<String, String> {
    let wire = read_standard_input()?;
    let request: WorkflowEventFanoutRequest =
        serde_json::from_slice(&wire).map_err(|_| "workflow_event_fanout_rejected".to_owned())?;
    if request.request_id.is_empty()
        || request.event_contract.is_empty()
        || request.event_id.is_empty()
    {
        return Err("workflow_event_fanout_rejected".to_owned());
    }
    let store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let portfolio = store
        .workflow_portfolio("active")
        .map_err(|_| "workflow_portfolio_unavailable".to_owned())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default();
    let mut response = WorkflowEventFanoutResponse {
        request_id: request.request_id.clone(),
        matched: 0,
        receipts: Vec::new(),
        errors: Vec::new(),
    };
    let mut journal: Option<Journal> = None;
    let mut llm = kaname_core::workflow_llm::ProcessWorkflowLlmProvider::from_environment();
    let mut capabilities =
        kaname_core::workflow_capabilities::ProcessWorkflowCapabilityHost::from_environment();
    let mut effects =
        kaname_core::workflow_effect_process::ProcessWorkflowEffectHost::from_environment(
            journal_path,
            projection_path,
            CURSOR_KEY,
        );
    let input_bytes = serde_json_canonicalizer::to_vec(&request.input).unwrap_or_default();
    let input_sha = {
        use sha2::Digest as _;
        hex::encode(sha2::Sha256::digest(&input_bytes))
    };
    for item in portfolio {
        let Some(revision_id) = item.active_revision_id.clone() else {
            continue;
        };
        let Ok(revision) = store.load_workflow_revision(&revision_id, "active") else {
            response
                .errors
                .push(format!("{}:revision_unavailable", item.workflow_id));
            continue;
        };
        let Ok(compiled) = serde_json::from_slice::<serde_json::Value>(&revision.compiled_source)
        else {
            response
                .errors
                .push(format!("{}:compiled_revision_invalid", item.workflow_id));
            continue;
        };
        let entry_node_id = compiled["entrypoints"][0]["nodeId"]
            .as_str()
            .unwrap_or_default();
        let Some(entry) = compiled["nodes"].as_array().and_then(|nodes| {
            nodes
                .iter()
                .find(|node| node["id"].as_str() == Some(entry_node_id))
        }) else {
            continue;
        };
        if entry["type"].as_str() != Some("trigger.event")
            || entry["config"]["eventContract"].as_str() != Some(request.event_contract.as_str())
        {
            continue;
        }
        response.matched += 1;
        if journal.is_none() {
            journal = Some(
                Journal::open(journal_path, &CURSOR_KEY)
                    .map_err(|_| "workflow_run_journal_unavailable".to_owned())?,
            );
        }
        let Some(journal) = journal.as_mut() else {
            continue;
        };
        let binding = kaname_core::workflow_executor::WorkflowTriggerRunBinding {
            workflow_id: item.workflow_id.clone(),
            revision_id: revision_id.clone(),
            package_digest: revision.summary.package_digest.clone(),
            installation_id: format!("installation-{}", item.workflow_id),
            case_id: format!(
                "case-{}-{}",
                item.workflow_id,
                if request.contract_key.is_empty() {
                    &request.event_id
                } else {
                    &request.contract_key
                }
            ),
            input: v1::WorkflowValueReference {
                value_id: format!("value-event-{}", request.event_id),
                content_type: "application/json".into(),
                byte_count: input_bytes.len() as u64,
                sha256: input_sha.clone(),
                inline_canonical_json: input_bytes.clone(),
                ..Default::default()
            },
            scope: v1::Scope {
                project_id: "project-kaname".into(),
                workspace_id: "workspace-local".into(),
                account_id: String::new(),
                authority_id: String::new(),
                egress_class: String::new(),
                destination_digest: String::new(),
            },
            actor_id: "kaname-event-source".into(),
            observed_at_unix_millis: now,
        };
        let trigger = kaname_core::workflow_executor::WorkflowEventTrigger {
            event_id: request.event_id.clone(),
            contract_key: if request.contract_key.is_empty() {
                request.event_id.clone()
            } else {
                request.contract_key.clone()
            },
        };
        match kaname_core::workflow_executor::execute_event_trigger_with_hosts(
            journal,
            &store,
            &binding,
            &trigger,
            &mut capabilities,
            &mut llm,
            &mut effects,
        ) {
            Ok(receipt) => response.receipts.push(WorkflowEventFanoutReceipt {
                workflow_id: item.workflow_id.clone(),
                revision_id: revision_id.clone(),
                run_id: receipt.run_id,
                admission: format!("{:?}", receipt.admission).to_lowercase(),
                outcome: receipt
                    .result
                    .as_ref()
                    .map(|result| format!("{:?}", result.outcome).to_lowercase())
                    .unwrap_or_default(),
            }),
            Err(error) => response
                .errors
                .push(format!("{}:{error:?}", item.workflow_id)),
        }
    }
    if let Some(journal) = journal.as_ref() {
        let _ = WorkflowRunProjection::open_or_rebuild(projection_path, journal);
    }
    serde_json::to_vec(&response)
        .map(hex::encode)
        .map_err(|_| "workflow_event_fanout_encode_failed".to_owned())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowLibraryPublishRequest {
    request_id: String,
    workflow_id: String,
    package_id: String,
    name: String,
    summary: String,
    /// Full v1 workflow document as JSON text.
    workflow_json: String,
    #[serde(default)]
    layout_json: String,
    #[serde(default)]
    schema_bundle_json: String,
    #[serde(default)]
    dependency_lock_json: String,
    #[serde(default)]
    configuration_contract_json: String,
    #[serde(default)]
    release_version: String,
    #[serde(default)]
    activate: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowLibraryPublishResponse {
    request_id: String,
    workflow_id: String,
    revision_id: String,
    package_digest: String,
    execution_support: String,
    activated: bool,
    activation_generation: i64,
}

/// Creates a draft from a complete workflow document, publishes it as a
/// revision (compiling through the same validator the executor trusts), and
/// optionally activates it. This is the first desktop-callable publish path.
fn workflow_library_publish(application_support: &str) -> Result<String, String> {
    use kaname_core::workflow_drafts::CreateWorkflowDraft;
    use kaname_core::workflow_publication::PublishWorkflowRevision;
    let wire = read_standard_input()?;
    let request: WorkflowLibraryPublishRequest = serde_json::from_slice(&wire)
        .map_err(|_| "workflow_library_publish_rejected".to_owned())?;
    if request.request_id.is_empty()
        || request.workflow_id.is_empty()
        || request.workflow_json.is_empty()
    {
        return Err("workflow_library_publish_rejected".to_owned());
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default();
    let mut store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let draft = store
        .create_draft(CreateWorkflowDraft {
            workflow_id: request.workflow_id.clone(),
            package_id: request.package_id.clone(),
            name: request.name.clone(),
            summary: request.summary.clone(),
            edit_id: format!("edit-{}", request.request_id),
            session_id: "kaname-desktop".into(),
            workflow_source: request.workflow_json.clone().into_bytes(),
            layout_source: if request.layout_json.is_empty() {
                br#"{"nodes":[]}"#.to_vec()
            } else {
                request.layout_json.clone().into_bytes()
            },
            recorded_at_unix_millis: now,
        })
        .map_err(|error| format!("workflow_library_publish_failed:draft:{error:?}"))?;
    let revision_id = format!("revision-{}", request.request_id);
    let published = store
        .publish_revision(PublishWorkflowRevision {
            workflow_id: request.workflow_id.clone(),
            expected_draft_sequence: draft.head_sequence,
            revision_id: revision_id.clone(),
            registration_id: format!("registration-{}", request.request_id),
            release_version: if request.release_version.is_empty() {
                "1.0.0".into()
            } else {
                request.release_version.clone()
            },
            schema_bundle_json: if request.schema_bundle_json.is_empty() {
                br#"{"bundleVersion":1,"schemas":[]}"#.to_vec()
            } else {
                request.schema_bundle_json.clone().into_bytes()
            },
            dependency_lock_json: if request.dependency_lock_json.is_empty() {
                br#"{"lockVersion":1,"dependencies":[]}"#.to_vec()
            } else {
                request.dependency_lock_json.clone().into_bytes()
            },
            configuration_contract_json: if request.configuration_contract_json.is_empty() {
                br#"{"type":"object"}"#.to_vec()
            } else {
                request.configuration_contract_json.clone().into_bytes()
            },
            published_at_unix_millis: now,
        })
        .map_err(|error| format!("workflow_library_publish_failed:publish:{error:?}"))?;
    let revision = store
        .load_workflow_revision(&revision_id, "active")
        .map_err(|error| format!("workflow_library_publish_failed:load:{error:?}"))?;
    let execution_support = format!("{:?}", revision.summary.execution_support).to_lowercase();
    let mut activated = false;
    let mut activation_generation = 0;
    if request.activate {
        let alias_id = format!("alias-active-{}", request.workflow_id);
        let mut expected_generation = 0;
        for _ in 0..3 {
            match store.set_workflow_activation(SetWorkflowActivation {
                alias_id: alias_id.clone(),
                workflow_id: request.workflow_id.clone(),
                alias_key: "active".into(),
                revision_id: Some(revision_id.clone()),
                expected_generation,
                updated_at_unix_millis: now,
            }) {
                Ok(outcome) => {
                    activated = true;
                    activation_generation = outcome.generation;
                    break;
                }
                Err(kaname_core::workflow_library::WorkflowLibraryError::ActivationConflict {
                    actual,
                    ..
                }) => {
                    expected_generation = actual;
                }
                Err(error) => {
                    return Err(format!(
                        "workflow_library_publish_failed:activate:{error:?}"
                    ));
                }
            }
        }
    }
    let json = serde_json::to_vec(&WorkflowLibraryPublishResponse {
        request_id: request.request_id,
        workflow_id: request.workflow_id,
        revision_id,
        package_digest: published.package_digest,
        execution_support,
        activated,
        activation_generation,
    })
    .map_err(|_| "workflow_library_publish_encode_failed".to_owned())?;
    Ok(hex::encode(json))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowNodeAvailabilityRequest {
    request_id: String,
    nodes: Vec<WorkflowNodeAvailabilityRequestNode>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowNodeAvailabilityRequestNode {
    node_id: String,
    #[serde(rename = "type")]
    node_type: String,
    #[serde(default)]
    config: serde_json::Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowNodeAvailabilityResponse {
    request_id: String,
    nodes: Vec<WorkflowNodeAvailabilityResponseNode>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkflowNodeAvailabilityResponseNode {
    node_id: String,
    availability: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    downgrade_condition: Option<&'static str>,
}

/// Answers the Builder's question "would the compiler execute this node as
/// configured?" without publishing anything. Same decision the compiler
/// records into the compiled artifact.
fn workflow_node_availability() -> Result<String, String> {
    let wire = read_standard_input()?;
    let request: WorkflowNodeAvailabilityRequest = serde_json::from_slice(&wire)
        .map_err(|_| "workflow_node_availability_rejected".to_owned())?;
    if request.request_id.is_empty() || request.nodes.len() > 512 {
        return Err("workflow_node_availability_rejected".to_owned());
    }
    let nodes = request
        .nodes
        .iter()
        .map(|node| {
            let decision =
                workflow_compiler::node_execution_availability(&node.node_type, &node.config);
            WorkflowNodeAvailabilityResponseNode {
                node_id: node.node_id.clone(),
                availability: decision.availability,
                downgrade_condition: decision.downgrade_condition,
            }
        })
        .collect();
    let json = serde_json::to_vec(&WorkflowNodeAvailabilityResponse {
        request_id: request.request_id,
        nodes,
    })
    .map_err(|_| "workflow_node_availability_encode_failed".to_owned())?;
    Ok(hex::encode(json))
}

#[derive(Deserialize)]
struct WorkflowEffectAuthorizeRequest {
    request_id: String,
    effect_id: String,
    approval_id: String,
    /// Hex of the approval request fingerprint the owner saw.
    fingerprint_hex: String,
    /// "approve" or "reject".
    decision: String,
    #[serde(default)]
    actor_id: String,
    #[serde(default)]
    device_id: String,
    /// Identity of the owner's standing rule when no human clicked this
    /// approval; empty for an explicit decision.
    #[serde(default)]
    standing_rule_reference: String,
}

#[derive(Serialize)]
struct WorkflowEffectAuthorizeResponse {
    request_id: String,
    effect_id: String,
    status: String,
    duplicate: bool,
}

/// Records the owner's decision for a proposed effect. The executor picks the
/// resolution up on its next transition; nothing is dispatched here.
fn workflow_effect_authorize(journal_path: &str, projection_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    let request: WorkflowEffectAuthorizeRequest = serde_json::from_slice(&wire)
        .map_err(|_| "workflow_effect_authorize_rejected".to_owned())?;
    let fingerprint = hex::decode(&request.fingerprint_hex)
        .map_err(|_| "workflow_effect_authorize_rejected:fingerprint".to_owned())?;
    let decision = match request.decision.as_str() {
        "approve" => v1::ApprovalDecision::Approve,
        "reject" => v1::ApprovalDecision::Reject,
        _ => return Err("workflow_effect_authorize_rejected:decision".to_owned()),
    };
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let (mut projection, _) = WorkflowRunProjection::open_or_rebuild(projection_path, &journal)
        .map_err(|_| "workflow_run_projection_unavailable".to_owned())?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default();
    let admission = kaname_core::workflow_effect_authority::authorize_workflow_effect(
        &mut journal,
        &mut projection,
        &request.effect_id,
        v1::ApprovalResolution {
            approval_id: request.approval_id,
            decision: decision as i32,
            expected_fingerprint: fingerprint,
            actor_id: if request.actor_id.is_empty() {
                "local-owner".into()
            } else {
                request.actor_id
            },
            device_id: request.device_id,
            standing_rule_reference: request.standing_rule_reference,
        },
        now,
    )
    .map_err(|error| format!("workflow_effect_authorize_failed:{error:?}"))?;
    let json = serde_json::to_vec(&WorkflowEffectAuthorizeResponse {
        request_id: request.request_id,
        effect_id: request.effect_id,
        status: admission.authority.status,
        duplicate: admission.duplicate,
    })
    .map_err(|_| "workflow_effect_authorize_encode_failed".to_owned())?;
    Ok(hex::encode(json))
}

fn workflow_run_inspect(journal_path: &str, projection_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    let query = kaname_core::workflow_protocol::decode_run_inspection_query(&wire)
        .map_err(|_| "workflow_run_inspection_rejected".to_owned())?;
    let journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let (projection, _) = WorkflowRunProjection::open_or_rebuild(projection_path, &journal)
        .map_err(|_| "workflow_run_projection_unavailable".to_owned())?;
    let runs = projection
        .inspect_runs_query(&query)
        .map_err(|_| "workflow_run_inspection_failed".to_owned())?;
    let absence_reason = if !query.run_id.is_empty() && runs.is_empty() {
        "not_found_or_purged"
    } else {
        ""
    };
    Ok(hex::encode(
        v1::WorkflowRunInspectionResponse {
            schema_version: Some(v1::SchemaVersion {
                major: kaname_core::SCHEMA_MAJOR,
                minor: 0,
            }),
            request_id: query.request_id,
            projection_high_water_mark: projection
                .high_water_mark()
                .map_err(|_| "workflow_run_projection_unavailable".to_owned())?,
            runs,
            absence_reason: absence_reason.into(),
        }
        .encode_to_vec(),
    ))
}

fn workflow_connector_observation_begin(
    journal_path: &str,
    projection_path: &str,
) -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_connector_observation_begin_wire(journal_path, projection_path, &wire)
}

fn workflow_connector_observation_begin_wire(
    journal_path: &str,
    projection_path: &str,
    wire: &[u8],
) -> Result<String, String> {
    let request = v1::BeginWorkflowConnectorObservationRequest::decode(wire)
        .map_err(|_| "workflow_connector_observation_begin_rejected".to_owned())?;
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let (mut projection, _) = WorkflowRunProjection::open_or_rebuild(projection_path, &journal)
        .map_err(|_| "workflow_run_projection_unavailable".to_owned())?;
    let response = begin_workflow_connector_observation(&mut journal, &mut projection, request)
        .map_err(|error| format!("workflow_connector_observation_begin_failed:{error}"))?;
    Ok(hex::encode(response.encode_to_vec()))
}

fn workflow_connector_observation_settle(
    journal_path: &str,
    projection_path: &str,
) -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_connector_observation_settle_wire(journal_path, projection_path, &wire)
}

fn workflow_connector_observation_settle_wire(
    journal_path: &str,
    projection_path: &str,
    wire: &[u8],
) -> Result<String, String> {
    let request = v1::SettleWorkflowConnectorObservationRequest::decode(wire)
        .map_err(|_| "workflow_connector_observation_settle_rejected".to_owned())?;
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let (mut projection, _) = WorkflowRunProjection::open_or_rebuild(projection_path, &journal)
        .map_err(|_| "workflow_run_projection_unavailable".to_owned())?;
    let response = settle_workflow_connector_observation(&mut journal, &mut projection, request)
        .map_err(|error| format!("workflow_connector_observation_settle_failed:{error}"))?;
    Ok(hex::encode(response.encode_to_vec()))
}

fn workflow_run_purge(
    journal_path: &str,
    projection_path: &str,
    application_support: &str,
) -> Result<String, String> {
    let wire = read_standard_input()?;
    let request = kaname_core::workflow_protocol::decode_run_purge_request(&wire)
        .map_err(|_| "workflow_run_purge_rejected".to_owned())?;
    let mut journal = Journal::open(journal_path, &CURSOR_KEY)
        .map_err(|_| "workflow_run_journal_unavailable".to_owned())?;
    let (mut projection, _) = WorkflowRunProjection::open_or_rebuild(projection_path, &journal)
        .map_err(|_| "workflow_run_projection_unavailable".to_owned())?;
    let mut storage = open_workflow_scoped_storage(
        application_support,
        WorkflowObjectStoreQuota::local_default(),
    )
    .map_err(|_| "workflow_run_storage_unavailable".to_owned())?;
    let response = purge_workflow_run(&mut journal, &mut projection, Some(&mut storage), request)
        .map_err(|error| format!("workflow_run_purge_failed:{error}"))?;
    Ok(hex::encode(response.encode_to_vec()))
}

fn workflow_canonicalize() -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_canonicalize_wire(&wire)
}

fn workflow_canonicalize_wire(wire: &[u8]) -> Result<String, String> {
    let report = workflow_canonical::canonicalize(&wire).map_err(|error| match error {
        workflow_canonical::WorkflowCanonicalError::InputOutOfBounds => {
            "workflow_canonical_input_out_of_bounds"
        }
        workflow_canonical::WorkflowCanonicalError::InvalidIJson => {
            "workflow_canonical_input_invalid"
        }
        workflow_canonical::WorkflowCanonicalError::EncodingFailed => {
            "workflow_canonical_encoding_failed"
        }
    })?;
    serde_json::to_string(&serde_json::json!({
        "canonical_hex": hex::encode(report.canonical_bytes),
        "sha256": report.sha256,
    }))
    .map_err(|_| "workflow_canonical_report_encoding_failed".into())
}

fn workflow_compile() -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_compile_wire(&wire)
}

fn workflow_compile_wire(wire: &[u8]) -> Result<String, String> {
    let request = kaname_core::workflow_protocol::decode_compile_request(wire)
        .map_err(|_| "workflow_compile_request_rejected".to_owned())?;
    Ok(hex::encode(
        workflow_compiler::compile(&request).encode_to_vec(),
    ))
}

fn workflow_library_query(application_support: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_library_query_wire(application_support, &wire)
}

fn workflow_library_query_wire(application_support: &str, wire: &[u8]) -> Result<String, String> {
    let request = kaname_core::workflow_protocol::decode_library_query_request(wire)
        .map_err(|_| "workflow_library_query_rejected".to_owned())?;
    let store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let mut response = v1::WorkflowLibraryQueryResponse {
        schema_version: Some(v1::SchemaVersion {
            major: kaname_core::SCHEMA_MAJOR,
            minor: 0,
        }),
        request_id: request.request_id,
        ..Default::default()
    };
    use v1::workflow_library_query_request::Query;
    match request
        .query
        .ok_or_else(|| "workflow_library_query_missing".to_owned())?
    {
        Query::Portfolio(query) => {
            response.portfolio = store
                .workflow_portfolio(&query.alias_key)
                .map_err(|_| "workflow_library_query_failed".to_owned())?
                .into_iter()
                .map(|item| v1::WorkflowPortfolioItem {
                    workflow_id: item.workflow_id,
                    package_id: item.package_id,
                    name: item.name,
                    summary: item.summary,
                    state: portfolio_state(item.state),
                    draft_present: item.has_draft,
                    latest_revision_id: item.latest_revision_id.unwrap_or_default(),
                    latest_revision_number: item.latest_revision_number.unwrap_or_default(),
                    active_revision_id: item.active_revision_id.unwrap_or_default(),
                    execution_support: item
                        .execution_support
                        .map(execution_support)
                        .unwrap_or_default(),
                })
                .collect();
        }
        Query::RevisionHistory(query) => {
            response.revision_history = store
                .workflow_revision_history(&query.workflow_id, &query.alias_key)
                .map_err(|_| "workflow_library_query_failed".to_owned())?
                .into_iter()
                .map(revision_summary)
                .collect();
        }
        Query::RevisionContent(query) => {
            let content = store
                .load_workflow_revision(&query.revision_id, &query.alias_key)
                .map_err(|_| "workflow_library_query_failed".to_owned())?;
            response.revision_content = Some(revision_content(content));
        }
        Query::RevisionComparison(query) => {
            let comparison = store
                .compare_workflow_revisions(&query.from_revision_id, &query.to_revision_id)
                .map_err(|_| "workflow_library_query_failed".to_owned())?;
            response.revision_comparison = Some(revision_comparison(comparison));
        }
    }
    Ok(hex::encode(response.encode_to_vec()))
}

fn workflow_library_activate(application_support: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_library_activate_wire(application_support, &wire)
}

fn workflow_library_activate_wire(
    application_support: &str,
    wire: &[u8],
) -> Result<String, String> {
    let request = kaname_core::workflow_protocol::decode_activation_request(wire)
        .map_err(|_| "workflow_activation_request_rejected".to_owned())?;
    let mut store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let outcome = store
        .set_workflow_activation(SetWorkflowActivation {
            alias_id: request.alias_id,
            workflow_id: request.workflow_id,
            alias_key: request.alias_key,
            revision_id: (!request.revision_id.is_empty()).then_some(request.revision_id),
            expected_generation: request.expected_generation,
            updated_at_unix_millis: request.updated_at_unix_millis,
        })
        .map_err(|_| "workflow_activation_failed".to_owned())?;
    Ok(hex::encode(
        v1::SetWorkflowActivationResponse {
            schema_version: Some(v1::SchemaVersion {
                major: kaname_core::SCHEMA_MAJOR,
                minor: 0,
            }),
            request_id: request.request_id,
            workflow_id: outcome.workflow_id,
            alias_key: outcome.alias_key,
            revision_id: outcome.revision_id.unwrap_or_default(),
            generation: outcome.generation,
            duplicate: outcome.duplicate,
        }
        .encode_to_vec(),
    ))
}

fn workflow_library_import_frozen(application_support: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_library_import_frozen_wire(application_support, &wire)
}

fn workflow_library_import_frozen_wire(
    application_support: &str,
    wire: &[u8],
) -> Result<String, String> {
    let request = kaname_core::workflow_protocol::decode_frozen_workspace_import_request(wire)
        .map_err(|_| "workflow_import_request_rejected".to_owned())?;
    let mut store = open_workflow_library(application_support)
        .map_err(|_| "workflow_library_unavailable".to_owned())?;
    let outcome = store
        .import_frozen_workspace(ImportFrozenWorkspace {
            receipt_id: request.receipt_id,
            source_digest: request.source_digest,
            imported_at_unix_millis: request.imported_at_unix_millis,
            drafts: request
                .drafts
                .into_iter()
                .map(|draft| ImportFrozenWorkflowDraft {
                    workflow_id: draft.workflow_id,
                    package_id: draft.package_id,
                    name: draft.name,
                    summary: draft.summary,
                    workflow_source: draft.workflow_json,
                    layout_source: draft.layout_json,
                    comparison_source: draft.comparison_json,
                    blocked: draft.blocked,
                })
                .collect(),
        })
        .map_err(|_| "workflow_import_failed".to_owned())?;
    let import_outcome = match outcome.outcome.as_str() {
        "created" => v1::FrozenWorkspaceImportOutcome::Created as i32,
        "blocked" => v1::FrozenWorkspaceImportOutcome::Blocked as i32,
        _ => return Err("workflow_import_outcome_invalid".into()),
    };
    Ok(hex::encode(
        v1::ImportFrozenWorkspaceResponse {
            schema_version: Some(v1::SchemaVersion {
                major: kaname_core::SCHEMA_MAJOR,
                minor: 0,
            }),
            request_id: request.request_id,
            source_digest: outcome.source_digest,
            outcome: import_outcome,
            comparison_digest: outcome.comparison_digest,
            duplicate: outcome.duplicate,
            workflows: outcome
                .workflows
                .into_iter()
                .map(|item| v1::ImportedFrozenWorkflow {
                    workflow_id: item.workflow_id,
                    generation: item.generation,
                    blocked: item.blocked,
                    comparison_digest: item.comparison_digest,
                })
                .collect(),
        }
        .encode_to_vec(),
    ))
}

fn portfolio_state(state: WorkflowPortfolioState) -> i32 {
    match state {
        WorkflowPortfolioState::Draft => v1::WorkflowPortfolioState::Draft as i32,
        WorkflowPortfolioState::Published => v1::WorkflowPortfolioState::Published as i32,
        WorkflowPortfolioState::Active => v1::WorkflowPortfolioState::Active as i32,
        WorkflowPortfolioState::Disabled => v1::WorkflowPortfolioState::Disabled as i32,
    }
}

fn execution_support(support: WorkflowExecutionSupport) -> i32 {
    match support {
        WorkflowExecutionSupport::Executable => v1::WorkflowExecutionSupport::Executable as i32,
        WorkflowExecutionSupport::Unsupported => v1::WorkflowExecutionSupport::Unsupported as i32,
    }
}

fn revision_summary(summary: StoredWorkflowRevisionSummary) -> v1::WorkflowRevisionSummary {
    v1::WorkflowRevisionSummary {
        workflow_id: summary.workflow_id,
        revision_id: summary.revision_id,
        revision_number: summary.revision_number,
        release_version: summary.release_version,
        created_at_unix_millis: summary.created_at_unix_millis,
        package_digest: summary.package_digest,
        is_active: summary.is_active,
        execution_support: execution_support(summary.execution_support),
    }
}

fn revision_content(content: StoredWorkflowRevisionContent) -> v1::WorkflowRevisionContent {
    v1::WorkflowRevisionContent {
        summary: Some(revision_summary(content.summary)),
        workflow_json: content.workflow_source,
        layout_json: content.layout_source,
        configuration_json: content.configuration_source,
        compiled_json: content.compiled_source,
    }
}

fn revision_comparison(
    comparison: StoredWorkflowRevisionComparison,
) -> v1::WorkflowRevisionComparison {
    v1::WorkflowRevisionComparison {
        workflow_id: comparison.workflow_id,
        from_revision_id: comparison.from_revision_id,
        to_revision_id: comparison.to_revision_id,
        added_node_ids: comparison.added_node_ids,
        removed_node_ids: comparison.removed_node_ids,
        changed_definition_pointers: comparison.changed_definition_pointers,
        changed_layout_pointers: comparison.changed_layout_pointers,
        changed_configuration_pointers: comparison.changed_configuration_pointers,
        truncated: comparison.truncated,
    }
}

fn read_standard_input() -> Result<Vec<u8>, String> {
    let mut wire = Vec::new();
    std::io::stdin()
        .read_to_end(&mut wire)
        .map_err(|error| error.to_string())?;
    Ok(wire)
}

fn workflow_schema_check() -> Result<String, String> {
    let wire = read_standard_input()?;
    workflow_schema_check_wire(&wire)
}

fn workflow_schema_check_wire(wire: &[u8]) -> Result<String, String> {
    if wire.is_empty() || wire.len() > workflow_schema::MAXIMUM_SCHEMA_CHECK_REQUEST_BYTES {
        return Err("workflow_schema_request_out_of_bounds".into());
    }
    let request: WorkflowSchemaCheckRequest =
        serde_json::from_slice(&wire).map_err(|_| "malformed_workflow_schema_request")?;
    serde_json::to_string(&workflow_schema::check(&request))
        .map_err(|_| "workflow_schema_report_encoding_failed".into())
}

fn append_event(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    append_event_wire(journal_path, &wire)
}

fn authorize_action(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    authorize_action_wire(journal_path, &wire)
}

fn authorize_action_wire(journal_path: &str, wire: &[u8]) -> Result<String, String> {
    let command = v1::ApprovalCommand::decode(wire).map_err(|_| "malformed_approval_command")?;
    let request = command.request.ok_or("approval_command_missing_request")?;
    let resolution = command
        .resolution
        .ok_or("approval_command_missing_resolution")?;
    validate_live_approval(&command.stream_id, &request, &resolution)?;

    let fingerprint = approval_fingerprint(&request);
    if request.fingerprint != fingerprint || resolution.expected_fingerprint != fingerprint {
        return Err("approval_fingerprint_mismatch".into());
    }

    let journal = Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let mut core = LocalPolicyCore::new(journal);
    core.request_approval(request.clone(), &command.stream_id)
        .map_err(|error| error.to_string())?;
    let result = core
        .resolve_approval(
            &resolution,
            command.resolved_at_unix_millis,
            &command.current_target_revision,
            &command.stream_id,
        )
        .map_err(|error| error.to_string())?;
    let (decision, reason_code) = match result {
        ApprovalResolutionResult::Approved => (v1::ApprovalDecision::Approve, "approved"),
        ApprovalResolutionResult::Rejected => (v1::ApprovalDecision::Reject, "rejected"),
        ApprovalResolutionResult::Stale => {
            return Err("approval_stale".into());
        }
        ApprovalResolutionResult::Expired => {
            return Err("approval_expired".into());
        }
    };
    let selector = format!("thread:{}", command.stream_id);
    let position = core
        .journal()
        .replay(&selector, None, 1)
        .map_err(|error| error.to_string())?
        .high_water_mark;
    let receipt = v1::ApprovalCommandReceipt {
        approval_id: request.approval_id,
        decision: decision as i32,
        fingerprint,
        store_position: position,
        reason_code: reason_code.into(),
    };
    Ok(hex::encode(receipt.encode_to_vec()))
}

fn validate_live_approval(
    stream_id: &str,
    request: &v1::ApprovalRequest,
    resolution: &v1::ApprovalResolution,
) -> Result<(), String> {
    let scope = request
        .scope
        .as_ref()
        .ok_or("live_approval_missing_scope")?;
    if !stream_id.starts_with("thread:project:")
        || request.action_kind != "codex.workspace_write"
        || scope.project_id.is_empty()
        || scope.workspace_id.is_empty()
        || !scope.account_id.is_empty()
        || scope.authority_id != "local-user"
        || scope.egress_class != "provider_and_workspace"
        || scope.destination_digest.is_empty()
        || request.target_id != scope.workspace_id
        || request.target_revision.is_empty()
        || request.effect_digest.is_empty()
        || request.consequence.is_empty()
        || !request.reversible
        || request.approval_payload_version != 1
        || resolution.actor_id.is_empty()
        || resolution.decision != v1::ApprovalDecision::Approve as i32
    {
        return Err("live_approval_scope_not_allowed".into());
    }
    Ok(())
}

fn record_review(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    record_review_wire(journal_path, &wire)
}

fn record_review_wire(journal_path: &str, wire: &[u8]) -> Result<String, String> {
    let command = v1::CommandEnvelope::decode(wire).map_err(|_| "malformed_review_command")?;
    let review_payload = command
        .payload
        .as_ref()
        .ok_or("review_command_missing_payload")?;
    if !matches!(command.kind.as_str(), "review.accept" | "review.reject")
        || review_payload.type_url != "kaname.review.decision.v1"
        || review_payload.content_type != "application/x-protobuf"
        || review_payload.payload_version != 1
    {
        return Err("review_command_not_allowed".into());
    }
    let review = v1::ReviewDecision::decode(review_payload.value.as_slice())
        .map_err(|_| "malformed_review_decision")?;
    let scope = command
        .scope
        .as_ref()
        .ok_or("review_command_missing_scope")?;
    if !review.stream_id.starts_with("thread:project:")
        || review.evidence_digest.is_empty()
        || scope.project_id.is_empty()
        || scope.workspace_id.is_empty()
        || !scope.account_id.is_empty()
        || scope.authority_id != "local-user"
        || scope.egress_class != "local_review"
        || !scope.destination_digest.is_empty()
        || command.actor_id.is_empty()
        || (command.kind == "review.accept") != review.accepted
    {
        return Err("review_scope_not_allowed".into());
    }

    let mut journal =
        Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let selector = format!("thread:{}", review.stream_id);
    let current_position = journal
        .replay(&selector, None, 1)
        .map_err(|error| error.to_string())?
        .high_water_mark;
    if command.expected_revision != current_position {
        return Err("review_revision_conflict".into());
    }
    let outcome = journal
        .admit_command(&command)
        .map_err(|error| error.to_string())?;
    let event = EventEnvelope {
        schema_version: Some(v1::SchemaVersion { major: 1, minor: 0 }),
        event_id: format!("event:{}", command.command_id),
        store_position: 0,
        stream_id: review.stream_id.clone(),
        stream_sequence: 0,
        occurred_at_unix_millis: command.submitted_at_unix_millis,
        kind: if review.accepted {
            "review.accepted".into()
        } else {
            "review.rejected".into()
        },
        payload: Some(v1::OpaqueTypedPayload {
            type_url: "kaname.review.decision.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: review.encode_to_vec(),
            payload_version: 1,
        }),
        provenance: Some(v1::EventProvenance {
            source_kind: "control_plane".into(),
            provider_instance_id: String::new(),
            native_type: String::new(),
            native_cursor: Vec::new(),
            raw_evidence_digest: String::new(),
            retention_class: v1::EvidenceRetentionClass::None as i32,
        }),
        causation_id: command.command_id,
        correlation_id: String::new(),
    };
    let appended = journal
        .append_event(event)
        .map_err(|error| error.to_string())?;
    let response = v1::CommandOutcome {
        store_position: appended.store_position,
        ..outcome
    };
    Ok(hex::encode(response.encode_to_vec()))
}

fn replay(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    replay_wire(journal_path, &wire)
}

fn replay_wire(journal_path: &str, wire: &[u8]) -> Result<String, String> {
    let request = v1::ReplayRequest::decode(wire).map_err(|_| "malformed_replay_request")?;
    let journal = Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let page = journal
        .replay(
            &request.selector_id,
            request.cursor.as_ref(),
            request.page_size,
        )
        .map_err(|error| error.to_string())?;
    let snapshot = page.snapshot.map(|snapshot| v1::SnapshotDescriptor {
        snapshot_id: snapshot.id,
        selector_id: snapshot.selector_id,
        high_water_mark: snapshot.high_water_mark,
        checksum: snapshot.checksum,
        projection_schema_version: snapshot.projection_schema_version,
        state: snapshot.state,
    });
    let response = v1::ReplayResponse {
        basis: match page.basis {
            JournalReplayBasis::Events => v1::ReplayBasis::Events as i32,
            JournalReplayBasis::ResyncRequired => v1::ReplayBasis::ResyncRequired as i32,
        },
        snapshot,
        events: page.events,
        next_cursor: Some(page.next_cursor),
        high_water_mark: page.high_water_mark,
        has_more: page.has_more,
        gap_reason: page.gap_reason.unwrap_or_default(),
    };
    Ok(hex::encode(response.encode_to_vec()))
}

fn mobile_propose(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    mobile_propose_wire(journal_path, &wire, now_unix_millis()?)
}

fn mobile_propose_wire(
    journal_path: &str,
    wire: &[u8],
    now_unix_millis: i64,
) -> Result<String, String> {
    let challenge = v1::DeviceEnrollmentChallenge::decode(wire)
        .map_err(|_| "malformed_device_enrollment_challenge")?;
    let device_id = challenge
        .proposed_device
        .as_ref()
        .map(|identity| identity.device_id.clone())
        .ok_or("enrollment_missing_device")?;
    let mut journal =
        Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let admission = journal
        .propose_mobile_device(&challenge, now_unix_millis)
        .map_err(|error| error.to_string())?;
    let receipt = v1::DeviceEnrollmentReceipt {
        enrollment_id: challenge.enrollment_id,
        device_id,
        state: v1::DeviceEnrollmentState::Pending as i32,
        duplicate: admission == EnrollmentAdmission::Duplicate,
        reason_code: match admission {
            EnrollmentAdmission::Pending => "pending_local_confirmation",
            EnrollmentAdmission::Duplicate => "duplicate_pending_enrollment",
        }
        .into(),
    };
    Ok(hex::encode(receipt.encode_to_vec()))
}

fn mobile_decide(journal_path: &str) -> Result<String, String> {
    let wire = read_standard_input()?;
    mobile_decide_wire(journal_path, &wire, now_unix_millis()?)
}

fn mobile_decide_wire(
    journal_path: &str,
    wire: &[u8],
    now_unix_millis: i64,
) -> Result<String, String> {
    let decision = v1::DeviceEnrollmentDecision::decode(wire)
        .map_err(|_| "malformed_device_enrollment_decision")?;
    let mut journal =
        Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let result = journal
        .decide_mobile_device(&decision, now_unix_millis)
        .map_err(|error| error.to_string())?;
    let receipt = v1::DeviceEnrollmentReceipt {
        enrollment_id: decision.enrollment_id,
        device_id: result.device_id,
        state: result.state as i32,
        duplicate: result.duplicate,
        reason_code: match result.state {
            v1::DeviceEnrollmentState::Active => "enrollment_activated",
            v1::DeviceEnrollmentState::Rejected => "enrollment_rejected",
            _ => "invalid_enrollment_state",
        }
        .into(),
    };
    Ok(hex::encode(receipt.encode_to_vec()))
}

fn mobile_admit(
    journal_path: &str,
    expected_recipient_device_id: &str,
    expected_recipient_key_id: &str,
) -> Result<String, String> {
    let wire = read_standard_input()?;
    mobile_admit_wire(
        journal_path,
        &wire,
        expected_recipient_device_id,
        expected_recipient_key_id,
        now_unix_millis()?,
    )
}

fn mobile_admit_wire(
    journal_path: &str,
    wire: &[u8],
    expected_recipient_device_id: &str,
    expected_recipient_key_id: &str,
    now_unix_millis: i64,
) -> Result<String, String> {
    let envelope =
        v1::EncryptedSyncEnvelope::decode(wire).map_err(|_| "malformed_encrypted_sync_envelope")?;
    let header = v1::SyncAuthenticatedHeader::decode(envelope.authenticated_header.as_slice())
        .map_err(|_| "malformed_sync_header")?;
    let mut journal =
        Journal::open(journal_path, &CURSOR_KEY).map_err(|error| error.to_string())?;
    let admission = journal
        .record_authenticated_mobile_sync_wire(
            wire,
            expected_recipient_device_id,
            expected_recipient_key_id,
            now_unix_millis,
        )
        .map_err(|error| error.to_string())?;
    let (state, reason_code) = match admission {
        SyncAdmission::Accepted { .. } => (
            v1::SyncReceiptState::Decrypted,
            "authenticated_envelope_recorded",
        ),
        SyncAdmission::Duplicate { .. } => (
            v1::SyncReceiptState::Decrypted,
            "duplicate_authenticated_envelope",
        ),
        SyncAdmission::ResyncRequired { .. } => {
            (v1::SyncReceiptState::ResyncRequired, "sender_sequence_gap")
        }
    };
    let receipt = v1::SyncReceipt {
        envelope_id: header.envelope_id,
        sender_device_id: header.sender_device_id,
        sender_sequence: header.sender_sequence,
        state: state as i32,
        reason_code: reason_code.into(),
        mac_store_position: 0,
        recorded_at_unix_millis: now_unix_millis,
    };
    Ok(hex::encode(receipt.encode_to_vec()))
}

fn now_unix_millis() -> Result<i64, String> {
    let duration = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?;
    i64::try_from(duration.as_millis()).map_err(|_| "system_time_out_of_range".into())
}

fn append_event_wire(journal_path: &str, wire: &[u8]) -> Result<String, String> {
    let event = EventEnvelope::decode(wire).map_err(|_| "malformed_event_envelope")?;
    if event.store_position != 0 || event.stream_sequence != 0 {
        return Err("local_event_must_be_unpositioned".into());
    }
    validate_live_codex_event(&event)?;
    let result = Journal::open(journal_path, &CURSOR_KEY)
        .and_then(|mut journal| journal.append_event(event))
        .map_err(|error| error.to_string())?;
    serde_json::to_string(&EventAppendReport {
        event_id: result.event.event_id,
        stream_id: result.event.stream_id,
        store_position: result.store_position,
        stream_sequence: result.stream_sequence,
        duplicate: result.duplicate,
    })
    .map_err(|error| error.to_string())
}

/// This entrypoint is deliberately narrower than `Journal::append_event`.
/// Signed local clients may record observations, but cannot manufacture review
/// acceptance, queue commands, or a write grant through the provider bridge.
fn validate_live_codex_event(event: &EventEnvelope) -> Result<(), String> {
    if !matches!(
        event.kind.as_str(),
        "run.started"
            | "run.provider_completed"
            | "run.failed"
            | "run.interrupted"
            | "approval.requested"
            | "approval.approved"
            | "approval.rejected"
            | "question.requested"
            | "question.answered"
            | "provider.native_event_observed"
    ) {
        return Err("live_provider_event_kind_not_allowed".into());
    }
    let provenance = event
        .provenance
        .as_ref()
        .ok_or("live_provider_event_missing_provenance")?;
    if provenance.source_kind != "provider"
        || provenance.provider_instance_id.is_empty()
        || provenance.provider_instance_id.len() > 64
        || !provenance.raw_evidence_digest.is_empty()
        || provenance.retention_class != kaname_core::v1::EvidenceRetentionClass::None as i32
    {
        return Err("live_provider_provenance_not_allowed".into());
    }
    let payload = event
        .payload
        .as_ref()
        .ok_or("live_provider_event_missing_payload")?;
    if payload.type_url != "kaname.codex.redacted-observation.v1"
        || payload.content_type != "application/json"
        || payload.payload_version != 1
    {
        return Err("live_provider_payload_not_allowed".into());
    }
    Ok(())
}

fn scenario(fixture_id: &str) -> Result<String, String> {
    scenario_with(fixture_id, run_scenario)
}

fn scenario_store(fixture_id: &str, journal_path: &str) -> Result<String, String> {
    scenario_with(fixture_id, |metadata| {
        run_scenario_at_path(metadata, journal_path)
    })
}

fn scenario_with(
    fixture_id: &str,
    run: impl FnOnce(
        &kaname_core::fake_provider::ScenarioMetadata,
    ) -> kaname_core::journal::Result<kaname_core::fake_provider::ScenarioReport>,
) -> Result<String, String> {
    let metadata = embedded_scenarios()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|scenario| scenario.fixture_id == fixture_id)
        .ok_or_else(|| "unknown_scenario".to_owned())?;
    serde_json::to_string(&run(&metadata).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())
}

fn scale(fixture_id: &str) -> Result<String, String> {
    let events = scale_fixture(fixture_id).map_err(|error| error.to_string())?;
    let report = ScaleReport {
        fixture_id: fixture_id.into(),
        event_count: events.len(),
        first_event_id: events
            .first()
            .map(|event| event.event_id.clone())
            .unwrap_or_default(),
        last_event_id: events
            .last()
            .map(|event| event.event_id.clone())
            .unwrap_or_default(),
    };
    serde_json::to_string(&report).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaname_core::v1::{
        ApprovalCommand, ApprovalDecision, ApprovalRequest, ApprovalResolution, CommandDisposition,
        CommandEnvelope, CompileWorkflowRequest, CompileWorkflowResponse,
        DeviceEnrollmentChallenge, DeviceEnrollmentDecision, DeviceEnrollmentReceipt,
        DeviceEnrollmentState, DevicePublicIdentity, EncryptedSyncEnvelope, EventProvenance,
        EvidenceRetentionClass, FrozenWorkflowDraftImport, ImportFrozenWorkspaceRequest,
        ImportFrozenWorkspaceResponse, OpaqueTypedPayload, ReplayRequest, ReviewDecision,
        SchemaVersion, Scope, SyncAuthenticatedHeader, SyncReceipt, SyncReceiptState,
        WorkflowLibraryQueryRequest, WorkflowLibraryQueryResponse, WorkflowPortfolioQuery,
    };
    use tempfile::tempdir;

    #[test]
    fn workflow_canonicalize_returns_bounded_bytes_and_digest() {
        let response = workflow_canonicalize_wire(br#"{"b":2,"a":1}"#).unwrap();
        let report: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(report["canonical_hex"], "7b2261223a312c2262223a327d");
        assert_eq!(
            report["sha256"],
            "sha256:43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777"
        );
        let oversized = vec![b' '; workflow_canonical::MAXIMUM_CANONICAL_INPUT_BYTES + 1];
        assert_eq!(
            workflow_canonicalize_wire(&oversized).unwrap_err(),
            "workflow_canonical_input_out_of_bounds"
        );
    }

    #[test]
    fn workflow_schema_check_rejects_malformed_and_oversized_requests() {
        assert_eq!(
            workflow_schema_check_wire(b"not-json").unwrap_err(),
            "malformed_workflow_schema_request"
        );
        let oversized = vec![b' '; workflow_schema::MAXIMUM_SCHEMA_CHECK_REQUEST_BYTES + 1];
        assert_eq!(
            workflow_schema_check_wire(&oversized).unwrap_err(),
            "workflow_schema_request_out_of_bounds"
        );
    }

    #[test]
    fn workflow_schema_check_returns_structured_json() {
        let response =
            workflow_schema_check_wire(br#"{"schema":{"type":"string"},"instance":5}"#).unwrap();
        let report: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(report["draft"], "2020-12");
        assert_eq!(report["outcome"], "invalid_instance");
        assert_eq!(report["diagnostics"][0]["instance_path"], "");
    }

    #[test]
    fn workflow_compile_returns_the_versioned_bounded_response_contract() {
        let request = CompileWorkflowRequest {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            request_id: "compile:local-core-test".into(),
            manifest_json: br#"{"compileManifestVersion":1}"#.to_vec(),
            schema_bundle_json: br#"{}"#.to_vec(),
            dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
            configuration_contract_json: br#"{}"#.to_vec(),
            maximum_diagnostics: 8,
        };
        let encoded = workflow_compile_wire(&request.encode_to_vec()).unwrap();
        let response =
            CompileWorkflowResponse::decode(hex::decode(encoded).unwrap().as_slice()).unwrap();
        assert_eq!(response.request_id, request.request_id);
        assert_eq!(response.outcome, v1::WorkflowCheckOutcome::Invalid as i32);
        assert_eq!(response.diagnostics[0].code, "document.malformed");
        assert!(response.compiled_artifact.is_empty());
    }

    #[test]
    fn workflow_library_query_uses_a_versioned_path_free_wire_contract() {
        let directory = tempdir().unwrap();
        let request = WorkflowLibraryQueryRequest {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            request_id: "library:portfolio-test".into(),
            query: Some(v1::workflow_library_query_request::Query::Portfolio(
                WorkflowPortfolioQuery {
                    alias_key: "active".into(),
                },
            )),
        };
        let encoded = workflow_library_query_wire(
            directory.path().to_str().unwrap(),
            &request.encode_to_vec(),
        )
        .unwrap();
        let response =
            WorkflowLibraryQueryResponse::decode(hex::decode(encoded).unwrap().as_slice()).unwrap();
        assert_eq!(response.request_id, request.request_id);
        assert!(response.portfolio.is_empty());
        assert!(response.revision_history.is_empty());
        assert!(response.revision_content.is_none());
        assert!(response.revision_comparison.is_none());

        let mut missing_query = request;
        missing_query.query = None;
        assert_eq!(
            workflow_library_query_wire(
                directory.path().to_str().unwrap(),
                &missing_query.encode_to_vec(),
            ),
            Err("workflow_library_query_rejected".into())
        );
    }

    #[test]
    fn frozen_workspace_import_wire_is_path_free_and_idempotent() {
        let directory = tempdir().unwrap();
        let source_digest = "a".repeat(64);
        let request = ImportFrozenWorkspaceRequest {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            request_id: "import:frozen-wire-001".into(),
            receipt_id: "workspace-aaaaaaaaaaaaaaaaaaaaaaaa".into(),
            source_digest: source_digest.clone(),
            imported_at_unix_millis: 100,
            drafts: vec![FrozenWorkflowDraftImport {
                workflow_id: "workflow-wire".into(),
                package_id: "dev.kaname.workflow-wire".into(),
                name: "Wire import".into(),
                summary: "Sanitized frozen workflow".into(),
                workflow_json: br#"{"workflowId":"workflow-wire","packageId":"dev.kaname.workflow-wire","name":"Wire import","summary":"Sanitized frozen workflow"}"#.to_vec(),
                layout_json: br#"{"nodes":[]}"#.to_vec(),
                comparison_json: format!(
                    "{{\"workspaceSourceDigest\":\"{source_digest}\",\"workflowId\":\"workflow-wire\",\"blocking\":true}}"
                )
                .into_bytes(),
                blocked: true,
            }],
        };

        let first = workflow_library_import_frozen_wire(
            directory.path().to_str().unwrap(),
            &request.encode_to_vec(),
        )
        .unwrap();
        let first =
            ImportFrozenWorkspaceResponse::decode(hex::decode(first).unwrap().as_slice()).unwrap();
        assert_eq!(first.request_id, request.request_id);
        assert_eq!(first.source_digest, source_digest);
        assert_eq!(
            first.outcome,
            v1::FrozenWorkspaceImportOutcome::Blocked as i32
        );
        assert!(!first.duplicate);
        assert_eq!(first.workflows.len(), 1);
        assert_eq!(first.workflows[0].workflow_id, "workflow-wire");

        let second = workflow_library_import_frozen_wire(
            directory.path().to_str().unwrap(),
            &request.encode_to_vec(),
        )
        .unwrap();
        let second =
            ImportFrozenWorkspaceResponse::decode(hex::decode(second).unwrap().as_slice()).unwrap();
        assert!(second.duplicate);
        assert_eq!(second.comparison_digest, first.comparison_digest);
        assert_eq!(second.workflows, first.workflows);
    }

    #[test]
    fn append_event_wire_assigns_order_and_retries_idempotently() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("live.sqlite");
        let event = EventEnvelope {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            event_id: "codex-run-001-1".into(),
            store_position: 0,
            stream_id: "thread:project:kaname:thread-001".into(),
            stream_sequence: 0,
            occurred_at_unix_millis: 1_762_000_000_000,
            kind: "run.started".into(),
            payload: Some(OpaqueTypedPayload {
                type_url: "kaname.codex.redacted-observation.v1".into(),
                content_type: "application/json".into(),
                value: br#"{"nativeType":"turn/started"}"#.to_vec(),
                payload_version: 1,
            }),
            provenance: Some(EventProvenance {
                source_kind: "provider".into(),
                provider_instance_id: "codexLocal".into(),
                native_type: "turn/started".into(),
                native_cursor: Vec::new(),
                raw_evidence_digest: "".into(),
                retention_class: EvidenceRetentionClass::None as i32,
            }),
            causation_id: "".into(),
            correlation_id: "run-001".into(),
        };
        let wire = event.encode_to_vec();

        let first: EventAppendReport =
            serde_json::from_str(&append_event_wire(path.to_str().unwrap(), &wire).unwrap())
                .unwrap();
        assert_eq!(first.event_id, "codex-run-001-1");
        assert_eq!(first.store_position, 1);
        assert_eq!(first.stream_sequence, 1);
        assert!(!first.duplicate);

        let second: EventAppendReport =
            serde_json::from_str(&append_event_wire(path.to_str().unwrap(), &wire).unwrap())
                .unwrap();
        assert!(second.duplicate);
        assert_eq!(second.store_position, 1);

        let mut forged = event;
        forged.event_id = "codex-run-001-forged".into();
        forged.kind = "review.accepted".into();
        assert_eq!(
            append_event_wire(path.to_str().unwrap(), &forged.encode_to_vec()),
            Err("live_provider_event_kind_not_allowed".into())
        );
    }

    #[test]
    fn signed_host_mobile_operations_return_bounded_authority_receipts() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("mobile.sqlite");
        let path = path.to_str().unwrap();
        let now = 1_786_220_000_000;
        let identity = DevicePublicIdentity {
            device_id: "iphone-justin".into(),
            key_id: "iphone-key-1".into(),
            display_name: "Justin's iPhone".into(),
            platform: "ios".into(),
            hpke_public_key: vec![0x31; 32],
            key_generation: 1,
            created_at_unix_millis: now,
            expires_at_unix_millis: now + 86_400_000,
        };
        let challenge = DeviceEnrollmentChallenge {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            enrollment_id: "enrollment-1".into(),
            proposed_device: Some(identity),
            mac_nonce: vec![0x4d; 32],
            confirmation_digest: vec![0x43; 32],
            expires_at_unix_millis: now + 60_000,
        };
        let proposed = DeviceEnrollmentReceipt::decode(
            hex::decode(mobile_propose_wire(path, &challenge.encode_to_vec(), now).unwrap())
                .unwrap()
                .as_slice(),
        )
        .unwrap();
        assert_eq!(proposed.state, DeviceEnrollmentState::Pending as i32);

        let decision = DeviceEnrollmentDecision {
            enrollment_id: challenge.enrollment_id,
            state: DeviceEnrollmentState::Active as i32,
            mac_device_id: "mac-authority".into(),
            transcript_digest: vec![0x54; 32],
            decided_at_unix_millis: now,
        };
        let decided = DeviceEnrollmentReceipt::decode(
            hex::decode(mobile_decide_wire(path, &decision.encode_to_vec(), now).unwrap())
                .unwrap()
                .as_slice(),
        )
        .unwrap();
        assert_eq!(decided.device_id, "iphone-justin");
        assert_eq!(decided.state, DeviceEnrollmentState::Active as i32);

        let header = SyncAuthenticatedHeader {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            envelope_id: "envelope-1".into(),
            sender_device_id: "iphone-justin".into(),
            sender_key_id: "iphone-key-1".into(),
            recipient_device_id: "mac-authority".into(),
            recipient_key_id: "mac-key-1".into(),
            sender_sequence: 1,
            previous_envelope_digest: Vec::new(),
            sent_at_unix_millis: now,
            expires_at_unix_millis: now + 60_000,
            payload_kind: "queue.enqueue".into(),
            plaintext_digest: vec![0x50; 32],
            content_type: "application/x-protobuf".into(),
        };
        let envelope = EncryptedSyncEnvelope {
            authenticated_header: header.encode_to_vec(),
            encapsulated_key: vec![0x45; 32],
            ciphertext: vec![0x43; 48],
        };
        let admitted = SyncReceipt::decode(
            hex::decode(
                mobile_admit_wire(
                    path,
                    &envelope.encode_to_vec(),
                    "mac-authority",
                    "mac-key-1",
                    now,
                )
                .unwrap(),
            )
            .unwrap()
            .as_slice(),
        )
        .unwrap();
        assert_eq!(admitted.state, SyncReceiptState::Decrypted as i32);
        assert_eq!(admitted.sender_sequence, 1);
        assert!(
            mobile_admit_wire(
                path,
                &envelope.encode_to_vec(),
                "wrong-mac",
                "mac-key-1",
                now,
            )
            .is_err()
        );
    }

    #[test]
    fn write_approval_and_review_are_authoritative_replayable_events() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("phase2.sqlite");
        let path = path.to_str().unwrap();
        let stream_id = "thread:project:kaname:thread-002";
        let scope = Scope {
            project_id: "kaname".into(),
            workspace_id: "/tmp/kaname-isolated-worktree".into(),
            account_id: String::new(),
            authority_id: "local-user".into(),
            egress_class: "provider_and_workspace".into(),
            destination_digest: "codex-model-digest".into(),
        };
        let mut request = ApprovalRequest {
            approval_id: "approval-002".into(),
            action_kind: "codex.workspace_write".into(),
            scope: Some(scope.clone()),
            target_id: scope.workspace_id.clone(),
            target_revision: "revision-002".into(),
            effect_digest: vec![0x22; 32],
            consequence: "One isolated reversible turn.".into(),
            reversible: true,
            expires_at_unix_millis: 2_000,
            policy_reference: "phase2-explicit-isolated-worktree".into(),
            fingerprint: Vec::new(),
            approval_payload_version: 1,
        };
        request.fingerprint = approval_fingerprint(&request);
        let command = ApprovalCommand {
            stream_id: stream_id.into(),
            request: Some(request.clone()),
            resolution: Some(ApprovalResolution {
                approval_id: request.approval_id.clone(),
                decision: ApprovalDecision::Approve as i32,
                expected_fingerprint: request.fingerprint.clone(),
                actor_id: "justin".into(),
                device_id: "local-mac".into(),
                standing_rule_reference: String::new(),
            }),
            resolved_at_unix_millis: 1_000,
            current_target_revision: request.target_revision.clone(),
        };
        let receipt = v1::ApprovalCommandReceipt::decode(
            hex::decode(authorize_action_wire(path, &command.encode_to_vec()).unwrap())
                .unwrap()
                .as_slice(),
        )
        .unwrap();
        assert_eq!(receipt.decision, ApprovalDecision::Approve as i32);
        assert_eq!(receipt.store_position, 2);

        let decision = ReviewDecision {
            stream_id: stream_id.into(),
            evidence_digest: vec![0x33; 32],
            accepted: true,
            knowledge_update_proposal: "Record the verified result.".into(),
        };
        let review = CommandEnvelope {
            schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
            command_id: "review-002".into(),
            idempotency_key: "review-002".into(),
            kind: "review.accept".into(),
            payload: Some(OpaqueTypedPayload {
                type_url: "kaname.review.decision.v1".into(),
                content_type: "application/x-protobuf".into(),
                value: decision.encode_to_vec(),
                payload_version: 1,
            }),
            scope: Some(Scope {
                egress_class: "local_review".into(),
                destination_digest: String::new(),
                ..scope
            }),
            actor_id: "justin".into(),
            expected_revision: receipt.store_position,
            submitted_at_unix_millis: 3_000,
        };
        let outcome = v1::CommandOutcome::decode(
            hex::decode(record_review_wire(path, &review.encode_to_vec()).unwrap())
                .unwrap()
                .as_slice(),
        )
        .unwrap();
        assert_eq!(outcome.disposition, CommandDisposition::Accepted as i32);
        assert_eq!(outcome.store_position, 3);

        let replay = ReplayRequest {
            selector_id: format!("thread:{stream_id}"),
            cursor: None,
            page_size: 20,
        };
        let response = v1::ReplayResponse::decode(
            hex::decode(replay_wire(path, &replay.encode_to_vec()).unwrap())
                .unwrap()
                .as_slice(),
        )
        .unwrap();
        assert_eq!(response.high_water_mark, 3);
        assert_eq!(response.events.last().unwrap().kind, "review.accepted");
    }

    #[test]
    fn write_approval_rejects_scope_or_fingerprint_tampering() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("denied.sqlite");
        let request = ApprovalRequest {
            approval_id: "approval-denied".into(),
            action_kind: "codex.workspace_write".into(),
            scope: Some(Scope {
                project_id: "kaname".into(),
                workspace_id: "/tmp/worktree".into(),
                authority_id: "local-user".into(),
                egress_class: "provider_and_workspace".into(),
                destination_digest: "model".into(),
                ..Default::default()
            }),
            target_id: "/tmp/worktree".into(),
            target_revision: "revision".into(),
            effect_digest: vec![1; 32],
            consequence: "reversible".into(),
            reversible: true,
            expires_at_unix_millis: 2_000,
            policy_reference: "policy".into(),
            fingerprint: vec![0; 32],
            approval_payload_version: 1,
        };
        let command = ApprovalCommand {
            stream_id: "thread:project:kaname:thread-denied".into(),
            request: Some(request.clone()),
            resolution: Some(ApprovalResolution {
                approval_id: request.approval_id,
                decision: ApprovalDecision::Approve as i32,
                expected_fingerprint: request.fingerprint,
                actor_id: "justin".into(),
                device_id: "local-mac".into(),
                standing_rule_reference: String::new(),
            }),
            resolved_at_unix_millis: 1_000,
            current_target_revision: "revision".into(),
        };
        assert_eq!(
            authorize_action_wire(path.to_str().unwrap(), &command.encode_to_vec()),
            Err("approval_fingerprint_mismatch".into())
        );
    }
}
