//! Process-backed effect host for `effect.connector` nodes.
//!
//! The executor keeps proposal, authorization, dispatch, and reconciliation
//! facts durable; this host only owns three things: which connectors exist,
//! how one authorized dispatch reaches the external command, and how an
//! unknown outcome is observed again. Authorization is never invented here.
//! `authorize` reads the run projection and returns the exact resolution the
//! owner recorded through `workflow-effect-authorize`, or nothing.
//!
//! The external command is named by `KANAME_WORKFLOW_EFFECT_COMMAND` and speaks
//! the same bounded JSON-on-stdio contract as the LLM and capability hosts:
//!
//! - `command describe` answers `{"connectors": [ … ]}`.
//! - `command dispatch` receives the authorized effect with its inline input and
//!   answers `{"outcome": "succeeded" | "rejected" | "not_sent" | "outcome_unknown", …}`.
//! - `command reconcile` receives the same effect plus the prior receipt and
//!   answers `{"outcome": "applied" | "not_applied" | "still_unknown", …}`.

use crate::{
    journal::Journal,
    v1,
    workflow_effect_connector::{
        WorkflowEffectConnector, WorkflowEffectConnectorDispatchResult,
        WorkflowEffectConnectorReconciliationResult, WorkflowEffectConnectorRequest,
        WorkflowEffectHost,
    },
    workflow_host_process::{
        ProcessHostCommand, ProcessHostFailure, encode_request, parse_response,
    },
    workflow_projection::WorkflowRunProjection,
    workflow_runtime::workflow_effect_connector_registration_digest,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::PathBuf, time::Duration};

pub const WORKFLOW_EFFECT_COMMAND_VARIABLE: &str = "KANAME_WORKFLOW_EFFECT_COMMAND";

const DESCRIBE_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_DISPATCH_TIMEOUT: Duration = Duration::from_secs(60);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expired_dispatch_never_starts_the_process_and_remains_uncertain() {
        let directory = tempfile::tempdir().unwrap();
        let mut host = ProcessWorkflowEffectHost {
            // Starting this missing program would produce connector.host_failed,
            // so the result also proves expiry is checked before invocation.
            command: Some(ProcessHostCommand::new(directory.path().join("not-a-host"))),
            registrations: BTreeMap::new(),
            dispatch_results: BTreeMap::new(),
            journal_path: directory.path().join("journal"),
            projection_path: directory.path().join("projection"),
            cursor_key: [0; 32],
            unavailable_reason: None,
        };
        let mut request = WorkflowEffectConnectorRequest {
            proposal: v1::WorkflowEffectProposed {
                intent: Some(v1::WorkflowEffectIntent::default()),
                ..Default::default()
            },
            authorization: v1::WorkflowEffectAuthorized {
                expires_at_unix_millis: i64::MAX,
                ..Default::default()
            },
            dispatch: v1::WorkflowEffectDispatchStarted {
                idempotency_key: "expired-effect".into(),
                deadline_unix_millis: 1,
                ..Default::default()
            },
            prior_receipt: None,
            input: None,
        };
        for authority_expired in [false, true] {
            if authority_expired {
                request.authorization.expires_at_unix_millis = 1;
                request.dispatch.deadline_unix_millis = i64::MAX;
            }
            assert!(
                matches!(host.dispatch(&request), WorkflowEffectConnectorDispatchResult::OutcomeUnknown { error_code, .. } if error_code == "connector.dispatch_expired")
            );
        }
    }

    #[test]
    fn child_failure_after_launch_does_not_claim_the_effect_was_unsent() {
        assert!(matches!(
            failure_dispatch_result(
                ProcessHostFailure::Crashed("exit 1 after write".into()),
                "effect"
            ),
            WorkflowEffectConnectorDispatchResult::OutcomeUnknown { .. }
        ));
    }
}

pub struct ProcessWorkflowEffectHost {
    command: Option<ProcessHostCommand>,
    registrations: BTreeMap<(String, String), v1::WorkflowEffectConnectorRegistration>,
    dispatch_results: BTreeMap<String, WorkflowEffectConnectorDispatchResult>,
    journal_path: PathBuf,
    projection_path: PathBuf,
    cursor_key: [u8; 32],
    unavailable_reason: Option<String>,
}

impl ProcessWorkflowEffectHost {
    /// Describes the command named by `KANAME_WORKFLOW_EFFECT_COMMAND`, or stays
    /// unavailable. Authorization lookups read `journal_path` and
    /// `projection_path`, which must be the run journal and projection the
    /// executor is using.
    pub fn from_environment(
        journal_path: impl Into<PathBuf>,
        projection_path: impl Into<PathBuf>,
        cursor_key: [u8; 32],
    ) -> Self {
        let journal_path = journal_path.into();
        let projection_path = projection_path.into();
        match ProcessHostCommand::from_environment(WORKFLOW_EFFECT_COMMAND_VARIABLE) {
            Some(command) => Self::describe(command, journal_path, projection_path, cursor_key),
            None => Self {
                command: None,
                registrations: BTreeMap::new(),
                dispatch_results: BTreeMap::new(),
                journal_path,
                projection_path,
                cursor_key,
                unavailable_reason: Some(format!("{WORKFLOW_EFFECT_COMMAND_VARIABLE} is not set")),
            },
        }
    }

    fn describe(
        command: ProcessHostCommand,
        journal_path: PathBuf,
        projection_path: PathBuf,
        cursor_key: [u8; 32],
    ) -> Self {
        let unavailable = |reason: String| Self {
            command: None,
            registrations: BTreeMap::new(),
            dispatch_results: BTreeMap::new(),
            journal_path: journal_path.clone(),
            projection_path: projection_path.clone(),
            cursor_key,
            unavailable_reason: Some(reason),
        };
        let response = match command.run("describe", b"", DESCRIBE_TIMEOUT) {
            Ok(response) => response,
            Err(failure) => return unavailable(failure.summary()),
        };
        let described: WireDescription = match parse_response(&response) {
            Ok(described) => described,
            Err(failure) => return unavailable(failure.summary()),
        };
        let mut registrations = BTreeMap::new();
        for connector in described.connectors {
            let mut registration = v1::WorkflowEffectConnectorRegistration {
                connector_class: connector.connector_class,
                version: connector.version,
                package_digest: connector.package_digest,
                binding_id: connector.binding_id,
                account_binding_id: connector.account_binding_id,
                allowed_actions: connector.allowed_actions,
                idempotent: connector.idempotent,
                supports_reconciliation: connector.supports_reconciliation,
                registration_digest: String::new(),
            };
            registration.allowed_actions.sort();
            registration.allowed_actions.dedup();
            registration.registration_digest =
                workflow_effect_connector_registration_digest(&registration);
            registrations.insert(
                (
                    registration.connector_class.clone(),
                    registration.account_binding_id.clone(),
                ),
                registration,
            );
        }
        if registrations.is_empty() {
            return unavailable("the host described no connector".into());
        }
        Self {
            command: Some(command),
            registrations,
            dispatch_results: BTreeMap::new(),
            journal_path,
            projection_path,
            cursor_key,
            unavailable_reason: None,
        }
    }

    pub fn is_available(&self) -> bool {
        self.command.is_some() && !self.registrations.is_empty()
    }

    pub fn unavailable_reason(&self) -> Option<&str> {
        self.unavailable_reason.as_deref()
    }

    pub fn registered_connectors(&self) -> Vec<(String, String)> {
        self.registrations.keys().cloned().collect()
    }

    fn projected_authority(
        &self,
        proposal: &v1::WorkflowEffectProposed,
    ) -> Option<v1::WorkflowProjectedEffectAuthority> {
        let intent = proposal.intent.as_ref()?;
        let journal = Journal::open_read_only(&self.journal_path, &self.cursor_key).ok()?;
        let (mut projection, _) =
            WorkflowRunProjection::open_or_rebuild(&self.projection_path, &journal).ok()?;
        projection.catch_up(&journal).ok()?;
        projection.effect_authority(&intent.effect_id).ok()?
    }

    fn wire_request<'a>(
        &self,
        request: &'a WorkflowEffectConnectorRequest,
    ) -> Option<WireEffectRequest<'a>> {
        let intent = request.proposal.intent.as_ref()?;
        Some(WireEffectRequest {
            effect_id: &intent.effect_id,
            run_id: &intent.run_id,
            node_id: &intent.node_id,
            workflow_id: &intent.workflow_id,
            revision_id: &intent.revision_id,
            connector_class: &intent.connector_class,
            action: &intent.action,
            account_binding_id: &intent.account_binding_id,
            destination_fingerprint: &intent.destination_fingerprint,
            input_digest: &intent.input_digest,
            idempotency_key: &intent.idempotency_key,
            dispatch_id: &request.dispatch.dispatch_id,
            grant_id: &request.dispatch.grant_id,
            deadline_unix_millis: request.dispatch.deadline_unix_millis,
            input: request
                .input
                .as_ref()
                .and_then(|value| serde_json::from_slice(&value.inline_canonical_json).ok()),
            prior_receipt: request
                .prior_receipt
                .as_ref()
                .map(|receipt| WireReceiptOut {
                    receipt_id: &receipt.receipt_id,
                    provider_reference: &receipt.provider_reference,
                    outcome: match v1::WorkflowEffectReceiptOutcome::try_from(receipt.outcome) {
                        Ok(v1::WorkflowEffectReceiptOutcome::Applied) => "applied",
                        Ok(v1::WorkflowEffectReceiptOutcome::NotApplied) => "not_applied",
                        _ => "unknown",
                    },
                    evidence_digest: &receipt.evidence_digest,
                }),
        })
    }

    fn dispatch_timeout(request: &WorkflowEffectConnectorRequest) -> Option<Duration> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or_default();
        request
            .remaining_dispatch_milliseconds(now)
            .map(|remaining| Duration::from_millis(remaining).min(Duration::from_secs(600)))
    }
}

impl WorkflowEffectConnector for ProcessWorkflowEffectHost {
    fn registration(
        &self,
        connector_class: &str,
        account_binding_id: &str,
    ) -> Option<v1::WorkflowEffectConnectorRegistration> {
        self.registrations
            .get(&(connector_class.to_owned(), account_binding_id.to_owned()))
            .cloned()
    }

    fn dispatch(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorDispatchResult {
        let key = request.dispatch.idempotency_key.clone();
        if let Some(result) = self.dispatch_results.get(&key) {
            return result.clone();
        }
        let Some(timeout) = Self::dispatch_timeout(request) else {
            return request.expired_dispatch_result();
        };
        let result = match (&self.command, self.wire_request(request)) {
            (Some(command), Some(wire)) => {
                match encode_request(&wire)
                    .and_then(|bytes| command.run("dispatch", &bytes, timeout))
                    .and_then(|response| parse_response::<WireEffectResponse>(&response))
                {
                    Ok(response) => response.into_dispatch_result(&key),
                    Err(failure) => failure_dispatch_result(failure, &key),
                }
            }
            _ => WorkflowEffectConnectorDispatchResult::NotSent {
                error_code: "connector.unavailable".into(),
                receipt: process_receipt(
                    &key,
                    "dispatch-unavailable",
                    v1::WorkflowEffectReceiptOutcome::NotApplied,
                    "",
                ),
                elapsed_milliseconds: 0,
            },
        };
        self.dispatch_results.insert(key, result.clone());
        result
    }

    fn reconcile(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorReconciliationResult {
        let key = request.dispatch.idempotency_key.clone();
        match (&self.command, self.wire_request(request)) {
            (Some(command), Some(wire)) => {
                match encode_request(&wire)
                    .and_then(|bytes| command.run("reconcile", &bytes, DEFAULT_DISPATCH_TIMEOUT))
                    .and_then(|response| parse_response::<WireEffectResponse>(&response))
                {
                    Ok(response) => response.into_reconciliation_result(&key),
                    Err(failure) => WorkflowEffectConnectorReconciliationResult::StillUnknown {
                        error_code: "connector.reconcile_failed".into(),
                        receipt: process_receipt(
                            &key,
                            "reconcile-failed",
                            v1::WorkflowEffectReceiptOutcome::Unknown,
                            &failure.summary(),
                        ),
                        elapsed_milliseconds: 0,
                    },
                }
            }
            _ => WorkflowEffectConnectorReconciliationResult::StillUnknown {
                error_code: "connector.unavailable".into(),
                receipt: process_receipt(
                    &key,
                    "reconcile-unavailable",
                    v1::WorkflowEffectReceiptOutcome::Unknown,
                    "",
                ),
                elapsed_milliseconds: 0,
            },
        }
    }
}

impl WorkflowEffectHost for ProcessWorkflowEffectHost {
    fn is_awaiting_authorization(&self, proposal: &v1::WorkflowEffectProposed) -> bool {
        self.is_available()
            && self
                .projected_authority(proposal)
                .is_some_and(|authority| authority.status == "proposed")
    }

    /// Returns the owner's recorded resolution for this proposal, read from the
    /// durable projection. Nothing is approved here.
    fn authorize(
        &mut self,
        proposal: &v1::WorkflowEffectProposed,
    ) -> Option<v1::ApprovalResolution> {
        let authority = self.projected_authority(proposal)?;
        if authority.status != "authorized" {
            return None;
        }
        authority.authorization?.resolution
    }
}

fn process_receipt(
    idempotency_key: &str,
    phase: &str,
    outcome: v1::WorkflowEffectReceiptOutcome,
    detail: &str,
) -> v1::WorkflowEffectReceipt {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.process-effect-receipt.v1\0");
    hasher.update(idempotency_key.as_bytes());
    hasher.update([0]);
    hasher.update(phase.as_bytes());
    hasher.update([0]);
    hasher.update(detail.as_bytes());
    hasher.update([0]);
    hasher.update((outcome as i32).to_be_bytes());
    let digest = hex::encode(hasher.finalize());
    v1::WorkflowEffectReceipt {
        receipt_id: format!("process-receipt:{digest}"),
        provider_reference: String::new(),
        outcome: outcome as i32,
        evidence_digest: digest,
    }
}

fn failure_dispatch_result(
    failure: ProcessHostFailure,
    idempotency_key: &str,
) -> WorkflowEffectConnectorDispatchResult {
    let summary = failure.summary();
    match failure {
        ProcessHostFailure::Unavailable(_) => WorkflowEffectConnectorDispatchResult::NotSent {
            error_code: "connector.host_failed".into(),
            receipt: process_receipt(
                idempotency_key,
                "dispatch-not-sent",
                v1::WorkflowEffectReceiptOutcome::NotApplied,
                &summary,
            ),
            elapsed_milliseconds: 0,
        },
        ProcessHostFailure::TimedOut
        | ProcessHostFailure::Malformed(_)
        | ProcessHostFailure::Crashed(_) => WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
            error_code: "connector.outcome_unknown".into(),
            receipt: process_receipt(
                idempotency_key,
                "dispatch-unknown",
                v1::WorkflowEffectReceiptOutcome::Unknown,
                &summary,
            ),
            elapsed_milliseconds: 0,
        },
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireDescription {
    connectors: Vec<WireConnector>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireConnector {
    connector_class: String,
    version: String,
    package_digest: String,
    binding_id: String,
    account_binding_id: String,
    #[serde(default)]
    allowed_actions: Vec<String>,
    #[serde(default)]
    idempotent: bool,
    #[serde(default)]
    supports_reconciliation: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEffectRequest<'a> {
    effect_id: &'a str,
    run_id: &'a str,
    node_id: &'a str,
    workflow_id: &'a str,
    revision_id: &'a str,
    connector_class: &'a str,
    action: &'a str,
    account_binding_id: &'a str,
    destination_fingerprint: &'a str,
    input_digest: &'a str,
    idempotency_key: &'a str,
    dispatch_id: &'a str,
    grant_id: &'a str,
    deadline_unix_millis: i64,
    input: Option<Value>,
    prior_receipt: Option<WireReceiptOut<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireReceiptOut<'a> {
    receipt_id: &'a str,
    provider_reference: &'a str,
    outcome: &'static str,
    evidence_digest: &'a str,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireReceiptIn {
    #[serde(default)]
    receipt_id: String,
    #[serde(default)]
    provider_reference: String,
    #[serde(default)]
    outcome: String,
    #[serde(default)]
    evidence_digest: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireEffectResponse {
    outcome: String,
    #[serde(default)]
    error_code: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    receipt: WireReceiptIn,
    #[serde(default)]
    elapsed_milliseconds: u64,
}

impl WireEffectResponse {
    fn receipt(
        &self,
        idempotency_key: &str,
        phase: &str,
        fallback: v1::WorkflowEffectReceiptOutcome,
    ) -> v1::WorkflowEffectReceipt {
        let outcome = match self.receipt.outcome.as_str() {
            "applied" => v1::WorkflowEffectReceiptOutcome::Applied,
            "not_applied" => v1::WorkflowEffectReceiptOutcome::NotApplied,
            "unknown" => v1::WorkflowEffectReceiptOutcome::Unknown,
            _ => fallback,
        };
        let mut receipt = process_receipt(idempotency_key, phase, outcome, &self.summary);
        if !self.receipt.receipt_id.is_empty() {
            receipt.receipt_id = self.receipt.receipt_id.clone();
        }
        receipt.provider_reference = self.receipt.provider_reference.clone();
        if self.receipt.evidence_digest.len() == 64 {
            receipt.evidence_digest = self.receipt.evidence_digest.clone();
        }
        receipt
    }

    fn into_dispatch_result(self, idempotency_key: &str) -> WorkflowEffectConnectorDispatchResult {
        let elapsed_milliseconds = self.elapsed_milliseconds;
        let error_code = if self.error_code.is_empty() {
            format!("connector.{}", self.outcome)
        } else {
            self.error_code.clone()
        };
        match self.outcome.as_str() {
            "succeeded" => WorkflowEffectConnectorDispatchResult::Succeeded {
                receipt: self.receipt(
                    idempotency_key,
                    "dispatch-applied",
                    v1::WorkflowEffectReceiptOutcome::Applied,
                ),
                elapsed_milliseconds,
            },
            "rejected" => WorkflowEffectConnectorDispatchResult::Rejected {
                error_code,
                receipt: self.receipt(
                    idempotency_key,
                    "dispatch-rejected",
                    v1::WorkflowEffectReceiptOutcome::NotApplied,
                ),
                elapsed_milliseconds,
            },
            "not_sent" => WorkflowEffectConnectorDispatchResult::NotSent {
                error_code,
                receipt: self.receipt(
                    idempotency_key,
                    "dispatch-not-sent",
                    v1::WorkflowEffectReceiptOutcome::NotApplied,
                ),
                elapsed_milliseconds,
            },
            _ => WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
                error_code,
                receipt: self.receipt(
                    idempotency_key,
                    "dispatch-unknown",
                    v1::WorkflowEffectReceiptOutcome::Unknown,
                ),
                elapsed_milliseconds,
            },
        }
    }

    fn into_reconciliation_result(
        self,
        idempotency_key: &str,
    ) -> WorkflowEffectConnectorReconciliationResult {
        let elapsed_milliseconds = self.elapsed_milliseconds;
        let error_code = if self.error_code.is_empty() {
            format!("connector.{}", self.outcome)
        } else {
            self.error_code.clone()
        };
        match self.outcome.as_str() {
            "applied" => WorkflowEffectConnectorReconciliationResult::Applied {
                receipt: self.receipt(
                    idempotency_key,
                    "reconcile-applied",
                    v1::WorkflowEffectReceiptOutcome::Applied,
                ),
                elapsed_milliseconds,
            },
            "not_applied" => WorkflowEffectConnectorReconciliationResult::NotApplied {
                error_code,
                receipt: self.receipt(
                    idempotency_key,
                    "reconcile-not-applied",
                    v1::WorkflowEffectReceiptOutcome::NotApplied,
                ),
                elapsed_milliseconds,
            },
            _ => WorkflowEffectConnectorReconciliationResult::StillUnknown {
                error_code,
                receipt: self.receipt(
                    idempotency_key,
                    "reconcile-unknown",
                    v1::WorkflowEffectReceiptOutcome::Unknown,
                ),
                elapsed_milliseconds,
            },
        }
    }
}
