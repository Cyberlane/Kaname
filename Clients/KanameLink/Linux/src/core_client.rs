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

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkMessage {
    pub id: String,
    pub author: String,
    pub author_name: String,
    pub body: String,
    pub receipt: String,
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
                        receipt: "Published result".to_owned(),
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
