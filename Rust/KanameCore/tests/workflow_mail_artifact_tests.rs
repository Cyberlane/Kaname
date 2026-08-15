use kaname_core::{
    workflow_mail::{WorkflowMailThreadEnvelope, normalize_fixture_json},
    workflow_mail_artifacts::{
        WorkflowMailArtifactError, WorkflowMailArtifactPipeline,
        WorkflowMailAttachmentCollectionRequest, WorkflowMailAttachmentInput,
        WorkflowMailOutputRequest, WorkflowMailPromotionRequest, compile_context,
    },
    workflow_object_store::WorkflowObjectStoreQuota,
    workflow_storage::{
        WorkflowStorageAccessContext, WorkflowStorageNamespace, WorkflowStorageNamespaceQuota,
        WorkflowStorageScopeKind,
    },
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use tempfile::tempdir;

const GMAIL: &[u8] = include_bytes!("../../../Fixtures/workflow-mail/wfp-101-gmail-metadata.json");

fn object_quota() -> WorkflowObjectStoreQuota {
    WorkflowObjectStoreQuota {
        maximum_object_bytes: 1024 * 1024,
        maximum_total_bytes: 4 * 1024 * 1024,
        maximum_object_count: 20,
    }
}

fn namespace_quota() -> WorkflowStorageNamespaceQuota {
    WorkflowStorageNamespaceQuota {
        maximum_item_count: 20,
        maximum_total_bytes: 4 * 1024 * 1024,
        maximum_value_bytes: 1024 * 1024,
    }
}

fn access() -> WorkflowStorageAccessContext {
    WorkflowStorageAccessContext {
        run_id: Some("run-wfp-102".into()),
        case_id: Some("case-wfp-102".into()),
        installation_id: "installation-wfp-102".into(),
        account_binding_ids: BTreeSet::from(["synthetic-account".into()]),
    }
}

fn namespace(kind: WorkflowStorageScopeKind, owner: &str) -> WorkflowStorageNamespace {
    WorkflowStorageNamespace {
        kind,
        owner_id: owner.into(),
        installation_id: Some("installation-wfp-102".into()),
    }
}

fn fixture() -> (WorkflowMailAttachmentInput, Vec<u8>) {
    let bytes = b"synthetic attachment bytes".to_vec();
    (
        WorkflowMailAttachmentInput {
            attachment_fingerprint: "sha256:synthetic-attachment".into(),
            filename: "report.pdf".into(),
            media_type: "application/pdf".into(),
            expected_sha256: hex::encode(Sha256::digest(&bytes)),
            bytes: bytes.clone(),
        },
        bytes,
    )
}

fn thread() -> WorkflowMailThreadEnvelope {
    normalize_fixture_json(GMAIL).unwrap()
}

#[test]
fn attachments_store_by_digest_compile_without_bytes_and_retry_idempotently() {
    let temporary = tempdir().unwrap();
    let mut pipeline =
        WorkflowMailArtifactPipeline::open(temporary.path(), object_quota()).unwrap();
    let job = namespace(WorkflowStorageScopeKind::Job, "run-wfp-102");
    pipeline
        .storage_mut()
        .register_namespace(job.clone(), namespace_quota(), 1_000)
        .unwrap();
    let (attachment, bytes) = fixture();
    let request = WorkflowMailAttachmentCollectionRequest {
        access: access(),
        job_namespace: job,
        attempt_id: "attempt-wfp-102-collect".into(),
        collected_at_unix_millis: 2_000,
        attachments: vec![attachment],
    };
    let first = pipeline.collect_attachments(request.clone()).unwrap();
    let second = pipeline.collect_attachments(request).unwrap();
    assert!(!first[0].storage_duplicate);
    assert!(second[0].object_duplicate);
    assert!(second[0].storage_duplicate);

    let compiled = compile_context(&thread(), &first).unwrap();
    let text = String::from_utf8(compiled.canonical_bytes).unwrap();
    assert_eq!(compiled.message_count, 2);
    assert_eq!(compiled.attachment_count, 1);
    assert!(!text.contains(&String::from_utf8(bytes).unwrap()));
    assert!(text.contains(&first[0].handle.handle_id));
}

#[test]
fn output_validation_fails_closed_then_stores_and_promotes_exact_lineage() {
    let temporary = tempdir().unwrap();
    let mut pipeline =
        WorkflowMailArtifactPipeline::open(temporary.path(), object_quota()).unwrap();
    let job = namespace(WorkflowStorageScopeKind::Job, "run-wfp-102");
    let case = namespace(WorkflowStorageScopeKind::Case, "case-wfp-102");
    pipeline
        .storage_mut()
        .register_namespace(job.clone(), namespace_quota(), 1_000)
        .unwrap();
    pipeline
        .storage_mut()
        .register_namespace(case.clone(), namespace_quota(), 1_000)
        .unwrap();

    let schema = json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "properties": {"summary": {"type": "string"}},
        "required": ["summary"],
        "unevaluatedProperties": false
    });
    let invalid = pipeline.validate_and_store_output(WorkflowMailOutputRequest {
        access: access(),
        namespace: job.clone(),
        attempt_id: "attempt-wfp-102-output".into(),
        logical_key: "mail/output/summary".into(),
        schema_ref: "kaname://schemas/mail-summary-v1".into(),
        schema: schema.clone(),
        output: json!({"summary": 7}),
        created_at_unix_millis: 3_000,
    });
    assert!(matches!(
        invalid,
        Err(WorkflowMailArtifactError::OutputInvalid(_))
    ));

    let stored = pipeline
        .validate_and_store_output(WorkflowMailOutputRequest {
            access: access(),
            namespace: job.clone(),
            attempt_id: "attempt-wfp-102-output".into(),
            logical_key: "mail/output/summary".into(),
            schema_ref: "kaname://schemas/mail-summary-v1".into(),
            schema,
            output: json!({"summary": "Synthetic result"}),
            created_at_unix_millis: 3_000,
        })
        .unwrap();
    let promoted = pipeline
        .promote_artifact(WorkflowMailPromotionRequest {
            access: access(),
            source_namespace: job,
            destination_namespace: case,
            source: stored.receipt.handle,
            destination_logical_key: "mail/artifacts/final-summary".into(),
            classification: "private".into(),
            attempt_id: "attempt-wfp-102-promote".into(),
            promoted_at_unix_millis: 4_000,
        })
        .unwrap();
    assert_eq!(
        promoted.handle.source_version_id.as_deref(),
        Some(promoted.source_handle_id.as_str())
    );
    let source = pipeline
        .storage_mut()
        .inspect_handle(&access(), &promoted.source_handle_id)
        .unwrap();
    let retry = pipeline
        .promote_artifact(WorkflowMailPromotionRequest {
            access: access(),
            source_namespace: namespace(WorkflowStorageScopeKind::Job, "run-wfp-102"),
            destination_namespace: namespace(WorkflowStorageScopeKind::Case, "case-wfp-102"),
            source,
            destination_logical_key: "mail/artifacts/final-summary".into(),
            classification: "private".into(),
            attempt_id: "attempt-wfp-102-promote".into(),
            promoted_at_unix_millis: 4_000,
        })
        .unwrap();
    assert!(retry.duplicate);
}

#[test]
fn duplicate_attachment_identity_and_digest_drift_are_rejected_before_storage() {
    let temporary = tempdir().unwrap();
    let mut pipeline =
        WorkflowMailArtifactPipeline::open(temporary.path(), object_quota()).unwrap();
    let job = namespace(WorkflowStorageScopeKind::Job, "run-wfp-102");
    pipeline
        .storage_mut()
        .register_namespace(job.clone(), namespace_quota(), 1_000)
        .unwrap();
    let (attachment, _) = fixture();
    let duplicate = pipeline.collect_attachments(WorkflowMailAttachmentCollectionRequest {
        access: access(),
        job_namespace: job.clone(),
        attempt_id: "attempt-wfp-102-duplicate".into(),
        collected_at_unix_millis: 2_000,
        attachments: vec![attachment.clone(), attachment.clone()],
    });
    assert!(matches!(
        duplicate,
        Err(WorkflowMailArtifactError::Invalid("attachment_contract"))
    ));

    let mut drifted = attachment;
    drifted.expected_sha256 = "0".repeat(64);
    let drift = pipeline.collect_attachments(WorkflowMailAttachmentCollectionRequest {
        access: access(),
        job_namespace: job,
        attempt_id: "attempt-wfp-102-drift".into(),
        collected_at_unix_millis: 2_000,
        attachments: vec![drifted],
    });
    assert!(matches!(
        drift,
        Err(WorkflowMailArtifactError::Invalid("attachment_digest"))
    ));
}
