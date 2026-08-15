//! Atomic publication of immutable workflow revision bundles.
//!
//! Publication freezes one persisted draft sequence, invokes the sole Rust
//! compiler, stages every canonical artifact, verifies a digest manifest,
//! atomically renames the directory, and only then registers the revision.
//! Activation is deliberately absent from this module.

use crate::{
    SCHEMA_MAJOR,
    v1::{CompileWorkflowRequest, SchemaVersion, WorkflowCheckOutcome},
    workflow_canonical, workflow_compiler,
    workflow_library::{
        Result, WorkflowLibraryError, WorkflowLibraryStore, ensure_private_directory,
        read_bounded_private_file, sync_directory, write_new_private_file_unflushed,
    },
    workflow_retention::WorkflowRunRetentionPolicy,
};
use rusqlite::{OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const MAXIMUM_BUNDLE_FILE_BYTES: usize = 512 * 1024;
const EXPECTED_BUNDLE_FILES: [&str; 7] = [
    "compiled.json",
    "layout.json",
    "lock.json",
    "schemas/bundle.json",
    "schemas/configuration.json",
    "validation.json",
    "workflow.json",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishWorkflowRevision {
    pub workflow_id: String,
    pub expected_draft_sequence: i64,
    pub revision_id: String,
    pub registration_id: String,
    pub release_version: String,
    pub schema_bundle_json: Vec<u8>,
    pub dependency_lock_json: Vec<u8>,
    pub configuration_contract_json: Vec<u8>,
    pub published_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishedWorkflowRevision {
    pub workflow_id: String,
    pub revision_id: String,
    pub revision_number: i64,
    pub bundle_relative_path: String,
    pub definition_digest: String,
    pub layout_digest: String,
    pub schema_bundle_digest: String,
    pub dependency_lock_digest: String,
    pub validation_digest: String,
    pub package_digest: String,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowPublicationFault {
    BeforeStagingWrite,
    AfterStagingWriteBeforeFsync,
    AfterStagingFsyncBeforeRename,
    AfterRenameBeforeRegistration,
    AfterRegistrationCommit,
}

#[derive(Debug)]
struct PreparedPublication {
    workflow_id: String,
    package_id: String,
    format_version: i64,
    files: BTreeMap<String, Vec<u8>>,
    definition_digest: String,
    layout_digest: String,
    schema_bundle_digest: String,
    dependency_lock_digest: String,
    validation_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishedCompiledContract {
    compiled_format_version: u32,
    workflow_id: String,
    package_id: String,
    definition_digest: String,
    layout_digest: String,
    schema_bundle_digest: String,
    dependency_lock_digest: String,
    configuration_contract_digest: String,
    entrypoints: Vec<PublishedCompiledEntrypoint>,
    #[serde(default)]
    interfaces: BTreeMap<String, Vec<PublishedInterfacePort>>,
    nodes: Vec<PublishedCompiledNode>,
    edges: Vec<Value>,
    resources: BTreeMap<String, String>,
    policies: BTreeMap<String, Value>,
    storage: BTreeMap<String, Value>,
    #[serde(default)]
    retention: WorkflowRunRetentionPolicy,
    dependencies: Vec<PublishedDependency>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishedCompiledEntrypoint {
    id: String,
    node_id: String,
    #[serde(default)]
    key: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishedCompiledNode {
    id: String,
    key: String,
    name: String,
    #[serde(rename = "type")]
    node_type: String,
    type_version: u32,
    execution_availability: String,
    config: Value,
    ports: Vec<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishedDependency {
    kind: String,
    id: String,
    #[serde(default)]
    version: Option<String>,
    digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PublishedInterfacePort {
    id: String,
    key: String,
    label: String,
    direction: String,
    cardinality: String,
    schema_ref: String,
    required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevisionBundleManifest {
    bundle_format_version: u32,
    workflow_id: String,
    package_id: String,
    revision_id: String,
    revision_number: i64,
    release_version: String,
    published_at_unix_millis: i64,
    files: Vec<RevisionBundleFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevisionBundleFile {
    path: String,
    media_type: String,
    role: String,
    byte_count: u64,
    sha256: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ValidationReceipt<'a> {
    validation_format_version: u32,
    outcome: &'static str,
    compiler_schema_major: u32,
    request_id: &'a str,
    diagnostics: Vec<ValidationDiagnostic<'a>>,
    digests: ValidationDigests<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ValidationDiagnostic<'a> {
    code: &'a str,
    source_id: &'a str,
    instance_pointer: &'a str,
    severity: i32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ValidationDigests<'a> {
    definition: &'a str,
    layout: &'a str,
    schema_bundle: &'a str,
    dependency_lock: &'a str,
    configuration_contract: &'a str,
    compiled_artifact: &'a str,
}

impl WorkflowLibraryStore {
    pub fn publish_revision(
        &mut self,
        request: PublishWorkflowRevision,
    ) -> Result<PublishedWorkflowRevision> {
        self.publish_revision_with_fault(request, None)
    }

    #[doc(hidden)]
    pub fn publish_revision_with_fault_for_test(
        &mut self,
        request: PublishWorkflowRevision,
        fault: WorkflowPublicationFault,
    ) -> Result<PublishedWorkflowRevision> {
        self.publish_revision_with_fault(request, Some(fault))
    }

    pub fn verify_published_revision(
        &self,
        revision_id: &str,
    ) -> Result<PublishedWorkflowRevision> {
        let stored = revision_record(&self.connection, revision_id)?.ok_or_else(|| {
            WorkflowLibraryError::PublicationConflict("revision_not_found".into())
        })?;
        let root = self.workflow_root()?;
        let directory = root.join(&stored.bundle_relative_path);
        let verified = verify_bundle(&directory)?;
        if manifest_digest(&directory)? != stored.package_digest
            || verified.workflow_id != stored.workflow_id
            || verified.revision_id != stored.revision_id
            || verified.revision_number != stored.revision_number
        {
            return Err(WorkflowLibraryError::InvalidRevisionBundle(
                "registered_bundle_mismatch".into(),
            ));
        }
        Ok(stored)
    }

    fn publish_revision_with_fault(
        &mut self,
        request: PublishWorkflowRevision,
        fault: Option<WorkflowPublicationFault>,
    ) -> Result<PublishedWorkflowRevision> {
        validate_request(&request)?;
        let draft = self.load_draft(&request.workflow_id)?;
        if draft.state != "editable" {
            return Err(WorkflowLibraryError::InvalidDraft("draft_not_publishable"));
        }
        if draft.head_sequence != request.expected_draft_sequence {
            return Err(WorkflowLibraryError::DraftConflict {
                expected: request.expected_draft_sequence,
                actual: draft.head_sequence,
            });
        }
        let prepared = prepare_publication(&request, &draft.workflow_source, &draft.layout_source)?;
        validate_pinned_subflows(self, &prepared)?;
        let workflow_root = self.workflow_root()?;
        let revisions = workflow_root.join("Revisions").join(&request.workflow_id);
        let staging_root = workflow_root.join("Staging").join("Revisions");
        ensure_private_directory(&revisions)?;
        ensure_private_directory(&staging_root)?;

        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(stored) = revision_record(&transaction, &request.revision_id)? {
            return verify_duplicate_publication(
                &transaction,
                &workflow_root,
                stored,
                &request,
                &prepared,
            );
        }
        let revision_number: i64 = transaction.query_row(
            "SELECT COALESCE(MAX(revision_number), 0) + 1
             FROM workflow_revisions WHERE workflow_id = ?1",
            [&request.workflow_id],
            |row| row.get(0),
        )?;
        let directory_name = format!("{revision_number}-{}", request.revision_id);
        let final_directory = revisions.join(&directory_name);
        let staging_directory =
            staging_root.join(format!("{}-{directory_name}.staging", request.workflow_id));
        let manifest = bundle_manifest(&request, &prepared, revision_number);
        let manifest_bytes = canonical_json(&manifest, "bundle_manifest")?;
        let package_digest = sha256_hex(&manifest_bytes);

        if fault == Some(WorkflowPublicationFault::BeforeStagingWrite) {
            return Err(WorkflowLibraryError::InjectedPublicationInterruption(
                "before_staging_write",
            ));
        }
        prepare_staging_directory(
            &workflow_root,
            &staging_directory,
            &manifest,
            &manifest_bytes,
            &prepared.files,
        )?;
        if fault == Some(WorkflowPublicationFault::AfterStagingWriteBeforeFsync) {
            return Err(WorkflowLibraryError::InjectedPublicationInterruption(
                "after_staging_write",
            ));
        }
        sync_bundle(&staging_directory)?;
        if fault == Some(WorkflowPublicationFault::AfterStagingFsyncBeforeRename) {
            return Err(WorkflowLibraryError::InjectedPublicationInterruption(
                "after_staging_fsync",
            ));
        }
        verify_expected_bundle(&staging_directory, &manifest, &package_digest)?;
        if final_directory.exists() {
            verify_expected_bundle(&final_directory, &manifest, &package_digest)?;
            if staging_directory.exists() {
                fs::remove_dir_all(&staging_directory)?;
                sync_directory(&staging_root)?;
            }
        } else {
            fs::rename(&staging_directory, &final_directory)?;
            sync_directory(&revisions)?;
        }
        make_bundle_immutable(&final_directory)?;
        if fault == Some(WorkflowPublicationFault::AfterRenameBeforeRegistration) {
            return Err(WorkflowLibraryError::InjectedPublicationInterruption(
                "after_revision_rename",
            ));
        }

        let bundle_relative_path = format!("Revisions/{}/{directory_name}", request.workflow_id);
        register_revision(
            &transaction,
            &request,
            &prepared,
            revision_number,
            &bundle_relative_path,
            &package_digest,
        )?;
        transaction.commit()?;

        let published = PublishedWorkflowRevision {
            workflow_id: request.workflow_id,
            revision_id: request.revision_id,
            revision_number,
            bundle_relative_path,
            definition_digest: prepared.definition_digest,
            layout_digest: prepared.layout_digest,
            schema_bundle_digest: prepared.schema_bundle_digest,
            dependency_lock_digest: prepared.dependency_lock_digest,
            validation_digest: prepared.validation_digest,
            package_digest,
            duplicate: false,
        };
        if fault == Some(WorkflowPublicationFault::AfterRegistrationCommit) {
            return Err(WorkflowLibraryError::InjectedPublicationInterruption(
                "after_registration_commit",
            ));
        }
        Ok(published)
    }

    pub(crate) fn workflow_root(&self) -> Result<PathBuf> {
        self.database_path
            .as_ref()
            .and_then(|path| path.parent())
            .map(Path::to_path_buf)
            .ok_or(WorkflowLibraryError::PublicationConflict(
                "file_backing_required".into(),
            ))
    }
}

fn validate_pinned_subflows(
    library: &WorkflowLibraryStore,
    prepared: &PreparedPublication,
) -> Result<()> {
    let compiled = parse_compiled_contract(
        prepared
            .files
            .get("compiled.json")
            .ok_or_else(|| workflow_compilation_error("dependency.subflow.compiled-missing"))?,
    )?;
    if compiled.package_id != prepared.package_id || compiled.workflow_id != prepared.workflow_id {
        return Err(workflow_compilation_error(
            "dependency.subflow.parent-identity",
        ));
    }
    let mut package_stack = BTreeSet::from([prepared.package_id.clone()]);
    let mut visited = BTreeSet::new();
    validate_compiled_subflows(library, &compiled, &mut package_stack, &mut visited, 0)
}

fn validate_compiled_subflows(
    library: &WorkflowLibraryStore,
    compiled: &PublishedCompiledContract,
    package_stack: &mut BTreeSet<String>,
    visited: &mut BTreeSet<String>,
    depth: usize,
) -> Result<()> {
    if depth > 16 {
        return Err(workflow_compilation_error("dependency.subflow.depth"));
    }
    for node in compiled
        .nodes
        .iter()
        .filter(|node| node.node_type == "control.subflow")
    {
        let package_id = node
            .config
            .get("packageId")
            .and_then(Value::as_str)
            .ok_or_else(|| workflow_compilation_error("dependency.subflow.package"))?;
        let digest = node
            .config
            .get("revisionDigest")
            .and_then(Value::as_str)
            .ok_or_else(|| workflow_compilation_error("dependency.subflow.digest"))?;
        let entrypoint = node
            .config
            .get("entrypoint")
            .and_then(Value::as_str)
            .ok_or_else(|| workflow_compilation_error("dependency.subflow.entrypoint"))?;
        if node.config.get("input") != Some(&serde_json::json!({"whole": true})) {
            return Err(workflow_compilation_error(
                "dependency.subflow.input-mapping",
            ));
        }
        let pins = compiled
            .dependencies
            .iter()
            .filter(|dependency| {
                dependency.kind == "subflow"
                    && dependency.id == package_id
                    && dependency.digest == digest
            })
            .count();
        if pins != 1 {
            return Err(workflow_compilation_error("dependency.subflow.lock"));
        }
        if !package_stack.insert(package_id.to_owned()) {
            return Err(workflow_compilation_error("dependency.subflow.cycle"));
        }
        let child = library
            .load_workflow_revision_by_package_digest(package_id, digest)
            .map_err(|_| workflow_compilation_error("dependency.subflow.unresolved"))?;
        let child_compiled = parse_compiled_contract(&child.compiled_source)?;
        if child_compiled.package_id != package_id
            || child_compiled.workflow_id != child.summary.workflow_id
            || child.summary.package_digest
                != digest
                    .strip_prefix("sha256:")
                    .unwrap_or(digest)
                    .to_ascii_lowercase()
        {
            return Err(workflow_compilation_error(
                "dependency.subflow.pin-mismatch",
            ));
        }
        validate_subflow_interface(&child_compiled, entrypoint)?;
        let visit_key = format!("{}:{}", package_id, child.summary.package_digest);
        if visited.insert(visit_key) {
            validate_compiled_subflows(
                library,
                &child_compiled,
                package_stack,
                visited,
                depth + 1,
            )?;
        }
        package_stack.remove(package_id);
    }
    Ok(())
}

fn validate_subflow_interface(
    child: &PublishedCompiledContract,
    requested_entrypoint: &str,
) -> Result<()> {
    let entrypoints = child
        .entrypoints
        .iter()
        .filter(|entrypoint| entrypoint.key.as_deref() == Some(requested_entrypoint))
        .collect::<Vec<_>>();
    if entrypoints.len() != 1 {
        return Err(workflow_compilation_error(
            "dependency.subflow.entrypoint-missing",
        ));
    }
    let ports = child
        .interfaces
        .get(requested_entrypoint)
        .ok_or_else(|| workflow_compilation_error("dependency.subflow.interface-missing"))?;
    let compatible = |id: &str, direction: &str, required: bool| {
        ports.iter().any(|port| {
            port.id == id
                && port.key == id
                && !port.label.is_empty()
                && port.direction == direction
                && port.cardinality == "one"
                && port.schema_ref == "dev.kaname.workflow.data/v1"
                && port.required == required
        })
    };
    if ports.len() != 2
        || !compatible("input", "input", true)
        || !compatible("success", "output", true)
    {
        return Err(workflow_compilation_error(
            "dependency.subflow.interface-incompatible",
        ));
    }
    Ok(())
}

fn parse_compiled_contract(bytes: &[u8]) -> Result<PublishedCompiledContract> {
    let compiled: PublishedCompiledContract = serde_json::from_slice(bytes)
        .map_err(|_| workflow_compilation_error("dependency.subflow.compiled-contract"))?;
    if compiled.compiled_format_version != 1
        || compiled.definition_digest.is_empty()
        || compiled.layout_digest.is_empty()
        || compiled.schema_bundle_digest.is_empty()
        || compiled.dependency_lock_digest.is_empty()
        || compiled.configuration_contract_digest.is_empty()
        || compiled.entrypoints.is_empty()
        || compiled.edges.len() > 4096
        || compiled.resources.len() > 1024
        || compiled.policies.len() > 1024
        || compiled.storage.len() > 1024
        || compiled.retention.validate().is_err()
        || compiled.dependencies.len() > 1024
        || compiled.nodes.iter().any(|node| {
            node.id.is_empty()
                || node.key.is_empty()
                || node.name.is_empty()
                || node.type_version == 0
                || node.execution_availability.is_empty()
                || node.ports.is_empty()
        })
        || compiled
            .entrypoints
            .iter()
            .any(|entrypoint| entrypoint.id.is_empty() || entrypoint.node_id.is_empty())
        || compiled.dependencies.iter().any(|dependency| {
            dependency.kind.is_empty()
                || dependency.id.is_empty()
                || dependency.digest.is_empty()
                || dependency.version.as_deref() == Some("")
        })
    {
        return Err(workflow_compilation_error(
            "dependency.subflow.compiled-contract",
        ));
    }
    Ok(compiled)
}

fn workflow_compilation_error(code: &str) -> WorkflowLibraryError {
    WorkflowLibraryError::WorkflowCompilationFailed(vec![code.into()])
}

fn prepare_publication(
    request: &PublishWorkflowRevision,
    workflow_source: &[u8],
    layout_source: &[u8],
) -> Result<PreparedPublication> {
    let workflow = canonical_source(workflow_source, "workflow_source")?;
    let layout = canonical_source(layout_source, "layout_source")?;
    let schemas = canonical_source(&request.schema_bundle_json, "schema_bundle")?;
    let lock = canonical_source(&request.dependency_lock_json, "dependency_lock")?;
    let configuration = canonical_source(
        &request.configuration_contract_json,
        "configuration_contract",
    )?;
    let workflow_value: Value = serde_json::from_slice(&workflow.0).map_err(|_| {
        WorkflowLibraryError::WorkflowCompilationFailed(vec!["workflow_json".into()])
    })?;
    let layout_value: Value = serde_json::from_slice(&layout.0)
        .map_err(|_| WorkflowLibraryError::WorkflowCompilationFailed(vec!["layout_json".into()]))?;
    let workflow_id = workflow_value
        .get("workflowId")
        .and_then(Value::as_str)
        .ok_or_else(|| WorkflowLibraryError::WorkflowCompilationFailed(vec!["workflow_id".into()]))?
        .to_owned();
    let package_id = workflow_value
        .get("packageId")
        .and_then(Value::as_str)
        .ok_or_else(|| WorkflowLibraryError::WorkflowCompilationFailed(vec!["package_id".into()]))?
        .to_owned();
    let format_version = workflow_value
        .get("formatVersion")
        .and_then(Value::as_i64)
        .ok_or_else(|| {
            WorkflowLibraryError::WorkflowCompilationFailed(vec!["format_version".into()])
        })?;
    if workflow_id != request.workflow_id {
        return Err(WorkflowLibraryError::PublicationConflict(
            "draft_workflow_identity_mismatch".into(),
        ));
    }

    let request_id = format!("publish:{}", request.revision_id);
    let compile_request = CompileWorkflowRequest {
        schema_version: Some(SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
        request_id: request_id.clone(),
        manifest_json: serde_json::to_vec(&serde_json::json!({
            "compileManifestVersion": 1,
            "workflow": workflow_value,
            "layout": layout_value,
        }))
        .map_err(|_| WorkflowLibraryError::WorkflowCompilationFailed(vec!["manifest".into()]))?,
        schema_bundle_json: schemas.0.clone(),
        dependency_lock_json: lock.0.clone(),
        configuration_contract_json: configuration.0.clone(),
        maximum_diagnostics: 256,
    };
    let response = workflow_compiler::compile(&compile_request);
    if response.outcome != WorkflowCheckOutcome::Valid as i32
        || response.diagnostics_truncated
        || response.compiled_artifact.is_empty()
    {
        let mut codes = response
            .diagnostics
            .iter()
            .map(|diagnostic| diagnostic.code.clone())
            .collect::<Vec<_>>();
        codes.sort();
        codes.dedup();
        if response.diagnostics_truncated {
            codes.push("diagnostics_truncated".into());
        }
        return Err(WorkflowLibraryError::WorkflowCompilationFailed(codes));
    }
    let digests = response
        .digests
        .as_ref()
        .ok_or_else(|| WorkflowLibraryError::WorkflowCompilationFailed(vec!["digests".into()]))?;
    let definition_digest = raw_digest(&digests.definition_digest)?;
    verify_compiler_digest(&digests.layout_digest, &layout.1, "layout")?;
    verify_compiler_digest(&digests.schema_bundle_digest, &schemas.1, "schemas")?;
    verify_compiler_digest(&digests.dependency_lock_digest, &lock.1, "lock")?;
    verify_compiler_digest(
        &digests.configuration_contract_digest,
        &configuration.1,
        "configuration",
    )?;
    verify_compiler_digest(
        &digests.compiled_artifact_digest,
        &sha256_hex(&response.compiled_artifact),
        "compiled",
    )?;

    let validation = ValidationReceipt {
        validation_format_version: 1,
        outcome: "valid",
        compiler_schema_major: SCHEMA_MAJOR,
        request_id: &request_id,
        diagnostics: response
            .diagnostics
            .iter()
            .map(|diagnostic| ValidationDiagnostic {
                code: &diagnostic.code,
                source_id: diagnostic
                    .location
                    .as_ref()
                    .map(|location| location.source_id.as_str())
                    .unwrap_or(""),
                instance_pointer: &diagnostic.instance_pointer,
                severity: diagnostic.severity,
            })
            .collect(),
        digests: ValidationDigests {
            definition: &digests.definition_digest,
            layout: &digests.layout_digest,
            schema_bundle: &digests.schema_bundle_digest,
            dependency_lock: &digests.dependency_lock_digest,
            configuration_contract: &digests.configuration_contract_digest,
            compiled_artifact: &digests.compiled_artifact_digest,
        },
    };
    let validation_bytes = canonical_json(&validation, "validation_receipt")?;
    let validation_digest = sha256_hex(&validation_bytes);
    let mut files = BTreeMap::new();
    files.insert("workflow.json".into(), workflow.0);
    files.insert("layout.json".into(), layout.0);
    files.insert("compiled.json".into(), response.compiled_artifact);
    files.insert("lock.json".into(), lock.0);
    files.insert("schemas/bundle.json".into(), schemas.0);
    files.insert("schemas/configuration.json".into(), configuration.0);
    files.insert("validation.json".into(), validation_bytes);
    Ok(PreparedPublication {
        workflow_id,
        package_id,
        format_version,
        files,
        definition_digest,
        layout_digest: layout.1,
        schema_bundle_digest: schemas.1,
        dependency_lock_digest: lock.1,
        validation_digest,
    })
}

fn bundle_manifest(
    request: &PublishWorkflowRevision,
    prepared: &PreparedPublication,
    revision_number: i64,
) -> RevisionBundleManifest {
    let files = prepared
        .files
        .iter()
        .map(|(path, bytes)| RevisionBundleFile {
            path: path.clone(),
            media_type: "application/json".into(),
            role: bundle_role(path).into(),
            byte_count: bytes.len() as u64,
            sha256: sha256_hex(bytes),
        })
        .collect();
    RevisionBundleManifest {
        bundle_format_version: 1,
        workflow_id: prepared.workflow_id.clone(),
        package_id: prepared.package_id.clone(),
        revision_id: request.revision_id.clone(),
        revision_number,
        release_version: request.release_version.clone(),
        published_at_unix_millis: request.published_at_unix_millis,
        files,
    }
}

fn prepare_staging_directory(
    workflow_root: &Path,
    staging: &Path,
    expected: &RevisionBundleManifest,
    manifest_bytes: &[u8],
    files: &BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    if staging.exists() {
        let package_digest = sha256_hex(manifest_bytes);
        if verify_expected_bundle(staging, expected, &package_digest).is_ok() {
            return Ok(());
        }
        quarantine_bundle(workflow_root, staging)?;
    }
    ensure_private_directory(staging)?;
    ensure_private_directory(&staging.join("schemas"))?;
    let mut open_files = Vec::new();
    for (relative, bytes) in files {
        let path = staging.join(relative);
        open_files.push(write_new_private_file_unflushed(&path, bytes)?);
    }
    open_files.push(write_new_private_file_unflushed(
        &staging.join("manifest.json"),
        manifest_bytes,
    )?);
    drop(open_files);
    Ok(())
}

fn sync_bundle(directory: &Path) -> Result<()> {
    for path in all_bundle_paths(directory)? {
        if path.is_file() {
            File::open(&path)?.sync_all()?;
        }
    }
    sync_directory(&directory.join("schemas"))?;
    sync_directory(directory)
}

fn verify_expected_bundle(
    directory: &Path,
    expected: &RevisionBundleManifest,
    package_digest: &str,
) -> Result<()> {
    let actual = verify_bundle(directory)?;
    if &actual != expected || manifest_digest(directory)? != package_digest {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "expected_manifest_mismatch".into(),
        ));
    }
    Ok(())
}

fn verify_bundle(directory: &Path) -> Result<RevisionBundleManifest> {
    let manifest_path = directory.join("manifest.json");
    let manifest_bytes = read_bounded_private_file(&manifest_path, MAXIMUM_BUNDLE_FILE_BYTES)?;
    let canonical = workflow_canonical::canonicalize(&manifest_bytes)
        .map_err(|_| WorkflowLibraryError::InvalidRevisionBundle("manifest_json".into()))?;
    if canonical.canonical_bytes != manifest_bytes {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "manifest_not_canonical".into(),
        ));
    }
    let manifest: RevisionBundleManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| WorkflowLibraryError::InvalidRevisionBundle("manifest_contract".into()))?;
    if manifest.bundle_format_version != 1 || manifest.revision_number <= 0 {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "manifest_version".into(),
        ));
    }
    let expected_paths = EXPECTED_BUNDLE_FILES
        .into_iter()
        .map(str::to_owned)
        .collect::<BTreeSet<_>>();
    let actual_paths = manifest
        .files
        .iter()
        .map(|file| file.path.clone())
        .collect::<BTreeSet<_>>();
    if actual_paths != expected_paths || actual_paths.len() != manifest.files.len() {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "manifest_file_set".into(),
        ));
    }
    for entry in &manifest.files {
        if !safe_bundle_path(&entry.path)
            || entry.media_type != "application/json"
            || entry.role != bundle_role(&entry.path)
        {
            return Err(WorkflowLibraryError::InvalidRevisionBundle(
                "manifest_file_contract".into(),
            ));
        }
        let bytes =
            read_bounded_private_file(&directory.join(&entry.path), MAXIMUM_BUNDLE_FILE_BYTES)?;
        if bytes.len() as u64 != entry.byte_count || sha256_hex(&bytes) != entry.sha256 {
            return Err(WorkflowLibraryError::InvalidRevisionBundle(
                "file_digest_mismatch".into(),
            ));
        }
    }
    let disk_paths = all_bundle_paths(directory)?
        .into_iter()
        .filter(|path| path.is_file())
        .map(|path| {
            path.strip_prefix(directory)
                .unwrap()
                .to_string_lossy()
                .to_string()
        })
        .collect::<BTreeSet<_>>();
    let mut expected_disk = expected_paths;
    expected_disk.insert("manifest.json".into());
    if disk_paths != expected_disk {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "unexpected_bundle_file".into(),
        ));
    }
    Ok(manifest)
}

fn register_revision(
    transaction: &Transaction<'_>,
    request: &PublishWorkflowRevision,
    prepared: &PreparedPublication,
    revision_number: i64,
    bundle_relative_path: &str,
    package_digest: &str,
) -> Result<()> {
    transaction.execute(
        "INSERT INTO workflow_revisions
           (revision_id, workflow_id, revision_number, bundle_relative_path,
            definition_digest, layout_digest, schema_bundle_digest,
            dependency_lock_digest, validation_digest, package_digest,
            format_version, created_at_unix_millis)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            request.revision_id,
            request.workflow_id,
            revision_number,
            bundle_relative_path,
            prepared.definition_digest,
            prepared.layout_digest,
            prepared.schema_bundle_digest,
            prepared.dependency_lock_digest,
            prepared.validation_digest,
            package_digest,
            prepared.format_version,
            request.published_at_unix_millis,
        ],
    )?;
    transaction.execute(
        "INSERT INTO package_registrations
           (registration_id, package_id, release_version, workflow_id,
            revision_id, package_digest, source_kind, registration_state,
            registered_at_unix_millis)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'local', 'registered', ?7)",
        params![
            request.registration_id,
            prepared.package_id,
            request.release_version,
            request.workflow_id,
            request.revision_id,
            package_digest,
            request.published_at_unix_millis,
        ],
    )?;
    let updated = transaction.execute(
        "UPDATE workflow_identities
         SET lifecycle_state = 'published', updated_at_unix_millis = ?1
         WHERE workflow_id = ?2 AND package_id = ?3",
        params![
            request.published_at_unix_millis,
            request.workflow_id,
            prepared.package_id,
        ],
    )?;
    if updated != 1 {
        return Err(WorkflowLibraryError::PublicationConflict(
            "library_identity_mismatch".into(),
        ));
    }
    Ok(())
}

fn revision_record(
    connection: &rusqlite::Connection,
    revision_id: &str,
) -> Result<Option<PublishedWorkflowRevision>> {
    Ok(connection
        .query_row(
            "SELECT workflow_id, revision_id, revision_number, bundle_relative_path,
                    definition_digest, layout_digest, schema_bundle_digest,
                    dependency_lock_digest, validation_digest, package_digest
             FROM workflow_revisions WHERE revision_id = ?1",
            [revision_id],
            |row| {
                Ok(PublishedWorkflowRevision {
                    workflow_id: row.get(0)?,
                    revision_id: row.get(1)?,
                    revision_number: row.get(2)?,
                    bundle_relative_path: row.get(3)?,
                    definition_digest: row.get(4)?,
                    layout_digest: row.get(5)?,
                    schema_bundle_digest: row.get(6)?,
                    dependency_lock_digest: row.get(7)?,
                    validation_digest: row.get(8)?,
                    package_digest: row.get(9)?,
                    duplicate: false,
                })
            },
        )
        .optional()?)
}

fn verify_duplicate_publication(
    connection: &rusqlite::Connection,
    workflow_root: &Path,
    mut stored: PublishedWorkflowRevision,
    request: &PublishWorkflowRevision,
    prepared: &PreparedPublication,
) -> Result<PublishedWorkflowRevision> {
    let directory = workflow_root.join(&stored.bundle_relative_path);
    let manifest = verify_bundle(&directory)?;
    let registration: Option<(String, String)> = connection
        .query_row(
            "SELECT registration_id, package_id
             FROM package_registrations WHERE revision_id = ?1",
            [&request.revision_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if stored.workflow_id != request.workflow_id
        || stored.revision_id != request.revision_id
        || stored.definition_digest != prepared.definition_digest
        || stored.layout_digest != prepared.layout_digest
        || stored.schema_bundle_digest != prepared.schema_bundle_digest
        || stored.dependency_lock_digest != prepared.dependency_lock_digest
        || stored.validation_digest != prepared.validation_digest
        || stored.package_digest != manifest_digest(&directory)?
        || manifest.release_version != request.release_version
        || manifest.published_at_unix_millis != request.published_at_unix_millis
        || manifest.package_id != prepared.package_id
        || registration != Some((request.registration_id.clone(), prepared.package_id.clone()))
    {
        return Err(WorkflowLibraryError::PublicationConflict(
            "revision_identity_reused".into(),
        ));
    }
    stored.duplicate = true;
    Ok(stored)
}

fn validate_request(request: &PublishWorkflowRevision) -> Result<()> {
    for (value, maximum, code) in [
        (request.workflow_id.as_str(), 128, "workflow_id"),
        (request.revision_id.as_str(), 128, "revision_id"),
        (request.registration_id.as_str(), 128, "registration_id"),
        (request.release_version.as_str(), 128, "release_version"),
    ] {
        if value.is_empty()
            || value.len() > maximum
            || value.chars().any(char::is_control)
            || ((code == "workflow_id" || code == "revision_id" || code == "registration_id")
                && !value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'))
        {
            return Err(WorkflowLibraryError::PublicationConflict(code.into()));
        }
    }
    if request.expected_draft_sequence < 0 || request.published_at_unix_millis < 0 {
        return Err(WorkflowLibraryError::PublicationConflict(
            "publication_bounds".into(),
        ));
    }
    Ok(())
}

fn canonical_source(bytes: &[u8], code: &str) -> Result<(Vec<u8>, String)> {
    let report = workflow_canonical::canonicalize(bytes)
        .map_err(|_| WorkflowLibraryError::WorkflowCompilationFailed(vec![code.to_owned()]))?;
    Ok((report.canonical_bytes, raw_digest(&report.sha256)?))
}

fn canonical_json(value: &impl Serialize, code: &str) -> Result<Vec<u8>> {
    let bytes = serde_json::to_vec(value)
        .map_err(|_| WorkflowLibraryError::InvalidRevisionBundle(code.into()))?;
    workflow_canonical::canonicalize(&bytes)
        .map(|report| report.canonical_bytes)
        .map_err(|_| WorkflowLibraryError::InvalidRevisionBundle(code.into()))
}

fn verify_compiler_digest(actual: &str, expected_raw: &str, code: &str) -> Result<()> {
    if raw_digest(actual)? != expected_raw {
        return Err(WorkflowLibraryError::WorkflowCompilationFailed(vec![
            format!("{code}_digest"),
        ]));
    }
    Ok(())
}

fn raw_digest(value: &str) -> Result<String> {
    let raw = value.strip_prefix("sha256:").unwrap_or(value);
    if raw.len() != 64 || !raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(WorkflowLibraryError::InvalidRevisionBundle(
            "digest_contract".into(),
        ));
    }
    Ok(raw.to_ascii_lowercase())
}

fn manifest_digest(directory: &Path) -> Result<String> {
    Ok(sha256_hex(&read_bounded_private_file(
        &directory.join("manifest.json"),
        MAXIMUM_BUNDLE_FILE_BYTES,
    )?))
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn bundle_role(path: &str) -> &'static str {
    match path {
        "workflow.json" => "definition",
        "layout.json" => "layout",
        "compiled.json" => "compiled",
        "lock.json" => "dependency-lock",
        "schemas/bundle.json" => "schema-bundle",
        "schemas/configuration.json" => "configuration-contract",
        "validation.json" => "validation-receipt",
        _ => "unknown",
    }
}

fn safe_bundle_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains("..")
        && path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_/.".contains(&byte))
}

fn all_bundle_paths(directory: &Path) -> Result<Vec<PathBuf>> {
    let mut pending = vec![directory.to_path_buf()];
    let mut paths = Vec::new();
    while let Some(current) = pending.pop() {
        for entry in fs::read_dir(&current)? {
            let entry = entry?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.file_type().is_symlink() {
                return Err(WorkflowLibraryError::InvalidRevisionBundle(
                    "bundle_symlink".into(),
                ));
            }
            if metadata.is_dir() {
                pending.push(path.clone());
            } else if !metadata.is_file() {
                return Err(WorkflowLibraryError::InvalidRevisionBundle(
                    "bundle_non_file".into(),
                ));
            }
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn make_bundle_immutable(directory: &Path) -> Result<()> {
    let mut directories = vec![directory.to_path_buf()];
    for path in all_bundle_paths(directory)? {
        if path.is_dir() {
            directories.push(path);
        } else {
            #[cfg(unix)]
            fs::set_permissions(&path, fs::Permissions::from_mode(0o400))?;
            #[cfg(not(unix))]
            {
                let mut permissions = fs::metadata(&path)?.permissions();
                permissions.set_readonly(true);
                fs::set_permissions(&path, permissions)?;
            }
        }
    }
    directories.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    for path in directories {
        #[cfg(unix)]
        fs::set_permissions(path, fs::Permissions::from_mode(0o500))?;
        #[cfg(not(unix))]
        {
            let mut permissions = fs::metadata(&path)?.permissions();
            permissions.set_readonly(true);
            fs::set_permissions(&path, permissions)?;
        }
    }
    Ok(())
}

fn quarantine_bundle(workflow_root: &Path, source: &Path) -> Result<()> {
    let recovery = workflow_root.join("Recovery").join("Revisions");
    ensure_private_directory(&recovery)?;
    let name = source
        .file_name()
        .ok_or_else(|| WorkflowLibraryError::InvalidRevisionBundle("bundle_name".into()))?;
    let target = recovery.join(format!("{}-{}", unix_millis(), name.to_string_lossy()));
    fs::rename(source, &target)?;
    sync_directory(&recovery)
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
