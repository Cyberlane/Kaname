use crate::{LinkError, Result};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SCHEMA_VERSION: u32 = 1;
pub const MAXIMUM_SHELL_REQUEST_BYTES: usize = 64 * 1024;
pub const MAXIMUM_SHELL_RESPONSE_BYTES: usize = 256 * 1024;
pub const MAXIMUM_HTTP_REQUEST_BYTES: usize = 96 * 1024;
pub const MAXIMUM_HTTP_RESPONSE_BYTES: usize = 96 * 1024;
pub const MAXIMUM_NOISE_MESSAGE_BYTES: usize = 65_535;
pub const MAXIMUM_NOISE_PAYLOAD_BYTES: usize = 48 * 1024;
pub const MAXIMUM_TEXT_BYTES: usize = 16 * 1024;
pub const MAXIMUM_NAME_BYTES: usize = 128;
pub const MAXIMUM_IDENTIFIER_BYTES: usize = 128;
pub const MAXIMUM_PAGE_SIZE: u32 = 100;
pub const MAXIMUM_SYNC_PAGE_SIZE: u32 = 2;
pub const MAXIMUM_INVITE_LIFETIME_SECONDS: u64 = 7 * 24 * 60 * 60;
pub const MINIMUM_INVITE_LIFETIME_SECONDS: u64 = 60;
pub const MAXIMUM_CLOCK_SKEW_MILLIS: i64 = 5 * 60 * 1_000;

pub fn now_unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(i64::MAX)
}

pub fn validate_schema(version: u32) -> Result<()> {
    if version != SCHEMA_VERSION {
        return Err(LinkError::Invalid("unsupported_schema_version"));
    }
    Ok(())
}

pub fn validate_identifier(value: &str, code: &'static str) -> Result<()> {
    let valid = !value.is_empty()
        && value.len() <= MAXIMUM_IDENTIFIER_BYTES
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte));
    if !valid {
        return Err(LinkError::Invalid(code));
    }
    Ok(())
}

pub fn validate_name(value: &str, code: &'static str) -> Result<()> {
    if value.trim() != value
        || value.is_empty()
        || value.len() > MAXIMUM_NAME_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(LinkError::Invalid(code));
    }
    Ok(())
}

pub fn validate_text(value: &str) -> Result<()> {
    if value.trim() != value
        || value.is_empty()
        || value.len() > MAXIMUM_TEXT_BYTES
        || value.contains('\0')
    {
        return Err(LinkError::Invalid("invalid_text"));
    }
    Ok(())
}

pub fn validate_gateway_url(value: &str) -> Result<()> {
    let parsed =
        reqwest::Url::parse(value).map_err(|_| LinkError::Invalid("invalid_gateway_url"))?;
    if parsed.username() != ""
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || (parsed.path() != "" && parsed.path() != "/")
    {
        return Err(LinkError::Invalid("invalid_gateway_url"));
    }
    let secure = parsed.scheme() == "https";
    let loopback_http = parsed.scheme() == "http"
        && parsed.host_str().is_some_and(|host| {
            host.eq_ignore_ascii_case("localhost")
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|address| address.is_loopback())
        });
    if !secure && !loopback_http {
        return Err(LinkError::Invalid("insecure_gateway_url"));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InviteArtifact {
    pub schema_version: u32,
    pub invite_id: String,
    pub space_id: String,
    pub space_name: String,
    pub gateway_url: String,
    pub host_static_public_key: String,
    pub invite_secret: String,
    pub expires_at_unix_millis: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentPayload {
    pub schema_version: u32,
    pub enrollment_id: String,
    pub device_id: String,
    pub display_name: String,
    pub space_id: String,
    pub created_at_unix_millis: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentReply {
    pub schema_version: u32,
    pub enrollment_id: String,
    pub device_id: String,
    pub state: String,
    pub host_key_fingerprint: String,
    pub verification_code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentHttpRequest {
    pub schema_version: u32,
    pub invite_id: String,
    pub noise_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NoiseHttpRequest {
    pub schema_version: u32,
    pub noise_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NoiseHttpResponse {
    pub schema_version: u32,
    pub noise_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RpcRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub device_id: String,
    pub space_id: String,
    pub issued_at_unix_millis: i64,
    pub operation: RpcOperation,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum RpcOperation {
    SendText {
        message_id: String,
        text: String,
        queued_at_unix_millis: i64,
    },
    Sync {
        after_position: u64,
        limit: u32,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RpcResponse {
    pub schema_version: u32,
    pub request_id: String,
    pub result: RpcResult,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum RpcResult {
    SendText {
        receipt: MessageReceipt,
    },
    Sync {
        messages: Vec<LinkMessage>,
        next_position: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MessageReceipt {
    pub message_id: String,
    pub state: String,
    pub queued_at_unix_millis: i64,
    pub host_received_at_unix_millis: Option<i64>,
    pub position: Option<u64>,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinkMessage {
    pub position: u64,
    pub message_id: String,
    pub space_id: String,
    pub sender: String,
    pub text: String,
    pub queued_at_unix_millis: i64,
    pub host_received_at_unix_millis: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub device_id: String,
    pub display_name: String,
    pub space_id: String,
    pub state: String,
    pub verification_code: String,
    pub created_at_unix_millis: i64,
    pub approved_at_unix_millis: Option<i64>,
    pub revoked_at_unix_millis: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SpaceSummary {
    pub space_id: String,
    pub name: String,
    pub device_count: u64,
    pub message_count: u64,
}
