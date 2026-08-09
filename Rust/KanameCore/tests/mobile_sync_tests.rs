use kaname_core::{
    journal::{Journal, JournalError},
    mobile::{EnrollmentAdmission, SyncAdmission},
    v1::{
        DeviceEnrollmentChallenge, DeviceEnrollmentDecision, DeviceEnrollmentState,
        DeviceKeyRotation, DevicePublicIdentity, DeviceRevocation, EncryptedSyncEnvelope,
        SchemaVersion, SyncAuthenticatedHeader,
    },
};
use prost::Message;
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x93; 32];
const NOW: i64 = 1_786_220_000_000;
const MAC_DEVICE: &str = "mac-authority";
const MAC_KEY: &str = "mac-key-1";

#[test]
fn enrollment_and_sync_order_survive_restart_without_duplicate_application() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("mobile.sqlite3");
    let mut journal = Journal::open(&database, &CURSOR_KEY).unwrap();
    enroll(&mut journal, identity("iphone-key-1", 1));

    let first_wire = envelope_wire(1, "envelope-1", "iphone-key-1", &[]);
    let first = journal
        .record_authenticated_mobile_sync_wire(&first_wire, MAC_DEVICE, MAC_KEY, NOW)
        .unwrap();
    let first_digest = match first {
        SyncAdmission::Accepted {
            sender_sequence,
            envelope_digest,
        } => {
            assert_eq!(sender_sequence, 1);
            envelope_digest
        }
        other => panic!("unexpected first admission: {other:?}"),
    };
    assert!(matches!(
        journal
            .record_authenticated_mobile_sync_wire(&first_wire, MAC_DEVICE, MAC_KEY, NOW)
            .unwrap(),
        SyncAdmission::Duplicate {
            sender_sequence: 1,
            ..
        }
    ));
    drop(journal);

    let mut reopened = Journal::open(&database, &CURSOR_KEY).unwrap();
    assert_eq!(
        reopened
            .device("iphone-justin")
            .unwrap()
            .unwrap()
            .last_sender_sequence,
        1
    );
    let second_wire = envelope_wire(2, "envelope-2", "iphone-key-1", &first_digest);
    assert!(matches!(
        reopened
            .record_authenticated_mobile_sync_wire(&second_wire, MAC_DEVICE, MAC_KEY, NOW)
            .unwrap(),
        SyncAdmission::Accepted {
            sender_sequence: 2,
            ..
        }
    ));
}

#[test]
fn gap_and_hash_chain_mismatch_fail_closed_until_exact_missing_sequence_arrives() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    enroll(&mut journal, identity("iphone-key-1", 1));
    let first = journal
        .record_authenticated_mobile_sync_wire(
            &envelope_wire(1, "envelope-1", "iphone-key-1", &[]),
            MAC_DEVICE,
            MAC_KEY,
            NOW,
        )
        .unwrap();
    let first_digest = match first {
        SyncAdmission::Accepted {
            envelope_digest, ..
        } => envelope_digest,
        other => panic!("unexpected first admission: {other:?}"),
    };

    assert_eq!(
        journal
            .record_authenticated_mobile_sync_wire(
                &envelope_wire(3, "envelope-3", "iphone-key-1", &[0x33; 32]),
                MAC_DEVICE,
                MAC_KEY,
                NOW,
            )
            .unwrap(),
        SyncAdmission::ResyncRequired {
            expected_sender_sequence: 2
        }
    );
    assert!(matches!(
        journal.record_authenticated_mobile_sync_wire(
            &envelope_wire(2, "envelope-2-wrong", "iphone-key-1", &[0x44; 32]),
            MAC_DEVICE,
            MAC_KEY,
            NOW,
        ),
        Err(JournalError::Protocol("sync_chain_mismatch"))
    ));
    assert!(matches!(
        journal
            .record_authenticated_mobile_sync_wire(
                &envelope_wire(2, "envelope-2", "iphone-key-1", &first_digest),
                MAC_DEVICE,
                MAC_KEY,
                NOW,
            )
            .unwrap(),
        SyncAdmission::Accepted {
            sender_sequence: 2,
            ..
        }
    ));
}

#[test]
fn key_rotation_resets_sender_chain_and_old_key_fails_closed() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    enroll(&mut journal, identity("iphone-key-1", 1));
    journal
        .record_authenticated_mobile_sync_wire(
            &envelope_wire(1, "envelope-old-1", "iphone-key-1", &[]),
            MAC_DEVICE,
            MAC_KEY,
            NOW,
        )
        .unwrap();

    let next = identity("iphone-key-2", 2);
    let rotation = DeviceKeyRotation {
        device_id: "iphone-justin".into(),
        previous_key_id: "iphone-key-1".into(),
        next_identity: Some(next),
        transcript_digest: vec![0x52; 32],
        rotated_at_unix_millis: NOW,
    };
    let rotated = journal.rotate_mobile_device_key(&rotation, NOW).unwrap();
    assert_eq!(rotated.identity.key_id, "iphone-key-2");
    assert_eq!(rotated.last_sender_sequence, 0);
    assert_eq!(
        journal.rotate_mobile_device_key(&rotation, NOW).unwrap(),
        rotated
    );

    assert!(matches!(
        journal.record_authenticated_mobile_sync_wire(
            &envelope_wire(2, "envelope-old-2", "iphone-key-1", &[0x11; 32]),
            MAC_DEVICE,
            MAC_KEY,
            NOW,
        ),
        Err(JournalError::Protocol("sender_key_not_active"))
    ));
    assert!(matches!(
        journal
            .record_authenticated_mobile_sync_wire(
                &envelope_wire(1, "envelope-new-1", "iphone-key-2", &[]),
                MAC_DEVICE,
                MAC_KEY,
                NOW,
            )
            .unwrap(),
        SyncAdmission::Accepted {
            sender_sequence: 1,
            ..
        }
    ));
}

#[test]
fn revocation_is_idempotent_and_rejects_every_later_envelope() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    enroll(&mut journal, identity("iphone-key-1", 1));
    let revocation = DeviceRevocation {
        device_id: "iphone-justin".into(),
        key_id: "iphone-key-1".into(),
        revoked_at_unix_millis: NOW,
        reason_code: "lost_device".into(),
    };
    let first = journal.revoke_mobile_device(&revocation, NOW).unwrap();
    let duplicate = journal.revoke_mobile_device(&revocation, NOW).unwrap();
    assert_eq!(first, duplicate);
    assert_eq!(first.state, DeviceEnrollmentState::Revoked);
    assert!(matches!(
        journal.record_authenticated_mobile_sync_wire(
            &envelope_wire(1, "envelope-after-revoke", "iphone-key-1", &[]),
            MAC_DEVICE,
            MAC_KEY,
            NOW,
        ),
        Err(JournalError::Protocol("sender_device_not_active"))
    ));
}

fn enroll(journal: &mut Journal, proposed_device: DevicePublicIdentity) {
    let challenge = DeviceEnrollmentChallenge {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        enrollment_id: "enrollment-1".into(),
        proposed_device: Some(proposed_device),
        mac_nonce: vec![0x4d; 32],
        confirmation_digest: vec![0x43; 32],
        expires_at_unix_millis: NOW + 60_000,
    };
    assert_eq!(
        journal.propose_mobile_device(&challenge, NOW).unwrap(),
        EnrollmentAdmission::Pending
    );
    assert_eq!(
        journal.propose_mobile_device(&challenge, NOW).unwrap(),
        EnrollmentAdmission::Duplicate
    );
    let decision = DeviceEnrollmentDecision {
        enrollment_id: challenge.enrollment_id,
        state: DeviceEnrollmentState::Active as i32,
        mac_device_id: MAC_DEVICE.into(),
        transcript_digest: vec![0x54; 32],
        decided_at_unix_millis: NOW,
    };
    let result = journal.decide_mobile_device(&decision, NOW).unwrap();
    assert_eq!(result.state, DeviceEnrollmentState::Active);
    assert!(!result.duplicate);
    assert!(
        journal
            .decide_mobile_device(&decision, NOW)
            .unwrap()
            .duplicate
    );
}

fn identity(key_id: &str, generation: u64) -> DevicePublicIdentity {
    DevicePublicIdentity {
        device_id: "iphone-justin".into(),
        key_id: key_id.into(),
        display_name: "Justin's iPhone".into(),
        platform: "ios".into(),
        hpke_public_key: vec![generation as u8; 32],
        key_generation: generation,
        created_at_unix_millis: NOW,
        expires_at_unix_millis: NOW + 86_400_000,
    }
}

fn envelope_wire(
    sequence: u64,
    envelope_id: &str,
    sender_key_id: &str,
    previous_digest: &[u8],
) -> Vec<u8> {
    let header = SyncAuthenticatedHeader {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        envelope_id: envelope_id.into(),
        sender_device_id: "iphone-justin".into(),
        sender_key_id: sender_key_id.into(),
        recipient_device_id: MAC_DEVICE.into(),
        recipient_key_id: MAC_KEY.into(),
        sender_sequence: sequence,
        previous_envelope_digest: previous_digest.to_vec(),
        sent_at_unix_millis: NOW,
        expires_at_unix_millis: NOW + 60_000,
        payload_kind: "queue.enqueue".into(),
        plaintext_digest: vec![0x50; 32],
        content_type: "application/x-protobuf".into(),
    };
    EncryptedSyncEnvelope {
        authenticated_header: header.encode_to_vec(),
        encapsulated_key: vec![0x45; 32],
        ciphertext: vec![0x43; 48],
    }
    .encode_to_vec()
}
