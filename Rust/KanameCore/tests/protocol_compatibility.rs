use kaname_core::v1::EventEnvelope;
use prost::Message;

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(format!("../../Fixtures/wire/v1/{name}")).expect("fixture is checked in")
}

#[test]
fn rust_decodes_and_reencodes_swift_vector_without_losing_unknown_outer_payload() {
    let source = fixture("swift-event-envelope.bin");
    let event = EventEnvelope::decode(source.as_slice()).expect("Swift wire vector decodes in Rust");
    assert_eq!(event.payload.as_ref().unwrap().type_url, "kaname.event.future.unsupported.v9");
    assert_eq!(event.payload.as_ref().unwrap().value, vec![0x08, 0x96, 0x01]);
    assert_eq!(event.encode_to_vec(), source);
}

#[test]
fn rust_vector_is_a_stable_received_byte_fixture() {
    let source = fixture("rust-event-envelope.bin");
    let event = EventEnvelope::decode(source.as_slice()).expect("Rust wire vector decodes");
    assert_eq!(event.event_id, "event-schema-vector-001");
    assert_eq!(event.encode_to_vec(), source);
}
