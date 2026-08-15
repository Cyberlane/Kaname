//! Typed boundary for workflow LLM providers.
//!
//! Kaname compiles, redacts, bounds, journals, and validates every context
//! record before this boundary is crossed. A provider receives no host path,
//! credential, or ambient conversation state. It must use the stable invocation
//! ID as an idempotency key so executor replay cannot create a second call.

use crate::v1;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowLlmProviderDefinition {
    pub provider_id: String,
    pub model_id: String,
    pub model_revision: String,
    pub model_class: String,
    pub timeout_milliseconds: u64,
    pub maximum_context_bytes: u64,
    pub idempotent: bool,
    pub tools: Vec<WorkflowLlmProviderToolDefinition>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowLlmProviderToolDefinition {
    pub tool_id: String,
    pub version: String,
    pub package_digest: String,
    pub description: String,
    pub input_schema_ref: String,
    pub input_schema: Value,
    pub output_schema_ref: String,
    pub output_schema: Value,
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
    pub tool_definitions: Vec<v1::WorkflowLlmToolDefinition>,
    pub output_schema: Value,
    pub timeout_milliseconds: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowLlmProviderToolResult {
    Succeeded(Value),
    Failed { code: String, error: Value },
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowLlmProviderToolCall {
    pub call_id: String,
    pub tool_id: String,
    pub input: Value,
    pub result: WorkflowLlmProviderToolResult,
    pub duration_milliseconds: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowLlmProviderResponseMessage {
    pub message_id: String,
    pub role: String,
    pub kind: String,
    pub summary: String,
    pub content: Value,
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkflowLlmProviderUsage {
    pub input_tokens: u64,
    pub cached_input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub cost_currency: String,
    pub input_cost_micros: u64,
    pub output_cost_micros: u64,
    pub reasoning_cost_micros: u64,
    pub tool_cost_micros: u64,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkflowLlmProviderTrace {
    pub request_id: String,
    pub response_id: String,
    pub receipt_metadata: Value,
    pub tool_calls: Vec<WorkflowLlmProviderToolCall>,
    pub response_messages: Vec<WorkflowLlmProviderResponseMessage>,
    pub usage: WorkflowLlmProviderUsage,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkflowLlmProviderResult {
    Succeeded {
        output: Value,
        elapsed_milliseconds: u64,
        receipt_id: String,
        provider_run_reference: String,
        trace: WorkflowLlmProviderTrace,
    },
    TimedOut {
        elapsed_milliseconds: u64,
        receipt_id: String,
        trace: WorkflowLlmProviderTrace,
    },
    MalformedResult {
        summary: String,
        elapsed_milliseconds: u64,
        receipt_id: String,
        trace: WorkflowLlmProviderTrace,
    },
    Crashed {
        summary: String,
        elapsed_milliseconds: u64,
        receipt_id: String,
        trace: WorkflowLlmProviderTrace,
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
    traces: BTreeMap<String, WorkflowLlmProviderTrace>,
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

    pub fn register_trace(&mut self, model_class: &str, trace: WorkflowLlmProviderTrace) {
        self.traces.insert(model_class.to_owned(), trace);
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
        let mut trace = self
            .traces
            .get(&invocation.settings.model_class)
            .cloned()
            .unwrap_or_default();
        if trace.request_id.is_empty() {
            trace.request_id = format!("request-{}", invocation.invocation_id);
        }
        if trace.response_id.is_empty() {
            trace.response_id = format!("response-{}", invocation.invocation_id);
        }
        let result = match plan {
            DeterministicLlmPlan::Succeed {
                output,
                elapsed_milliseconds,
            } => {
                if trace.response_messages.is_empty() {
                    trace
                        .response_messages
                        .push(WorkflowLlmProviderResponseMessage {
                            message_id: format!("message-{}", invocation.invocation_id),
                            role: "assistant".into(),
                            kind: "final".into(),
                            summary: "Final structured response".into(),
                            content: output.clone(),
                            tool_call_id: None,
                        });
                }
                WorkflowLlmProviderResult::Succeeded {
                    output,
                    elapsed_milliseconds,
                    receipt_id,
                    provider_run_reference: format!("fake-{}", invocation.invocation_id),
                    trace,
                }
            }
            DeterministicLlmPlan::TimeOut {
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::TimedOut {
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
            DeterministicLlmPlan::Malformed {
                summary,
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::MalformedResult {
                summary,
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
            DeterministicLlmPlan::Crash {
                summary,
                elapsed_milliseconds,
            } => WorkflowLlmProviderResult::Crashed {
                summary,
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
        };
        self.completed
            .insert(invocation.invocation_id.clone(), result.clone());
        result
    }
}
