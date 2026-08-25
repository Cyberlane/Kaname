use crate::{
    LinkError, Result,
    client::{ClientSnapshot, LinkClient},
    default_state_root,
    gateway::{GatewayStatus, GatewayStore},
    model::{
        DeviceSummary, InviteArtifact, LinkMessage, MAXIMUM_PAGE_SIZE, MAXIMUM_SHELL_REQUEST_BYTES,
        MAXIMUM_SHELL_RESPONSE_BYTES, SCHEMA_VERSION, SpaceSummary, now_unix_millis,
        validate_identifier, validate_schema,
    },
    secret_store::SharedSecretStore,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GatewayAdminRequest {
    pub schema_version: u32,
    #[serde(rename = "requestID", alias = "requestId")]
    pub request_id: String,
    pub operation: String,
    #[serde(default = "empty_payload")]
    pub payload: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ClientShellRequest {
    pub schema_version: u32,
    #[serde(rename = "requestID", alias = "requestId")]
    pub request_id: String,
    pub operation: String,
    #[serde(default = "empty_payload")]
    pub payload: Value,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellResponse {
    pub schema_version: u32,
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ShellError>,
}

#[derive(Debug, Serialize)]
pub struct ShellError {
    pub code: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostShellSnapshot {
    pub schema_version: u32,
    pub status: GatewayStatus,
    pub spaces: Vec<SpaceSummary>,
    pub pending_devices: Vec<DeviceSummary>,
    pub inbox: Vec<LinkMessage>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum ClientUiConnection {
    #[serde(rename = "hostOnline")]
    HostOnline,
    #[serde(rename = "connecting")]
    Connecting,
    #[serde(rename = "hostOffline")]
    HostOffline,
    #[serde(rename = "enrollmentRequired")]
    EnrollmentRequired,
    #[serde(rename = "revoked")]
    Revoked,
    #[serde(rename = "connectionStateUnavailable")]
    Unavailable,
}

impl ClientUiConnection {
    fn from_enrollment_state(state: Option<&str>, connected: bool) -> Self {
        match state {
            None => Self::EnrollmentRequired,
            Some("pending") => Self::Connecting,
            Some("revoked") => Self::Revoked,
            Some("approved") if connected => Self::HostOnline,
            Some("approved") => Self::HostOffline,
            Some(_) => Self::Unavailable,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum ClientUiDiscussionStatus {
    #[serde(rename = "Waiting for host")]
    WaitingForHost,
    #[serde(rename = "Up to date")]
    UpToDate,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum ClientUiParticipant {
    #[serde(rename = "host")]
    Host,
    #[serde(rename = "collaborator")]
    Collaborator,
    #[serde(rename = "unrecognized")]
    Unrecognized,
}

impl ClientUiParticipant {
    fn from_sender(sender: &str) -> Self {
        match sender {
            "host" => Self::Host,
            "collaborator" => Self::Collaborator,
            _ => Self::Unrecognized,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum ClientUiReceipt {
    #[serde(rename = "Received by host")]
    ReceivedByHost,
    #[serde(rename = "Queued on this device")]
    QueuedOnDevice,
    #[serde(rename = "Published by host")]
    PublishedByHost,
    #[serde(rename = "Outcome uncertain")]
    OutcomeUncertain,
}

impl ClientUiReceipt {
    fn from_client_state(state: &str) -> Self {
        match state {
            "hostReceived" => Self::ReceivedByHost,
            "queued" => Self::QueuedOnDevice,
            "hostPublished" => Self::PublishedByHost,
            _ => Self::OutcomeUncertain,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientUiSnapshot {
    pub connection: ClientUiConnection,
    pub last_sync_unix_millis: Option<i64>,
    pub spaces: Vec<ClientUiSpace>,
    pub diagnostic_code: Option<String>,
    pub verification_code: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientUiSpace {
    pub id: String,
    pub name: String,
    pub host_name: String,
    pub verified: bool,
    pub discussions: Vec<ClientUiDiscussion>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientUiDiscussion {
    pub id: String,
    pub title: String,
    pub status: ClientUiDiscussionStatus,
    pub action_label: String,
    pub messages: Vec<ClientUiMessage>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientUiMessage {
    pub id: String,
    pub author: ClientUiParticipant,
    pub author_name: String,
    pub body: String,
    pub sent_at_unix_millis: i64,
    pub receipt: ClientUiReceipt,
}

impl ShellResponse {
    fn success(request_id: String, value: impl Serialize) -> Self {
        match serde_json::to_value(value) {
            Ok(result) => Self {
                schema_version: SCHEMA_VERSION,
                request_id,
                ok: true,
                result: Some(result),
                snapshot: None,
                error_code: None,
                error: None,
            },
            Err(_) => Self::failure(request_id, "response_encoding_failed"),
        }
    }

    fn success_with_snapshot(
        request_id: String,
        result: impl Serialize,
        snapshot: impl Serialize,
    ) -> Self {
        match (serde_json::to_value(result), serde_json::to_value(snapshot)) {
            (Ok(result), Ok(snapshot)) => Self {
                schema_version: SCHEMA_VERSION,
                request_id,
                ok: true,
                result: Some(result),
                snapshot: Some(snapshot),
                error_code: None,
                error: None,
            },
            _ => Self::failure(request_id, "response_encoding_failed"),
        }
    }

    fn failure(request_id: impl Into<String>, code: impl Into<String>) -> Self {
        let code = code.into();
        Self {
            schema_version: SCHEMA_VERSION,
            request_id: request_id.into(),
            ok: false,
            result: None,
            snapshot: None,
            error_code: Some(code.clone()),
            error: Some(ShellError { code }),
        }
    }
}

pub fn execute_gateway_admin(state_root: &Path, request: GatewayAdminRequest) -> ShellResponse {
    let request_id = request.request_id.clone();
    match GatewayStore::open(state_root)
        .and_then(|store| execute_gateway_operation(store, &request))
    {
        Ok(value) => ShellResponse::success(request_id, value),
        Err(error) => ShellResponse::failure(request_id, error.code()),
    }
}

pub fn execute_gateway_admin_with_secret_store(
    state_root: &Path,
    secrets: SharedSecretStore,
    request: GatewayAdminRequest,
) -> ShellResponse {
    let request_id = request.request_id.clone();
    match GatewayStore::open_with_secret_store(state_root, secrets)
        .and_then(|store| execute_gateway_operation(store, &request))
    {
        Ok(value) => ShellResponse::success(request_id, value),
        Err(error) => ShellResponse::failure(request_id, error.code()),
    }
}

fn execute_gateway_operation(
    mut store: GatewayStore,
    request: &GatewayAdminRequest,
) -> Result<Value> {
    validate_shell_request(request.schema_version, &request.request_id)?;
    match request.operation.as_str() {
        "status" => {
            decode_payload::<EmptyPayload>(&request.payload)?;
            Ok(serde_json::to_value(store.status()?)?)
        }
        "spaces" => {
            decode_payload::<EmptyPayload>(&request.payload)?;
            Ok(serde_json::to_value(store.spaces()?)?)
        }
        "hostSnapshot" => {
            decode_payload::<EmptyPayload>(&request.payload)?;
            Ok(serde_json::to_value(host_snapshot(&store)?)?)
        }
        "createInvite" => {
            let payload: CreateInvitePayload = decode_payload(&request.payload)?;
            Ok(serde_json::to_value(store.create_invite(
                &payload.space_id,
                &payload.space_name,
                &payload.gateway_url,
                payload.expires_in_seconds,
            )?)?)
        }
        "pending" => {
            let payload: PendingPayload = decode_payload(&request.payload)?;
            Ok(serde_json::to_value(
                store.pending_devices(payload.space_id.as_deref())?,
            )?)
        }
        "approve" => {
            let payload: DevicePayload = decode_payload(&request.payload)?;
            Ok(serde_json::to_value(
                store.approve_device(&payload.device_id)?,
            )?)
        }
        "deny" | "revoke" => {
            let payload: DevicePayload = decode_payload(&request.payload)?;
            Ok(serde_json::to_value(
                store.revoke_device(&payload.device_id)?,
            )?)
        }
        "inbox" => {
            let payload: InboxPayload = decode_payload(&request.payload)?;
            Ok(serde_json::to_value(store.inbox(
                &payload.space_id,
                payload.after_position,
                payload.limit,
            )?)?)
        }
        "publish" | "send" => {
            let payload: PublishPayload = decode_payload(&request.payload)?;
            let message_id = payload
                .message_id
                .unwrap_or_else(|| format!("message-{}", Uuid::new_v4()));
            Ok(serde_json::to_value(store.send_host_text(
                &payload.space_id,
                &message_id,
                &payload.body,
            )?)?)
        }
        _ => Err(LinkError::Invalid("unknown_operation")),
    }
}

pub fn execute_client_rpc(state_root: &Path, request: ClientShellRequest) -> ShellResponse {
    let request_id = request.request_id.clone();
    match LinkClient::open(state_root).and_then(|client| execute_client_operation(client, &request))
    {
        Ok((result, snapshot)) => {
            ShellResponse::success_with_snapshot(request_id, result, snapshot)
        }
        Err(error) => ShellResponse::failure(request_id, error.code()),
    }
}

pub fn execute_client_rpc_with_secret_store(
    state_root: &Path,
    secrets: SharedSecretStore,
    request: ClientShellRequest,
) -> ShellResponse {
    let request_id = request.request_id.clone();
    match LinkClient::open_with_secret_store(state_root, secrets)
        .and_then(|client| execute_client_operation(client, &request))
    {
        Ok((result, snapshot)) => {
            ShellResponse::success_with_snapshot(request_id, result, snapshot)
        }
        Err(error) => ShellResponse::failure(request_id, error.code()),
    }
}

fn execute_client_operation(
    mut client: LinkClient,
    request: &ClientShellRequest,
) -> Result<(Value, ClientUiSnapshot)> {
    validate_shell_request(request.schema_version, &request.request_id)?;
    match request.operation.as_str() {
        "snapshot" | "uiSnapshot" => {
            decode_payload::<EmptyPayload>(&request.payload)?;
            let before = client.snapshot()?;
            if before.enrolled && before.enrollment_state.as_deref() != Some("revoked") {
                let sync = client.sync()?;
                let snapshot =
                    client_ui_snapshot(&sync.snapshot, sync.connected, sync.last_error.as_deref());
                Ok((json!({ "synced": sync.connected }), snapshot))
            } else {
                let snapshot = client_ui_snapshot(&before, false, None);
                Ok((json!({ "synced": false }), snapshot))
            }
        }
        "enroll" => {
            let payload: EnrollPayload = decode_payload(&request.payload)?;
            let result = client.enroll(&payload.invite, &payload.display_name)?;
            let raw = client.snapshot()?;
            let snapshot = client_ui_snapshot(&raw, false, None);
            Ok((serde_json::to_value(result)?, snapshot))
        }
        "send" | "sendMessage" => {
            let payload: SendMessagePayload = decode_payload(&request.payload)?;
            validate_client_scope(&client.snapshot()?, &payload)?;
            let result = client.send_text(&payload.body, payload.message_id.as_deref())?;
            let raw = client.snapshot()?;
            let snapshot = client_ui_snapshot(&raw, result.connected, result.last_error.as_deref());
            Ok((serde_json::to_value(result)?, snapshot))
        }
        "sync" => {
            decode_payload::<EmptyPayload>(&request.payload)?;
            let result = client.sync()?;
            let snapshot = client_ui_snapshot(
                &result.snapshot,
                result.connected,
                result.last_error.as_deref(),
            );
            Ok((
                json!({
                    "connected": result.connected,
                    "deliveredReceipts": result.delivered_receipts,
                    "lastError": result.last_error,
                }),
                snapshot,
            ))
        }
        _ => Err(LinkError::Invalid("unknown_operation")),
    }
}

fn host_snapshot(store: &GatewayStore) -> Result<HostShellSnapshot> {
    let spaces = store.spaces()?;
    let mut inbox = Vec::new();
    for space in &spaces {
        let remaining = 10_u32.saturating_sub(inbox.len() as u32);
        if remaining == 0 {
            break;
        }
        inbox.extend(store.inbox(&space.space_id, 0, remaining)?);
    }
    Ok(HostShellSnapshot {
        schema_version: SCHEMA_VERSION,
        status: store.status()?,
        spaces,
        pending_devices: store.pending_devices(None)?,
        inbox,
    })
}

fn client_ui_snapshot(
    raw: &ClientSnapshot,
    connected: bool,
    last_error: Option<&str>,
) -> ClientUiSnapshot {
    let connection =
        ClientUiConnection::from_enrollment_state(raw.enrollment_state.as_deref(), connected);
    let spaces = match (&raw.space_id, &raw.space_name) {
        (Some(space_id), Some(space_name)) => {
            let messages = raw
                .timeline_messages
                .iter()
                .map(|message| {
                    let author = ClientUiParticipant::from_sender(&message.sender);
                    ClientUiMessage {
                        id: message.message_id.clone(),
                        author,
                        author_name: match author {
                            ClientUiParticipant::Host => "Host".to_owned(),
                            ClientUiParticipant::Collaborator => raw
                                .display_name
                                .clone()
                                .unwrap_or_else(|| "Collaborator".to_owned()),
                            ClientUiParticipant::Unrecognized => "External participant".to_owned(),
                        },
                        body: message.text.clone(),
                        sent_at_unix_millis: message.sent_at_unix_millis,
                        receipt: ClientUiReceipt::from_client_state(&message.receipt),
                    }
                })
                .collect();
            vec![ClientUiSpace {
                id: space_id.clone(),
                name: space_name.clone(),
                host_name: "Kaname Link host".to_owned(),
                verified: raw.enrollment_state.as_deref() == Some("approved"),
                discussions: vec![ClientUiDiscussion {
                    id: "discussion-main".to_owned(),
                    title: "Shared discussion".to_owned(),
                    status: if raw
                        .queued_messages
                        .iter()
                        .any(|item| item.state == "queued")
                    {
                        ClientUiDiscussionStatus::WaitingForHost
                    } else {
                        ClientUiDiscussionStatus::UpToDate
                    },
                    action_label: "Send message".to_owned(),
                    messages,
                }],
            }]
        }
        _ => Vec::new(),
    };
    ClientUiSnapshot {
        connection,
        last_sync_unix_millis: connected.then(now_unix_millis),
        spaces,
        diagnostic_code: last_error.map(ToOwned::to_owned),
        verification_code: raw.verification_code.clone(),
    }
}

fn validate_client_scope(raw: &ClientSnapshot, payload: &SendMessagePayload) -> Result<()> {
    if payload
        .space_id
        .as_deref()
        .is_some_and(|space_id| raw.space_id.as_deref() != Some(space_id))
        || payload
            .discussion_id
            .as_deref()
            .is_some_and(|discussion_id| discussion_id != "discussion-main")
    {
        return Err(LinkError::Forbidden("space_scope_mismatch"));
    }
    Ok(())
}

pub fn read_gateway_admin_request() -> std::result::Result<GatewayAdminRequest, Box<ShellResponse>>
{
    read_shell_request()
}

pub fn read_client_shell_request() -> std::result::Result<ClientShellRequest, Box<ShellResponse>> {
    read_shell_request()
}

pub fn write_shell_response(response: &ShellResponse) -> Result<()> {
    let mut output = std::io::stdout().lock();
    let wire = bounded_shell_response_wire(response)?;
    output.write_all(&wire)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}

fn bounded_shell_response_wire(response: &ShellResponse) -> Result<Vec<u8>> {
    let mut wire = serde_json::to_vec(response)?;
    if wire.len() > MAXIMUM_SHELL_RESPONSE_BYTES {
        wire = serde_json::to_vec(&ShellResponse::failure(
            response.request_id.clone(),
            "response_bounds",
        ))?;
    }
    Ok(wire)
}

pub fn default_gateway_state_root() -> Result<PathBuf> {
    default_state_root("gateway")
}

pub fn default_client_state_root() -> Result<PathBuf> {
    default_state_root("client")
}

pub fn state_root_override(arguments: &[String]) -> Result<Option<PathBuf>> {
    let Some(index) = arguments
        .iter()
        .position(|argument| argument == "--state-root")
    else {
        return Ok(None);
    };
    let value = arguments
        .get(index + 1)
        .filter(|value| !value.is_empty())
        .ok_or(LinkError::Invalid("missing_argument"))?;
    Ok(Some(PathBuf::from(value)))
}

fn read_shell_request<T: DeserializeOwned>() -> std::result::Result<T, Box<ShellResponse>> {
    let mut input = Vec::new();
    let read_result = std::io::stdin()
        .lock()
        .take((MAXIMUM_SHELL_REQUEST_BYTES + 1) as u64)
        .read_to_end(&mut input);
    if read_result.is_err() || input.is_empty() || input.len() > MAXIMUM_SHELL_REQUEST_BYTES {
        return Err(Box::new(ShellResponse::failure(
            "invalid",
            "request_bounds",
        )));
    }
    serde_json::from_slice(&input)
        .map_err(|_| Box::new(ShellResponse::failure("invalid", "invalid_json")))
}

fn validate_shell_request(schema_version: u32, request_id: &str) -> Result<()> {
    validate_schema(schema_version)?;
    validate_identifier(request_id, "invalid_request_id")
}

fn decode_payload<T: DeserializeOwned>(payload: &Value) -> Result<T> {
    serde_json::from_value(payload.clone()).map_err(|_| LinkError::Invalid("invalid_payload"))
}

fn empty_payload() -> Value {
    json!({})
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EmptyPayload {}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateInvitePayload {
    #[serde(rename = "spaceID", alias = "spaceId")]
    space_id: String,
    space_name: String,
    gateway_url: String,
    expires_in_seconds: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PendingPayload {
    #[serde(default)]
    #[serde(rename = "spaceID", alias = "spaceId")]
    space_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DevicePayload {
    #[serde(rename = "deviceID", alias = "deviceId")]
    device_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InboxPayload {
    #[serde(rename = "spaceID", alias = "spaceId")]
    space_id: String,
    #[serde(default)]
    after_position: u64,
    #[serde(default = "default_page_size")]
    limit: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishPayload {
    #[serde(rename = "spaceID", alias = "spaceId")]
    space_id: String,
    body: String,
    #[serde(default)]
    #[serde(rename = "messageID", alias = "messageId")]
    message_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EnrollPayload {
    invite: InviteArtifact,
    display_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SendMessagePayload {
    #[serde(default)]
    #[serde(rename = "spaceID", alias = "spaceId")]
    space_id: Option<String>,
    #[serde(default)]
    #[serde(rename = "discussionID", alias = "discussionId")]
    discussion_id: Option<String>,
    #[serde(alias = "text")]
    body: String,
    #[serde(default)]
    #[serde(rename = "messageID", alias = "messageId")]
    message_id: Option<String>,
}

const fn default_page_size() -> u32 {
    if MAXIMUM_PAGE_SIZE < 50 {
        MAXIMUM_PAGE_SIZE
    } else {
        50
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_shell_response_becomes_bounded_correlated_failure() {
        let response = ShellResponse::success(
            "request-bounded-response".to_owned(),
            "x".repeat(MAXIMUM_SHELL_RESPONSE_BYTES + 1),
        );
        let wire = bounded_shell_response_wire(&response).unwrap();
        assert!(wire.len() <= MAXIMUM_SHELL_RESPONSE_BYTES);
        let decoded: Value = serde_json::from_slice(&wire).unwrap();
        assert_eq!(decoded["requestID"], "request-bounded-response");
        assert_eq!(decoded["ok"], false);
        assert_eq!(decoded["errorCode"], "response_bounds");
    }

    #[test]
    fn client_ui_status_types_preserve_schema_v1_wire_values() {
        let connections = [
            (ClientUiConnection::HostOnline, "hostOnline"),
            (ClientUiConnection::Connecting, "connecting"),
            (ClientUiConnection::HostOffline, "hostOffline"),
            (ClientUiConnection::EnrollmentRequired, "enrollmentRequired"),
            (ClientUiConnection::Revoked, "revoked"),
        ];
        for (value, expected) in connections {
            assert_eq!(serde_json::to_value(value).unwrap(), json!(expected));
        }

        let discussions = [
            (ClientUiDiscussionStatus::WaitingForHost, "Waiting for host"),
            (ClientUiDiscussionStatus::UpToDate, "Up to date"),
        ];
        for (value, expected) in discussions {
            assert_eq!(serde_json::to_value(value).unwrap(), json!(expected));
        }

        let receipts = [
            (ClientUiReceipt::ReceivedByHost, "Received by host"),
            (ClientUiReceipt::QueuedOnDevice, "Queued on this device"),
            (ClientUiReceipt::PublishedByHost, "Published by host"),
        ];
        for (value, expected) in receipts {
            assert_eq!(serde_json::to_value(value).unwrap(), json!(expected));
        }

        assert_eq!(
            serde_json::to_value(ClientUiParticipant::Host).unwrap(),
            json!("host")
        );
        assert_eq!(
            serde_json::to_value(ClientUiParticipant::Collaborator).unwrap(),
            json!("collaborator")
        );
    }

    #[test]
    fn client_ui_unknown_source_states_fail_closed() {
        assert_eq!(
            ClientUiConnection::from_enrollment_state(Some("future-state"), true),
            ClientUiConnection::Unavailable
        );
        assert_eq!(
            ClientUiParticipant::from_sender("future-participant"),
            ClientUiParticipant::Unrecognized
        );
        assert_eq!(
            ClientUiReceipt::from_client_state("future-receipt"),
            ClientUiReceipt::OutcomeUncertain
        );
        assert_eq!(
            serde_json::to_value(ClientUiConnection::Unavailable).unwrap(),
            json!("connectionStateUnavailable")
        );
        assert_eq!(
            serde_json::to_value(ClientUiReceipt::OutcomeUncertain).unwrap(),
            json!("Outcome uncertain")
        );
    }
}
