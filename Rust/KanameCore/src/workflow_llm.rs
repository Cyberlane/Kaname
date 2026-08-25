//! Typed boundary for workflow LLM providers.
//!
//! Kaname compiles, redacts, bounds, journals, and validates every context
//! record before this boundary is crossed. A provider receives no host path,
//! credential, or ambient conversation state. It must use the stable invocation
//! ID as an idempotency key so executor replay cannot create a second call.
//!
//! Three implementations ship here:
//!
//! - [`UnavailableWorkflowLlmProvider`] registers nothing, so a graph containing
//!   `compute.llm` is rejected before a run token exists.
//! - [`DeterministicWorkflowLlmProvider`] replays a registered plan and records
//!   what it observed, which is how fixtures prove journal receipts without a
//!   live model.
//! - [`ProcessWorkflowLlmProvider`] forwards the already compiled invocation to
//!   an external command named by `KANAME_WORKFLOW_LLM_COMMAND`. When that
//!   variable is absent, empty, or the command cannot describe itself, the
//!   provider behaves exactly like the unavailable one.
//!
//! The process boundary is one bounded canonical JSON request on standard input
//! and one bounded JSON response on standard output. The child is started with a
//! cleared environment, so a provider cannot inherit a credential, an endpoint,
//! or a host path from the Kaname process:
//!
//! - `command describe` answers `{"providers": [ … ]}` once at construction.
//! - `command invoke` receives the compiled invocation and answers
//!   `{"outcome": "succeeded" | "timed_out" | "malformed_result" | "crashed", … }`.
//!
//! Every response still crosses the executor's redaction, schema, trace-bound,
//! and tool-budget checks before it becomes durable evidence.

use crate::v1;
use crate::workflow_host_process::{
    ProcessHostCommand, ProcessHostFailure, encode_request, parse_response,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::time::Duration;

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

/// The environment variable that names the external LLM host command.
pub const WORKFLOW_LLM_COMMAND_VARIABLE: &str = "KANAME_WORKFLOW_LLM_COMMAND";

const DESCRIBE_TIMEOUT: Duration = Duration::from_secs(10);

/// A provider that forwards compiled invocations to an external command.
///
/// Construction is where availability is decided: the command must describe at
/// least one model class before any run can reach it. A provider that cannot
/// describe itself registers nothing, which makes the executor reject the graph
/// instead of starting an attempt it cannot settle.
pub struct ProcessWorkflowLlmProvider {
    command: Option<ProcessHostCommand>,
    definitions: BTreeMap<String, WorkflowLlmProviderDefinition>,
    completed: BTreeMap<String, WorkflowLlmProviderResult>,
    unavailable_reason: Option<String>,
}

impl ProcessWorkflowLlmProvider {
    /// Describes the command named by `KANAME_WORKFLOW_LLM_COMMAND`, or stays
    /// unavailable when the variable is absent or empty.
    pub fn from_environment() -> Self {
        match ProcessHostCommand::from_environment(WORKFLOW_LLM_COMMAND_VARIABLE) {
            Some(command) => Self::describe(command),
            None => Self::unavailable(format!("{WORKFLOW_LLM_COMMAND_VARIABLE} is not set")),
        }
    }

    /// Describes an explicitly named command. Fixtures use this instead of
    /// mutating process-wide environment state.
    pub fn with_command(program: impl Into<std::path::PathBuf>) -> Self {
        Self::describe(ProcessHostCommand::new(program))
    }

    fn unavailable(reason: String) -> Self {
        Self {
            command: None,
            definitions: BTreeMap::new(),
            completed: BTreeMap::new(),
            unavailable_reason: Some(reason),
        }
    }

    fn describe(command: ProcessHostCommand) -> Self {
        let response = match command.run("describe", b"", DESCRIBE_TIMEOUT) {
            Ok(response) => response,
            Err(failure) => return Self::unavailable(failure.summary()),
        };
        let described: WireProviderDescription = match parse_response(&response) {
            Ok(described) => described,
            Err(failure) => return Self::unavailable(failure.summary()),
        };
        let definitions = described
            .providers
            .into_iter()
            .map(|provider| (provider.model_class.clone(), provider.into()))
            .collect::<BTreeMap<String, WorkflowLlmProviderDefinition>>();
        if definitions.is_empty() {
            return Self::unavailable("the host described no model class".into());
        }
        Self {
            command: Some(command),
            definitions,
            completed: BTreeMap::new(),
            unavailable_reason: None,
        }
    }

    pub fn is_available(&self) -> bool {
        self.command.is_some() && !self.definitions.is_empty()
    }

    /// Explains why an unavailable provider registered nothing. Callers surface
    /// this instead of treating a missing host as an empty or successful run.
    pub fn unavailable_reason(&self) -> Option<&str> {
        self.unavailable_reason.as_deref()
    }

    pub fn registered_model_classes(&self) -> Vec<String> {
        self.definitions.keys().cloned().collect()
    }
}

impl WorkflowLlmProvider for ProcessWorkflowLlmProvider {
    fn definition(&self, model_class: &str) -> Option<WorkflowLlmProviderDefinition> {
        self.definitions.get(model_class).cloned()
    }

    fn invoke(&mut self, invocation: &WorkflowLlmInvocation) -> WorkflowLlmProviderResult {
        if let Some(completed) = self.completed.get(&invocation.invocation_id) {
            return completed.clone();
        }
        let receipt_id = format!("receipt-{}", invocation.invocation_id);
        let result = self
            .command
            .as_ref()
            .ok_or_else(|| {
                ProcessHostFailure::Unavailable(
                    self.unavailable_reason
                        .clone()
                        .unwrap_or_else(|| "no host command is configured".into()),
                )
            })
            .and_then(|command| {
                let request = encode_request(&WireInvocationRequest::from(invocation))?;
                let response = command.run(
                    "invoke",
                    &request,
                    Duration::from_millis(invocation.timeout_milliseconds),
                )?;
                parse_response::<WireInvocationResponse>(&response)
            })
            .map_or_else(
                |failure| failure_result(failure, receipt_id.clone()),
                |response| response.into_result(receipt_id.clone()),
            );
        self.completed
            .insert(invocation.invocation_id.clone(), result.clone());
        result
    }
}

fn failure_result(failure: ProcessHostFailure, receipt_id: String) -> WorkflowLlmProviderResult {
    let summary = failure.summary();
    match failure {
        ProcessHostFailure::TimedOut => WorkflowLlmProviderResult::TimedOut {
            elapsed_milliseconds: 0,
            receipt_id,
            trace: WorkflowLlmProviderTrace::default(),
        },
        ProcessHostFailure::Malformed(_) => WorkflowLlmProviderResult::MalformedResult {
            summary,
            elapsed_milliseconds: 0,
            receipt_id,
            trace: WorkflowLlmProviderTrace::default(),
        },
        ProcessHostFailure::Unavailable(_) | ProcessHostFailure::Crashed(_) => {
            WorkflowLlmProviderResult::Crashed {
                summary,
                elapsed_milliseconds: 0,
                receipt_id,
                trace: WorkflowLlmProviderTrace::default(),
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireProviderDescription {
    providers: Vec<WireProviderDefinition>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireProviderDefinition {
    provider_id: String,
    model_id: String,
    model_revision: String,
    model_class: String,
    timeout_milliseconds: u64,
    maximum_context_bytes: u64,
    idempotent: bool,
    #[serde(default)]
    tools: Vec<WireProviderTool>,
}

impl From<WireProviderDefinition> for WorkflowLlmProviderDefinition {
    fn from(described: WireProviderDefinition) -> Self {
        Self {
            provider_id: described.provider_id,
            model_id: described.model_id,
            model_revision: described.model_revision,
            model_class: described.model_class,
            timeout_milliseconds: described.timeout_milliseconds,
            maximum_context_bytes: described.maximum_context_bytes,
            idempotent: described.idempotent,
            tools: described
                .tools
                .into_iter()
                .map(WorkflowLlmProviderToolDefinition::from)
                .collect(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireProviderTool {
    tool_id: String,
    version: String,
    package_digest: String,
    description: String,
    input_schema_ref: String,
    input_schema: Value,
    output_schema_ref: String,
    output_schema: Value,
}

impl From<WireProviderTool> for WorkflowLlmProviderToolDefinition {
    fn from(described: WireProviderTool) -> Self {
        Self {
            tool_id: described.tool_id,
            version: described.version,
            package_digest: described.package_digest,
            description: described.description,
            input_schema_ref: described.input_schema_ref,
            input_schema: described.input_schema,
            output_schema_ref: described.output_schema_ref,
            output_schema: described.output_schema,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireInvocationRequest<'a> {
    invocation_id: &'a str,
    run_id: &'a str,
    attempt_id: &'a str,
    node_id: &'a str,
    settings: WireModelSettings<'a>,
    context_digest: &'a str,
    context_groups: Vec<WireContextGroup<'a>>,
    messages: Vec<WireMessage<'a>>,
    prior_episode_ids: &'a [String],
    attachments: Vec<WireAttachment<'a>>,
    tool_definitions: Vec<WireToolContract<'a>>,
    output_schema: &'a Value,
    timeout_milliseconds: u64,
}

impl<'a> From<&'a WorkflowLlmInvocation> for WireInvocationRequest<'a> {
    fn from(invocation: &'a WorkflowLlmInvocation) -> Self {
        Self {
            invocation_id: &invocation.invocation_id,
            run_id: &invocation.run_id,
            attempt_id: &invocation.attempt_id,
            node_id: &invocation.node_id,
            settings: WireModelSettings {
                model_class: &invocation.settings.model_class,
                provider_id: &invocation.settings.provider_id,
                model_id: &invocation.settings.model_id,
                model_revision: &invocation.settings.model_revision,
                reasoning_effort: &invocation.settings.reasoning_effort,
                temperature_milli: invocation.settings.temperature_milli,
                maximum_context_bytes: invocation.settings.maximum_context_bytes,
                maximum_output_tokens: invocation.settings.maximum_output_tokens,
                conversation_scope: &invocation.settings.conversation_scope,
            },
            context_digest: &invocation.context_digest,
            context_groups: invocation
                .context_groups
                .iter()
                .map(|group| WireContextGroup {
                    group_id: &group.group_id,
                    kind: &group.kind,
                    title: &group.title,
                    provenance: &group.provenance,
                    content: group.content.as_ref().and_then(|value| {
                        serde_json::from_slice(&value.inline_canonical_json).ok()
                    }),
                    truncated: group.truncated,
                    source_episode_ids: &group.source_episode_ids,
                })
                .collect(),
            messages: invocation
                .messages
                .iter()
                .map(|message| WireMessage {
                    message_id: &message.message_id,
                    sequence: message.sequence,
                    role: &message.role,
                    context_group_id: &message.context_group_id,
                    summary: &message.summary,
                    content_value_id: &message.content_value_id,
                    truncated: message.truncated,
                })
                .collect(),
            prior_episode_ids: &invocation.prior_episode_ids,
            attachments: invocation
                .attachments
                .iter()
                .map(|attachment| WireAttachment {
                    handle_id: &attachment.handle_id,
                    role: &attachment.role,
                    content_type: attachment
                        .value
                        .as_ref()
                        .map(|value| value.content_type.as_str())
                        .unwrap_or_default(),
                    sha256: attachment
                        .value
                        .as_ref()
                        .map(|value| value.sha256.as_str())
                        .unwrap_or_default(),
                    byte_count: attachment
                        .value
                        .as_ref()
                        .map(|value| value.byte_count)
                        .unwrap_or_default(),
                })
                .collect(),
            tool_definitions: invocation
                .tool_definitions
                .iter()
                .map(|tool| WireToolContract {
                    tool_id: &tool.tool_id,
                    version: &tool.version,
                    package_digest: &tool.package_digest,
                    description: &tool.description,
                    input_schema_ref: &tool.input_schema_ref,
                    input_schema_digest: &tool.input_schema_digest,
                    output_schema_ref: &tool.output_schema_ref,
                    output_schema_digest: &tool.output_schema_digest,
                })
                .collect(),
            output_schema: &invocation.output_schema,
            timeout_milliseconds: invocation.timeout_milliseconds,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireModelSettings<'a> {
    model_class: &'a str,
    provider_id: &'a str,
    model_id: &'a str,
    model_revision: &'a str,
    reasoning_effort: &'a str,
    temperature_milli: u32,
    maximum_context_bytes: u64,
    maximum_output_tokens: u32,
    conversation_scope: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireContextGroup<'a> {
    group_id: &'a str,
    kind: &'a str,
    title: &'a str,
    provenance: &'a str,
    content: Option<Value>,
    truncated: bool,
    source_episode_ids: &'a [String],
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireMessage<'a> {
    message_id: &'a str,
    sequence: u32,
    role: &'a str,
    context_group_id: &'a str,
    summary: &'a str,
    content_value_id: &'a str,
    truncated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireAttachment<'a> {
    handle_id: &'a str,
    role: &'a str,
    content_type: &'a str,
    sha256: &'a str,
    byte_count: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireToolContract<'a> {
    tool_id: &'a str,
    version: &'a str,
    package_digest: &'a str,
    description: &'a str,
    input_schema_ref: &'a str,
    input_schema_digest: &'a str,
    output_schema_ref: &'a str,
    output_schema_digest: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireInvocationResponse {
    outcome: String,
    #[serde(default)]
    output: Value,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    elapsed_milliseconds: u64,
    #[serde(default)]
    receipt_id: String,
    #[serde(default)]
    provider_run_reference: String,
    #[serde(default)]
    trace: WireTrace,
}

impl WireInvocationResponse {
    fn into_result(self, fallback_receipt_id: String) -> WorkflowLlmProviderResult {
        let receipt_id = if self.receipt_id.is_empty() {
            fallback_receipt_id
        } else {
            self.receipt_id
        };
        let elapsed_milliseconds = self.elapsed_milliseconds;
        let trace = self.trace.into();
        match self.outcome.as_str() {
            "succeeded" => WorkflowLlmProviderResult::Succeeded {
                output: self.output,
                elapsed_milliseconds,
                receipt_id,
                provider_run_reference: self.provider_run_reference,
                trace,
            },
            "timed_out" => WorkflowLlmProviderResult::TimedOut {
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
            "malformed_result" => WorkflowLlmProviderResult::MalformedResult {
                summary: self.summary,
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
            "crashed" => WorkflowLlmProviderResult::Crashed {
                summary: self.summary,
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
            other => WorkflowLlmProviderResult::MalformedResult {
                summary: format!("The host reported the unknown outcome {other}."),
                elapsed_milliseconds,
                receipt_id,
                trace,
            },
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireTrace {
    #[serde(default)]
    request_id: String,
    #[serde(default)]
    response_id: String,
    #[serde(default)]
    receipt_metadata: Value,
    #[serde(default)]
    tool_calls: Vec<WireToolCall>,
    #[serde(default)]
    response_messages: Vec<WireResponseMessage>,
    #[serde(default)]
    usage: WireUsage,
}

impl From<WireTrace> for WorkflowLlmProviderTrace {
    fn from(trace: WireTrace) -> Self {
        Self {
            request_id: trace.request_id,
            response_id: trace.response_id,
            receipt_metadata: trace.receipt_metadata,
            tool_calls: trace
                .tool_calls
                .into_iter()
                .map(WorkflowLlmProviderToolCall::from)
                .collect(),
            response_messages: trace
                .response_messages
                .into_iter()
                .map(WorkflowLlmProviderResponseMessage::from)
                .collect(),
            usage: trace.usage.into(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireToolCall {
    call_id: String,
    tool_id: String,
    #[serde(default)]
    input: Value,
    status: String,
    #[serde(default)]
    output: Value,
    #[serde(default)]
    error_code: String,
    #[serde(default)]
    error: Value,
    #[serde(default)]
    duration_milliseconds: u64,
}

impl From<WireToolCall> for WorkflowLlmProviderToolCall {
    fn from(call: WireToolCall) -> Self {
        let result = if call.status == "succeeded" {
            WorkflowLlmProviderToolResult::Succeeded(call.output)
        } else {
            WorkflowLlmProviderToolResult::Failed {
                code: call.error_code,
                error: call.error,
            }
        };
        Self {
            call_id: call.call_id,
            tool_id: call.tool_id,
            input: call.input,
            result,
            duration_milliseconds: call.duration_milliseconds,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireResponseMessage {
    message_id: String,
    role: String,
    kind: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    content: Value,
    #[serde(default)]
    tool_call_id: Option<String>,
}

impl From<WireResponseMessage> for WorkflowLlmProviderResponseMessage {
    fn from(message: WireResponseMessage) -> Self {
        Self {
            message_id: message.message_id,
            role: message.role,
            kind: message.kind,
            summary: message.summary,
            content: message.content,
            tool_call_id: message.tool_call_id,
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    cached_input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    reasoning_tokens: u64,
    #[serde(default)]
    cost_currency: String,
    #[serde(default)]
    input_cost_micros: u64,
    #[serde(default)]
    output_cost_micros: u64,
    #[serde(default)]
    reasoning_cost_micros: u64,
    #[serde(default)]
    tool_cost_micros: u64,
}

impl From<WireUsage> for WorkflowLlmProviderUsage {
    fn from(usage: WireUsage) -> Self {
        Self {
            input_tokens: usage.input_tokens,
            cached_input_tokens: usage.cached_input_tokens,
            output_tokens: usage.output_tokens,
            reasoning_tokens: usage.reasoning_tokens,
            cost_currency: usage.cost_currency,
            input_cost_micros: usage.input_cost_micros,
            output_cost_micros: usage.output_cost_micros,
            reasoning_cost_micros: usage.reasoning_cost_micros,
            tool_cost_micros: usage.tool_cost_micros,
        }
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
