use kaname_link_core::{
    LinkError, Result,
    client::LinkClient,
    gateway::GatewayStore,
    model::{
        EnrollmentPayload, InviteArtifact, MAXIMUM_CLOCK_SKEW_MILLIS, MAXIMUM_HTTP_RESPONSE_BYTES,
        MAXIMUM_NOISE_MESSAGE_BYTES, NoiseHttpRequest, NoiseHttpResponse, RpcOperation, RpcRequest,
        SCHEMA_VERSION, now_unix_millis,
    },
    noise::{
        decode_bytes, encode_bytes, generate_invite_secret, generate_static_keypair,
        read_handshake_message, session_responder, write_handshake_message,
    },
    secret_store::{SecretStore, SharedSecretStore, state_secret_reference},
    server::spawn_gateway_with_secret_store,
    shell::{ClientShellRequest, execute_client_rpc_with_secret_store},
};
use rusqlite::{Connection, params};
use serde_json::json;
use std::{
    collections::HashMap,
    io::{Read, Write},
    net::{SocketAddr, TcpListener},
    path::Path,
    sync::{Arc, Mutex},
    thread,
};
use tempfile::tempdir;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[derive(Default)]
struct TestSecretState {
    values: HashMap<String, Vec<u8>>,
    fail_put: bool,
    fail_get: bool,
    fail_delete: bool,
    successful_deletes: HashMap<String, usize>,
}

#[derive(Default)]
struct TestSecretStore {
    state: Mutex<TestSecretState>,
}

impl TestSecretStore {
    fn shared() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn as_shared(self: &Arc<Self>) -> SharedSecretStore {
        self.clone()
    }

    fn set_fail_put(&self, value: bool) {
        self.state.lock().unwrap().fail_put = value;
    }

    fn set_fail_delete(&self, value: bool) {
        self.state.lock().unwrap().fail_delete = value;
    }

    fn references(&self) -> Vec<String> {
        self.state.lock().unwrap().values.keys().cloned().collect()
    }

    fn entries(&self) -> Vec<(String, Vec<u8>)> {
        self.state
            .lock()
            .unwrap()
            .values
            .iter()
            .map(|(reference, secret)| (reference.clone(), secret.clone()))
            .collect()
    }

    fn successful_delete_count(&self, reference: &str) -> usize {
        self.state
            .lock()
            .unwrap()
            .successful_deletes
            .get(reference)
            .copied()
            .unwrap_or(0)
    }
}

impl SecretStore for TestSecretStore {
    fn put(&self, reference: &str, secret: &[u8]) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.fail_put {
            return Err(LinkError::Unavailable("test_secret_put_failed"));
        }
        state.values.insert(reference.to_owned(), secret.to_vec());
        Ok(())
    }

    fn get(&self, reference: &str) -> Result<Vec<u8>> {
        let state = self.state.lock().unwrap();
        if state.fail_get {
            return Err(LinkError::Unavailable("test_secret_get_failed"));
        }
        state
            .values
            .get(reference)
            .cloned()
            .ok_or(LinkError::Unavailable("test_secret_missing"))
    }

    fn delete(&self, reference: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if state.fail_delete {
            return Err(LinkError::Unavailable("test_secret_delete_failed"));
        }
        state.values.remove(reference);
        *state
            .successful_deletes
            .entry(reference.to_owned())
            .or_insert(0) += 1;
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn encrypted_local_lifecycle_is_scoped_idempotent_and_revocable() {
    let temporary = tempdir().unwrap();
    let gateway_root = temporary.path().join("gateway-state");
    let client_root = temporary.path().join("client-state");
    let replay_client_root = temporary.path().join("replay-client-state");
    let denied_client_root = temporary.path().join("denied-client-state");
    let secrets = TestSecretStore::shared();
    let gateway = spawn_gateway_with_secret_store(
        &gateway_root,
        "127.0.0.1:0".parse().unwrap(),
        secrets.as_shared(),
    )
    .await
    .unwrap();
    let gateway_url = format!("http://{}", gateway.address);
    let invite = GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared())
        .unwrap()
        .create_invite("space-pilot", "Pilot space", &gateway_url, 3_600)
        .unwrap();

    let workflow_gateway_root = gateway_root.clone();
    let workflow_client_root = client_root.clone();
    let workflow_replay_root = replay_client_root.clone();
    let workflow_denied_root = denied_client_root.clone();
    let workflow_secrets = secrets.clone();
    tokio::task::spawn_blocking(move || {
        assert_secure_database_shape(&workflow_gateway_root, "kaname-link-gateway.sqlite3");
        assert_secret_values_absent_from_database(
            &workflow_gateway_root.join("kaname-link-gateway.sqlite3"),
            &workflow_secrets,
        );

        let mut client =
            LinkClient::open_with_secret_store(&workflow_client_root, workflow_secrets.as_shared())
                .unwrap();
        let enrollment = client.enroll(&invite, "External collaborator").unwrap();
        assert_eq!(enrollment.state, "pending");
        assert_eq!(
            client.snapshot().unwrap().enrollment_state.as_deref(),
            Some("pending")
        );
        assert!(
            workflow_secrets
                .references()
                .iter()
                .all(|reference| !reference.contains(":invite-")),
            "the single-use invite PSK must be removed after enrollment"
        );
        assert_secret_values_absent_from_database(
            &workflow_client_root.join("kaname-link-client.sqlite3"),
            &workflow_secrets,
        );

        let queued = client
            .send_text("Pending devices cannot send yet.", Some("message-pending"))
            .unwrap();
        assert!(!queued.connected);
        assert_eq!(queued.receipt.state, "queued");
        assert_eq!(queued.last_error.as_deref(), Some("session_rejected"));
        assert_eq!(
            client.snapshot().unwrap().enrollment_state.as_deref(),
            Some("pending")
        );

        let mut admin = GatewayStore::open_with_secret_store(
            &workflow_gateway_root,
            workflow_secrets.as_shared(),
        )
        .unwrap();
        let pending = admin.pending_devices(Some("space-pilot")).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].device_id, enrollment.device_id);
        assert_eq!(pending[0].verification_code, enrollment.verification_code);
        assert_eq!(enrollment.verification_code.len(), 24);
        assert!(
            enrollment
                .verification_code
                .bytes()
                .enumerate()
                .all(|(index, byte)| if [4, 9, 14, 19].contains(&index) {
                    byte == b'-'
                } else {
                    byte.is_ascii_hexdigit() && !byte.is_ascii_lowercase()
                })
        );
        admin.approve_device(&enrollment.device_id).unwrap();

        let first_sync = client.sync().unwrap();
        assert!(first_sync.connected);
        assert_eq!(first_sync.delivered_receipts.len(), 1);
        let receipt = &first_sync.delivered_receipts[0];
        assert_eq!(receipt.message_id, "message-pending");
        assert_eq!(receipt.state, "hostReceived");
        assert!(receipt.host_received_at_unix_millis.is_some());
        assert!(receipt.position.is_some());
        let inbox = admin.inbox("space-pilot", 0, 100).unwrap();
        assert_eq!(inbox.len(), 1);
        assert_eq!(inbox[0].text, "Pending devices cannot send yet.");

        let client_database = workflow_client_root.join("kaname-link-client.sqlite3");
        Connection::open(&client_database)
            .unwrap()
            .execute(
                "UPDATE outbox SET state = 'queued', host_received_at_unix_millis = NULL,
                        host_position = NULL WHERE message_id = 'message-pending'",
                [],
            )
            .unwrap();
        let replay = client.sync().unwrap();
        assert!(replay.connected);
        assert_eq!(replay.delivered_receipts.len(), 1);
        assert_eq!(
            admin.inbox("space-pilot", 0, 100).unwrap().len(),
            1,
            "an exact request replay must return the stored receipt without duplicating the message"
        );

        let duplicate = client
            .send_text("Pending devices cannot send yet.", Some("message-pending"))
            .unwrap();
        assert!(duplicate.receipt.duplicate);
        assert_eq!(duplicate.receipt.state, "hostReceived");

        admin
            .send_host_text("space-pilot", "message-host", "Approved reply")
            .unwrap();
        let host_sync = client.sync().unwrap();
        assert!(host_sync.connected);
        assert!(host_sync.snapshot.received_messages.iter().any(|message| {
            message.message_id == "message-host" && message.text == "Approved reply"
        }));

        let client_secret_reference = workflow_secrets
            .references()
            .into_iter()
            .find(|reference| reference.starts_with("client:"))
            .expect("the approved client must retain its static private key");
        let client_static_public: Vec<u8> = Connection::open(&client_database)
            .unwrap()
            .query_row(
                "SELECT client_static_public FROM client_identity WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let gateway_database = workflow_gateway_root.join("kaname-link-gateway.sqlite3");
        assert_eq!(
            Connection::open(&gateway_database)
                .unwrap()
                .execute(
                    "UPDATE devices SET static_public = ?1 WHERE device_id = ?2",
                    params![vec![0_u8; 32], enrollment.device_id],
                )
                .unwrap(),
            1
        );
        let unknown_device = client.sync().unwrap();
        assert!(!unknown_device.connected);
        assert_eq!(
            unknown_device.last_error.as_deref(),
            Some("session_rejected")
        );
        assert_eq!(
            unknown_device.snapshot.enrollment_state.as_deref(),
            Some("approved")
        );
        assert!(
            workflow_secrets
                .references()
                .contains(&client_secret_reference),
            "an unknown-device rejection is not authenticated revocation"
        );
        assert_eq!(
            workflow_secrets.successful_delete_count(&client_secret_reference),
            0
        );
        Connection::open(&gateway_database)
            .unwrap()
            .execute(
                "UPDATE devices SET static_public = ?1 WHERE device_id = ?2",
                params![client_static_public, enrollment.device_id],
            )
            .unwrap();
        assert!(client.sync().unwrap().connected);

        let references_before_replay = workflow_secrets.references();
        let mut replay_client =
            LinkClient::open_with_secret_store(&workflow_replay_root, workflow_secrets.as_shared())
                .unwrap();
        let replay_error = replay_client.enroll(&invite, "Replay device").unwrap_err();
        assert_eq!(replay_error.code(), "enrollment_rejected");
        assert_eq!(workflow_secrets.references(), references_before_replay);

        admin.revoke_device(&enrollment.device_id).unwrap();
        let revoked_send = client
            .send_text("This must remain local.", Some("message-revoked"))
            .unwrap();
        assert!(!revoked_send.connected);
        assert_eq!(revoked_send.receipt.state, "queued");
        assert_eq!(revoked_send.last_error.as_deref(), Some("device_revoked"));
        assert_eq!(
            client.snapshot().unwrap().enrollment_state.as_deref(),
            Some("revoked")
        );
        assert!(
            workflow_secrets
                .references()
                .iter()
                .all(|reference| !reference.starts_with("client:")),
            "revocation must delete the client's static private key"
        );
        assert_eq!(
            workflow_secrets.successful_delete_count(&client_secret_reference),
            1
        );
        let revoked_retry = client.sync().unwrap();
        assert!(!revoked_retry.connected);
        assert_eq!(
            revoked_retry.last_error.as_deref(),
            Some("client_key_unavailable")
        );
        assert_eq!(
            workflow_secrets.successful_delete_count(&client_secret_reference),
            1,
            "authenticated revocation must destroy the key exactly once"
        );
        assert_eq!(admin.inbox("space-pilot", 0, 100).unwrap().len(), 1);

        let denied_invite = admin
            .create_invite("space-pilot", "Pilot space", &invite.gateway_url, 3_600)
            .unwrap();
        let mut denied_client =
            LinkClient::open_with_secret_store(&workflow_denied_root, workflow_secrets.as_shared())
                .unwrap();
        let denied_enrollment = denied_client
            .enroll(&denied_invite, "Denied collaborator")
            .unwrap();
        let denied_private_reference = state_secret_reference(
            &workflow_denied_root,
            "client",
            &format!("device-{}-static-v1", denied_enrollment.device_id),
        )
        .unwrap();
        let denied_queued = denied_client
            .send_text(
                "Host denial must leave this queued.",
                Some("message-denied-pending"),
            )
            .unwrap();
        assert!(!denied_queued.connected);
        assert_eq!(denied_queued.receipt.state, "queued");
        assert_eq!(
            denied_queued.last_error.as_deref(),
            Some("session_rejected")
        );
        assert_eq!(
            denied_client
                .snapshot()
                .unwrap()
                .enrollment_state
                .as_deref(),
            Some("pending")
        );
        assert!(
            workflow_secrets
                .references()
                .contains(&denied_private_reference)
        );
        assert_eq!(
            workflow_secrets.successful_delete_count(&denied_private_reference),
            0
        );

        admin.revoke_device(&denied_enrollment.device_id).unwrap();
        let denied_sync = denied_client.sync().unwrap();
        assert!(!denied_sync.connected);
        assert_eq!(denied_sync.last_error.as_deref(), Some("device_revoked"));
        assert_eq!(
            denied_sync.snapshot.enrollment_state.as_deref(),
            Some("revoked")
        );
        assert!(denied_sync.snapshot.queued_messages.iter().any(|receipt| {
            receipt.message_id == "message-denied-pending" && receipt.state == "queued"
        }));
        assert!(
            !workflow_secrets
                .references()
                .contains(&denied_private_reference)
        );
        assert_eq!(
            workflow_secrets.successful_delete_count(&denied_private_reference),
            1
        );

        let denied_retry = denied_client.sync().unwrap();
        assert!(!denied_retry.connected);
        assert_eq!(
            denied_retry.last_error.as_deref(),
            Some("client_key_unavailable")
        );
        assert!(denied_retry.snapshot.queued_messages.iter().any(|receipt| {
            receipt.message_id == "message-denied-pending" && receipt.state == "queued"
        }));
        assert_eq!(
            workflow_secrets.successful_delete_count(&denied_private_reference),
            1,
            "authenticated denial must destroy the pending key exactly once"
        );
        assert_eq!(admin.inbox("space-pilot", 0, 100).unwrap().len(), 1);

        assert_secure_database_shape(&workflow_client_root, "kaname-link-client.sqlite3");
        assert_secure_database_shape(&workflow_denied_root, "kaname-link-client.sqlite3");
    })
    .await
    .unwrap();

    gateway.shutdown().await.unwrap();
}

#[test]
fn secret_store_failures_and_invite_cleanup_are_fail_closed() {
    let temporary = tempdir().unwrap();
    let unavailable_root = temporary.path().join("unavailable-gateway");
    let unavailable = TestSecretStore::shared();
    unavailable.set_fail_put(true);
    let error = GatewayStore::open_with_secret_store(&unavailable_root, unavailable.as_shared())
        .err()
        .expect("the gateway must reject a missing secret backend");
    assert_eq!(error.code(), "test_secret_put_failed");
    let identity_count: i64 =
        Connection::open(unavailable_root.join("kaname-link-gateway.sqlite3"))
            .unwrap()
            .query_row("SELECT COUNT(*) FROM gateway_identity", [], |row| {
                row.get(0)
            })
            .unwrap();
    assert_eq!(identity_count, 0);

    let gateway_root = temporary.path().join("gateway");
    let secrets = TestSecretStore::shared();
    let mut store =
        GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared()).unwrap();
    store
        .create_invite(
            "space-cleanup",
            "Cleanup space",
            "http://127.0.0.1:12345",
            3_600,
        )
        .unwrap();
    let references_before_conflict = secrets.references();
    let conflict = store
        .create_invite(
            "space-cleanup",
            "Different name",
            "http://127.0.0.1:12345",
            3_600,
        )
        .unwrap_err();
    assert_eq!(conflict.code(), "space_name_mismatch");
    assert_eq!(secrets.references(), references_before_conflict);

    let invite = store
        .create_invite(
            "space-consume",
            "Consume space",
            "http://127.0.0.1:12345",
            3_600,
        )
        .unwrap();
    let active = store
        .active_invite(&invite.invite_id, now_unix_millis())
        .unwrap();
    let invite_reference = active.secret_reference.clone();
    let client_keys = generate_static_keypair().unwrap();
    let now = now_unix_millis();
    secrets.set_fail_delete(true);
    let delete_error = store
        .admit_pending_device(
            &active,
            &EnrollmentPayload {
                schema_version: SCHEMA_VERSION,
                enrollment_id: "enrollment-delete-failure".to_owned(),
                device_id: "device-delete-failure".to_owned(),
                display_name: "Delete failure".to_owned(),
                space_id: "space-consume".to_owned(),
                created_at_unix_millis: now,
            },
            &client_keys.public,
            now,
        )
        .unwrap_err();
    assert_eq!(delete_error.code(), "test_secret_delete_failed");
    let database = Connection::open(gateway_root.join("kaname-link-gateway.sqlite3")).unwrap();
    let consumed: (Option<i64>, Option<String>) = database
        .query_row(
            "SELECT consumed_at_unix_millis, secret_reference FROM invites
              WHERE invite_id = ?1",
            [&invite.invite_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(
        consumed.0.is_some(),
        "DB state must be consumed before secret cleanup"
    );
    assert_eq!(consumed.1.as_deref(), Some(invite_reference.as_str()));
    drop(database);
    drop(store);

    secrets.set_fail_delete(false);
    let mut reopened =
        GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared()).unwrap();
    assert_eq!(secrets.successful_delete_count(&invite_reference), 1);
    assert_eq!(
        reopened
            .active_invite(&invite.invite_id, now_unix_millis())
            .err()
            .expect("consumed invite must be unavailable")
            .code(),
        "invite_unavailable"
    );
    assert_eq!(secrets.successful_delete_count(&invite_reference), 1);
}

#[test]
fn expired_invite_secret_is_deleted_once_and_reference_is_cleared() {
    let temporary = tempdir().unwrap();
    let gateway_root = temporary.path().join("gateway");
    let secrets = TestSecretStore::shared();
    let mut store =
        GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared()).unwrap();
    let invite = store
        .create_invite(
            "space-expiry",
            "Expiry space",
            "http://127.0.0.1:12345",
            3_600,
        )
        .unwrap();
    let active = store
        .active_invite(&invite.invite_id, now_unix_millis())
        .unwrap();
    let reference = active.secret_reference;
    Connection::open(gateway_root.join("kaname-link-gateway.sqlite3"))
        .unwrap()
        .execute(
            "UPDATE invites SET expires_at_unix_millis = ?1 WHERE invite_id = ?2",
            (now_unix_millis() - 1, &invite.invite_id),
        )
        .unwrap();
    drop(store);

    let mut reopened =
        GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared()).unwrap();
    assert_eq!(secrets.successful_delete_count(&reference), 1);
    assert_eq!(
        reopened
            .active_invite(&invite.invite_id, now_unix_millis())
            .err()
            .expect("expired invite must be unavailable")
            .code(),
        "invite_unavailable"
    );
    assert_eq!(secrets.successful_delete_count(&reference), 1);
    let stored_reference: Option<String> =
        Connection::open(gateway_root.join("kaname-link-gateway.sqlite3"))
            .unwrap()
            .query_row(
                "SELECT secret_reference FROM invites WHERE invite_id = ?1",
                [&invite.invite_id],
                |row| row.get(0),
            )
            .unwrap();
    assert!(stored_reference.is_none());
}

#[test]
fn exact_rpc_replay_survives_freshness_window_but_changed_reuse_is_rejected() {
    let temporary = tempdir().unwrap();
    let gateway_root = temporary.path().join("gateway");
    let secrets = TestSecretStore::shared();
    let mut store =
        GatewayStore::open_with_secret_store(&gateway_root, secrets.as_shared()).unwrap();
    let invite = store
        .create_invite(
            "space-replay",
            "Replay space",
            "http://127.0.0.1:12345",
            3_600,
        )
        .unwrap();
    let now = now_unix_millis();
    let active = store.active_invite(&invite.invite_id, now).unwrap();
    let client_keys = generate_static_keypair().unwrap();
    let device_id = "device-rpc-replay";
    store
        .admit_pending_device(
            &active,
            &EnrollmentPayload {
                schema_version: SCHEMA_VERSION,
                enrollment_id: "enrollment-rpc-replay".to_owned(),
                device_id: device_id.to_owned(),
                display_name: "Replay collaborator".to_owned(),
                space_id: "space-replay".to_owned(),
                created_at_unix_millis: now,
            },
            &client_keys.public,
            now,
        )
        .unwrap();
    store.approve_device(device_id).unwrap();
    let device = store.device_for_static(&client_keys.public).unwrap();
    let request = RpcRequest {
        schema_version: SCHEMA_VERSION,
        request_id: "request-exact-replay".to_owned(),
        device_id: device_id.to_owned(),
        space_id: "space-replay".to_owned(),
        issued_at_unix_millis: now,
        operation: RpcOperation::SendText {
            message_id: "message-exact-replay".to_owned(),
            text: "Exactly once".to_owned(),
            queued_at_unix_millis: now,
        },
    };
    let first = store.handle_rpc(&device, &request, now).unwrap();
    let replay = store
        .handle_rpc(&device, &request, now + MAXIMUM_CLOCK_SKEW_MILLIS + 1)
        .unwrap();
    assert_eq!(replay, first);
    assert_eq!(store.inbox("space-replay", 0, 100).unwrap().len(), 1);

    let mut changed = request;
    changed.operation = RpcOperation::SendText {
        message_id: "message-exact-replay".to_owned(),
        text: "Changed body".to_owned(),
        queued_at_unix_millis: now,
    };
    assert_eq!(
        store.handle_rpc(&device, &changed, now).unwrap_err().code(),
        "request_id_reused"
    );
}

#[test]
fn unauthenticated_rejections_and_malformed_noise_preserve_enrollment() {
    let copied_revocation = json!({
        "schemaVersion": SCHEMA_VERSION,
        "error": { "code": "device_revoked" }
    })
    .to_string();
    let malformed_noise = serde_json::to_string(&NoiseHttpResponse {
        schema_version: SCHEMA_VERSION,
        noise_message: encode_bytes(&[1, 2, 3]),
    })
    .unwrap();
    let cases = [
        ("401 Unauthorized", String::new(), "session_rejected"),
        ("403 Forbidden", String::new(), "session_rejected"),
        ("403 Forbidden", copied_revocation, "session_rejected"),
        (
            "500 Internal Server Error",
            String::new(),
            "gateway_unavailable",
        ),
        ("200 OK", malformed_noise, "noise_failure"),
    ];

    for (index, (status, body, expected_error)) in cases.into_iter().enumerate() {
        let (gateway_url, server) = serve_one_http_response(status, body);
        let temporary = tempdir().unwrap();
        let secrets = TestSecretStore::shared();
        let host_keys = generate_static_keypair().unwrap();
        let (mut client, private_reference) = seed_approved_client(
            &temporary.path().join(format!("client-{index}")),
            secrets.clone(),
            &gateway_url,
            &host_keys.public,
        );
        let message_id = format!("message-edge-{index}");
        let result = client
            .send_text("This must remain enrolled.", Some(&message_id))
            .unwrap();
        assert!(!result.connected);
        assert_eq!(result.last_error.as_deref(), Some(expected_error));
        let snapshot = client.snapshot().unwrap();
        assert!(snapshot.enrolled);
        assert_eq!(snapshot.enrollment_state.as_deref(), Some("approved"));
        assert!(secrets.references().contains(&private_reference));
        assert_eq!(secrets.successful_delete_count(&private_reference), 0);
        server.join().unwrap();
    }
}

#[test]
fn authenticated_malformed_session_envelope_preserves_enrollment() {
    let host_keys = generate_static_keypair().unwrap();
    let host_public = host_keys.public.clone();
    let malformed_envelope = json!({
        "schemaVersion": SCHEMA_VERSION,
        "reply": {
            "kind": "rejection",
            "code": "edge_copied_device_revoked"
        }
    })
    .to_string()
    .into_bytes();
    let (gateway_url, server) =
        serve_one_authenticated_noise_response(host_keys.private, malformed_envelope);
    let temporary = tempdir().unwrap();
    let secrets = TestSecretStore::shared();
    let (mut client, private_reference) = seed_approved_client(
        &temporary.path().join("client"),
        secrets.clone(),
        &gateway_url,
        &host_public,
    );

    let result = client
        .send_text(
            "Malformed replies cannot revoke me.",
            Some("message-malformed"),
        )
        .unwrap();
    assert!(!result.connected);
    assert_eq!(result.last_error.as_deref(), Some("invalid_json"));
    assert_eq!(
        client.snapshot().unwrap().enrollment_state.as_deref(),
        Some("approved")
    );
    assert!(secrets.references().contains(&private_reference));
    assert_eq!(secrets.successful_delete_count(&private_reference), 0);
    server.join().unwrap();
}

#[test]
fn oversized_http_response_is_rejected_before_json_decode() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = vec![0_u8; 128 * 1024];
        let _ = stream.read(&mut request);
        let length = MAXIMUM_HTTP_RESPONSE_BYTES + 1;
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(header.as_bytes()).unwrap();
        let _ = stream.write_all(&vec![b'x'; length]);
    });

    let temporary = tempdir().unwrap();
    let secrets = TestSecretStore::shared();
    let host = generate_static_keypair().unwrap();
    let invite_secret = generate_invite_secret().unwrap();
    let invite = InviteArtifact {
        schema_version: SCHEMA_VERSION,
        invite_id: "invite-oversized".to_owned(),
        space_id: "space-oversized".to_owned(),
        space_name: "Oversized response".to_owned(),
        gateway_url: format!("http://{address}"),
        host_static_public_key: encode_bytes(&host.public),
        invite_secret: encode_bytes(&invite_secret),
        expires_at_unix_millis: now_unix_millis() + 60_000,
    };
    let mut client =
        LinkClient::open_with_secret_store(temporary.path().join("client"), secrets.as_shared())
            .unwrap();
    let error = client.enroll(&invite, "Bounded client").unwrap_err();
    assert_eq!(error.code(), "gateway_response_too_large");
    assert!(secrets.references().is_empty());
    server.join().unwrap();
}

#[tokio::test]
async fn gateway_rejects_non_loopback_bind() {
    let temporary = tempdir().unwrap();
    let secrets = TestSecretStore::shared();
    let error = spawn_gateway_with_secret_store(
        temporary.path().join("gateway"),
        "0.0.0.0:0".parse::<SocketAddr>().unwrap(),
        secrets.as_shared(),
    )
    .await
    .err()
    .expect("non-loopback binds must be rejected");
    assert_eq!(error.code(), "gateway_must_bind_loopback");
}

#[test]
fn native_shell_envelope_has_bounded_snapshot_adapter() {
    let request: ClientShellRequest = serde_json::from_value(json!({
        "schemaVersion": 1,
        "requestID": "request-shell-snapshot",
        "operation": "snapshot",
        "payload": {}
    }))
    .unwrap();
    let temporary = tempdir().unwrap();
    let secrets = TestSecretStore::shared();
    let response = execute_client_rpc_with_secret_store(
        &temporary.path().join("client"),
        secrets.as_shared(),
        request,
    );
    let wire = serde_json::to_value(response).unwrap();
    assert_eq!(wire["schemaVersion"], 1);
    assert_eq!(wire["requestID"], "request-shell-snapshot");
    assert_eq!(wire["ok"], true);
    assert_eq!(wire["snapshot"]["connection"], "enrollmentRequired");
    assert_eq!(wire["snapshot"]["spaces"], json!([]));
}

fn serve_one_http_response(status: &'static str, body: String) -> (String, thread::JoinHandle<()>) {
    serve_one_http_exchange(move |_| (status, body))
}

fn serve_one_authenticated_noise_response(
    host_private: Vec<u8>,
    encrypted_payload: Vec<u8>,
) -> (String, thread::JoinHandle<()>) {
    serve_one_http_exchange(move |body| {
        let request: NoiseHttpRequest = serde_json::from_slice(&body).unwrap();
        let first = decode_bytes(
            &request.noise_message,
            MAXIMUM_NOISE_MESSAGE_BYTES,
            "invalid_noise_message",
        )
        .unwrap();
        let mut noise = session_responder(&host_private).unwrap();
        read_handshake_message(&mut noise, &first).unwrap();
        let second = write_handshake_message(&mut noise, &encrypted_payload).unwrap();
        let response = serde_json::to_string(&NoiseHttpResponse {
            schema_version: SCHEMA_VERSION,
            noise_message: encode_bytes(&second),
        })
        .unwrap();
        ("200 OK", response)
    })
}

fn serve_one_http_exchange<Response>(response: Response) -> (String, thread::JoinHandle<()>)
where
    Response: FnOnce(Vec<u8>) -> (&'static str, String) + Send + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let request_body = read_http_request_body(&mut stream);
        let (status, response_body) = response(request_body);
        let header = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            response_body.len()
        );
        stream.write_all(header.as_bytes()).unwrap();
        stream.write_all(response_body.as_bytes()).unwrap();
    });
    (format!("http://{address}"), server)
}

fn read_http_request_body(stream: &mut std::net::TcpStream) -> Vec<u8> {
    let mut request = Vec::new();
    let (body_start, body_length) = loop {
        let mut chunk = [0_u8; 4096];
        let count = stream.read(&mut chunk).unwrap();
        assert!(count > 0, "HTTP request ended before its body arrived");
        request.extend_from_slice(&chunk[..count]);
        let Some(header_end) = request.windows(4).position(|window| window == b"\r\n\r\n") else {
            continue;
        };
        let header = std::str::from_utf8(&request[..header_end]).unwrap();
        let body_length = header
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().unwrap())
            })
            .expect("Noise RPC request must include Content-Length");
        break (header_end + 4, body_length);
    };
    while request.len() < body_start + body_length {
        let mut chunk = [0_u8; 4096];
        let count = stream.read(&mut chunk).unwrap();
        assert!(count > 0, "HTTP request body was truncated");
        request.extend_from_slice(&chunk[..count]);
    }
    request[body_start..body_start + body_length].to_vec()
}

fn seed_approved_client(
    state_root: &Path,
    secrets: Arc<TestSecretStore>,
    gateway_url: &str,
    host_static_public: &[u8],
) -> (LinkClient, String) {
    let client = LinkClient::open_with_secret_store(state_root, secrets.as_shared()).unwrap();
    drop(client);
    let client_keys = generate_static_keypair().unwrap();
    let private_reference =
        state_secret_reference(state_root, "client", "device-device-edge-static-v1").unwrap();
    secrets
        .put(&private_reference, &client_keys.private)
        .unwrap();
    Connection::open(state_root.join("kaname-link-client.sqlite3"))
        .unwrap()
        .execute(
            "INSERT INTO client_identity(
                 singleton, enrollment_id, device_id, display_name, space_id, space_name,
                 gateway_url, host_static_public, client_static_private_reference,
                 client_static_public, state, enrolled_at_unix_millis
             ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'approved', ?10)",
            params![
                "enrollment-edge",
                "device-edge",
                "Edge fixture",
                "space-edge",
                "Edge space",
                gateway_url,
                host_static_public,
                private_reference,
                client_keys.public,
                now_unix_millis(),
            ],
        )
        .unwrap();
    let client = LinkClient::open_with_secret_store(state_root, secrets.as_shared()).unwrap();
    (client, private_reference)
}

fn assert_secure_database_shape(state_root: &Path, filename: &str) {
    let path = state_root.join(filename);
    let connection = Connection::open(&path).unwrap();
    let identity_columns: Vec<String> = if filename.contains("gateway") {
        connection
            .prepare("SELECT name FROM pragma_table_info('gateway_identity')")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    } else {
        connection
            .prepare("SELECT name FROM pragma_table_info('client_identity')")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    };
    assert!(identity_columns.iter().all(|column| {
        column != "static_private" && column != "client_static_private" && column != "invite_secret"
    }));
    if filename.contains("gateway") {
        let invite_columns: Vec<String> = connection
            .prepare("SELECT name FROM pragma_table_info('invites')")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert!(
            !invite_columns
                .iter()
                .any(|column| column == "invite_secret")
        );
    }
    #[cfg(unix)]
    {
        assert_eq!(
            std::fs::metadata(state_root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

fn assert_secret_values_absent_from_database(path: &Path, secrets: &TestSecretStore) {
    let database = std::fs::read(path).unwrap();
    for (reference, secret) in secrets.entries() {
        assert!(
            !database
                .windows(secret.len())
                .any(|window| window == secret),
            "secret {reference} appeared in SQLite"
        );
    }
}
