use kaname_core::workflow_mail::{WorkflowMailError, canonical_envelope, normalize_fixture_json};

const GMAIL: &[u8] = include_bytes!("../../../Fixtures/workflow-mail/wfp-101-gmail-metadata.json");
const JMAP: &[u8] = include_bytes!("../../../Fixtures/workflow-mail/wfp-101-jmap-metadata.json");
const INVALID_BODY: &[u8] =
    include_bytes!("../../../Fixtures/workflow-mail/wfp-101-invalid-body.json");

#[test]
fn provider_fixtures_normalize_to_one_typed_body_free_contract() {
    for fixture in [GMAIL, JMAP] {
        let envelope = normalize_fixture_json(fixture).unwrap();
        assert_eq!(envelope.schema_version, 1);
        assert_eq!(envelope.messages.len(), 2);
        assert!(envelope.conversation_fingerprint.starts_with("sha256:"));
        assert!(
            envelope
                .cursor_fingerprint
                .as_deref()
                .unwrap()
                .starts_with("sha256:")
        );
        assert_eq!(envelope.messages[0].headers["subject"], "Quarterly report");
        assert_eq!(envelope.messages[1].attachments[0].filename, "report.pdf");
        let canonical = canonical_envelope(&envelope).unwrap();
        let text = String::from_utf8(canonical.canonical_bytes).unwrap();
        for forbidden in [
            "gmail-thread-private",
            "jmap-thread-private",
            "message-private",
            "attachment-private",
            "body",
        ] {
            assert!(!text.contains(forbidden), "leaked {forbidden}");
        }
    }
}

#[test]
fn message_and_attachment_order_do_not_change_the_canonical_envelope() {
    let canonical = canonical_envelope(&normalize_fixture_json(GMAIL).unwrap()).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(GMAIL).unwrap();
    value["messages"].as_array_mut().unwrap().reverse();
    value["messages"][0]["resourceIds"]
        .as_array_mut()
        .unwrap()
        .reverse();
    let reordered = serde_json::to_vec(&value).unwrap();
    let second = canonical_envelope(&normalize_fixture_json(&reordered).unwrap()).unwrap();
    assert_eq!(second.canonical_bytes, canonical.canonical_bytes);
    assert_eq!(second.sha256, canonical.sha256);
}

#[test]
fn body_content_and_inconsistent_identity_fail_closed() {
    assert_eq!(
        normalize_fixture_json(INVALID_BODY),
        Err(WorkflowMailError::InvalidJson)
    );

    let mut value: serde_json::Value = serde_json::from_slice(GMAIL).unwrap();
    value["messages"][0]["conversationId"] = serde_json::json!("different-thread");
    assert_eq!(
        normalize_fixture_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailError::InvalidConversation)
    );

    value["messages"][0]["conversationId"] = value["conversationId"].clone();
    value["messages"][1]["id"] = value["messages"][0]["id"].clone();
    assert_eq!(
        normalize_fixture_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailError::DuplicateMessage)
    );
}
