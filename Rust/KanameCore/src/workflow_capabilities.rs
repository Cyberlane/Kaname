//! Typed host boundary for version-pinned workflow capabilities.
//!
//! The durable executor owns validation, journaling, and replay. A host owns
//! only registration and one idempotent invocation identified by the stable
//! invocation ID supplied here. No host path, credential, or ambient process
//! state is part of the serialized contract.
//!
//! Three implementations ship here:
//!
//! - [`UnavailableWorkflowCapabilityHost`] registers nothing, so a graph
//!   containing `compute.capability` is rejected before a run token exists.
//! - [`DeterministicWorkflowCapabilityHost`] replays a registered plan, which is
//!   how fixtures prove journal receipts without a real sandbox.
//! - [`ProcessWorkflowCapabilityHost`] runs a bounded external command named
//!   by `KANAME_WORKFLOW_CAPABILITY_COMMAND`. When that variable is absent or
//!   the command cannot describe itself, the host behaves exactly like the
//!   unavailable one.
//!
//! The process host admits a described capability only when its package digest
//! is a lowercase 64-character SHA-256 and, if
//! `KANAME_WORKFLOW_CAPABILITY_PACKAGE_DIGESTS` is set, only when that digest is
//! on the comma-separated allowlist. A wrong or unpinned build therefore cannot
//! register itself under a trusted capability identity.
//!
//! The process boundary is one bounded canonical JSON request on standard input
//! and one bounded JSON response on standard output, with a cleared child
//! environment. It is not an operating-system sandbox: the child retains the
//! inherited current directory and ordinary filesystem and network privileges.
//! Candidate wiring must add and qualify isolation before using an untrusted
//! capability executable:
//!
//! - `command describe` answers `{"capabilities": [ … ]}` once at construction.
//! - `command invoke` receives the pinned invocation and answers
//!   `{"outcome": "succeeded" | "timed_out" | "malformed_result" | "crashed", … }`.
//!
//! A subprocess capability returns typed JSON and sanitized logs only. Artifact
//! outputs stay with hosts that already hold the scoped-storage boundary,
//! because a handle cannot be minted from outside it.

use crate::v1;
use crate::workflow_host_process::{
    ProcessHostCommand, ProcessHostFailure, encode_request, parse_response,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

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

/// The environment variable that names the external capability host command.
pub const WORKFLOW_CAPABILITY_COMMAND_VARIABLE: &str = "KANAME_WORKFLOW_CAPABILITY_COMMAND";

/// The environment variable that pins which package digests may register.
pub const WORKFLOW_CAPABILITY_DIGEST_ALLOWLIST_VARIABLE: &str =
    "KANAME_WORKFLOW_CAPABILITY_PACKAGE_DIGESTS";

const DESCRIBE_TIMEOUT: Duration = Duration::from_secs(10);

/// A capability host that runs each invocation in an external command.
pub struct ProcessWorkflowCapabilityHost {
    command: Option<ProcessHostCommand>,
    registrations: BTreeMap<(String, String, String), WorkflowCapabilityDefinition>,
    completed: BTreeMap<String, WorkflowCapabilityHostResult>,
    unavailable_reason: Option<String>,
}

impl ProcessWorkflowCapabilityHost {
    /// Describes the command named by `KANAME_WORKFLOW_CAPABILITY_COMMAND`, or
    /// stays unavailable when the variable is absent or empty.
    pub fn from_environment() -> Self {
        match ProcessHostCommand::from_environment(WORKFLOW_CAPABILITY_COMMAND_VARIABLE) {
            Some(command) => Self::describe(command, digest_allowlist_from_environment()),
            None => Self::unavailable(format!("{WORKFLOW_CAPABILITY_COMMAND_VARIABLE} is not set")),
        }
    }

    /// Describes an explicitly named command against an explicit digest
    /// allowlist. An empty allowlist admits any well-formed digest.
    pub fn with_command(
        program: impl Into<std::path::PathBuf>,
        allowed_package_digests: impl IntoIterator<Item = String>,
    ) -> Self {
        Self::describe(
            ProcessHostCommand::new(program),
            allowed_package_digests.into_iter().collect(),
        )
    }

    fn unavailable(reason: String) -> Self {
        Self {
            command: None,
            registrations: BTreeMap::new(),
            completed: BTreeMap::new(),
            unavailable_reason: Some(reason),
        }
    }

    fn describe(command: ProcessHostCommand, allowed_package_digests: BTreeSet<String>) -> Self {
        let response = match command.run("describe", b"", DESCRIBE_TIMEOUT) {
            Ok(response) => response,
            Err(failure) => return Self::unavailable(failure.summary()),
        };
        let described: WireCapabilityDescription = match parse_response(&response) {
            Ok(described) => described,
            Err(failure) => return Self::unavailable(failure.summary()),
        };
        let registrations = described
            .capabilities
            .into_iter()
            .filter(|capability| {
                admissible_package_digest(&capability.package_digest, &allowed_package_digests)
            })
            .map(|capability| {
                let definition = WorkflowCapabilityDefinition::from(capability);
                (
                    (
                        definition.capability_id.clone(),
                        definition.version.clone(),
                        definition.package_digest.clone(),
                    ),
                    definition,
                )
            })
            .collect::<BTreeMap<_, _>>();
        if registrations.is_empty() {
            return Self::unavailable(
                "the host described no capability with an admitted package digest".into(),
            );
        }
        Self {
            command: Some(command),
            registrations,
            completed: BTreeMap::new(),
            unavailable_reason: None,
        }
    }

    pub fn is_available(&self) -> bool {
        self.command.is_some() && !self.registrations.is_empty()
    }

    /// Explains why an unavailable host registered nothing. Callers surface this
    /// instead of treating a missing host as an empty or successful run.
    pub fn unavailable_reason(&self) -> Option<&str> {
        self.unavailable_reason.as_deref()
    }

    pub fn registered_capabilities(&self) -> Vec<(String, String, String)> {
        self.registrations.keys().cloned().collect()
    }
}

fn digest_allowlist_from_environment() -> BTreeSet<String> {
    std::env::var(WORKFLOW_CAPABILITY_DIGEST_ALLOWLIST_VARIABLE)
        .map(|value| {
            value
                .split(',')
                .map(|digest| {
                    digest
                        .trim()
                        .trim_start_matches("sha256:")
                        .to_ascii_lowercase()
                })
                .filter(|digest| !digest.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn admissible_package_digest(digest: &str, allowed: &BTreeSet<String>) -> bool {
    digest.len() == 64
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        && (allowed.is_empty() || allowed.contains(digest))
}

impl WorkflowCapabilityHost for ProcessWorkflowCapabilityHost {
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
                let request = encode_request(&WireCapabilityRequest::from(invocation))?;
                let response = command.run(
                    "invoke",
                    &request,
                    Duration::from_millis(invocation.timeout_milliseconds),
                )?;
                parse_response::<WireCapabilityResponse>(&response)
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

fn failure_result(failure: ProcessHostFailure, receipt_id: String) -> WorkflowCapabilityHostResult {
    let summary = failure.summary();
    match failure {
        ProcessHostFailure::TimedOut => WorkflowCapabilityHostResult::TimedOut {
            logs: Vec::new(),
            elapsed_milliseconds: 0,
            receipt_id,
        },
        ProcessHostFailure::Malformed(_) => WorkflowCapabilityHostResult::MalformedResult {
            summary,
            logs: Vec::new(),
            elapsed_milliseconds: 0,
            receipt_id,
        },
        ProcessHostFailure::Unavailable(_) | ProcessHostFailure::Crashed(_) => {
            WorkflowCapabilityHostResult::Crashed {
                summary,
                logs: Vec::new(),
                elapsed_milliseconds: 0,
                receipt_id,
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireCapabilityDescription {
    capabilities: Vec<WireCapabilityDefinition>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireCapabilityDefinition {
    capability_id: String,
    version: String,
    package_digest: String,
    configuration_schema: Value,
    input_schema: Value,
    output_schema: Value,
    timeout_milliseconds: u64,
    deterministic: bool,
    idempotent: bool,
}

impl From<WireCapabilityDefinition> for WorkflowCapabilityDefinition {
    fn from(described: WireCapabilityDefinition) -> Self {
        Self {
            capability_id: described.capability_id,
            version: described.version,
            package_digest: described.package_digest,
            configuration_schema: described.configuration_schema,
            input_schema: described.input_schema,
            output_schema: described.output_schema,
            timeout_milliseconds: described.timeout_milliseconds,
            deterministic: described.deterministic,
            idempotent: described.idempotent,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireCapabilityRequest<'a> {
    invocation_id: &'a str,
    run_id: &'a str,
    attempt_id: &'a str,
    node_id: &'a str,
    capability_id: &'a str,
    version: &'a str,
    package_digest: &'a str,
    configuration: &'a Value,
    input: WireValue<'a>,
    artifact_inputs: Vec<WireArtifact<'a>>,
    timeout_milliseconds: u64,
}

impl<'a> From<&'a WorkflowCapabilityInvocation> for WireCapabilityRequest<'a> {
    fn from(invocation: &'a WorkflowCapabilityInvocation) -> Self {
        Self {
            invocation_id: &invocation.invocation_id,
            run_id: &invocation.run_id,
            attempt_id: &invocation.attempt_id,
            node_id: &invocation.node_id,
            capability_id: &invocation.capability_id,
            version: &invocation.version,
            package_digest: &invocation.package_digest,
            configuration: &invocation.configuration,
            input: WireValue::from(&invocation.input),
            artifact_inputs: invocation
                .artifact_inputs
                .iter()
                .map(|artifact| WireArtifact {
                    role: &artifact.role,
                    handle_id: &artifact.value.storage_reference_id,
                    content_type: &artifact.value.content_type,
                    sha256: &artifact.value.sha256,
                    byte_count: artifact.value.byte_count,
                })
                .collect(),
            timeout_milliseconds: invocation.timeout_milliseconds,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireValue<'a> {
    value_id: &'a str,
    content_type: &'a str,
    byte_count: u64,
    sha256: &'a str,
    inline: Option<Value>,
    storage_reference_id: &'a str,
}

impl<'a> From<&'a v1::WorkflowValueReference> for WireValue<'a> {
    fn from(value: &'a v1::WorkflowValueReference) -> Self {
        Self {
            value_id: &value.value_id,
            content_type: &value.content_type,
            byte_count: value.byte_count,
            sha256: &value.sha256,
            inline: serde_json::from_slice(&value.inline_canonical_json).ok(),
            storage_reference_id: &value.storage_reference_id,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireArtifact<'a> {
    role: &'a str,
    handle_id: &'a str,
    content_type: &'a str,
    sha256: &'a str,
    byte_count: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireCapabilityResponse {
    outcome: String,
    #[serde(default)]
    output: Value,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    logs: Vec<WireLog>,
    #[serde(default)]
    elapsed_milliseconds: u64,
    #[serde(default)]
    receipt_id: String,
    #[serde(default)]
    provider_run_reference: String,
}

impl WireCapabilityResponse {
    fn into_result(self, fallback_receipt_id: String) -> WorkflowCapabilityHostResult {
        let receipt_id = if self.receipt_id.is_empty() {
            fallback_receipt_id
        } else {
            self.receipt_id
        };
        let elapsed_milliseconds = self.elapsed_milliseconds;
        let logs = self
            .logs
            .into_iter()
            .map(WorkflowCapabilityLog::from)
            .collect();
        match self.outcome.as_str() {
            "succeeded" => WorkflowCapabilityHostResult::Succeeded {
                output: WorkflowCapabilityValue::Json(self.output),
                artifacts: Vec::new(),
                logs,
                elapsed_milliseconds,
                receipt_id,
                provider_run_reference: self.provider_run_reference,
            },
            "timed_out" => WorkflowCapabilityHostResult::TimedOut {
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
            "malformed_result" => WorkflowCapabilityHostResult::MalformedResult {
                summary: self.summary,
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
            "crashed" => WorkflowCapabilityHostResult::Crashed {
                summary: self.summary,
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
            other => WorkflowCapabilityHostResult::MalformedResult {
                summary: format!("The host reported the unknown outcome {other}."),
                logs,
                elapsed_milliseconds,
                receipt_id,
            },
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireLog {
    level: String,
    message: String,
    #[serde(default)]
    offset_milliseconds: u64,
}

impl From<WireLog> for WorkflowCapabilityLog {
    fn from(log: WireLog) -> Self {
        Self {
            level: log.level,
            message: log.message,
            offset_milliseconds: log.offset_milliseconds,
        }
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
