use kaname_core::workflow_mail_feedback::{
    WorkflowMailFeedbackError, qualify_synthetic_feedback_json,
};

const FEEDBACK: &[u8] =
    include_bytes!("../../../Fixtures/workflow-mail/wfp-104-simplykay-feedback.json");

#[test]
fn simplykay_fixture_proves_route_wait_attachment_correction_and_cumulative_context() {
    let receipt = qualify_synthetic_feedback_json(FEEDBACK).unwrap();
    assert_eq!(receipt.route, "simplykay_feedback");
    assert_eq!(receipt.wait_count, 2);
    assert_eq!(receipt.episodes.len(), 2);
    assert_eq!(receipt.episodes[0].intent, "initial");
    assert_eq!(receipt.episodes[1].intent, "correction");
    assert_eq!(
        receipt.episodes[1].prior_episode_ids,
        [receipt.episodes[0].episode_id.clone()]
    );
    assert_eq!(
        receipt.episodes[0].result_attachment.filename,
        "synthetic-report-v1.docx"
    );
    assert_eq!(
        receipt.episodes[1].result_attachment.filename,
        "synthetic-report-v2.docx"
    );
    assert!(receipt.cumulative_context_digest.starts_with("sha256:"));
    assert_eq!(receipt.external_operation_count, 0);
}

#[test]
fn reply_correlation_and_event_order_fail_closed() {
    let mut value: serde_json::Value = serde_json::from_slice(FEEDBACK).unwrap();
    value["events"][2]["inReplyToMessageFingerprint"] = serde_json::json!("sha256:wrong");
    assert_eq!(
        qualify_synthetic_feedback_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailFeedbackError::CorrelationMismatch)
    );

    let mut value: serde_json::Value = serde_json::from_slice(FEEDBACK).unwrap();
    value["events"].as_array_mut().unwrap().swap(1, 2);
    assert_eq!(
        qualify_synthetic_feedback_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailFeedbackError::InvalidSequence)
    );
}

#[test]
fn missing_attachment_and_unknown_fields_fail_closed() {
    let mut value: serde_json::Value = serde_json::from_slice(FEEDBACK).unwrap();
    value["events"][1]["attachment"]["sha256"] = serde_json::json!("bad");
    assert_eq!(
        qualify_synthetic_feedback_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailFeedbackError::MissingAttachment)
    );

    let mut value: serde_json::Value = serde_json::from_slice(FEEDBACK).unwrap();
    value["gmailToken"] = serde_json::json!("forbidden");
    assert_eq!(
        qualify_synthetic_feedback_json(&serde_json::to_vec(&value).unwrap()),
        Err(WorkflowMailFeedbackError::InvalidJson)
    );
}
