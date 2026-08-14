use kaname_core::{
    fake_provider::{embedded_scenarios, run_scenario, run_scenario_at_path, scale_fixture},
    journal::{Journal, ReplayBasis as JournalReplayBasis},
    mobile::{EnrollmentAdmission, SyncAdmission},
    policy::{ApprovalResolutionResult, LocalPolicyCore, approval_fingerprint},
    v1::{self, EventEnvelope},
    workflow_canonical, workflow_compiler,
    workflow_schema::{self, WorkflowSchemaCheckRequest},
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
        _ => Err("usage: kaname-local-core scenario <F-01..F-14> | scenario-store <F-01..F-14> <journal-path> | append-event <journal-path> < event-envelope.bin | authorize-action <journal-path> < approval-command.bin | record-review <journal-path> < command-envelope.bin | replay <journal-path> < replay-request.bin | mobile-propose <journal-path> < enrollment-challenge.bin | mobile-decide <journal-path> < enrollment-decision.bin | mobile-admit <journal-path> <recipient-device-id> <recipient-key-id> < encrypted-envelope.bin | scale <S-01..S-04> | workflow-schema-check < request.json | workflow-canonicalize < value.json | workflow-compile < compile-request.bin".to_owned()),
    };
    match result {
        Ok(json) => println!("{json}"),
        Err(error) => {
            eprintln!("kaname-local-core: {error}");
            std::process::exit(64);
        }
    }
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
        EvidenceRetentionClass, OpaqueTypedPayload, ReplayRequest, ReviewDecision, SchemaVersion,
        Scope, SyncAuthenticatedHeader, SyncReceipt, SyncReceiptState,
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
