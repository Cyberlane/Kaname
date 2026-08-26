//! Durable dispatch and reconciliation for installation-private workflow connectors.
//!
//! The journaled dispatch-started fact is the outbox boundary: after it exists,
//! this module never invokes dispatch again for the same effect. An interrupted
//! or unknown dispatch can only cross the connector's read-only reconciliation
//! boundary. The deterministic connector below is fixture-only and performs no
//! network, credential, account, filesystem, or external-effect operation.

use crate::{
    journal::Journal,
    v1,
    workflow_effect_authority::{
        WorkflowEffectAuthorityError, append_effect_event, stable_effect_id,
    },
    workflow_projection::{WorkflowProjectionError, WorkflowRunProjection},
    workflow_runtime::{
        WORKFLOW_EFFECT_DISPATCH_SETTLED_KIND, WORKFLOW_EFFECT_DISPATCH_SETTLED_TYPE,
        WORKFLOW_EFFECT_DISPATCH_STARTED_KIND, WORKFLOW_EFFECT_DISPATCH_STARTED_TYPE,
        WORKFLOW_EFFECT_RECONCILED_KIND, WORKFLOW_EFFECT_RECONCILED_TYPE,
        workflow_effect_connector_registration_digest,
    },
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fmt};

const DEFAULT_DISPATCH_TIMEOUT_MILLISECONDS: i64 = 60_000;

#[derive(Debug)]
pub enum WorkflowEffectConnectorError {
    Authority(WorkflowEffectAuthorityError),
    Projection(WorkflowProjectionError),
    Invalid(&'static str),
    NotFound,
    AuthorityUnavailable,
    AuthorityExpired,
    ConnectorUnavailable,
    RegistrationMismatch,
    ReconciliationRequired,
    NotReconcilable,
}

impl fmt::Display for WorkflowEffectConnectorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Authority(error) => write!(formatter, "workflow effect authority: {error}"),
            Self::Projection(error) => write!(formatter, "workflow effect projection: {error}"),
            Self::Invalid(code) => formatter.write_str(code),
            Self::NotFound => formatter.write_str("workflow_effect_not_found"),
            Self::AuthorityUnavailable => formatter.write_str("workflow_effect_not_authorized"),
            Self::AuthorityExpired => formatter.write_str("workflow_effect_authority_expired"),
            Self::ConnectorUnavailable => {
                formatter.write_str("workflow_effect_connector_unavailable")
            }
            Self::RegistrationMismatch => {
                formatter.write_str("workflow_effect_connector_registration_mismatch")
            }
            Self::ReconciliationRequired => {
                formatter.write_str("workflow_effect_reconciliation_required")
            }
            Self::NotReconcilable => formatter.write_str("workflow_effect_not_reconcilable"),
        }
    }
}

impl std::error::Error for WorkflowEffectConnectorError {}

impl From<WorkflowEffectAuthorityError> for WorkflowEffectConnectorError {
    fn from(value: WorkflowEffectAuthorityError) -> Self {
        Self::Authority(value)
    }
}

impl From<WorkflowProjectionError> for WorkflowEffectConnectorError {
    fn from(value: WorkflowProjectionError) -> Self {
        Self::Projection(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowEffectConnectorError>;

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowEffectConnectorRequest {
    pub proposal: v1::WorkflowEffectProposed,
    pub authorization: v1::WorkflowEffectAuthorized,
    pub dispatch: v1::WorkflowEffectDispatchStarted,
    pub prior_receipt: Option<v1::WorkflowEffectReceipt>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowEffectConnectorDispatchResult {
    Succeeded {
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
    Rejected {
        error_code: String,
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
    NotSent {
        error_code: String,
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
    OutcomeUnknown {
        error_code: String,
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowEffectConnectorReconciliationResult {
    Applied {
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
    NotApplied {
        error_code: String,
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
    StillUnknown {
        error_code: String,
        receipt: v1::WorkflowEffectReceipt,
        elapsed_milliseconds: u64,
    },
}

pub trait WorkflowEffectConnector {
    fn registration(
        &self,
        connector_class: &str,
        account_binding_id: &str,
    ) -> Option<v1::WorkflowEffectConnectorRegistration>;

    /// Dispatch must treat the request idempotency key as the provider key.
    fn dispatch(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorDispatchResult;

    /// Reconciliation observes provider state and must not repeat the effect.
    fn reconcile(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorReconciliationResult;
}

/// The connector boundary plus the local approval authority an `effect.connector`
/// node needs to run inside the durable executor. Authority stays outside the
/// executor: the host either returns the exact resolution an owner recorded for
/// the proposal's approval request, or nothing, and the executor never invents
/// one.
pub trait WorkflowEffectHost: WorkflowEffectConnector {
    fn authorize(
        &mut self,
        proposal: &v1::WorkflowEffectProposed,
    ) -> Option<v1::ApprovalResolution>;
}

/// The host an executor entry point without effect support installs. It
/// registers no connector and authorizes nothing, so a revision containing an
/// `effect.connector` node cannot execute through it.
pub struct UnavailableWorkflowEffectHost;

impl WorkflowEffectConnector for UnavailableWorkflowEffectHost {
    fn registration(
        &self,
        _connector_class: &str,
        _account_binding_id: &str,
    ) -> Option<v1::WorkflowEffectConnectorRegistration> {
        None
    }

    fn dispatch(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorDispatchResult {
        WorkflowEffectConnectorDispatchResult::NotSent {
            error_code: "connector.unavailable".into(),
            receipt: deterministic_receipt(
                &request.dispatch.idempotency_key,
                "dispatch-unavailable",
                v1::WorkflowEffectReceiptOutcome::NotApplied,
            ),
            elapsed_milliseconds: 0,
        }
    }

    fn reconcile(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorReconciliationResult {
        WorkflowEffectConnectorReconciliationResult::NotApplied {
            error_code: "connector.unavailable".into(),
            receipt: deterministic_receipt(
                &request.dispatch.idempotency_key,
                "reconciled-unavailable",
                v1::WorkflowEffectReceiptOutcome::NotApplied,
            ),
            elapsed_milliseconds: 0,
        }
    }
}

impl WorkflowEffectHost for UnavailableWorkflowEffectHost {
    fn authorize(
        &mut self,
        _proposal: &v1::WorkflowEffectProposed,
    ) -> Option<v1::ApprovalResolution> {
        None
    }
}

/// A fixture host that approves every proposal it is shown and delegates
/// dispatch and reconciliation to the deterministic connector. It performs no
/// network, credential, account, filesystem, or external-effect operation and
/// exists so the durable `effect.connector` path can be qualified end to end.
pub struct AutoApprovedWorkflowEffectHost {
    connector: DeterministicWorkflowEffectConnector,
    actor_id: String,
    device_id: String,
}

impl AutoApprovedWorkflowEffectHost {
    pub fn new(actor_id: impl Into<String>, device_id: impl Into<String>) -> Self {
        Self {
            connector: DeterministicWorkflowEffectConnector::default(),
            actor_id: actor_id.into(),
            device_id: device_id.into(),
        }
    }

    pub fn register(
        &mut self,
        registration: v1::WorkflowEffectConnectorRegistration,
        plan: DeterministicEffectConnectorPlan,
    ) {
        self.connector.register(registration, plan);
    }

    pub fn dispatch_count(&self, idempotency_key: &str) -> usize {
        self.connector.dispatch_count(idempotency_key)
    }

    pub fn reconciliation_count(&self, idempotency_key: &str) -> usize {
        self.connector.reconciliation_count(idempotency_key)
    }
}

impl WorkflowEffectConnector for AutoApprovedWorkflowEffectHost {
    fn registration(
        &self,
        connector_class: &str,
        account_binding_id: &str,
    ) -> Option<v1::WorkflowEffectConnectorRegistration> {
        self.connector
            .registration(connector_class, account_binding_id)
    }

    fn dispatch(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorDispatchResult {
        self.connector.dispatch(request)
    }

    fn reconcile(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorReconciliationResult {
        self.connector.reconcile(request)
    }
}

impl WorkflowEffectHost for AutoApprovedWorkflowEffectHost {
    fn authorize(
        &mut self,
        proposal: &v1::WorkflowEffectProposed,
    ) -> Option<v1::ApprovalResolution> {
        let approval = proposal.approval_request.as_ref()?;
        Some(v1::ApprovalResolution {
            approval_id: approval.approval_id.clone(),
            decision: v1::ApprovalDecision::Approve as i32,
            expected_fingerprint: approval.fingerprint.clone(),
            actor_id: self.actor_id.clone(),
            device_id: self.device_id.clone(),
            standing_rule_reference: String::new(),
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowEffectConnectorAdmission {
    pub authority: v1::WorkflowProjectedEffectAuthority,
    pub duplicate: bool,
}

pub fn dispatch_workflow_effect(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    connector: &mut dyn WorkflowEffectConnector,
    effect_id: &str,
    dispatched_at_unix_millis: i64,
) -> Result<WorkflowEffectConnectorAdmission> {
    projection.catch_up(journal)?;
    let authority = projection
        .effect_authority(effect_id)?
        .ok_or(WorkflowEffectConnectorError::NotFound)?;
    match authority.status.as_str() {
        "succeeded" | "rejected" | "not_sent" | "reconciled_applied" | "reconciled_not_applied" => {
            return Ok(WorkflowEffectConnectorAdmission {
                authority,
                duplicate: true,
            });
        }
        "dispatching" | "outcome_unknown" => {
            return Err(WorkflowEffectConnectorError::ReconciliationRequired);
        }
        "proposed" => return Err(WorkflowEffectConnectorError::AuthorityUnavailable),
        "authorized" => {}
        _ => {
            return Err(WorkflowEffectConnectorError::Invalid(
                "effect_status_invalid",
            ));
        }
    }
    let proposal = authority
        .proposal
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::AuthorityUnavailable)?;
    let intent = proposal
        .intent
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::AuthorityUnavailable)?;
    let authorization = authority
        .authorization
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::AuthorityUnavailable)?;
    if dispatched_at_unix_millis < 0 {
        return Err(WorkflowEffectConnectorError::Invalid(
            "effect_dispatch_time_invalid",
        ));
    }
    if authorization.expires_at_unix_millis <= dispatched_at_unix_millis {
        return Err(WorkflowEffectConnectorError::AuthorityExpired);
    }
    let registration = connector
        .registration(&intent.connector_class, &intent.account_binding_id)
        .ok_or(WorkflowEffectConnectorError::ConnectorUnavailable)?;
    if !registration_matches(&registration, intent) {
        return Err(WorkflowEffectConnectorError::RegistrationMismatch);
    }
    let dispatch_id = stable_effect_id("effect-dispatch", effect_id, &intent.idempotency_key);
    let dispatch = v1::WorkflowEffectDispatchStarted {
        run_id: intent.run_id.clone(),
        run_token_id: intent.run_token_id.clone(),
        effect_id: effect_id.into(),
        dispatch_id: dispatch_id.clone(),
        grant_id: authorization.grant_id.clone(),
        intent_digest: proposal.intent_digest.clone(),
        preview_digest: proposal
            .preview
            .as_ref()
            .map_or_else(String::new, |preview| preview.preview_digest.clone()),
        destination_fingerprint: intent.destination_fingerprint.clone(),
        idempotency_key: intent.idempotency_key.clone(),
        registration: Some(registration),
        deadline_unix_millis: authorization
            .expires_at_unix_millis
            .min(dispatched_at_unix_millis.saturating_add(DEFAULT_DISPATCH_TIMEOUT_MILLISECONDS)),
    };
    append_effect_event(
        journal,
        &intent.run_id,
        stable_effect_id("effect-dispatch-started", effect_id, &dispatch_id),
        dispatched_at_unix_millis,
        WORKFLOW_EFFECT_DISPATCH_STARTED_KIND,
        WORKFLOW_EFFECT_DISPATCH_STARTED_TYPE,
        dispatch.encode_to_vec(),
        &authorization.grant_id,
    )?;
    projection.catch_up(journal)?;

    let request = WorkflowEffectConnectorRequest {
        proposal: proposal.clone(),
        authorization: authorization.clone(),
        dispatch: dispatch.clone(),
        prior_receipt: None,
    };
    let settled = dispatch_result_payload(&request, connector.dispatch(&request));
    append_effect_event(
        journal,
        &intent.run_id,
        stable_effect_id("effect-dispatch-settled", effect_id, &dispatch_id),
        occurred_after_elapsed(dispatched_at_unix_millis, settled.elapsed_milliseconds),
        WORKFLOW_EFFECT_DISPATCH_SETTLED_KIND,
        WORKFLOW_EFFECT_DISPATCH_SETTLED_TYPE,
        settled.encode_to_vec(),
        &dispatch_id,
    )?;
    projection.catch_up(journal)?;
    Ok(WorkflowEffectConnectorAdmission {
        authority: projection
            .effect_authority(effect_id)?
            .ok_or(WorkflowEffectConnectorError::NotFound)?,
        duplicate: false,
    })
}

pub fn reconcile_workflow_effect(
    journal: &mut Journal,
    projection: &mut WorkflowRunProjection,
    connector: &mut dyn WorkflowEffectConnector,
    effect_id: &str,
    reconciled_at_unix_millis: i64,
) -> Result<WorkflowEffectConnectorAdmission> {
    projection.catch_up(journal)?;
    let authority = projection
        .effect_authority(effect_id)?
        .ok_or(WorkflowEffectConnectorError::NotFound)?;
    match authority.status.as_str() {
        "reconciled_applied" | "reconciled_not_applied" => {
            return Ok(WorkflowEffectConnectorAdmission {
                authority,
                duplicate: true,
            });
        }
        "dispatching" | "outcome_unknown" => {}
        _ => return Err(WorkflowEffectConnectorError::NotReconcilable),
    }
    if reconciled_at_unix_millis < 0 {
        return Err(WorkflowEffectConnectorError::Invalid(
            "effect_reconciliation_time_invalid",
        ));
    }
    let proposal = authority
        .proposal
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::NotFound)?;
    let intent = proposal
        .intent
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::NotFound)?;
    let authorization = authority
        .authorization
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::AuthorityUnavailable)?;
    let dispatch = authority
        .dispatch_started
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::NotReconcilable)?;
    let expected_registration = dispatch
        .registration
        .as_ref()
        .ok_or(WorkflowEffectConnectorError::RegistrationMismatch)?;
    let registration = connector
        .registration(&intent.connector_class, &intent.account_binding_id)
        .ok_or(WorkflowEffectConnectorError::ConnectorUnavailable)?;
    if &registration != expected_registration || !registration_matches(&registration, intent) {
        return Err(WorkflowEffectConnectorError::RegistrationMismatch);
    }
    let request = WorkflowEffectConnectorRequest {
        proposal: proposal.clone(),
        authorization: authorization.clone(),
        dispatch: dispatch.clone(),
        prior_receipt: authority
            .dispatch_settled
            .as_ref()
            .and_then(|settled| settled.receipt.clone()),
    };
    let ordinal = authority.reconciliation_count.saturating_add(1);
    let reconciliation_id = stable_effect_id(
        "effect-reconciliation",
        effect_id,
        &format!("{}:{ordinal}", dispatch.dispatch_id),
    );
    let reconciled = reconciliation_result_payload(
        &request,
        reconciliation_id.clone(),
        connector.reconcile(&request),
    );
    append_effect_event(
        journal,
        &intent.run_id,
        stable_effect_id("effect-reconciled", effect_id, &reconciliation_id),
        occurred_after_elapsed(reconciled_at_unix_millis, reconciled.elapsed_milliseconds),
        WORKFLOW_EFFECT_RECONCILED_KIND,
        WORKFLOW_EFFECT_RECONCILED_TYPE,
        reconciled.encode_to_vec(),
        &dispatch.dispatch_id,
    )?;
    projection.catch_up(journal)?;
    Ok(WorkflowEffectConnectorAdmission {
        authority: projection
            .effect_authority(effect_id)?
            .ok_or(WorkflowEffectConnectorError::NotFound)?,
        duplicate: false,
    })
}

fn occurred_after_elapsed(started_at_unix_millis: i64, elapsed_milliseconds: u64) -> i64 {
    started_at_unix_millis.saturating_add(i64::try_from(elapsed_milliseconds).unwrap_or(i64::MAX))
}

/// A registration may carry an intent only when it binds the same class and
/// account, allows the exact action, is idempotent, can reconcile, and its
/// digest still covers its own contents.
pub(crate) fn registration_matches(
    registration: &v1::WorkflowEffectConnectorRegistration,
    intent: &v1::WorkflowEffectIntent,
) -> bool {
    registration.connector_class == intent.connector_class
        && registration.account_binding_id == intent.account_binding_id
        && registration
            .allowed_actions
            .binary_search(&intent.action)
            .is_ok()
        && registration.idempotent
        && registration.supports_reconciliation
        && registration.registration_digest
            == workflow_effect_connector_registration_digest(registration)
}

/// Turns one connector dispatch answer into the durable settlement fact.
pub(crate) fn dispatch_result_payload(
    request: &WorkflowEffectConnectorRequest,
    result: WorkflowEffectConnectorDispatchResult,
) -> v1::WorkflowEffectDispatchSettled {
    let (outcome, error_code, receipt, elapsed_milliseconds) = match result {
        WorkflowEffectConnectorDispatchResult::Succeeded {
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectDispatchOutcome::Succeeded,
            String::new(),
            receipt,
            elapsed_milliseconds,
        ),
        WorkflowEffectConnectorDispatchResult::Rejected {
            error_code,
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectDispatchOutcome::Rejected,
            error_code,
            receipt,
            elapsed_milliseconds,
        ),
        WorkflowEffectConnectorDispatchResult::NotSent {
            error_code,
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectDispatchOutcome::NotSent,
            error_code,
            receipt,
            elapsed_milliseconds,
        ),
        WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
            error_code,
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectDispatchOutcome::Unknown,
            error_code,
            receipt,
            elapsed_milliseconds,
        ),
    };
    v1::WorkflowEffectDispatchSettled {
        run_id: request.dispatch.run_id.clone(),
        run_token_id: request.dispatch.run_token_id.clone(),
        effect_id: request.dispatch.effect_id.clone(),
        dispatch_id: request.dispatch.dispatch_id.clone(),
        grant_id: request.dispatch.grant_id.clone(),
        outcome: outcome as i32,
        error_code,
        receipt: Some(receipt),
        elapsed_milliseconds,
        idempotency_key: request.dispatch.idempotency_key.clone(),
    }
}

/// Turns one connector reconciliation answer into the durable reconciled fact.
pub(crate) fn reconciliation_result_payload(
    request: &WorkflowEffectConnectorRequest,
    reconciliation_id: String,
    result: WorkflowEffectConnectorReconciliationResult,
) -> v1::WorkflowEffectReconciled {
    let (outcome, error_code, receipt, elapsed_milliseconds) = match result {
        WorkflowEffectConnectorReconciliationResult::Applied {
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectReconciliationOutcome::Applied,
            String::new(),
            receipt,
            elapsed_milliseconds,
        ),
        WorkflowEffectConnectorReconciliationResult::NotApplied {
            error_code,
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectReconciliationOutcome::NotApplied,
            error_code,
            receipt,
            elapsed_milliseconds,
        ),
        WorkflowEffectConnectorReconciliationResult::StillUnknown {
            error_code,
            receipt,
            elapsed_milliseconds,
        } => (
            v1::WorkflowEffectReconciliationOutcome::StillUnknown,
            error_code,
            receipt,
            elapsed_milliseconds,
        ),
    };
    v1::WorkflowEffectReconciled {
        run_id: request.dispatch.run_id.clone(),
        run_token_id: request.dispatch.run_token_id.clone(),
        effect_id: request.dispatch.effect_id.clone(),
        dispatch_id: request.dispatch.dispatch_id.clone(),
        reconciliation_id,
        outcome: outcome as i32,
        error_code,
        receipt: Some(receipt),
        elapsed_milliseconds,
        idempotency_key: request.dispatch.idempotency_key.clone(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeterministicEffectConnectorPlan {
    Succeed,
    Reject,
    TimeoutBeforeSend,
    TimeoutAfterSend,
    /// Dispatch times out without the provider ever applying the effect, so a
    /// reconciliation check settles the effect as not applied.
    TimeoutWithoutApply,
    Ambiguous,
    /// Dispatch is ambiguous and the first reconciliation check still cannot
    /// tell, so only a later check observes the applied provider state.
    AmbiguousUntilSecondCheck,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DeterministicRemoteState {
    Applied,
    NotApplied,
    Unknown,
    /// Unknown to the first reconciliation check and applied to every later one.
    UnknownUntilSecondCheck,
}

#[derive(Default)]
pub struct DeterministicWorkflowEffectConnector {
    registrations: BTreeMap<(String, String), v1::WorkflowEffectConnectorRegistration>,
    plans: BTreeMap<(String, String), DeterministicEffectConnectorPlan>,
    dispatch_results: BTreeMap<String, WorkflowEffectConnectorDispatchResult>,
    remote_states: BTreeMap<String, DeterministicRemoteState>,
    dispatch_counts: BTreeMap<String, usize>,
    reconciliation_counts: BTreeMap<String, usize>,
}

impl DeterministicWorkflowEffectConnector {
    pub fn register(
        &mut self,
        mut registration: v1::WorkflowEffectConnectorRegistration,
        plan: DeterministicEffectConnectorPlan,
    ) {
        registration.allowed_actions.sort();
        registration.allowed_actions.dedup();
        registration.registration_digest =
            workflow_effect_connector_registration_digest(&registration);
        let key = (
            registration.connector_class.clone(),
            registration.account_binding_id.clone(),
        );
        self.registrations.insert(key.clone(), registration);
        self.plans.insert(key, plan);
    }

    pub fn dispatch_count(&self, idempotency_key: &str) -> usize {
        self.dispatch_counts
            .get(idempotency_key)
            .copied()
            .unwrap_or_default()
    }

    pub fn reconciliation_count(&self, idempotency_key: &str) -> usize {
        self.reconciliation_counts
            .get(idempotency_key)
            .copied()
            .unwrap_or_default()
    }
}

impl WorkflowEffectConnector for DeterministicWorkflowEffectConnector {
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
        *self.dispatch_counts.entry(key.clone()).or_default() += 1;
        let registration = request
            .dispatch
            .registration
            .as_ref()
            .expect("validated dispatch");
        let plan = self
            .plans
            .get(&(
                registration.connector_class.clone(),
                registration.account_binding_id.clone(),
            ))
            .copied()
            .unwrap_or(DeterministicEffectConnectorPlan::Ambiguous);
        let result = match plan {
            DeterministicEffectConnectorPlan::Succeed => {
                self.remote_states
                    .insert(key.clone(), DeterministicRemoteState::Applied);
                WorkflowEffectConnectorDispatchResult::Succeeded {
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-applied",
                        v1::WorkflowEffectReceiptOutcome::Applied,
                    ),
                    elapsed_milliseconds: 20,
                }
            }
            DeterministicEffectConnectorPlan::Reject => {
                self.remote_states
                    .insert(key.clone(), DeterministicRemoteState::NotApplied);
                WorkflowEffectConnectorDispatchResult::Rejected {
                    error_code: "connector.rejected".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-rejected",
                        v1::WorkflowEffectReceiptOutcome::NotApplied,
                    ),
                    elapsed_milliseconds: 15,
                }
            }
            DeterministicEffectConnectorPlan::TimeoutBeforeSend => {
                WorkflowEffectConnectorDispatchResult::NotSent {
                    error_code: "connector.timeout_before_send".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-not-sent",
                        v1::WorkflowEffectReceiptOutcome::NotApplied,
                    ),
                    elapsed_milliseconds: 60_000,
                }
            }
            DeterministicEffectConnectorPlan::TimeoutAfterSend => {
                self.remote_states
                    .insert(key.clone(), DeterministicRemoteState::Applied);
                WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
                    error_code: "connector.timeout_after_send".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-unknown",
                        v1::WorkflowEffectReceiptOutcome::Unknown,
                    ),
                    elapsed_milliseconds: 60_000,
                }
            }
            DeterministicEffectConnectorPlan::TimeoutWithoutApply => {
                self.remote_states
                    .insert(key.clone(), DeterministicRemoteState::NotApplied);
                WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
                    error_code: "connector.timeout_without_apply".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-unknown",
                        v1::WorkflowEffectReceiptOutcome::Unknown,
                    ),
                    elapsed_milliseconds: 60_000,
                }
            }
            DeterministicEffectConnectorPlan::Ambiguous => {
                self.remote_states
                    .insert(key.clone(), DeterministicRemoteState::Unknown);
                WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
                    error_code: "connector.outcome_ambiguous".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-ambiguous",
                        v1::WorkflowEffectReceiptOutcome::Unknown,
                    ),
                    elapsed_milliseconds: 25,
                }
            }
            DeterministicEffectConnectorPlan::AmbiguousUntilSecondCheck => {
                self.remote_states.insert(
                    key.clone(),
                    DeterministicRemoteState::UnknownUntilSecondCheck,
                );
                WorkflowEffectConnectorDispatchResult::OutcomeUnknown {
                    error_code: "connector.outcome_ambiguous".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "dispatch-ambiguous",
                        v1::WorkflowEffectReceiptOutcome::Unknown,
                    ),
                    elapsed_milliseconds: 25,
                }
            }
        };
        self.dispatch_results.insert(key, result.clone());
        result
    }

    fn reconcile(
        &mut self,
        request: &WorkflowEffectConnectorRequest,
    ) -> WorkflowEffectConnectorReconciliationResult {
        let key = request.dispatch.idempotency_key.clone();
        *self.reconciliation_counts.entry(key.clone()).or_default() += 1;
        if self.remote_states.get(&key).copied()
            == Some(DeterministicRemoteState::UnknownUntilSecondCheck)
        {
            self.remote_states
                .insert(key.clone(), DeterministicRemoteState::Applied);
            return WorkflowEffectConnectorReconciliationResult::StillUnknown {
                error_code: "connector.outcome_still_unknown".into(),
                receipt: deterministic_receipt(
                    &key,
                    "reconciled-unknown",
                    v1::WorkflowEffectReceiptOutcome::Unknown,
                ),
                elapsed_milliseconds: 10,
            };
        }
        match self.remote_states.get(&key).copied() {
            Some(DeterministicRemoteState::Applied) => {
                WorkflowEffectConnectorReconciliationResult::Applied {
                    receipt: deterministic_receipt(
                        &key,
                        "reconciled-applied",
                        v1::WorkflowEffectReceiptOutcome::Applied,
                    ),
                    elapsed_milliseconds: 10,
                }
            }
            Some(DeterministicRemoteState::NotApplied) | None => {
                WorkflowEffectConnectorReconciliationResult::NotApplied {
                    error_code: "connector.not_applied".into(),
                    receipt: deterministic_receipt(
                        &key,
                        "reconciled-not-applied",
                        v1::WorkflowEffectReceiptOutcome::NotApplied,
                    ),
                    elapsed_milliseconds: 10,
                }
            }
            Some(
                DeterministicRemoteState::Unknown
                | DeterministicRemoteState::UnknownUntilSecondCheck,
            ) => WorkflowEffectConnectorReconciliationResult::StillUnknown {
                error_code: "connector.outcome_still_unknown".into(),
                receipt: deterministic_receipt(
                    &key,
                    "reconciled-unknown",
                    v1::WorkflowEffectReceiptOutcome::Unknown,
                ),
                elapsed_milliseconds: 10,
            },
        }
    }
}

fn deterministic_receipt(
    idempotency_key: &str,
    phase: &str,
    outcome: v1::WorkflowEffectReceiptOutcome,
) -> v1::WorkflowEffectReceipt {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.fake-effect-receipt.v1\0");
    hasher.update(idempotency_key.as_bytes());
    hasher.update([0]);
    hasher.update(phase.as_bytes());
    hasher.update([0]);
    hasher.update((outcome as i32).to_be_bytes());
    let digest = hex::encode(hasher.finalize());
    v1::WorkflowEffectReceipt {
        receipt_id: format!("fake-receipt:{digest}"),
        provider_reference: format!("fake-effect:{idempotency_key}"),
        outcome: outcome as i32,
        evidence_digest: digest,
    }
}
