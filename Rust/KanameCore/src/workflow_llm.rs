//! Typed boundary for workflow LLM providers.
//!
//! Kaname compiles, redacts, bounds, journals, and validates every context
//! record before this boundary is crossed. A provider receives no host path,
//! credential, or ambient conversation state. It must use the stable invocation
//! ID as an idempotency key so executor replay cannot create a second call.

use crate::v1;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowLlmProviderDefinition {
    pub provider_id: String,
    pub model_id: String,
    pub model_revision: String,
    pub model_class: String,
    pub timeout_milliseconds: u64,
    pub maximum_context_bytes: u64,
    pub idempotent: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowLlmInvocation {
    pub invocation_id: String,
    pub run_id: String,
    pub attempt_id: String,
    pub node_id: String,
    pub settings: v1::WorkflowLlmModelSettings,
    pub context_digest: String,
    pub context_groups: Vec<v1::WorkflowLlmContextGroup>,
    pub messages: Vec<v1::WorkflowLlmMessage>,
    pub prior_episode_ids: Vec<String>,
    pub attachments: Vec<v1::WorkflowCapabilityArtifactHandle>,
    pub output_schema: Value,
    pub timeout_milliseconds: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowLlmProviderResult {
    Succeeded {
        output: Value,
        elapsed_milliseconds: u64,
        receipt_id: String,
        provider_run_reference: String,
    },
    TimedOut {
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
    MalformedResult {
        summary: String,
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
    Crashed {
        summary: String,
        elapsed_milliseconds: u64,
        receipt_id: String,
    },
}

pub trait WorkflowLlmProvider {
    fn definition(&self, model_class: &str) -> Option<WorkflowLlmProviderDefinition>;

    /// Providers must treat `invocation.invocation_id` as an idempotency key.
    fn invoke(&mut self, invocation: &WorkflowLlmInvocation) -> WorkflowLlmProviderResult;
}

#[derive(Default)]
pub struct UnavailableWorkflowLlmProvider;

impl WorkflowLlmProvider for UnavailableWorkflowLlmProvider {
    fn definition(&self, _model_class: &str) -> Option<WorkflowLlmProviderDefinition> {
        None
    }

    fn invoke(&mut self, _invocation: &WorkflowLlmInvocation) -> WorkflowLlmProviderResult {
        unreachable!("an unavailable LLM provider cannot be invoked")
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum DeterministicLlmPlan {
    Succeed {
        output: Value,
        elapsed_milliseconds: u64,
    },
    TimeOut {
        elapsed_milliseconds: u64,
    },
    Malformed {
        summary: String,
        elapsed_milliseconds: u64,
    },
    Crash {
        summary: String,
        elapsed_milliseconds: u64,
    },
}

#[derive(Default)]
pub struct DeterministicWorkflowLlmProvider {
    registrations: BTreeMap<String, WorkflowLlmProviderDefinition>,
    plans: BTreeMap<String, DeterministicLlmPlan>,
    completed: BTreeMap<String, WorkflowLlmProviderResult>,
    invocation_counts: BTreeMap<String, usize>,
    observed: BTreeMap<String, WorkflowLlmInvocation>,
}

impl DeterministicWorkflowLlmProvider {
    pub fn register(
        &mut self,
        definition: WorkflowLlmProviderDefinition,
        plan: DeterministicLlmPlan,
    ) {
        self.plans.insert(definition.model_class.clone(), plan);
        self.registrations
            .insert(definition.model_class.clone(), definition);
    }

    pub fn invocation_count(&self, invocation_id: &str) -> usize {
        self.invocation_counts
            .get(invocation_id)
            .copied()
            .unwrap_or_default()
    }

    pub fn observed(&self, invocation_id: &str) -> Option<&WorkflowLlmInvocation> {
        self.observed.get(invocation_id)
    }
}

impl WorkflowLlmProvider for DeterministicWorkflowLlmProvider {
    fn definition(&self, model_class: &str) -> Option<WorkflowLlmProviderDefinition> {
        self.registrations.get(model_class).cloned()
    }

    fn invoke(&mut self, invocation: &WorkflowLlmInvocation) -> WorkflowLlmProviderResult {
        if let Some(completed) = self.completed.get(&invocation.invocation_id) {
            return completed.clone();
        }
        *self
            .invocation_counts
            .entry(invocation.invocation_id.clone())
            .or_default() += 1;
        self.observed
            .insert(invocation.invocation_id.clone(), invocation.clone());
        let plan = self
            .plans
            .get(&invocation.settings.model_class)
            .cloned()
            .unwrap_or_else(|| DeterministicLlmPlan::Crash {
                summary: "The deterministic provider has no registered execution plan.".into(),
                elapsed_milliseconds: 0,
            });
        let receipt_id = format!("receipt-{}", invocation.invocation_id);
        let result = match plan {
            DeterministicLlmPlan::Succeed {
                output,
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::Succeeded {
                output,
                elapsed_milliseconds,
                receipt_id,
                provider_run_reference: format!("fake-{}", invocation.invocation_id),
            },
            DeterministicLlmPlan::TimeOut {
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::TimedOut {
                elapsed_milliseconds,
                receipt_id,
            },
            DeterministicLlmPlan::Malformed {
                summary,
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::MalformedResult {
                summary,
                elapsed_milliseconds,
                receipt_id,
            },
            DeterministicLlmPlan::Crash {
                summary,
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::Crashed {
                summary,
                elapsed_milliseconds,
                receipt_id,
            },
        };
        self.completed
            .insert(invocation.invocation_id.clone(), result.clone());
        result
    }
}
