//! Reusable attachment, context, output, and artifact operations for mail workflows.
//!
//! Provider reads end before this boundary. Callers supply already bounded bytes and
//! scoped metadata; this module validates them, stores content by digest, compiles a
//! body-free context document, validates structured output offline, and promotes only
//! an explicitly selected durable handle. It grants no provider or effect authority.

use crate::{
    workflow_canonical::{WorkflowCanonicalError, WorkflowCanonicalReport, canonicalize},
    workflow_mail::WorkflowMailThreadEnvelope,
    workflow_object_store::{
        WorkflowObjectStore, WorkflowObjectStoreError, WorkflowObjectStoreQuota,
    },
    workflow_schema::{
        WorkflowSchemaCheckOutcome, WorkflowSchemaCheckRequest, WorkflowSchemaDiagnostic,
    },
    workflow_storage::{
        WorkflowScopedStorage, WorkflowStorageAccessContext, WorkflowStorageError,
        WorkflowStorageHandle, WorkflowStorageNamespace, WorkflowStoragePromoteReceipt,
        WorkflowStoragePromoteRequest, WorkflowStorageValueInput, WorkflowStorageWriteReceipt,
        WorkflowStorageWriteRequest,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fmt, path::Path};

const MAXIMUM_ATTACHMENTS: usize = 32;
const MAXIMUM_ATTACHMENT_BYTES: usize = 16 * 1024 * 1024;
const MAXIMUM_TOTAL_ATTACHMENT_BYTES: usize = 64 * 1024 * 1024;
const MAXIMUM_CONTEXT_BYTES: usize = 256 * 1024;
const MAXIMUM_OUTPUT_BYTES: usize = 256 * 1024;

#[derive(Debug)]
pub enum WorkflowMailArtifactError {
    Invalid(&'static str),
    ObjectStore(WorkflowObjectStoreError),
    Storage(WorkflowStorageError),
    Canonicalization,
    OutputInvalid(Vec<WorkflowSchemaDiagnostic>),
}

impl fmt::Display for WorkflowMailArtifactError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(code) => write!(formatter, "workflow mail artifact invalid: {code}"),
            Self::ObjectStore(error) => write!(formatter, "workflow mail artifact object: {error}"),
            Self::Storage(error) => write!(formatter, "workflow mail artifact storage: {error}"),
            Self::Canonicalization => {
                formatter.write_str("workflow mail artifact canonicalization")
            }
            Self::OutputInvalid(diagnostics) => write!(
                formatter,
                "workflow mail artifact output invalid: {} diagnostic(s)",
                diagnostics.len()
            ),
        }
    }
}

impl std::error::Error for WorkflowMailArtifactError {}

impl From<WorkflowObjectStoreError> for WorkflowMailArtifactError {
    fn from(value: WorkflowObjectStoreError) -> Self {
        Self::ObjectStore(value)
    }
}

impl From<WorkflowStorageError> for WorkflowMailArtifactError {
    fn from(value: WorkflowStorageError) -> Self {
        Self::Storage(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowMailArtifactError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowMailAttachmentInput {
    pub attachment_fingerprint: String,
    pub filename: String,
    pub media_type: String,
    pub expected_sha256: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowMailAttachmentCollectionRequest {
    pub access: WorkflowStorageAccessContext,
    pub job_namespace: WorkflowStorageNamespace,
    pub attempt_id: String,
    pub collected_at_unix_millis: i64,
    pub attachments: Vec<WorkflowMailAttachmentInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailCollectedAttachment {
    pub attachment_fingerprint: String,
    pub filename: String,
    pub handle: WorkflowStorageHandle,
    pub object_duplicate: bool,
    pub storage_duplicate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMailContextCompilation {
    pub canonical_bytes: Vec<u8>,
    pub sha256: String,
    pub message_count: u64,
    pub attachment_count: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkflowMailOutputRequest {
    pub access: WorkflowStorageAccessContext,
    pub namespace: WorkflowStorageNamespace,
    pub attempt_id: String,
    pub logical_key: String,
    pub schema_ref: String,
    pub schema: Value,
    pub output: Value,
    pub created_at_unix_millis: i64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct WorkflowMailValidatedOutput {
    pub canonical: WorkflowCanonicalReport,
    pub receipt: WorkflowStorageWriteReceipt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowMailPromotionRequest {
    pub access: WorkflowStorageAccessContext,
    pub source_namespace: WorkflowStorageNamespace,
    pub destination_namespace: WorkflowStorageNamespace,
    pub source: WorkflowStorageHandle,
    pub destination_logical_key: String,
    pub classification: String,
    pub attempt_id: String,
    pub promoted_at_unix_millis: i64,
}

pub struct WorkflowMailArtifactPipeline {
    objects: WorkflowObjectStore,
    storage: WorkflowScopedStorage,
}

impl WorkflowMailArtifactPipeline {
    pub fn open(root: impl AsRef<Path>, quota: WorkflowObjectStoreQuota) -> Result<Self> {
        let root = root.as_ref();
        Ok(Self {
            objects: WorkflowObjectStore::open(root, quota)?,
            storage: WorkflowScopedStorage::open(root, quota)?,
        })
    }

    pub fn storage_mut(&mut self) -> &mut WorkflowScopedStorage {
        &mut self.storage
    }

    pub fn collect_attachments(
        &mut self,
        request: WorkflowMailAttachmentCollectionRequest,
    ) -> Result<Vec<WorkflowMailCollectedAttachment>> {
        validate_collection(&request)?;
        let mut output = Vec::with_capacity(request.attachments.len());
        for attachment in request.attachments {
            let digest = sha256(&attachment.bytes);
            if normalize_digest(&attachment.expected_sha256) != Some(digest.as_str()) {
                return Err(WorkflowMailArtifactError::Invalid("attachment_digest"));
            }
            let identity = stable_identity(&[
                &request.job_namespace.owner_id,
                &attachment.attachment_fingerprint,
                &digest,
            ]);
            let write_id = format!("mail-object-{identity}");
            let mut writer = self.objects.begin_write(&write_id, Some(&digest))?;
            writer.write_chunk(&attachment.bytes)?;
            let stored = self.objects.finalize(writer)?;
            let receipt = self.storage.write_value(WorkflowStorageWriteRequest {
                command_id: format!("mail-write-{identity}"),
                access: request.access.clone(),
                namespace: request.job_namespace.clone(),
                entry_id: format!("mail-entry-{identity}"),
                version_id: format!("mail-version-{identity}"),
                reference_id: Some(format!("mail-reference-{identity}")),
                logical_key: format!("mail/attachments/{identity}"),
                expected_revision: 0,
                schema_ref: None,
                media_type: attachment.media_type,
                classification: "private".into(),
                purpose: "file".into(),
                value: WorkflowStorageValueInput::Object {
                    digest: stored.manifest.digest,
                    byte_count: stored.manifest.byte_count,
                },
                created_by_attempt_id: request.attempt_id.clone(),
                created_at_unix_millis: request.collected_at_unix_millis,
            })?;
            output.push(WorkflowMailCollectedAttachment {
                attachment_fingerprint: attachment.attachment_fingerprint,
                filename: attachment.filename,
                handle: receipt.handle,
                object_duplicate: stored.duplicate,
                storage_duplicate: receipt.duplicate,
            });
        }
        output.sort_by(|left, right| {
            left.attachment_fingerprint
                .cmp(&right.attachment_fingerprint)
        });
        Ok(output)
    }

    pub fn validate_and_store_output(
        &mut self,
        request: WorkflowMailOutputRequest,
    ) -> Result<WorkflowMailValidatedOutput> {
        let report = crate::workflow_schema::check(&WorkflowSchemaCheckRequest {
            schema: request.schema,
            instance: request.output.clone(),
        });
        if report.outcome != WorkflowSchemaCheckOutcome::Valid {
            return Err(WorkflowMailArtifactError::OutputInvalid(report.diagnostics));
        }
        let encoded = serde_json::to_vec(&request.output)
            .map_err(|_| WorkflowMailArtifactError::Canonicalization)?;
        if encoded.len() > MAXIMUM_OUTPUT_BYTES {
            return Err(WorkflowMailArtifactError::Invalid("output_bytes"));
        }
        let canonical = canonicalize(&encoded).map_err(map_canonical_error)?;
        let identity = stable_identity(&[
            &request.namespace.owner_id,
            &request.logical_key,
            &canonical.sha256,
        ]);
        let receipt = self.storage.write_value(WorkflowStorageWriteRequest {
            command_id: format!("mail-output-write-{identity}"),
            access: request.access,
            namespace: request.namespace,
            entry_id: format!("mail-output-entry-{identity}"),
            version_id: format!("mail-output-version-{identity}"),
            reference_id: None,
            logical_key: request.logical_key,
            expected_revision: 0,
            schema_ref: Some(request.schema_ref),
            media_type: "application/json".into(),
            classification: "private".into(),
            purpose: "value".into(),
            value: WorkflowStorageValueInput::InlineCanonicalJson {
                bytes: canonical.canonical_bytes.clone(),
            },
            created_by_attempt_id: request.attempt_id,
            created_at_unix_millis: request.created_at_unix_millis,
        })?;
        Ok(WorkflowMailValidatedOutput { canonical, receipt })
    }

    pub fn promote_artifact(
        &mut self,
        request: WorkflowMailPromotionRequest,
    ) -> Result<WorkflowStoragePromoteReceipt> {
        let identity = stable_identity(&[
            &request.destination_namespace.owner_id,
            &request.destination_logical_key,
            &request.source.handle_id,
        ]);
        let reference_id = (request.source.value_kind == "object")
            .then(|| format!("mail-promoted-reference-{identity}"));
        Ok(self.storage.promote_value(WorkflowStoragePromoteRequest {
            command_id: format!("mail-promote-{identity}"),
            access: request.access,
            source_namespace: request.source_namespace,
            destination_namespace: request.destination_namespace,
            source_handle_id: request.source.handle_id,
            destination_entry_id: format!("mail-promoted-entry-{identity}"),
            destination_version_id: format!("mail-promoted-version-{identity}"),
            destination_reference_id: reference_id,
            destination_logical_key: request.destination_logical_key,
            expected_revision: 0,
            schema_ref: request.source.schema_ref,
            media_type: request.source.media_type,
            classification: request.classification,
            purpose: "artifact".into(),
            promoted_by_attempt_id: request.attempt_id,
            promoted_at_unix_millis: request.promoted_at_unix_millis,
        })?)
    }
}

pub fn compile_context(
    thread: &WorkflowMailThreadEnvelope,
    attachments: &[WorkflowMailCollectedAttachment],
) -> Result<WorkflowMailContextCompilation> {
    if attachments.len() > MAXIMUM_ATTACHMENTS {
        return Err(WorkflowMailArtifactError::Invalid("context_attachments"));
    }
    let document = json!({
        "schemaVersion": 1,
        "providerKind": thread.provider_kind,
        "accountBindingId": thread.account_binding_id,
        "conversationFingerprint": thread.conversation_fingerprint,
        "cursorFingerprint": thread.cursor_fingerprint,
        "messages": thread.messages.iter().map(|message| json!({
            "messageFingerprint": message.message_fingerprint,
            "occurredAtUnixMillis": message.occurred_at_unix_millis,
            "headers": message.headers,
            "resourceIds": message.resource_ids,
        })).collect::<Vec<_>>(),
        "attachments": attachments.iter().map(|attachment| json!({
            "attachmentFingerprint": attachment.attachment_fingerprint,
            "filename": attachment.filename,
            "handleId": attachment.handle.handle_id,
            "mediaType": attachment.handle.media_type,
            "byteCount": attachment.handle.byte_count,
            "sha256": attachment.handle.sha256,
        })).collect::<Vec<_>>(),
    });
    let encoded =
        serde_json::to_vec(&document).map_err(|_| WorkflowMailArtifactError::Canonicalization)?;
    if encoded.len() > MAXIMUM_CONTEXT_BYTES {
        return Err(WorkflowMailArtifactError::Invalid("context_bytes"));
    }
    let canonical = canonicalize(&encoded).map_err(map_canonical_error)?;
    Ok(WorkflowMailContextCompilation {
        canonical_bytes: canonical.canonical_bytes,
        sha256: canonical.sha256,
        message_count: thread.messages.len() as u64,
        attachment_count: attachments.len() as u64,
    })
}

fn validate_collection(request: &WorkflowMailAttachmentCollectionRequest) -> Result<()> {
    if request.attachments.len() > MAXIMUM_ATTACHMENTS || request.collected_at_unix_millis < 0 {
        return Err(WorkflowMailArtifactError::Invalid("collection_metadata"));
    }
    let mut fingerprints = BTreeSet::new();
    let mut total = 0usize;
    for attachment in &request.attachments {
        if attachment.attachment_fingerprint.is_empty()
            || !fingerprints.insert(&attachment.attachment_fingerprint)
            || attachment.filename.is_empty()
            || attachment.filename.len() > 255
            || attachment.filename.chars().any(char::is_control)
            || attachment.media_type.is_empty()
            || attachment.media_type.len() > 255
            || !attachment
                .media_type
                .bytes()
                .all(|byte| byte.is_ascii_graphic())
            || attachment.bytes.len() > MAXIMUM_ATTACHMENT_BYTES
        {
            return Err(WorkflowMailArtifactError::Invalid("attachment_contract"));
        }
        total = total
            .checked_add(attachment.bytes.len())
            .ok_or(WorkflowMailArtifactError::Invalid("attachment_total"))?;
        if total > MAXIMUM_TOTAL_ATTACHMENT_BYTES {
            return Err(WorkflowMailArtifactError::Invalid("attachment_total"));
        }
    }
    Ok(())
}

fn normalize_digest(value: &str) -> Option<&str> {
    let value = value.strip_prefix("sha256:").unwrap_or(value);
    (value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
    .then_some(value)
}

fn sha256(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn stable_identity(components: &[&str]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"kaname.workflow.mail.artifact.v1\0");
    for component in components {
        hasher.update(component.as_bytes());
        hasher.update([0]);
    }
    hex::encode(hasher.finalize())[..32].to_owned()
}

fn map_canonical_error(_: WorkflowCanonicalError) -> WorkflowMailArtifactError {
    WorkflowMailArtifactError::Canonicalization
}
