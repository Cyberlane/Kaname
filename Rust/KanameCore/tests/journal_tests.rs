use kaname_core::{
    journal::{Journal, JournalError, ReplayBasis},
    v1::{CommandEnvelope, EventEnvelope, EventProvenance, OpaqueTypedPayload, SchemaVersion},
};
use prost::Message;
use tempfile::tempdir;

const CURSOR_KEY: [u8; 32] = [0x5a; 32];

fn event(id: &str, kind: &str, sequence_time: i64) -> EventEnvelope {
    EventEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        event_id: id.into(),
        store_position: 0,
        stream_id: "thread:journal-test".into(),
        stream_sequence: 0,
        occurred_at_unix_millis: sequence_time,
        kind: kind.into(),
        payload: Some(OpaqueTypedPayload {
            type_url: "kaname.test.synthetic.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: vec![0x08, 0x01],
            payload_version: 1,
        }),
        provenance: Some(EventProvenance {
            source_kind: "synthetic".into(),
            provider_instance_id: "".into(),
            native_type: "".into(),
            native_cursor: Vec::new(),
            raw_evidence_digest: "".into(),
            retention_class: 0,
        }),
        causation_id: "approval-journal-test".into(),
        correlation_id: "task-journal-test".into(),
    }
}

fn command(id: &str, key: &str) -> CommandEnvelope {
    CommandEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        command_id: id.into(),
        idempotency_key: key.into(),
        kind: "intent.enqueue".into(),
        payload: Some(OpaqueTypedPayload {
            type_url: "kaname.command.enqueue.v1".into(),
            content_type: "application/x-protobuf".into(),
            value: b"synthetic".to_vec(),
            payload_version: 1,
        }),
        scope: None,
        actor_id: "test-client".into(),
        expected_revision: 0,
        submitted_at_unix_millis: 1_762_000_000_000,
    }
}

#[test]
fn journal_preserves_received_wire_bytes_and_rebuilds_after_restart() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("kaname.sqlite");
    let mut journal = Journal::open(&path, &CURSOR_KEY).unwrap();

    let queued = journal
        .append_event(event("event-1", "task.queued", 1))
        .unwrap();
    let exact_received_bytes = queued.event.encode_to_vec();
    let duplicate = journal.append_received_wire(&exact_received_bytes).unwrap();
    assert!(duplicate.duplicate);
    assert_eq!(duplicate.store_position, 1);

    journal
        .append_event(event("event-2", "run.started", 2))
        .unwrap();
    journal
        .append_event(event("event-3", "provider.native_event_observed", 3))
        .unwrap();
    journal
        .append_event(event("event-4", "run.provider_completed", 4))
        .unwrap();
    journal
        .append_event(event("event-5", "review.accepted", 5))
        .unwrap();
    journal.integrity_check().unwrap();

    let page = journal
        .replay("thread:thread:journal-test", None, 500)
        .unwrap();
    assert_eq!(page.events.len(), 5);
    assert_eq!(page.events[0].encode_to_vec(), exact_received_bytes);
    let projection = journal
        .rebuild_thread_projection("thread:thread:journal-test")
        .unwrap();
    assert_eq!(projection.task_state, "accepted");
    assert_eq!(projection.attention, "none");
    assert_eq!(projection.unsupported_event_count, 1);
    drop(journal);

    let reopened = Journal::open(&path, &CURSOR_KEY).unwrap();
    assert_eq!(
        reopened
            .rebuild_thread_projection("thread:thread:journal-test")
            .unwrap(),
        projection
    );
}

#[test]
fn command_admission_is_idempotent_and_key_reuse_fails_closed() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let first = journal
        .admit_command(&command("command-1", "idempotency-1"))
        .unwrap();
    let retry = journal
        .admit_command(&command("command-1", "idempotency-1"))
        .unwrap();
    assert_eq!(first, retry);

    let reused = journal.admit_command(&command("command-2", "idempotency-1"));
    assert!(
        matches!(reused, Err(JournalError::Integrity(code)) if code == "idempotency_key_reused")
    );
}

#[test]
fn crash_before_event_commit_has_no_durable_acceptance_and_retry_is_singleton() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let pending = event("event-crash", "task.queued", 1);
    assert!(matches!(
        journal.inject_crash_before_event_commit_for_test(pending.clone()),
        Err(JournalError::Protocol("injected_crash_before_event_commit"))
    ));
    assert!(
        journal
            .replay("thread:thread:journal-test", None, 10)
            .unwrap()
            .events
            .is_empty()
    );

    let recovered = journal.append_event(pending).unwrap();
    assert_eq!(recovered.store_position, 1);
    assert_eq!(
        journal
            .replay("thread:thread:journal-test", None, 10)
            .unwrap()
            .events
            .len(),
        1
    );
}

#[test]
fn replay_is_paged_deduplicated_and_cursor_tampering_fails_closed() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    let first = journal
        .append_event(event("event-1", "task.queued", 1))
        .unwrap();
    journal
        .append_event(event("event-2", "run.started", 2))
        .unwrap();
    journal
        .append_event(event("event-3", "run.interrupted", 3))
        .unwrap();
    assert!(
        journal
            .append_received_wire(&first.event.encode_to_vec())
            .unwrap()
            .duplicate
    );

    let first_page = journal
        .replay("thread:thread:journal-test", None, 2)
        .unwrap();
    assert_eq!(first_page.events.len(), 2);
    assert!(first_page.has_more);
    let second_page = journal
        .replay(
            "thread:thread:journal-test",
            Some(&first_page.next_cursor),
            2,
        )
        .unwrap();
    assert_eq!(second_page.events.len(), 1);
    assert!(!second_page.has_more);

    let mut tampered = first_page.next_cursor;
    tampered.after_store_position = 0;
    assert!(matches!(
        journal.replay("thread:thread:journal-test", Some(&tampered), 2),
        Err(JournalError::Protocol("invalid_cursor"))
    ));
}

#[test]
fn corrupted_snapshot_is_discarded_and_retention_gap_never_omits_history() {
    let mut journal = Journal::open_in_memory(&CURSOR_KEY).unwrap();
    journal
        .append_event(event("event-1", "task.queued", 1))
        .unwrap();
    journal
        .append_event(event("event-2", "run.started", 2))
        .unwrap();
    let snapshot = journal
        .create_snapshot("thread:thread:journal-test")
        .unwrap();
    journal
        .set_retention_horizon("thread:thread:journal-test", snapshot.high_water_mark)
        .unwrap();

    let resync = journal
        .replay("thread:thread:journal-test", None, 10)
        .unwrap();
    assert_eq!(resync.basis, ReplayBasis::ResyncRequired);
    assert_eq!(resync.snapshot.as_ref().unwrap().id, snapshot.id);

    journal.corrupt_snapshot_for_test(&snapshot.id).unwrap();
    let corrupt_resync = journal
        .replay("thread:thread:journal-test", None, 10)
        .unwrap();
    assert_eq!(corrupt_resync.basis, ReplayBasis::ResyncRequired);
    assert!(corrupt_resync.snapshot.is_none());
    let rebuilt = journal
        .rebuild_thread_projection("thread:thread:journal-test")
        .unwrap();
    assert_eq!(rebuilt.task_state, "running");
}

#[test]
fn backup_and_safe_read_only_mode_preserve_replay_without_allowing_mutation() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("kaname.sqlite");
    let backup = directory.path().join("kaname.backup.sqlite");
    let mut journal = Journal::open(&database, &CURSOR_KEY).unwrap();
    journal
        .append_event(event("event-1", "task.queued", 1))
        .unwrap();
    journal.backup_to(&backup).unwrap();
    drop(journal);

    let mut read_only = Journal::open_read_only(&backup, &CURSOR_KEY).unwrap();
    assert_eq!(
        read_only
            .replay("thread:thread:journal-test", None, 10)
            .unwrap()
            .events
            .len(),
        1
    );
    assert!(matches!(
        read_only.append_event(event("event-2", "run.started", 2)),
        Err(JournalError::ReadOnly)
    ));
}
