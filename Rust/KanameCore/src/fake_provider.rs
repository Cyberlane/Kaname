//! Deterministic, in-process provider simulator for the Phase 1 corpus.
//!
//! `FakeProvider` has no process, filesystem, network, clock, random source,
//! credential, or integration capability. A test advances exactly one literal
//! native observation at a time; all observable effects are counted locally.

use crate::{
    MAXIMUM_ENVELOPE_BYTES, SCHEMA_MAJOR,
    journal::{Journal, JournalError, ReplayBasis, Result},
    policy::{ApprovalResolutionResult, LocalPolicyCore, QueueMutationResult},
    v1,
};
use prost::Message;
use serde::{Deserialize, Serialize};
use std::path::Path;

const CURSOR_KEY: [u8; 32] = [0x42; 32];
const STREAM_ID: &str = "thread:fake-provider";
const SELECTOR_ID: &str = "thread:thread:fake-provider";

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ScenarioMetadata {
    #[serde(rename = "fixtureID")]
    pub fixture_id: String,
    #[serde(rename = "corpusVersion")]
    pub corpus_version: u32,
    #[serde(rename = "fixedClockUnixMillis")]
    pub fixed_clock_unix_millis: i64,
    #[serde(rename = "expectedEffectCount")]
    pub expected_effect_count: u64,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderHealth {
    Ready,
    Degraded,
    ReconciliationRequired,
}

impl ProviderHealth {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Degraded => "degraded",
            Self::ReconciliationRequired => "reconciliation_required",
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ScenarioReport {
    pub fixture_id: String,
    pub task_state: String,
    pub attention: String,
    pub health: ProviderHealth,
    pub effect_count: u64,
    pub event_count: usize,
    pub unsupported_event_count: u64,
}

#[derive(Debug, Clone)]
pub struct FakeNativeObservation {
    pub id: &'static str,
    pub raw_type: &'static str,
    pub native_cursor: &'static [u8],
    pub raw_payload: &'static [u8],
    pub normalized_kind: Option<&'static str>,
    pub retain_evidence: bool,
}

pub struct FakeProvider {
    fixed_clock_unix_millis: i64,
    observations: Vec<FakeNativeObservation>,
    next_observation: usize,
    effect_count: u64,
    health: ProviderHealth,
}

impl FakeProvider {
    pub fn new(fixed_clock_unix_millis: i64, observations: Vec<FakeNativeObservation>) -> Self {
        Self {
            fixed_clock_unix_millis,
            observations,
            next_observation: 0,
            effect_count: 0,
            health: ProviderHealth::Ready,
        }
    }

    pub fn dispatch(&mut self, journal: &mut Journal) -> Result<()> {
        journal.append_event(event(
            "fake-dispatch",
            "run.starting",
            self.fixed_clock_unix_millis,
            None,
        ))?;
        self.effect_count += 1;
        Ok(())
    }

    pub fn advance(&mut self, journal: &mut Journal) -> Result<Option<FakeNativeObservation>> {
        let Some(observation) = self.observations.get(self.next_observation).cloned() else {
            return Ok(None);
        };
        self.next_observation += 1;
        let offset = self.next_observation as i64;
        let provenance = v1::EventProvenance {
            source_kind: "fake_provider".into(),
            provider_instance_id: "fake-local".into(),
            native_type: observation.raw_type.into(),
            native_cursor: observation.native_cursor.to_vec(),
            raw_evidence_digest: observation
                .retain_evidence
                .then(|| format!("sha256:fake:{}", observation.id))
                .unwrap_or_default(),
            retention_class: if observation.retain_evidence {
                v1::EvidenceRetentionClass::SevenDays as i32
            } else {
                v1::EvidenceRetentionClass::None as i32
            },
        };
        journal.append_event(event(
            observation.id,
            "provider.native_event_observed",
            self.fixed_clock_unix_millis + offset,
            Some((provenance, observation.raw_payload)),
        ))?;
        if let Some(kind) = observation.normalized_kind {
            journal.append_event(event(
                &format!("{}-normalized", observation.id),
                kind,
                self.fixed_clock_unix_millis + offset + 100,
                None,
            ))?;
        }
        Ok(Some(observation))
    }

    pub fn outage(&mut self) {
        self.health = ProviderHealth::Degraded;
    }

    pub fn reconciliation_required(&mut self) {
        self.health = ProviderHealth::ReconciliationRequired;
    }

    pub fn effect_count(&self) -> u64 {
        self.effect_count
    }

    pub fn health(&self) -> ProviderHealth {
        self.health
    }
}

pub fn embedded_scenarios() -> Result<Vec<ScenarioMetadata>> {
    const FIXTURES: [&str; 14] = [
        include_str!("../../../Fixtures/scenarios/F-01-happy-coding-run.json"),
        include_str!("../../../Fixtures/scenarios/F-02-idempotent-enqueue.json"),
        include_str!("../../../Fixtures/scenarios/F-03-crash-before-admission.json"),
        include_str!("../../../Fixtures/scenarios/F-04-crash-after-dispatch.json"),
        include_str!("../../../Fixtures/scenarios/F-05-unknown-observation.json"),
        include_str!("../../../Fixtures/scenarios/F-06-reconnect-duplicate.json"),
        include_str!("../../../Fixtures/scenarios/F-07-retention-snapshot.json"),
        include_str!("../../../Fixtures/scenarios/F-08-stale-approval.json"),
        include_str!("../../../Fixtures/scenarios/F-09-queue-conflict.json"),
        include_str!("../../../Fixtures/scenarios/F-10-interrupt-race.json"),
        include_str!("../../../Fixtures/scenarios/F-11-notification-ambiguity.json"),
        include_str!("../../../Fixtures/scenarios/F-12-scope-denial.json"),
        include_str!("../../../Fixtures/scenarios/F-13-provider-outage.json"),
        include_str!("../../../Fixtures/scenarios/F-14-malformed-envelope.json"),
    ];
    FIXTURES
        .into_iter()
        .map(|fixture| {
            serde_json::from_str(fixture)
                .map_err(|_| JournalError::Protocol("invalid_corpus_fixture"))
        })
        .collect()
}

pub fn run_scenario(metadata: &ScenarioMetadata) -> Result<ScenarioReport> {
    Ok(run_scenario_in_journal(metadata, journal()?)?.0)
}

/// Runs the deterministic scenario using a caller-owned journal. The native
/// XPC service uses this path so service restart exercises the same SQLite
/// authority and corpus as the core tests, rather than a separate UI fixture.
pub fn run_scenario_at_path(
    metadata: &ScenarioMetadata,
    path: impl AsRef<Path>,
) -> Result<ScenarioReport> {
    Ok(run_scenario_in_journal(metadata, Journal::open(path, &CURSOR_KEY)?)?.0)
}

fn run_scenario_in_journal(
    metadata: &ScenarioMetadata,
    journal: Journal,
) -> Result<(ScenarioReport, Journal)> {
    let (report, journal) = match metadata.fixture_id.as_str() {
        "F-01" => run_f01(metadata, journal)?,
        "F-02" => run_f02(metadata, journal)?,
        "F-03" => run_f03(metadata, journal)?,
        "F-04" => run_f04(metadata, journal)?,
        "F-05" => run_f05(metadata, journal)?,
        "F-06" => run_f06(metadata, journal)?,
        "F-07" => run_f07(metadata, journal)?,
        "F-08" => run_f08(metadata, journal)?,
        "F-09" => run_f09(metadata, journal)?,
        "F-10" => run_f10(metadata, journal)?,
        "F-11" => run_f11(metadata, journal)?,
        "F-12" => run_f12(metadata, journal)?,
        "F-13" => run_f13(metadata, journal)?,
        "F-14" => run_f14(metadata, journal)?,
        _ => return Err(JournalError::Protocol("unknown_corpus_fixture")),
    };
    if report.effect_count != metadata.expected_effect_count {
        return Err(JournalError::Integrity(
            "fixture_effect_count_mismatch".into(),
        ));
    }
    Ok((report, journal))
}

/// S-01 through S-04 are generated deterministically from literal IDs and a
/// fixed event distribution. They intentionally do not read a wall clock or
/// random source.
pub fn scale_fixture(name: &str) -> Result<Vec<v1::EventEnvelope>> {
    let (count, unknown_only, many_streams) = match name {
        "S-01" => (500, false, false),
        "S-02" => (10_000, false, false),
        "S-03" => (100_000, false, true),
        "S-04" => (1_000, true, false),
        _ => return Err(JournalError::Protocol("unknown_scale_fixture")),
    };
    let mut events = Vec::with_capacity(count);
    for index in 0..count {
        let stream_id = if many_streams {
            format!("thread:project:scale-project:{:03}", index % 100)
        } else {
            "thread:scale-single".into()
        };
        let kind = if unknown_only || index % 7 == 0 {
            "provider.native_event_observed"
        } else if index % 11 == 0 {
            "run.provider_completed"
        } else {
            "run.started"
        };
        events.push(v1::EventEnvelope {
            schema_version: Some(v1::SchemaVersion {
                major: SCHEMA_MAJOR,
                minor: 0,
            }),
            event_id: format!("{name}-event-{index:06}"),
            store_position: 0,
            stream_id,
            stream_sequence: 0,
            occurred_at_unix_millis: 1_762_100_000_000 + index as i64,
            kind: kind.into(),
            payload: Some(v1::OpaqueTypedPayload {
                type_url: if unknown_only {
                    "fake.v1.unknown.extension".into()
                } else {
                    "fake.v1.synthetic".into()
                },
                content_type: "application/x-protobuf".into(),
                value: vec![0x08, (index % 127) as u8],
                payload_version: 1,
            }),
            provenance: Some(v1::EventProvenance {
                source_kind: "fake_provider".into(),
                provider_instance_id: "fake-local".into(),
                native_type: if unknown_only {
                    "fake.v1.unknown.extension".into()
                } else {
                    String::new()
                },
                native_cursor: format!("scale-{index}").into_bytes(),
                raw_evidence_digest: unknown_only
                    .then(|| format!("sha256:scale-{index}"))
                    .unwrap_or_default(),
                retention_class: if unknown_only {
                    v1::EvidenceRetentionClass::SevenDays as i32
                } else {
                    v1::EvidenceRetentionClass::None as i32
                },
            }),
            causation_id: String::new(),
            correlation_id: "scale-task".into(),
        });
    }
    Ok(events)
}

fn run_f01(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    journal.append_event(event(
        "f01-queue",
        "task.queued",
        metadata.fixed_clock_unix_millis,
        None,
    ))?;
    let mut provider = FakeProvider::new(metadata.fixed_clock_unix_millis, happy_observations());
    provider.dispatch(&mut journal)?;
    while provider.advance(&mut journal)?.is_some() {}
    journal.append_event(event(
        "f01-accepted",
        "review.accepted",
        metadata.fixed_clock_unix_millis + 99,
        None,
    ))?;
    let report = report(
        metadata,
        &journal,
        provider.health(),
        provider.effect_count(),
    )?;
    Ok((report, journal))
}

fn run_f02(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    let command = command("f02-command", "f02-key");
    core.enqueue(&command, "f02-queue", STREAM_ID, "synthetic queue")?;
    core.enqueue(&command, "f02-queue", STREAM_ID, "synthetic queue")?;
    let mut provider = FakeProvider::new(metadata.fixed_clock_unix_millis, Vec::new());
    provider.dispatch(core.journal_mut())?;
    let report = report(
        metadata,
        core.journal(),
        provider.health(),
        provider.effect_count(),
    )?;
    Ok((report, core.into_journal()))
}

fn run_f03(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let pending = event(
        "f03-queue",
        "task.queued",
        metadata.fixed_clock_unix_millis,
        None,
    );
    assert!(matches!(
        journal.inject_crash_before_event_commit_for_test(pending.clone()),
        Err(JournalError::Protocol("injected_crash_before_event_commit"))
    ));
    journal.append_event(pending)?;
    let report = report(metadata, &journal, ProviderHealth::Ready, 0)?;
    Ok((report, journal))
}

fn run_f04(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    journal.append_event(event(
        "f04-queue",
        "task.queued",
        metadata.fixed_clock_unix_millis,
        None,
    ))?;
    let mut provider = FakeProvider::new(metadata.fixed_clock_unix_millis, Vec::new());
    provider.dispatch(&mut journal)?;
    journal.append_event(event(
        "f04-reconcile",
        "run.reconciliation_required",
        metadata.fixed_clock_unix_millis + 2,
        None,
    ))?;
    provider.reconciliation_required();
    let report = report(
        metadata,
        &journal,
        provider.health(),
        provider.effect_count(),
    )?;
    Ok((report, journal))
}

fn run_f05(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut provider = FakeProvider::new(
        metadata.fixed_clock_unix_millis,
        vec![unknown_observation("f05-unknown")],
    );
    provider.advance(&mut journal)?;
    let report = report(
        metadata,
        &journal,
        provider.health(),
        provider.effect_count(),
    )?;
    Ok((report, journal))
}

fn run_f06(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let first = journal.append_event(event(
        "f06-queue",
        "task.queued",
        metadata.fixed_clock_unix_millis,
        None,
    ))?;
    journal.append_event(event(
        "f06-start",
        "run.started",
        metadata.fixed_clock_unix_millis + 1,
        None,
    ))?;
    journal.append_event(event(
        "f06-interrupt",
        "run.interrupted",
        metadata.fixed_clock_unix_millis + 2,
        None,
    ))?;
    let page = journal.replay(SELECTOR_ID, None, 2)?;
    let resumed = journal.replay(SELECTOR_ID, Some(&page.next_cursor), 2)?;
    if page.events.len() + resumed.events.len() != 3
        || !journal
            .append_received_wire(&first.event.encode_to_vec())?
            .duplicate
    {
        return Err(JournalError::Integrity("reconnect_dedup_failed".into()));
    }
    let report = report(metadata, &journal, ProviderHealth::Ready, 0)?;
    Ok((report, journal))
}

fn run_f07(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    journal.append_event(event(
        "f07-queue",
        "task.queued",
        metadata.fixed_clock_unix_millis,
        None,
    ))?;
    journal.append_event(event(
        "f07-start",
        "run.started",
        metadata.fixed_clock_unix_millis + 1,
        None,
    ))?;
    let snapshot = journal.create_snapshot(SELECTOR_ID)?;
    journal.set_retention_horizon(SELECTOR_ID, snapshot.high_water_mark)?;
    let valid = journal.replay(SELECTOR_ID, None, 20)?;
    if valid.basis != ReplayBasis::ResyncRequired || valid.snapshot.is_none() {
        return Err(JournalError::Integrity("snapshot_resync_failed".into()));
    }
    journal.corrupt_snapshot_for_test(&snapshot.id)?;
    let corrupt = journal.replay(SELECTOR_ID, None, 20)?;
    if corrupt.snapshot.is_some() {
        return Err(JournalError::Integrity("corrupt_snapshot_used".into()));
    }
    let report = report(metadata, &journal, ProviderHealth::Ready, 0)?;
    Ok((report, journal))
}

fn run_f08(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    let request = approval(
        "f08-approval",
        "target-revision-1",
        metadata.fixed_clock_unix_millis + 10_000,
    );
    let state = core.request_approval(request.clone(), STREAM_ID)?;
    let result = core.resolve_approval(
        &v1::ApprovalResolution {
            approval_id: request.approval_id,
            decision: v1::ApprovalDecision::Approve as i32,
            expected_fingerprint: state.fingerprint,
            actor_id: "fixture".into(),
            device_id: "fixture-mac".into(),
            standing_rule_reference: String::new(),
        },
        metadata.fixed_clock_unix_millis + 1,
        "target-revision-2",
        STREAM_ID,
    )?;
    if result != ApprovalResolutionResult::Stale
        || core.effect_ledger().external_action_attempts != 0
    {
        return Err(JournalError::Integrity("stale_approval_effect".into()));
    }
    let report = report(metadata, core.journal(), ProviderHealth::Ready, 0)?;
    Ok((report, core.into_journal()))
}

fn run_f09(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    core.enqueue(
        &command("f09-command", "f09-key"),
        "f09-queue",
        STREAM_ID,
        "initial",
    )?;
    core.edit_queue("f09-queue", 1, "mac current", "mac")?;
    if !matches!(
        core.edit_queue("f09-queue", 1, "phone stale", "phone")?,
        QueueMutationResult::Conflict(_)
    ) {
        return Err(JournalError::Integrity("queue_conflict_missing".into()));
    }
    let report = report(metadata, core.journal(), ProviderHealth::Ready, 0)?;
    Ok((report, core.into_journal()))
}

fn run_f10(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut provider = FakeProvider::new(
        metadata.fixed_clock_unix_millis,
        vec![FakeNativeObservation {
            id: "f10-completed",
            raw_type: "fake.v1.run.completed",
            native_cursor: b"f10",
            raw_payload: b"complete",
            normalized_kind: Some("run.provider_completed"),
            retain_evidence: false,
        }],
    );
    provider.dispatch(&mut journal)?;
    journal.append_event(event(
        "f10-interrupt",
        "run.interrupted",
        metadata.fixed_clock_unix_millis + 1,
        None,
    ))?;
    provider.advance(&mut journal)?;
    provider.reconciliation_required();
    let report = report(
        metadata,
        &journal,
        provider.health(),
        provider.effect_count(),
    )?;
    Ok((report, journal))
}

fn run_f11(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    core.record_notification_receipt("f11-attention", "delivery-1", STREAM_ID)?;
    core.record_notification_receipt("f11-attention", "delivery-1", STREAM_ID)?;
    if core.effect_ledger().notification_receipts != 1 {
        return Err(JournalError::Integrity("notification_dedup_failed".into()));
    }
    let report = report(metadata, core.journal(), ProviderHealth::Ready, 0)?;
    Ok((report, core.into_journal()))
}

fn run_f12(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    let scope = v1::Scope {
        project_id: "fixture-project".into(),
        workspace_id: "fixture-workspace".into(),
        account_id: "excluded".into(),
        authority_id: "fixture-mac".into(),
        egress_class: "external_communication".into(),
        destination_digest: "synthetic".into(),
    };
    assert!(matches!(
        core.authorize_fake_provider(&scope, STREAM_ID),
        Err(JournalError::Protocol("scope_or_egress_denied"))
    ));
    let report = report(metadata, core.journal(), ProviderHealth::Ready, 0)?;
    Ok((report, core.into_journal()))
}

fn run_f13(metadata: &ScenarioMetadata, journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut core = LocalPolicyCore::new(journal);
    core.enqueue(
        &command("f13-command", "f13-key"),
        "f13-queue",
        STREAM_ID,
        "offline queue",
    )?;
    core.edit_queue("f13-queue", 1, "still editable", "fixture")?;
    let mut provider = FakeProvider::new(metadata.fixed_clock_unix_millis, Vec::new());
    provider.outage();
    let report = report(metadata, core.journal(), provider.health(), 0)?;
    Ok((report, core.into_journal()))
}

fn run_f14(metadata: &ScenarioMetadata, mut journal: Journal) -> Result<(ScenarioReport, Journal)> {
    let mut malformed = command("f14-command", "f14-key");
    malformed.payload.as_mut().unwrap().value = vec![0_u8; MAXIMUM_ENVELOPE_BYTES];
    assert!(matches!(
        journal.admit_command(&malformed),
        Err(JournalError::Protocol("envelope_too_large"))
    ));
    assert!(matches!(
        journal.append_received_wire(&[0x80]),
        Err(JournalError::Protocol("malformed_event_envelope"))
    ));
    let report = report(metadata, &journal, ProviderHealth::Ready, 0)?;
    Ok((report, journal))
}

fn report(
    metadata: &ScenarioMetadata,
    journal: &Journal,
    health: ProviderHealth,
    effect_count: u64,
) -> Result<ScenarioReport> {
    let projection = journal.rebuild_thread_projection(SELECTOR_ID)?;
    let event_count = journal.replay(SELECTOR_ID, None, 500)?.events.len();
    Ok(ScenarioReport {
        fixture_id: metadata.fixture_id.clone(),
        task_state: projection.task_state,
        attention: projection.attention,
        health,
        effect_count,
        event_count,
        unsupported_event_count: projection.unsupported_event_count,
    })
}

fn journal() -> Result<Journal> {
    Journal::open_in_memory(&CURSOR_KEY)
}

fn event(
    id: &str,
    kind: &str,
    occurred_at: i64,
    provenance_payload: Option<(v1::EventProvenance, &[u8])>,
) -> v1::EventEnvelope {
    let (provenance, payload) = match provenance_payload {
        Some((provenance, bytes)) => (provenance, bytes.to_vec()),
        None => (
            v1::EventProvenance {
                source_kind: "synthetic".into(),
                provider_instance_id: String::new(),
                native_type: String::new(),
                native_cursor: Vec::new(),
                raw_evidence_digest: String::new(),
                retention_class: v1::EvidenceRetentionClass::None as i32,
            },
            Vec::new(),
        ),
    };
    v1::EventEnvelope {
        schema_version: Some(v1::SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
        event_id: id.into(),
        store_position: 0,
        stream_id: STREAM_ID.into(),
        stream_sequence: 0,
        occurred_at_unix_millis: occurred_at,
        kind: kind.into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: "kaname.fake.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: payload,
            payload_version: 1,
        }),
        provenance: Some(provenance),
        causation_id: id.into(),
        correlation_id: "fake-task".into(),
    }
}

fn command(id: &str, key: &str) -> v1::CommandEnvelope {
    v1::CommandEnvelope {
        schema_version: Some(v1::SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
        command_id: id.into(),
        idempotency_key: key.into(),
        kind: "intent.enqueue".into(),
        payload: Some(v1::OpaqueTypedPayload {
            type_url: "kaname.fake.enqueue.v1".into(),
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

fn approval(id: &str, target_revision: &str, expires_at: i64) -> v1::ApprovalRequest {
    v1::ApprovalRequest {
        approval_id: id.into(),
        action_kind: "fake.provider.dispatch".into(),
        scope: Some(v1::Scope {
            project_id: "fixture-project".into(),
            workspace_id: "fixture-workspace".into(),
            account_id: String::new(),
            authority_id: "fixture-mac".into(),
            egress_class: "none".into(),
            destination_digest: String::new(),
        }),
        target_id: "fixture-target".into(),
        target_revision: target_revision.into(),
        effect_digest: b"fixture-effect".to_vec(),
        consequence: "synthetic only".into(),
        reversible: true,
        expires_at_unix_millis: expires_at,
        policy_reference: "fixture-policy".into(),
        fingerprint: Vec::new(),
        approval_payload_version: 1,
    }
}

fn happy_observations() -> Vec<FakeNativeObservation> {
    vec![
        FakeNativeObservation {
            id: "f01-message",
            raw_type: "fake.v1.message.delta",
            native_cursor: b"f01-1",
            raw_payload: b"message",
            normalized_kind: None,
            retain_evidence: false,
        },
        FakeNativeObservation {
            id: "f01-plan",
            raw_type: "fake.v1.plan.proposed",
            native_cursor: b"f01-2",
            raw_payload: b"plan",
            normalized_kind: None,
            retain_evidence: false,
        },
        FakeNativeObservation {
            id: "f01-tool",
            raw_type: "fake.v1.tool.requested",
            native_cursor: b"f01-3",
            raw_payload: b"tool",
            normalized_kind: None,
            retain_evidence: false,
        },
        FakeNativeObservation {
            id: "f01-artifact",
            raw_type: "fake.v1.artifact.ready",
            native_cursor: b"f01-4",
            raw_payload: b"artifact",
            normalized_kind: None,
            retain_evidence: false,
        },
        FakeNativeObservation {
            id: "f01-completed",
            raw_type: "fake.v1.run.completed",
            native_cursor: b"f01-5",
            raw_payload: b"completed",
            normalized_kind: Some("run.provider_completed"),
            retain_evidence: false,
        },
    ]
}

fn unknown_observation(id: &'static str) -> FakeNativeObservation {
    FakeNativeObservation {
        id,
        raw_type: "fake.v1.unknown.extension",
        native_cursor: b"unknown-cursor",
        raw_payload: &[0x08, 0x96, 0x01],
        normalized_kind: None,
        retain_evidence: true,
    }
}
