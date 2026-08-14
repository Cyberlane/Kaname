//! Typed host boundary for version-pinned workflow capabilities.
//!
//! The durable executor owns validation, journaling, and replay. A host owns
//! only registration and one idempotent invocation identified by the stable
//! invocation ID supplied here. No host path, credential, or ambient process
//! state is part of this contract.

use crate::v1;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowCapabilityDefinition {
    pub capability_id: String,
    pub version: String,
    pub package_digest: String,
    pub configuration_schema: Value,
    pub input_schema: Value,
    pub output_schema: Value,
    pub timeout_milliseconds: u64,
    pub deterministic: bool,
    pub idempotent: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowCapabilityArtifactHandle {
    pub value: v1::WorkflowValueReference,
    pub role: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowCapabilityInvocation {
    pub invocation_id: String,
    pub run_id: String,
    pub attempt_id: String,
    pub node_id: String,
    pub capability_id: String,
    pub version: String,
    pub package_digest: String,
    pub configuration: Value,
    pub input: v1::WorkflowValueReference,
    pub artifact_inputs: Vec<WorkflowCapabilityArtifactHandle>,
    pub timeout_milliseconds: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowCapabilityLog {
    pub level: String,
    pub message: String,
    pub offset_milliseconds: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowCapabilityValue {
    Json(Value),
    StorageReference(v1::WorkflowValueReference),
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowCapabilityHostResult {
    Succeeded {
        output: WorkflowCapabilityValue,
        artifacts: Vec<WorkflowCapabilityArtifactHandle>,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
        receipt_id: String,
        provider_run_reference: String,
    },
    TimedOut {
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
    MalformedResult {
        summary: String,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
    Crashed {
        summary: String,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
}

pub trait WorkflowCapabilityHost {
    fn definition(
        &self,
        capability_id: &str,
        version: &str,
        package_digest: &str,
    ) -> Option<WorkflowCapabilityDefinition>;

    /// Hosts must treat `invocation.invocation_id` as an idempotency key.
    fn invoke(&mut self, invocation: &WorkflowCapabilityInvocation)
    -> WorkflowCapabilityHostResult;
}

#[derive(Default)]
pub struct UnavailableWorkflowCapabilityHost;

impl WorkflowCapabilityHost for UnavailableWorkflowCapabilityHost {
    fn definition(
        &self,
        _capability_id: &str,
        _version: &str,
        _package_digest: &str,
    ) -> Option<WorkflowCapabilityDefinition> {
        None
    }

    fn invoke(
        &mut self,
        _invocation: &WorkflowCapabilityInvocation,
    ) -> WorkflowCapabilityHostResult {
        unreachable!("an unavailable capability host cannot be invoked")
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum DeterministicCapabilityPlan {
    Succeed {
        output: WorkflowCapabilityValue,
        artifacts: Vec<WorkflowCapabilityArtifactHandle>,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
    },
    TimeOut {
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
    },
    Malformed {
        summary: String,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
    },
    Crash {
        summary: String,
        logs: Vec<WorkflowCapabilityLog>,
        elapsed_milliseconds: u64,
    },
}

#[derive(Default)]
pub struct DeterministicWorkflowCapabilityHost {
    registrations: BTreeMap<(String, String, String), WorkflowCapabilityDefinition>,
    plans: BTreeMap<(String, String, String), DeterministicCapabilityPlan>,
    completed: BTreeMap<String, WorkflowCapabilityHostResult>,
    invocation_counts: BTreeMap<String, usize>,
}

impl DeterministicWorkflowCapabilityHost {
    pub fn register(
        &mut self,
        definition: WorkflowCapabilityDefinition,
        plan: DeterministicCapabilityPlan,
    ) {
        let key = (
            definition.capability_id.clone(),
            definition.version.clone(),
            definition.package_digest.clone(),
        );
        self.registrations.insert(key.clone(), definition);
        self.plans.insert(key, plan);
    }

    pub fn invocation_count(&self, invocation_id: &str) -> usize {
        self.invocation_counts
            .get(invocation_id)
            .copied()
            .unwrap_or_default()
    }
}

impl WorkflowCapabilityHost for DeterministicWorkflowCapabilityHost {
    fn definition(
        &self,
        capability_id: &str,
        version: &str,
        package_digest: &str,
    ) -> Option<WorkflowCapabilityDefinition> {
        self.registrations
            .get(&(
                capability_id.to_owned(),
                version.to_owned(),
                package_digest.to_owned(),
            ))
            .cloned()
    }

    fn invoke(
        &mut self,
        invocation: &WorkflowCapabilityInvocation,
    ) -> WorkflowCapabilityHostResult {
        if let Some(completed) = self.completed.get(&invocation.invocation_id) {
            return completed.clone();
        }
        *self
            .invocation_counts
            .entry(invocation.invocation_id.clone())
            .or_default() += 1;
        let key = (
            invocation.capability_id.clone(),
            invocation.version.clone(),
            invocation.package_digest.clone(),
        );
        let plan =
            self.plans
                .get(&key)
                .cloned()
                .unwrap_or_else(|| DeterministicCapabilityPlan::Crash {
                    summary: "The registered deterministic capability has no execution plan."
                        .into(),
                    logs: Vec::new(),
                    elapsed_milliseconds: 0,
                });
        let receipt_id = format!("receipt-{}", invocation.invocation_id);
        let result = match plan {
            DeterministicCapabilityPlan::Succeed {
                output,
                artifacts,
                logs,
                elapsed_milliseconds,
            } => WorkflowCapabilityHostResult::Succeeded {
                output,
                artifacts,
                logs,
                elapsed_milliseconds,
                receipt_id,
                provider_run_reference: format!("fake-{}", invocation.invocation_id),
            },
            DeterministicCapabilityPlan::TimeOut {
                logs,
                elapsed_milliseconds,
            } => WorkflowCapabilityHostResult::TimedOut {
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
            DeterministicCapabilityPlan::Malformed {
                summary,
                logs,
                elapsed_milliseconds,
            } => WorkflowCapabilityHostResult::MalformedResult {
                summary,
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
            DeterministicCapabilityPlan::Crash {
                summary,
                logs,
                elapsed_milliseconds,
            } => WorkflowCapabilityHostResult::Crashed {
                summary,
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
        };
        self.completed
            .insert(invocation.invocation_id.clone(), result.clone());
        result
    }
}
