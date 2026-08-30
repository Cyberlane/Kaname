use crate::{
    LinkError, Result,
    gateway::GatewayStore,
    model::{
        EnrollmentHttpRequest, EnrollmentPayload, EnrollmentReply, MAXIMUM_HTTP_REQUEST_BYTES,
        MAXIMUM_NOISE_MESSAGE_BYTES, NoiseHttpRequest, NoiseHttpResponse, RpcRequest,
        SCHEMA_VERSION, SessionRejection, SessionReply, SessionReplyEnvelope, now_unix_millis,
        validate_schema,
    },
    noise::{
        decode_bytes, encode_bytes, enrollment_responder, key_fingerprint, read_handshake_message,
        remote_static, session_responder, verification_code, write_handshake_message,
    },
    secret_store::{SharedSecretStore, production_secret_store},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Serialize;
use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
};
use tokio::{net::TcpListener, sync::oneshot, task::JoinHandle};

#[derive(Clone)]
struct GatewayHttpState {
    state_root: PathBuf,
    secrets: SharedSecretStore,
}

pub struct RunningGateway {
    pub address: SocketAddr,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<std::io::Result<()>>,
}

impl RunningGateway {
    pub async fn shutdown(mut self) -> Result<()> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))??;
        Ok(())
    }
}

pub async fn spawn_gateway(
    state_root: impl AsRef<Path>,
    bind: SocketAddr,
) -> Result<RunningGateway> {
    spawn_gateway_with_secret_store(state_root, bind, production_secret_store()?).await
}

pub async fn spawn_gateway_with_secret_store(
    state_root: impl AsRef<Path>,
    bind: SocketAddr,
    secrets: SharedSecretStore,
) -> Result<RunningGateway> {
    require_loopback(bind)?;
    GatewayStore::open_with_secret_store(state_root.as_ref(), secrets.clone())?;
    let listener = TcpListener::bind(bind).await?;
    let address = listener.local_addr()?;
    let router = router(state_root.as_ref().to_owned(), secrets);
    let (shutdown_sender, shutdown_receiver) = oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                let _ = shutdown_receiver.await;
            })
            .await
    });
    Ok(RunningGateway {
        address,
        shutdown: Some(shutdown_sender),
        task,
    })
}

pub async fn serve_gateway(state_root: impl AsRef<Path>, bind: SocketAddr) -> Result<()> {
    require_loopback(bind)?;
    let secrets = production_secret_store()?;
    GatewayStore::open_with_secret_store(state_root.as_ref(), secrets.clone())?;
    let listener = TcpListener::bind(bind).await?;
    axum::serve(listener, router(state_root.as_ref().to_owned(), secrets)).await?;
    Ok(())
}

fn router(state_root: PathBuf, secrets: SharedSecretStore) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/enroll", post(enroll))
        .route("/v1/rpc", post(rpc))
        .layer(DefaultBodyLimit::max(MAXIMUM_HTTP_REQUEST_BYTES))
        .with_state(GatewayHttpState {
            state_root,
            secrets,
        })
}

async fn health() -> impl IntoResponse {
    StatusCode::NO_CONTENT
}

async fn enroll(
    State(state): State<GatewayHttpState>,
    Json(request): Json<EnrollmentHttpRequest>,
) -> std::result::Result<Json<NoiseHttpResponse>, ApiError> {
    let result = (|| -> Result<NoiseHttpResponse> {
        validate_schema(request.schema_version)?;
        let now = now_unix_millis();
        let mut store =
            GatewayStore::open_with_secret_store(&state.state_root, state.secrets.clone())?;
        let invite = store.active_invite(&request.invite_id, now)?;
        let host = store.host_keypair()?;
        let first = decode_bytes(
            &request.noise_message,
            MAXIMUM_NOISE_MESSAGE_BYTES,
            "invalid_noise_message",
        )?;
        let mut noise = enrollment_responder(&host.private, &invite.secret)?;
        let payload_wire = read_handshake_message(&mut noise, &first)?;
        let client_static = remote_static(&noise)?;
        let payload: EnrollmentPayload = serde_json::from_slice(&payload_wire)?;
        let reply = EnrollmentReply {
            schema_version: SCHEMA_VERSION,
            enrollment_id: payload.enrollment_id.clone(),
            device_id: payload.device_id.clone(),
            state: "pending".to_owned(),
            host_key_fingerprint: key_fingerprint(&host.public)?,
            verification_code: verification_code(&client_static)?,
        };
        let second = write_handshake_message(&mut noise, &serde_json::to_vec(&reply)?)?;
        store.admit_pending_device(&invite, &payload, &client_static, now)?;
        Ok(NoiseHttpResponse {
            schema_version: SCHEMA_VERSION,
            noise_message: encode_bytes(&second),
        })
    })();
    result.map(Json).map_err(ApiError::enrollment)
}

async fn rpc(
    State(state): State<GatewayHttpState>,
    Json(request): Json<NoiseHttpRequest>,
) -> std::result::Result<Json<NoiseHttpResponse>, ApiError> {
    let result = (|| -> Result<NoiseHttpResponse> {
        validate_schema(request.schema_version)?;
        let mut store =
            GatewayStore::open_with_secret_store(&state.state_root, state.secrets.clone())?;
        let host = store.host_keypair()?;
        let first = decode_bytes(
            &request.noise_message,
            MAXIMUM_NOISE_MESSAGE_BYTES,
            "invalid_noise_message",
        )?;
        let mut noise = session_responder(&host.private)?;
        let request_wire = read_handshake_message(&mut noise, &first)?;
        let client_static = remote_static(&noise)?;
        let device = store.device_for_static(&client_static)?;
        let response = (|| -> Result<_> {
            device.require_approved_session()?;
            let rpc_request: RpcRequest = serde_json::from_slice(&request_wire)?;
            store.handle_rpc(&device, &rpc_request, now_unix_millis())
        })();
        let reply = match response {
            Ok(response) => SessionReply::RpcResponse { response },
            Err(LinkError::DeviceRevoked) => SessionReply::Rejection {
                code: SessionRejection::DeviceRevoked,
            },
            Err(error) => return Err(error),
        };
        let envelope = SessionReplyEnvelope {
            schema_version: SCHEMA_VERSION,
            reply,
        };
        let second = write_handshake_message(&mut noise, &serde_json::to_vec(&envelope)?)?;
        Ok(NoiseHttpResponse {
            schema_version: SCHEMA_VERSION,
            noise_message: encode_bytes(&second),
        })
    })();
    result.map(Json).map_err(ApiError::session)
}

fn require_loopback(bind: SocketAddr) -> Result<()> {
    if !bind.ip().is_loopback() {
        return Err(LinkError::Forbidden("gateway_must_bind_loopback"));
    }
    Ok(())
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
}

impl ApiError {
    fn enrollment(error: LinkError) -> Self {
        let status = match error {
            LinkError::Invalid(_) | LinkError::Json(_) => StatusCode::BAD_REQUEST,
            LinkError::Conflict(_) => StatusCode::CONFLICT,
            LinkError::Io(_) | LinkError::Sql(_) | LinkError::Unavailable(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
            _ => StatusCode::FORBIDDEN,
        };
        Self {
            status,
            code: if status.is_server_error() {
                "gateway_failure"
            } else {
                "enrollment_rejected"
            },
        }
    }

    fn session(error: LinkError) -> Self {
        let status = match error {
            LinkError::Invalid(_) | LinkError::Json(_) => StatusCode::BAD_REQUEST,
            LinkError::Conflict(_) => StatusCode::CONFLICT,
            LinkError::Io(_) | LinkError::Sql(_) | LinkError::Unavailable(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
            _ => StatusCode::FORBIDDEN,
        };
        Self {
            status,
            code: if status.is_server_error() {
                "gateway_failure"
            } else {
                "session_rejected"
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApiErrorBody {
    schema_version: u32,
    error: ApiErrorDetail,
}

#[derive(Serialize)]
struct ApiErrorDetail {
    code: &'static str,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(ApiErrorBody {
                schema_version: SCHEMA_VERSION,
                error: ApiErrorDetail { code: self.code },
            }),
        )
            .into_response()
    }
}
