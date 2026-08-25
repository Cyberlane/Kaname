use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::env;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

const MAXIMUM_REQUEST_BYTES: usize = 64 * 1024;
const MAXIMUM_RESPONSE_BYTES: usize = 256 * 1024;
const MAXIMUM_ERROR_BYTES: usize = 16 * 1024;
const MAXIMUM_INVITE_BYTES: usize = 32 * 1024;
const MAXIMUM_DISPLAY_NAME_BYTES: usize = 128;
const MAXIMUM_MESSAGE_BYTES: usize = 16 * 1024;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreClientError {
    Unavailable,
    Launch,
    TimedOut,
    Io,
    TooLarge,
    Invalid,
    Rejected(String),
}

impl CoreClientError {
    pub fn code(&self) -> &str {
        match self {
            Self::Unavailable => "signed_core_unavailable",
            Self::Launch => "core_launch_failed",
            Self::TimedOut => "core_timed_out",
            Self::Io => "core_io_failed",
            Self::TooLarge => "core_bounds_exceeded",
            Self::Invalid => "core_response_invalid",
            Self::Rejected(code) => code,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkSemanticTone {
    Neutral,
    Informational,
    Active,
    Attention,
    Success,
    Warning,
    Danger,
    Blocked,
    External,
}

impl LinkSemanticTone {
    pub const fn contract_value(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::Informational => "informational",
            Self::Active => "active",
            Self::Attention => "attention",
            Self::Success => "success",
            Self::Warning => "warning",
            Self::Danger => "danger",
            Self::Blocked => "blocked",
            Self::External => "external",
        }
    }

    pub const fn css_class(self) -> &'static str {
        match self {
            Self::Neutral => "status-neutral",
            Self::Informational => "status-informational",
            Self::Active => "status-active",
            Self::Attention => "status-attention",
            Self::Success => "status-success",
            Self::Warning => "status-warning",
            Self::Danger => "status-danger",
            Self::Blocked => "status-blocked",
            Self::External => "status-external",
        }
    }

    pub const fn icon_css_class(self) -> &'static str {
        match self {
            Self::Neutral => "kaname-status-neutral-icon",
            Self::Informational => "kaname-status-informational-icon",
            Self::Active => "kaname-status-active-icon",
            Self::Attention => "kaname-status-attention-icon",
            Self::Success => "kaname-status-success-icon",
            Self::Warning => "kaname-status-warning-icon",
            Self::Danger => "kaname-status-danger-icon",
            Self::Blocked => "kaname-status-blocked-icon",
            Self::External => "kaname-status-external-icon",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkStatusPresentation {
    pub label: &'static str,
    pub tone: LinkSemanticTone,
    pub accessibility_label: String,
}

impl LinkStatusPresentation {
    fn new(
        label: &'static str,
        tone: LinkSemanticTone,
        accessibility_label: impl Into<String>,
    ) -> Self {
        Self {
            label,
            tone,
            accessibility_label: accessibility_label.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinkConnectionCapabilities {
    pub can_request_enrollment: bool,
    pub can_queue_message: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkConnectionStatus {
    HostOnline,
    Connecting,
    HostOffline,
    EnrollmentRequired,
    Revoked,
    Unrecognized(String),
}

impl LinkConnectionStatus {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "hostOnline" => Self::HostOnline,
            "connecting" => Self::Connecting,
            "hostOffline" => Self::HostOffline,
            "enrollmentRequired" => Self::EnrollmentRequired,
            "revoked" => Self::Revoked,
            value => Self::Unrecognized(value.to_owned()),
        }
    }

    pub const fn kind_key(&self) -> &'static str {
        match self {
            Self::HostOnline => "hostOnline",
            Self::Connecting => "connecting",
            Self::HostOffline => "hostOffline",
            Self::EnrollmentRequired => "enrollmentRequired",
            Self::Revoked => "revoked",
            Self::Unrecognized(_) => "unrecognized",
        }
    }

    pub fn presentation(&self) -> LinkStatusPresentation {
        match self {
            Self::HostOnline => LinkStatusPresentation::new(
                "Host online",
                LinkSemanticTone::Success,
                "Connection status: Host online",
            ),
            Self::Connecting => LinkStatusPresentation::new(
                "Connecting",
                LinkSemanticTone::Active,
                "Connection status: Connecting",
            ),
            Self::HostOffline => LinkStatusPresentation::new(
                "Host offline",
                LinkSemanticTone::Warning,
                "Connection status: Host offline",
            ),
            Self::EnrollmentRequired => LinkStatusPresentation::new(
                "Enrollment required",
                LinkSemanticTone::External,
                "Connection status: Enrollment required",
            ),
            Self::Revoked => LinkStatusPresentation::new(
                "Access revoked",
                LinkSemanticTone::Blocked,
                "Connection status: Access revoked",
            ),
            Self::Unrecognized(_) => LinkStatusPresentation::new(
                "Connection state unavailable",
                LinkSemanticTone::Blocked,
                "Connection status: Connection state unavailable",
            ),
        }
    }

    pub const fn capabilities(&self) -> LinkConnectionCapabilities {
        match self {
            Self::HostOnline | Self::HostOffline => LinkConnectionCapabilities {
                can_request_enrollment: false,
                // Linux already permits durable local queueing while the host is offline.
                can_queue_message: true,
            },
            Self::EnrollmentRequired => LinkConnectionCapabilities {
                can_request_enrollment: true,
                can_queue_message: false,
            },
            Self::Connecting | Self::Revoked | Self::Unrecognized(_) => {
                LinkConnectionCapabilities {
                    can_request_enrollment: false,
                    can_queue_message: false,
                }
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkDiscussionStatus {
    ActionRequired,
    WaitingForHost,
    UpToDate,
    Delivered,
    Unrecognized(String),
}

impl LinkDiscussionStatus {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "Waiting for you" => Self::ActionRequired,
            "Waiting for host" => Self::WaitingForHost,
            "Up to date" => Self::UpToDate,
            "Delivered" => Self::Delivered,
            value => Self::Unrecognized(value.to_owned()),
        }
    }

    pub const fn kind_key(&self) -> &'static str {
        match self {
            Self::ActionRequired => "actionRequired",
            Self::WaitingForHost => "waitingForHost",
            Self::UpToDate => "upToDate",
            Self::Delivered => "delivered",
            Self::Unrecognized(_) => "unrecognized",
        }
    }

    pub fn presentation(&self) -> LinkStatusPresentation {
        match self {
            Self::ActionRequired => LinkStatusPresentation::new(
                "Waiting for you",
                LinkSemanticTone::Attention,
                "Discussion status: Waiting for you. Action required.",
            ),
            Self::WaitingForHost => LinkStatusPresentation::new(
                "Waiting for host",
                LinkSemanticTone::Active,
                "Discussion status: Waiting for host",
            ),
            Self::UpToDate => LinkStatusPresentation::new(
                "Up to date",
                LinkSemanticTone::Success,
                "Discussion status: Up to date",
            ),
            Self::Delivered => LinkStatusPresentation::new(
                "Delivered",
                LinkSemanticTone::Success,
                "Discussion status: Delivered",
            ),
            Self::Unrecognized(_) => LinkStatusPresentation::new(
                "Outcome uncertain",
                LinkSemanticTone::Warning,
                "Discussion status: Outcome uncertain",
            ),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkReceiptStatus {
    LocalStored,
    Queued,
    GatewayAccepted,
    Published,
    Delivered,
    Failed,
    OutcomeUncertain,
    Unrecognized(String),
}

impl LinkReceiptStatus {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "Stored locally" => Self::LocalStored,
            "Queued locally" | "Queued on this device" => Self::Queued,
            "Received by host" => Self::GatewayAccepted,
            "Published by host" | "Published result" => Self::Published,
            "Delivered" => Self::Delivered,
            "Observed failure" => Self::Failed,
            "Outcome uncertain" => Self::OutcomeUncertain,
            value => Self::Unrecognized(value.to_owned()),
        }
    }

    pub const fn kind_key(&self) -> &'static str {
        match self {
            Self::LocalStored => "localStored",
            Self::Queued => "queued",
            Self::GatewayAccepted => "gatewayAccepted",
            Self::Published => "published",
            Self::Delivered => "delivered",
            Self::Failed => "failed",
            Self::OutcomeUncertain => "outcomeUncertain",
            Self::Unrecognized(_) => "unrecognized",
        }
    }

    pub fn presentation(&self) -> LinkStatusPresentation {
        match self {
            Self::LocalStored => LinkStatusPresentation::new(
                "Stored locally",
                LinkSemanticTone::Informational,
                "Message status: Stored locally",
            ),
            Self::Queued => LinkStatusPresentation::new(
                "Queued locally",
                LinkSemanticTone::Active,
                "Message status: Queued locally",
            ),
            Self::GatewayAccepted => LinkStatusPresentation::new(
                "Received by host",
                LinkSemanticTone::Informational,
                "Message status: Received by host",
            ),
            Self::Published => LinkStatusPresentation::new(
                "Published by host",
                LinkSemanticTone::External,
                "Message status: Published by host",
            ),
            Self::Delivered => LinkStatusPresentation::new(
                "Delivered",
                LinkSemanticTone::Success,
                "Message status: Delivered",
            ),
            Self::Failed => LinkStatusPresentation::new(
                "Observed failure",
                LinkSemanticTone::Danger,
                "Message status: Observed failure",
            ),
            Self::OutcomeUncertain | Self::Unrecognized(_) => LinkStatusPresentation::new(
                "Outcome uncertain",
                LinkSemanticTone::Warning,
                "Message status: Outcome uncertain",
            ),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkParticipantRole {
    Host,
    Collaborator,
    Unrecognized(String),
}

impl LinkParticipantRole {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "host" => Self::Host,
            "collaborator" => Self::Collaborator,
            value => Self::Unrecognized(value.to_owned()),
        }
    }

    pub const fn kind_key(&self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::Collaborator => "collaborator",
            Self::Unrecognized(_) => "unrecognized",
        }
    }

    pub const fn is_local_principal(&self) -> bool {
        matches!(self, Self::Collaborator)
    }

    pub fn presentation(&self) -> LinkStatusPresentation {
        match self {
            Self::Host => LinkStatusPresentation::new(
                "Host",
                LinkSemanticTone::Informational,
                "Participant: Host",
            ),
            Self::Collaborator => LinkStatusPresentation::new(
                "External collaborator",
                LinkSemanticTone::External,
                "Participant: External collaborator",
            ),
            Self::Unrecognized(_) => LinkStatusPresentation::new(
                "External participant",
                LinkSemanticTone::Blocked,
                "Participant: Unrecognized external participant",
            ),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkHostVerificationState {
    Verified,
    ApprovalPending,
}

impl LinkHostVerificationState {
    pub const fn from_verified(verified: bool) -> Self {
        if verified {
            Self::Verified
        } else {
            Self::ApprovalPending
        }
    }

    pub const fn kind_key(self) -> &'static str {
        match self {
            Self::Verified => "verified",
            Self::ApprovalPending => "approvalPending",
        }
    }

    pub fn presentation(self) -> LinkStatusPresentation {
        match self {
            Self::Verified => LinkStatusPresentation::new(
                "Verified host",
                LinkSemanticTone::Success,
                "Host verification: Verified",
            ),
            Self::ApprovalPending => LinkStatusPresentation::new(
                "Approval pending",
                LinkSemanticTone::Attention,
                "Host verification: Approval pending",
            ),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkSnapshot {
    pub connection: String,
    pub last_sync_unix_millis: Option<i64>,
    pub spaces: Vec<LinkSpace>,
    pub diagnostic_code: Option<String>,
    pub verification_code: Option<String>,
}

impl LinkSnapshot {
    pub fn connection_status(&self) -> LinkConnectionStatus {
        LinkConnectionStatus::from_wire(&self.connection)
    }

    pub fn verification_code_for_display(&self) -> Option<&str> {
        self.verification_code
            .as_deref()
            .filter(|code| valid_verification_code(code))
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkSpace {
    pub id: String,
    pub name: String,
    pub host_name: String,
    pub verified: bool,
    pub discussions: Vec<LinkDiscussion>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkDiscussion {
    pub id: String,
    pub title: String,
    pub status: String,
    pub action_label: String,
    pub messages: Vec<LinkMessage>,
}

impl LinkDiscussion {
    pub fn status_kind(&self) -> LinkDiscussionStatus {
        LinkDiscussionStatus::from_wire(&self.status)
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkMessage {
    pub id: String,
    pub author: String,
    pub author_name: String,
    pub body: String,
    pub receipt: String,
}

impl LinkMessage {
    pub fn participant_role(&self) -> LinkParticipantRole {
        LinkParticipantRole::from_wire(&self.author)
    }

    pub fn receipt_status(&self) -> LinkReceiptStatus {
        LinkReceiptStatus::from_wire(&self.receipt)
    }
}

#[derive(Clone, Debug)]
pub struct EnrollmentOutcome {
    pub snapshot: LinkSnapshot,
    pub verification_code: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CoreRequest {
    schema_version: u32,
    #[serde(rename = "requestID")]
    request_id: String,
    operation: String,
    payload: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CoreResponse {
    schema_version: u32,
    #[serde(rename = "requestID")]
    request_id: String,
    ok: bool,
    result: Option<Value>,
    snapshot: Option<LinkSnapshot>,
    error_code: Option<String>,
}

#[derive(Clone)]
pub struct CoreClient {
    executable: PathBuf,
    timeout: Duration,
}

impl CoreClient {
    pub fn discover() -> Result<Self, CoreClientError> {
        if let Some(path) = env::var_os("KANAME_LINK_CLIENT_CORE") {
            let path = PathBuf::from(path);
            if path.is_file() {
                return Ok(Self {
                    executable: path,
                    timeout: DEFAULT_TIMEOUT,
                });
            }
        }
        let current = env::current_exe().map_err(|_| CoreClientError::Unavailable)?;
        let sibling = current.with_file_name("kaname-link-client");
        if sibling.is_file() {
            Ok(Self {
                executable: sibling,
                timeout: DEFAULT_TIMEOUT,
            })
        } else {
            Err(CoreClientError::Unavailable)
        }
    }

    pub fn snapshot(&self) -> Result<LinkSnapshot, CoreClientError> {
        self.request("snapshot", json!({}))?
            .snapshot
            .ok_or(CoreClientError::Invalid)
    }

    pub fn enroll(
        &self,
        invite_json: &str,
        display_name: &str,
    ) -> Result<EnrollmentOutcome, CoreClientError> {
        let invite_json = invite_json.trim();
        let display_name = display_name.trim();
        if invite_json.is_empty()
            || invite_json.len() > MAXIMUM_INVITE_BYTES
            || display_name.is_empty()
            || display_name.len() > MAXIMUM_DISPLAY_NAME_BYTES
            || display_name.chars().any(char::is_control)
        {
            return Err(CoreClientError::Invalid);
        }
        let invite: Value =
            serde_json::from_str(invite_json).map_err(|_| CoreClientError::Invalid)?;
        if !invite.is_object() {
            return Err(CoreClientError::Invalid);
        }
        let response = self.request(
            "enroll",
            json!({
                "invite": invite,
                "displayName": display_name,
            }),
        )?;
        let verification_code = enrollment_verification_code(response.result.as_ref())?;
        Ok(EnrollmentOutcome {
            snapshot: response.snapshot.ok_or(CoreClientError::Invalid)?,
            verification_code,
        })
    }

    pub fn send_message(
        &self,
        space_id: &str,
        discussion_id: &str,
        body: &str,
    ) -> Result<LinkSnapshot, CoreClientError> {
        let body = body.trim();
        if body.is_empty() || body.len() > MAXIMUM_MESSAGE_BYTES {
            return Err(CoreClientError::Invalid);
        }
        self.request(
            "sendMessage",
            json!({
                "spaceID": space_id,
                "discussionID": discussion_id,
                "body": body,
            }),
        )?
        .snapshot
        .ok_or(CoreClientError::Invalid)
    }

    fn request(&self, operation: &str, payload: Value) -> Result<CoreResponse, CoreClientError> {
        self.request_with_id(operation, payload, Uuid::new_v4().to_string())
    }

    fn request_with_id(
        &self,
        operation: &str,
        payload: Value,
        request_id: String,
    ) -> Result<CoreResponse, CoreClientError> {
        let input = serde_json::to_vec(&CoreRequest {
            schema_version: 1,
            request_id: request_id.clone(),
            operation: operation.to_owned(),
            payload,
        })
        .map_err(|_| CoreClientError::Invalid)?;
        if input.len() > MAXIMUM_REQUEST_BYTES {
            return Err(CoreClientError::TooLarge);
        }

        let mut child = Command::new(&self.executable)
            .arg("rpc")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| CoreClientError::Launch)?;
        let stdout = child.stdout.take().ok_or(CoreClientError::Io)?;
        let stderr = child.stderr.take().ok_or(CoreClientError::Io)?;
        let stdout_reader = thread::spawn(move || read_bounded(stdout, MAXIMUM_RESPONSE_BYTES));
        let stderr_reader = thread::spawn(move || read_bounded(stderr, MAXIMUM_ERROR_BYTES));
        {
            let mut stdin = child.stdin.take().ok_or(CoreClientError::Io)?;
            if stdin.write_all(&input).is_err() || stdin.flush().is_err() {
                terminate(&mut child);
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(CoreClientError::Io);
            }
        }

        let status = match wait_for_exit(&mut child, self.timeout) {
            Ok(status) => status,
            Err(error) => {
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(error);
            }
        };
        let output = stdout_reader.join().map_err(|_| CoreClientError::Io)??;
        let error_output = stderr_reader.join().map_err(|_| CoreClientError::Io)??;
        if output.exceeded || error_output.exceeded {
            return Err(CoreClientError::TooLarge);
        }
        if !status.success() {
            return Err(CoreClientError::Rejected("core_process_failed".to_owned()));
        }
        let response: CoreResponse =
            serde_json::from_slice(&output.bytes).map_err(|_| CoreClientError::Invalid)?;
        if response.schema_version != 1 || response.request_id != request_id {
            return Err(CoreClientError::Invalid);
        }
        if !response.ok {
            return Err(CoreClientError::Rejected(
                response
                    .error_code
                    .unwrap_or_else(|| "core_request_rejected".to_owned()),
            ));
        }
        Ok(response)
    }

    #[cfg(test)]
    fn for_test(executable: PathBuf, timeout: Duration) -> Self {
        Self {
            executable,
            timeout,
        }
    }
}

fn enrollment_verification_code(result: Option<&Value>) -> Result<String, CoreClientError> {
    let code = result
        .and_then(|result| result.get("verificationCode"))
        .and_then(Value::as_str)
        .ok_or(CoreClientError::Invalid)?;
    if !valid_verification_code(code) {
        return Err(CoreClientError::Invalid);
    }
    Ok(code.to_owned())
}

fn valid_verification_code(code: &str) -> bool {
    !code.is_empty() && code.len() <= 128 && !code.chars().any(char::is_control)
}

struct BoundedRead {
    bytes: Vec<u8>,
    exceeded: bool,
}

fn read_bounded(mut reader: impl Read, limit: usize) -> Result<BoundedRead, CoreClientError> {
    let mut bytes = Vec::with_capacity(limit.min(64 * 1024));
    let mut exceeded = false;
    let mut buffer = [0_u8; 8 * 1024];
    loop {
        let count = reader.read(&mut buffer).map_err(|_| CoreClientError::Io)?;
        if count == 0 {
            break;
        }
        let remaining = limit.saturating_sub(bytes.len());
        let retained = remaining.min(count);
        bytes.extend_from_slice(&buffer[..retained]);
        exceeded |= retained < count;
    }
    Ok(BoundedRead { bytes, exceeded })
}

fn wait_for_exit(child: &mut Child, timeout: Duration) -> Result<ExitStatus, CoreClientError> {
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|_| CoreClientError::Io)? {
            return Ok(status);
        }
        if started.elapsed() >= timeout {
            terminate(child);
            return Err(CoreClientError::TimedOut);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn terminate(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

pub fn synthetic_snapshot() -> LinkSnapshot {
    LinkSnapshot {
        connection: "hostOnline".to_owned(),
        last_sync_unix_millis: Some(1_776_990_640_000),
        diagnostic_code: Some("SYNTHETIC-PREVIEW".to_owned()),
        verification_code: None,
        spaces: vec![LinkSpace {
            id: "space-synthetic-simplykay".to_owned(),
            name: "SimplyKay pilot".to_owned(),
            host_name: "Justin's Kaname".to_owned(),
            verified: true,
            discussions: vec![LinkDiscussion {
                id: "discussion-wfp-104".to_owned(),
                title: "Monthly reporting correction".to_owned(),
                status: "Waiting for you".to_owned(),
                action_label: "Review version 2".to_owned(),
                messages: vec![
                    LinkMessage {
                        id: "message-1".to_owned(),
                        author: "collaborator".to_owned(),
                        author_name: "Kay".to_owned(),
                        body: "The subscription total should exclude the cancelled account. Could you update the report?".to_owned(),
                        receipt: "Received by host".to_owned(),
                    },
                    LinkMessage {
                        id: "message-2".to_owned(),
                        author: "host".to_owned(),
                        author_name: "Justin".to_owned(),
                        body: "Version 2 is ready. I corrected the synthetic account total and validated the spreadsheet structure.".to_owned(),
                        receipt: "Published by host".to_owned(),
                    },
                ],
            }],
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct StatusContract {
        schema_version: u32,
        privacy_class: String,
        semantic_tones: Vec<String>,
        connections: Vec<StatusContractEntry>,
        discussions: Vec<StatusContractEntry>,
        receipts: Vec<StatusContractEntry>,
        participants: Vec<ParticipantContractEntry>,
        host_verifications: Vec<HostVerificationContractEntry>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct StatusContractEntry {
        wire_value: String,
        kind: String,
        label: String,
        tone: String,
        accessibility_label: String,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ParticipantContractEntry {
        wire_value: String,
        kind: String,
        label: String,
        tone: String,
        accessibility_label: String,
        is_local_principal: bool,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct HostVerificationContractEntry {
        verified: bool,
        kind: String,
        tone: String,
        accessibility_label: String,
    }

    fn status_contract() -> StatusContract {
        serde_json::from_str(include_str!(
            "../../../../Fixtures/kaname-link/status-presentation-v1.json"
        ))
        .unwrap()
    }

    #[test]
    fn status_adapters_match_the_cross_platform_contract() {
        let contract = status_contract();
        assert_eq!(contract.schema_version, 1);
        assert_eq!(contract.privacy_class, "synthetic-public");
        let tones = [
            LinkSemanticTone::Neutral,
            LinkSemanticTone::Informational,
            LinkSemanticTone::Active,
            LinkSemanticTone::Attention,
            LinkSemanticTone::Success,
            LinkSemanticTone::Warning,
            LinkSemanticTone::Danger,
            LinkSemanticTone::Blocked,
            LinkSemanticTone::External,
        ];
        assert_eq!(
            contract.semantic_tones,
            tones
                .into_iter()
                .map(|tone| tone.contract_value().to_owned())
                .collect::<Vec<_>>()
        );

        for expected in contract.connections {
            let status = LinkConnectionStatus::from_wire(&expected.wire_value);
            let presentation = status.presentation();
            assert_eq!(status.kind_key(), expected.kind);
            assert_eq!(presentation.label, expected.label);
            assert_eq!(presentation.tone.contract_value(), expected.tone);
            assert_eq!(
                presentation.accessibility_label,
                expected.accessibility_label
            );
        }
        for expected in contract.discussions {
            let status = LinkDiscussionStatus::from_wire(&expected.wire_value);
            let presentation = status.presentation();
            assert_eq!(status.kind_key(), expected.kind);
            assert_eq!(presentation.label, expected.label);
            assert_eq!(presentation.tone.contract_value(), expected.tone);
            assert_eq!(
                presentation.accessibility_label,
                expected.accessibility_label
            );
        }
        for expected in contract.receipts {
            let status = LinkReceiptStatus::from_wire(&expected.wire_value);
            let presentation = status.presentation();
            assert_eq!(status.kind_key(), expected.kind);
            assert_eq!(presentation.label, expected.label);
            assert_eq!(presentation.tone.contract_value(), expected.tone);
            assert_eq!(
                presentation.accessibility_label,
                expected.accessibility_label
            );
        }
        for expected in contract.participants {
            let role = LinkParticipantRole::from_wire(&expected.wire_value);
            let presentation = role.presentation();
            assert_eq!(role.kind_key(), expected.kind);
            assert_eq!(presentation.label, expected.label);
            assert_eq!(presentation.tone.contract_value(), expected.tone);
            assert_eq!(
                presentation.accessibility_label,
                expected.accessibility_label
            );
            assert_eq!(role.is_local_principal(), expected.is_local_principal);
        }
        for expected in contract.host_verifications {
            let state = LinkHostVerificationState::from_verified(expected.verified);
            let presentation = state.presentation();
            assert_eq!(state.kind_key(), expected.kind);
            assert_eq!(presentation.tone.contract_value(), expected.tone);
            assert_eq!(
                presentation.accessibility_label,
                expected.accessibility_label
            );
        }
    }

    #[test]
    fn unknown_statuses_fail_closed_and_linux_keeps_offline_queueing() {
        let unknown_connection = LinkConnectionStatus::from_wire("future-connection");
        assert_eq!(unknown_connection.kind_key(), "unrecognized");
        assert_eq!(
            unknown_connection.presentation().tone,
            LinkSemanticTone::Blocked
        );
        assert!(!unknown_connection.capabilities().can_request_enrollment);
        assert!(!unknown_connection.capabilities().can_queue_message);

        let unknown_discussion = LinkDiscussionStatus::from_wire("future-discussion");
        assert_eq!(
            unknown_discussion.presentation().tone,
            LinkSemanticTone::Warning
        );
        let unknown_receipt = LinkReceiptStatus::from_wire("future-receipt");
        assert_eq!(unknown_receipt.kind_key(), "unrecognized");
        assert_eq!(unknown_receipt.presentation().label, "Outcome uncertain");
        let unknown_participant = LinkParticipantRole::from_wire("future-participant");
        assert!(!unknown_participant.is_local_principal());
        assert_eq!(
            unknown_participant.presentation().tone,
            LinkSemanticTone::Blocked
        );

        assert!(
            LinkConnectionStatus::HostOffline
                .capabilities()
                .can_queue_message
        );
    }

    #[test]
    fn request_uses_canonical_id_and_nested_payload() {
        let request = CoreRequest {
            schema_version: 1,
            request_id: "request-canonical".to_owned(),
            operation: "sendMessage".to_owned(),
            payload: json!({
                "spaceID": "space-one",
                "discussionID": "discussion-main",
                "body": "Hello",
            }),
        };
        let wire = serde_json::to_value(request).unwrap();
        assert_eq!(wire["requestID"], "request-canonical");
        assert!(wire.get("requestId").is_none());
        assert_eq!(wire["operation"], "sendMessage");
        assert_eq!(wire["payload"]["spaceID"], "space-one");

        let enrollment = CoreRequest {
            schema_version: 1,
            request_id: "request-enroll".to_owned(),
            operation: "enroll".to_owned(),
            payload: json!({
                "invite": {"schemaVersion": 1, "inviteID": "invite-one"},
                "displayName": "Collaborator",
            }),
        };
        let wire = serde_json::to_value(enrollment).unwrap();
        assert_eq!(wire["payload"]["invite"]["inviteID"], "invite-one");
        assert_eq!(wire["payload"]["displayName"], "Collaborator");
    }

    #[test]
    fn enrollment_requires_a_bounded_verification_code() {
        let result = json!({"verificationCode": "482 193"});
        assert_eq!(
            enrollment_verification_code(Some(&result)).unwrap(),
            "482 193"
        );
        assert_eq!(
            enrollment_verification_code(Some(&json!({}))).unwrap_err(),
            CoreClientError::Invalid
        );
        assert_eq!(
            enrollment_verification_code(Some(&json!({"verificationCode": "bad\ncode"})))
                .unwrap_err(),
            CoreClientError::Invalid
        );
    }

    #[test]
    fn bounded_reader_drains_but_retains_only_limit() {
        let source = vec![b'x'; 65];
        let output = read_bounded(source.as_slice(), 64).unwrap();
        assert!(output.exceeded);
        assert_eq!(output.bytes.len(), 64);
    }

    #[cfg(unix)]
    #[test]
    fn runner_correlates_response_and_enforces_timeout() {
        let temporary = tempfile::tempdir().unwrap();
        let success = temporary.path().join("success.sh");
        fs::write(
            &success,
            "#!/bin/sh\nIFS= read -r request\nprintf '%s' '{\"schemaVersion\":1,\"requestID\":\"request-test\",\"ok\":true,\"result\":{},\"snapshot\":{\"connection\":\"enrollmentRequired\",\"lastSyncUnixMillis\":null,\"spaces\":[],\"diagnosticCode\":null}}'\n",
        )
        .unwrap();
        fs::set_permissions(&success, fs::Permissions::from_mode(0o700)).unwrap();
        let client = CoreClient::for_test(success, Duration::from_secs(5));
        let response = client
            .request_with_id("snapshot", json!({}), "request-test".to_owned())
            .unwrap();
        assert_eq!(response.snapshot.unwrap().connection, "enrollmentRequired");

        let timeout = temporary.path().join("timeout.sh");
        fs::write(&timeout, "#!/bin/sh\nsleep 1\n").unwrap();
        fs::set_permissions(&timeout, fs::Permissions::from_mode(0o700)).unwrap();
        let client = CoreClient::for_test(timeout, Duration::from_millis(20));
        assert_eq!(
            client
                .request_with_id("snapshot", json!({}), "request-timeout".to_owned())
                .unwrap_err(),
            CoreClientError::TimedOut
        );
    }

    #[cfg(unix)]
    #[test]
    fn runner_rejects_oversized_stdout_and_stderr() {
        let temporary = tempfile::tempdir().unwrap();
        let stdout_overflow = temporary.path().join("stdout-overflow.sh");
        fs::write(
            &stdout_overflow,
            "#!/bin/sh\nIFS= read -r request\ndd if=/dev/zero bs=1024 count=257 2>/dev/null\n",
        )
        .unwrap();
        fs::set_permissions(&stdout_overflow, fs::Permissions::from_mode(0o700)).unwrap();
        let client = CoreClient::for_test(stdout_overflow, Duration::from_secs(5));
        assert_eq!(
            client
                .request_with_id("snapshot", json!({}), "request-stdout".to_owned())
                .unwrap_err(),
            CoreClientError::TooLarge
        );

        let stderr_overflow = temporary.path().join("stderr-overflow.sh");
        fs::write(
            &stderr_overflow,
            "#!/bin/sh\nIFS= read -r request\ndd if=/dev/zero bs=1024 count=17 1>&2 2>/dev/null\nprintf '%s' '{\"schemaVersion\":1,\"requestID\":\"request-stderr\",\"ok\":true,\"result\":{},\"snapshot\":{\"connection\":\"enrollmentRequired\",\"lastSyncUnixMillis\":null,\"spaces\":[],\"diagnosticCode\":null}}'\n",
        )
        .unwrap();
        fs::set_permissions(&stderr_overflow, fs::Permissions::from_mode(0o700)).unwrap();
        let client = CoreClient::for_test(stderr_overflow, Duration::from_secs(5));
        assert_eq!(
            client
                .request_with_id("snapshot", json!({}), "request-stderr".to_owned())
                .unwrap_err(),
            CoreClientError::TooLarge
        );
    }

    #[test]
    fn message_limit_matches_portable_core() {
        assert_eq!(MAXIMUM_MESSAGE_BYTES, 16 * 1024);
        let client = CoreClient::for_test(
            PathBuf::from("/path/that/does/not/exist/kaname-link-client"),
            Duration::from_secs(1),
        );
        let maximum = "x".repeat(MAXIMUM_MESSAGE_BYTES);
        let oversized = "x".repeat(MAXIMUM_MESSAGE_BYTES + 1);
        assert_eq!(
            client
                .send_message("space-one", "discussion-main", &oversized)
                .unwrap_err(),
            CoreClientError::Invalid
        );
        assert_eq!(
            client
                .send_message("space-one", "discussion-main", &maximum)
                .unwrap_err(),
            CoreClientError::Launch
        );
    }
}
