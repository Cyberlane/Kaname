//! Idempotent import of a frozen legacy workspace into read-only v2 drafts.
//!
//! Swift owns legacy snapshot decoding and produces sanitized v2 source plus a
//! comparison document. Rust verifies those products, persists immutable
//! comparison evidence, and records the workspace digest without ever reading
//! or mutating the legacy file itself.

use crate::{
    workflow_canonical,
    workflow_drafts::CreateWorkflowDraft,
    workflow_library::{
        Result, WorkflowLibraryError, WorkflowLibraryStore, ensure_private_directory,
        is_workflow_identifier, read_bounded_private_file, sync_directory, write_new_private_file,
    },
};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs, path::Path};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const MAXIMUM_IMPORTED_WORKFLOWS: usize = 256;
const MAXIMUM_COMPARISON_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportFrozenWorkflowDraft {
    pub workflow_id: String,
    pub package_id: String,
    pub name: String,
    pub summary: String,
    pub workflow_source: Vec<u8>,
    pub layout_source: Vec<u8>,
    pub comparison_source: Vec<u8>,
    pub blocked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportFrozenWorkspace {
    pub receipt_id: String,
    pub source_digest: String,
    pub imported_at_unix_millis: i64,
    pub drafts: Vec<ImportFrozenWorkflowDraft>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportedFrozenWorkflow {
    pub workflow_id: String,
    pub generation: i64,
    pub blocked: bool,
    pub comparison_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrozenWorkspaceImportReceipt {
    pub source_digest: String,
    pub outcome: String,
    pub comparison_digest: String,
    pub duplicate: bool,
    pub workflows: Vec<ImportedFrozenWorkflow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FrozenImportManifest {
    format_version: u32,
    source_digest: String,
    outcome: String,
    workflows: Vec<ImportedFrozenWorkflow>,
}

impl WorkflowLibraryStore {
    pub fn import_frozen_workspace(
        &mut self,
        request: ImportFrozenWorkspace,
    ) -> Result<FrozenWorkspaceImportReceipt> {
        let prepared = prepare_import(&request)?;
        if let Some(outcome) = existing_receipt(self, &request, &prepared)? {
            verify_import_bundle(self, &prepared)?;
            verify_imported_drafts(self, &request, &prepared)?;
            return Ok(receipt(&request, &prepared, outcome, true));
        }

        let recovering_interrupted_import = import_bundle_exists(self, &prepared)?;
        if recovering_interrupted_import {
            verify_import_bundle(self, &prepared)?;
        }
        verify_import_targets(self, &request, recovering_interrupted_import)?;
        install_import_bundle(self, &prepared)?;
        for item in &prepared.manifest.workflows {
            let draft = request
                .drafts
                .iter()
                .find(|candidate| candidate.workflow_id == item.workflow_id)
                .ok_or(WorkflowLibraryError::InvalidImport("draft_missing"))?;
            adopt_or_create_draft(self, &request, draft, item, recovering_interrupted_import)?;
        }
        let inserted = self.connection.execute(
            "INSERT INTO import_receipts
               (receipt_id, source_kind, source_digest, workflow_id,
                draft_generation, outcome, loss_report_digest, imported_at_unix_millis)
             VALUES (?1, 'workspace-snapshot', ?2, NULL, NULL, ?3, ?4, ?5)",
            params![
                request.receipt_id,
                request.source_digest,
                prepared.manifest.outcome,
                prepared.manifest_digest,
                request.imported_at_unix_millis,
            ],
        )?;
        if inserted != 1 {
            return Err(WorkflowLibraryError::ImportConflict(
                "receipt_insert_count".into(),
            ));
        }
        Ok(receipt(
            &request,
            &prepared,
            prepared.manifest.outcome.clone(),
            false,
        ))
    }
}

struct PreparedImport {
    manifest: FrozenImportManifest,
    manifest_bytes: Vec<u8>,
    manifest_digest: String,
    comparisons: Vec<Vec<u8>>,
}

fn prepare_import(request: &ImportFrozenWorkspace) -> Result<PreparedImport> {
    validate_identifier(&request.receipt_id, 128, "receipt_id")?;
    validate_digest(&request.source_digest, "source_digest")?;
    if request.imported_at_unix_millis < 0 {
        return Err(WorkflowLibraryError::InvalidImport("imported_at"));
    }
    if request.drafts.is_empty() || request.drafts.len() > MAXIMUM_IMPORTED_WORKFLOWS {
        return Err(WorkflowLibraryError::InvalidImport("draft_count"));
    }
    let mut identities = BTreeSet::new();
    let mut package_ids = BTreeSet::new();
    let mut prepared_workflows = Vec::with_capacity(request.drafts.len());
    for draft in &request.drafts {
        validate_draft(request, draft)?;
        if !identities.insert(draft.workflow_id.clone()) {
            return Err(WorkflowLibraryError::InvalidImport("duplicate_workflow_id"));
        }
        if !package_ids.insert(draft.package_id.clone()) {
            return Err(WorkflowLibraryError::InvalidImport("duplicate_package_id"));
        }
        let comparison = canonical_comparison(request, draft)?;
        let comparison_digest = sha256_hex(&comparison);
        prepared_workflows.push((
            ImportedFrozenWorkflow {
                workflow_id: draft.workflow_id.clone(),
                generation: 1,
                blocked: draft.blocked,
                comparison_digest,
            },
            comparison,
        ));
    }
    prepared_workflows.sort_by(|left, right| left.0.workflow_id.cmp(&right.0.workflow_id));
    let (workflows, comparisons): (Vec<_>, Vec<_>) = prepared_workflows.into_iter().unzip();
    let outcome = if workflows.iter().any(|item| item.blocked) {
        "blocked"
    } else {
        "created"
    };
    let manifest = FrozenImportManifest {
        format_version: 1,
        source_digest: request.source_digest.clone(),
        outcome: outcome.into(),
        workflows,
    };
    let encoded = serde_json::to_vec(&manifest)
        .map_err(|_| WorkflowLibraryError::InvalidImport("manifest_encoding"))?;
    let manifest_bytes = workflow_canonical::canonicalize(&encoded)
        .map_err(|_| WorkflowLibraryError::InvalidImport("manifest_canonical"))?
        .canonical_bytes;
    let manifest_digest = sha256_hex(&manifest_bytes);
    Ok(PreparedImport {
        manifest,
        manifest_bytes,
        manifest_digest,
        comparisons,
    })
}

fn validate_draft(
    request: &ImportFrozenWorkspace,
    draft: &ImportFrozenWorkflowDraft,
) -> Result<()> {
    validate_identifier(&draft.workflow_id, 128, "workflow_id")?;
    validate_text(&draft.package_id, 255, "package_id")?;
    validate_text(&draft.name, 160, "name")?;
    if draft.summary.len() > 1_000 || draft.summary.chars().any(char::is_control) {
        return Err(WorkflowLibraryError::InvalidImport("summary"));
    }
    let workflow: Value = serde_json::from_slice(&draft.workflow_source)
        .map_err(|_| WorkflowLibraryError::InvalidImport("workflow_json"))?;
    if workflow.get("workflowId").and_then(Value::as_str) != Some(&draft.workflow_id)
        || workflow.get("packageId").and_then(Value::as_str) != Some(&draft.package_id)
        || workflow.get("name").and_then(Value::as_str) != Some(&draft.name)
        || workflow.get("summary").and_then(Value::as_str) != Some(&draft.summary)
    {
        return Err(WorkflowLibraryError::InvalidImport("workflow_identity"));
    }
    let _: Value = serde_json::from_slice(&draft.layout_source)
        .map_err(|_| WorkflowLibraryError::InvalidImport("layout_json"))?;
    let comparison: Value = serde_json::from_slice(&draft.comparison_source)
        .map_err(|_| WorkflowLibraryError::InvalidImport("comparison_json"))?;
    if comparison
        .get("workspaceSourceDigest")
        .and_then(Value::as_str)
        != Some(&request.source_digest)
        || comparison.get("workflowId").and_then(Value::as_str) != Some(&draft.workflow_id)
        || comparison.get("blocking").and_then(Value::as_bool) != Some(draft.blocked)
    {
        return Err(WorkflowLibraryError::InvalidImport("comparison_identity"));
    }
    Ok(())
}

fn canonical_comparison(
    _request: &ImportFrozenWorkspace,
    draft: &ImportFrozenWorkflowDraft,
) -> Result<Vec<u8>> {
    if draft.comparison_source.is_empty()
        || draft.comparison_source.len() > MAXIMUM_COMPARISON_BYTES
    {
        return Err(WorkflowLibraryError::InvalidImport("comparison_bounds"));
    }
    workflow_canonical::canonicalize(&draft.comparison_source)
        .map(|report| report.canonical_bytes)
        .map_err(|_| WorkflowLibraryError::InvalidImport("comparison_canonical"))
}

fn existing_receipt(
    store: &WorkflowLibraryStore,
    request: &ImportFrozenWorkspace,
    prepared: &PreparedImport,
) -> Result<Option<String>> {
    let mut statement = store.connection.prepare(
        "SELECT receipt_id, source_digest, outcome, COALESCE(loss_report_digest, '')
         FROM import_receipts
         WHERE receipt_id = ?1
            OR (source_kind = 'workspace-snapshot' AND source_digest = ?2)",
    )?;
    let existing = statement
        .query_map(params![request.receipt_id, request.source_digest], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?
        .collect::<std::result::Result<Vec<(String, String, String, String)>, _>>()?;
    match existing.as_slice() {
        [(receipt_id, source_digest, outcome, digest)]
            if receipt_id == &request.receipt_id
                && source_digest == &request.source_digest
                && digest == &prepared.manifest_digest =>
        {
            Ok(Some(outcome.clone()))
        }
        [] => Ok(None),
        _ => Err(WorkflowLibraryError::ImportConflict(
            "receipt_identity".into(),
        )),
    }
}

fn adopt_or_create_draft(
    store: &mut WorkflowLibraryStore,
    request: &ImportFrozenWorkspace,
    draft: &ImportFrozenWorkflowDraft,
    item: &ImportedFrozenWorkflow,
    recovering_interrupted_import: bool,
) -> Result<()> {
    match store.load_draft(&draft.workflow_id) {
        Ok(existing) => {
            if existing.workflow_source != draft.workflow_source
                || existing.layout_source != draft.layout_source
                || existing.head_sequence != 0
                || (existing.state != "unsupported"
                    && !(recovering_interrupted_import && existing.state == "editable"))
            {
                return Err(WorkflowLibraryError::ImportConflict(
                    "existing_draft_changed".into(),
                ));
            }
        }
        Err(WorkflowLibraryError::DraftNotFound) => {
            store.create_draft(CreateWorkflowDraft {
                workflow_id: draft.workflow_id.clone(),
                package_id: draft.package_id.clone(),
                name: draft.name.clone(),
                summary: draft.summary.clone(),
                edit_id: format!("import-{}", &request.source_digest[..24]),
                session_id: "frozen-workspace-import".into(),
                workflow_source: draft.workflow_source.clone(),
                layout_source: draft.layout_source.clone(),
                recorded_at_unix_millis: request.imported_at_unix_millis,
            })?;
        }
        Err(error) => return Err(error),
    }
    let changed = store.connection.execute(
        "UPDATE workflow_drafts SET state = 'unsupported' WHERE workflow_id = ?1;",
        [&draft.workflow_id],
    )?;
    if changed != 1 {
        return Err(WorkflowLibraryError::ImportConflict("draft_state".into()));
    }
    store.connection.execute(
        "UPDATE workflow_identities
         SET lifecycle_state = 'unsupported', updated_at_unix_millis = ?1
         WHERE workflow_id = ?2",
        params![request.imported_at_unix_millis, draft.workflow_id],
    )?;
    if item.generation != 1 {
        return Err(WorkflowLibraryError::ImportConflict(
            "draft_generation".into(),
        ));
    }
    Ok(())
}

fn verify_import_targets(
    store: &mut WorkflowLibraryStore,
    request: &ImportFrozenWorkspace,
    recovering_interrupted_import: bool,
) -> Result<()> {
    for draft in &request.drafts {
        let package_owner: Option<String> = store
            .connection
            .query_row(
                "SELECT workflow_id FROM workflow_identities WHERE package_id = ?1",
                [&draft.package_id],
                |row| row.get(0),
            )
            .optional()?;
        if package_owner
            .as_deref()
            .is_some_and(|owner| owner != draft.workflow_id)
        {
            return Err(WorkflowLibraryError::ImportConflict(
                "existing_package_changed".into(),
            ));
        }
        match store.load_draft(&draft.workflow_id) {
            Ok(existing) => {
                let identity_matches: bool = store.connection.query_row(
                    "SELECT package_id = ?2 AND name = ?3 AND summary = ?4
                     FROM workflow_identities WHERE workflow_id = ?1",
                    params![
                        draft.workflow_id,
                        draft.package_id,
                        draft.name,
                        draft.summary
                    ],
                    |row| row.get(0),
                )?;
                let recoverable_state = existing.state == "unsupported"
                    || (recovering_interrupted_import && existing.state == "editable");
                if !recovering_interrupted_import
                    || !recoverable_state
                    || !identity_matches
                    || existing.workflow_source != draft.workflow_source
                    || existing.layout_source != draft.layout_source
                    || existing.head_sequence != 0
                {
                    return Err(WorkflowLibraryError::ImportConflict(
                        "existing_draft_changed".into(),
                    ));
                }
            }
            Err(WorkflowLibraryError::DraftNotFound) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn verify_imported_drafts(
    store: &mut WorkflowLibraryStore,
    request: &ImportFrozenWorkspace,
    prepared: &PreparedImport,
) -> Result<()> {
    for item in &prepared.manifest.workflows {
        let draft = request
            .drafts
            .iter()
            .find(|candidate| candidate.workflow_id == item.workflow_id)
            .ok_or_else(|| WorkflowLibraryError::ImportConflict("draft_missing".into()))?;
        let existing = store.load_draft(&item.workflow_id)?;
        if existing.workflow_source != draft.workflow_source
            || existing.layout_source != draft.layout_source
            || existing.state != "unsupported"
            || existing.head_sequence != 0
        {
            return Err(WorkflowLibraryError::ImportConflict(
                "duplicate_draft_mismatch".into(),
            ));
        }
    }
    Ok(())
}

fn install_import_bundle(store: &WorkflowLibraryStore, prepared: &PreparedImport) -> Result<()> {
    let imports = store.workflow_root()?.join("Imports");
    ensure_private_directory(&imports)?;
    let final_directory = imports.join(&prepared.manifest.source_digest);
    if final_directory.exists() {
        return verify_import_bundle(store, prepared);
    }
    let staging = imports.join(format!(".{}.staging", prepared.manifest.source_digest));
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    ensure_private_directory(&staging)?;
    write_new_private_file(&staging.join("receipt.json"), &prepared.manifest_bytes)?;
    for (item, comparison) in prepared
        .manifest
        .workflows
        .iter()
        .zip(&prepared.comparisons)
    {
        write_new_private_file(
            &staging.join(format!("comparison-{}.json", item.workflow_id)),
            comparison,
        )?;
    }
    sync_directory(&staging)?;
    fs::rename(&staging, &final_directory)?;
    sync_directory(&imports)?;
    protect_frozen_tree(&final_directory)?;
    verify_import_bundle(store, prepared)
}

fn import_bundle_exists(store: &WorkflowLibraryStore, prepared: &PreparedImport) -> Result<bool> {
    Ok(store
        .workflow_root()?
        .join("Imports")
        .join(&prepared.manifest.source_digest)
        .exists())
}

fn verify_import_bundle(store: &WorkflowLibraryStore, prepared: &PreparedImport) -> Result<()> {
    let directory = store
        .workflow_root()?
        .join("Imports")
        .join(&prepared.manifest.source_digest);
    let receipt_bytes =
        read_bounded_private_file(&directory.join("receipt.json"), MAXIMUM_COMPARISON_BYTES)?;
    if receipt_bytes != prepared.manifest_bytes
        || sha256_hex(&receipt_bytes) != prepared.manifest_digest
    {
        return Err(WorkflowLibraryError::ImportConflict(
            "receipt_bundle".into(),
        ));
    }
    for (item, expected) in prepared
        .manifest
        .workflows
        .iter()
        .zip(&prepared.comparisons)
    {
        let actual = read_bounded_private_file(
            &directory.join(format!("comparison-{}.json", item.workflow_id)),
            MAXIMUM_COMPARISON_BYTES,
        )?;
        if actual != *expected || sha256_hex(&actual) != item.comparison_digest {
            return Err(WorkflowLibraryError::ImportConflict(
                "comparison_bundle".into(),
            ));
        }
    }
    Ok(())
}

fn receipt(
    request: &ImportFrozenWorkspace,
    prepared: &PreparedImport,
    outcome: String,
    duplicate: bool,
) -> FrozenWorkspaceImportReceipt {
    FrozenWorkspaceImportReceipt {
        source_digest: request.source_digest.clone(),
        outcome,
        comparison_digest: prepared.manifest_digest.clone(),
        duplicate,
        workflows: prepared.manifest.workflows.clone(),
    }
}

fn validate_identifier(value: &str, maximum: usize, code: &'static str) -> Result<()> {
    if !is_workflow_identifier(value, maximum) {
        return Err(WorkflowLibraryError::InvalidImport(code));
    }
    Ok(())
}

fn validate_text(value: &str, maximum: usize, code: &'static str) -> Result<()> {
    if value.is_empty() || value.len() > maximum || value.chars().any(char::is_control) {
        return Err(WorkflowLibraryError::InvalidImport(code));
    }
    Ok(())
}

fn validate_digest(value: &str, code: &'static str) -> Result<()> {
    if !is_digest(value) {
        return Err(WorkflowLibraryError::InvalidImport(code));
    }
    Ok(())
}

fn is_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn protect_frozen_tree(root: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        for entry in fs::read_dir(root)? {
            let path = entry?.path();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o400))?;
        }
        fs::set_permissions(root, fs::Permissions::from_mode(0o500))?;
    }
    Ok(())
}
