use kaname_link_core::{
    LinkError, Result,
    client::LinkClient,
    gateway::GatewayStore,
    model::{
        EnrollmentPayload, InviteArtifact, MAXIMUM_CLOCK_SKEW_MILLIS, MAXIMUM_HTTP_RESPONSE_BYTES,
        RpcOperation, RpcRequest, SCHEMA_VERSION, now_unix_millis,
    },
    noise::{encode_bytes, generate_invite_secret, generate_static_keypair},
    secret_store::{SecretStore, SharedSecretStore},
    server::spawn_gateway_with_secret_store,
    shell::{ClientShellRequest, execute_client_rpc_with_secret_store},
};
use rusqlite::Connection;
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
        assert_eq!(revoked_send.last_error.as_deref(), Some("session_rejected"));
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
        assert_eq!(admin.inbox("space-pilot", 0, 100).unwrap().len(), 1);

        assert_secure_database_shape(&workflow_client_root, "kaname-link-client.sqlite3");
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
