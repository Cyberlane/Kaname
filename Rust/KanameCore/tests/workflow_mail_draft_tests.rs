use kaname_core::{
    workflow_mail_draft::{
        WorkflowMailDraftError, WorkflowMailDraftKind, WorkflowMailDraftRequest, compose_draft,
    },
    workflow_storage::{WorkflowStorageHandle, WorkflowStorageScopeKind},
};

fn attachment() -> WorkflowStorageHandle {
    WorkflowStorageHandle {
        handle_id: "artifact-report-v2".into(),
        entry_id: "entry-report-v2".into(),
        version_id: "artifact-report-v2".into(),
        scope_kind: WorkflowStorageScopeKind::Case,
        logical_key: "mail/artifacts/report-v2.docx".into(),
        revision: 1,
        previous_version_id: None,
        source_version_id: Some("artifact-report-v1".into()),
        schema_ref: None,
        media_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            .into(),
        classification: "private".into(),
        value_kind: "object".into(),
        byte_count: 42,
        sha256: "b".repeat(64),
    }
}

fn request(kind: WorkflowMailDraftKind) -> WorkflowMailDraftRequest {
    WorkflowMailDraftRequest {
        kind,
        account_binding_id: "synthetic-account".into(),
        conversation_fingerprint: "sha256:synthetic-conversation".into(),
        source_message_fingerprint: "sha256:synthetic-message".into(),
        from: "ASSISTANT@EXAMPLE.TEST".into(),
        to: vec!["recipient@example.test".into()],
        cc: Vec::new(),
        bcc: Vec::new(),
        subject: "Synthetic monthly report".into(),
        body_utf8: "Attached is the revised synthetic report.".into(),
        attachments: vec![attachment()],
    }
}

#[test]
fn reply_draft_has_exact_destinations_attachments_and_no_send_authority() {
    let draft = compose_draft(request(WorkflowMailDraftKind::Reply)).unwrap();
    assert_eq!(draft.envelope.from, "assistant@example.test");
    assert_eq!(draft.envelope.to, ["recipient@example.test"]);
    assert_eq!(draft.envelope.subject, "Re: Synthetic monthly report");
    assert_eq!(draft.preview.destinations, ["recipient@example.test"]);
    assert_eq!(draft.preview.attachment_handle_ids, ["artifact-report-v2"]);
    assert_eq!(draft.preview.attachment_byte_count, 42);
    assert!(!draft.preview.send_authority);
    assert_eq!(draft.preview.external_operation_count, 0);
}

#[test]
fn forward_and_reply_digests_are_stable_but_distinct() {
    let reply = compose_draft(request(WorkflowMailDraftKind::Reply)).unwrap();
    let repeated = compose_draft(request(WorkflowMailDraftKind::Reply)).unwrap();
    let forward = compose_draft(request(WorkflowMailDraftKind::Forward)).unwrap();
    assert_eq!(reply.preview.draft_digest, repeated.preview.draft_digest);
    assert_ne!(reply.preview.draft_digest, forward.preview.draft_digest);
    assert_eq!(forward.envelope.subject, "Fwd: Synthetic monthly report");
}

#[test]
fn missing_destination_and_non_object_attachment_fail_closed() {
    let mut missing = request(WorkflowMailDraftKind::Reply);
    missing.to.clear();
    assert_eq!(
        compose_draft(missing),
        Err(WorkflowMailDraftError::InvalidDestination)
    );

    let mut inline = request(WorkflowMailDraftKind::Reply);
    inline.attachments[0].value_kind = "inline_json".into();
    assert_eq!(
        compose_draft(inline),
        Err(WorkflowMailDraftError::InvalidAttachment)
    );
}
