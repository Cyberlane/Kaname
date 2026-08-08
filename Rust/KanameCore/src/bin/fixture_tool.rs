use kaname_core::v1::{
    EventEnvelope, EventProvenance, EvidenceRetentionClass, OpaqueTypedPayload, SchemaVersion,
};
use prost::Message;
use std::io::Write;

fn main() {
    let event = EventEnvelope {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        event_id: "event-schema-vector-001".into(),
        store_position: 42,
        stream_id: "thread-schema-vector-001".into(),
        stream_sequence: 7,
        occurred_at_unix_millis: 1_762_000_000_000,
        kind: "provider.native_event_observed".into(),
        payload: Some(OpaqueTypedPayload {
            type_url: "kaname.event.future.unsupported.v9".into(),
            content_type: "application/x-protobuf".into(),
            value: vec![0x08, 0x96, 0x01],
            payload_version: 9,
        }),
        provenance: Some(EventProvenance {
            source_kind: "fake_provider".into(),
            provider_instance_id: "fake-local".into(),
            native_type: "fake.v1.unknown.extension".into(),
            native_cursor: b"cursor-unknown-1".to_vec(),
            raw_evidence_digest: "sha256:synthetic-vector".into(),
            retention_class: EvidenceRetentionClass::SevenDays as i32,
        }),
        causation_id: "command-schema-vector-001".into(),
        correlation_id: "task-schema-vector-001".into(),
    };
    std::io::stdout()
        .write_all(&event.encode_to_vec())
        .expect("write fixture");
}
