//! Crash-safe, bounded workflow draft persistence.
//!
//! SQLite owns optimistic sequence admission while private files hold source
//! text. A change file is durably installed before its sequence is committed;
//! reopen can therefore adopt one complete interrupted edit, while partial or
//! corrupt tails are quarantined and the last verified source remains usable.

use crate::workflow_library::{
    Result, WorkflowLibraryError, WorkflowLibraryStore, ensure_private_directory,
    read_bounded_private_file, sync_directory, write_new_private_file,
};
use rusqlite::{ErrorCode, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const MAXIMUM_DRAFT_SOURCE_BYTES: usize = 512 * 1024;
pub const MAXIMUM_DRAFT_CHANGES_BEFORE_COMPACTION: i64 = 32;
pub const RETAINED_DRAFT_CHANGES_AFTER_COMPACTION: i64 = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreateWorkflowDraft {
    pub workflow_id: String,
    pub package_id: String,
    pub name: String,
    pub summary: String,
    pub edit_id: String,
    pub session_id: String,
    pub workflow_source: Vec<u8>,
    pub layout_source: Vec<u8>,
    pub recorded_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveWorkflowDraft {
    pub workflow_id: String,
    pub expected_head_sequence: i64,
    pub edit_id: String,
    pub session_id: String,
    pub workflow_source: Vec<u8>,
    pub layout_source: Vec<u8>,
    pub recorded_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowDraftSnapshot {
    pub workflow_id: String,
    pub generation: i64,
    pub checkpoint_sequence: i64,
    pub head_sequence: i64,
    pub workflow_source: Vec<u8>,
    pub layout_source: Vec<u8>,
    pub workflow_digest: String,
    pub layout_digest: String,
    pub state: String,
    pub recovered_interrupted_edit: bool,
    pub recovered_corrupt_tail: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowDraftSaveResult {
    pub snapshot: WorkflowDraftSnapshot,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowDraftFault {
    AfterChangeFileBeforeDatabaseCommit,
}

#[derive(Debug, Clone)]
struct DraftRow {
    workflow_id: String,
    relative_path: String,
    generation: i64,
    checkpoint_sequence: i64,
    head_sequence: i64,
    workflow_digest: String,
    layout_digest: String,
    state: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DraftCheckpointManifest {
    format_version: u32,
    workflow_id: String,
    sequence: i64,
    workflow_digest: String,
    layout_digest: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DraftChangeRecord {
    format_version: u32,
    workflow_id: String,
    edit_id: String,
    session_id: String,
    base_sequence: i64,
    sequence: i64,
    recorded_at_unix_millis: i64,
    workflow_source: String,
    layout_source: String,
    workflow_digest: String,
    layout_digest: String,
}

impl WorkflowLibraryStore {
    pub fn create_draft(&mut self, request: CreateWorkflowDraft) -> Result<WorkflowDraftSnapshot> {
        validate_create_request(&request)?;
        if self.draft_row(&request.workflow_id)?.is_some() {
            return Err(WorkflowLibraryError::DraftAlreadyExists);
        }
        let root = self.draft_root(&request.workflow_id)?;
        ensure_private_directory(&root)?;
        ensure_private_directory(&root.join("Checkpoints"))?;
        ensure_private_directory(&root.join("Changes"))?;

        let workflow_digest = sha256_hex(&request.workflow_source);
        let layout_digest = sha256_hex(&request.layout_source);
        install_checkpoint(
            &root,
            &request.workflow_id,
            0,
            &request.edit_id,
            &request.workflow_source,
            &request.layout_source,
        )?;

        let transaction = self.connection.transaction()?;
        let identity_insert = transaction.execute(
            "INSERT INTO workflow_identities
               (workflow_id, package_id, name, summary, lifecycle_state,
                created_at_unix_millis, updated_at_unix_millis)
             VALUES (?1, ?2, ?3, ?4, 'draft', ?5, ?5)",
            params![
                request.workflow_id,
                request.package_id,
                request.name,
                request.summary,
                request.recorded_at_unix_millis,
            ],
        );
        match identity_insert {
            Ok(1) => {}
            Err(rusqlite::Error::SqliteFailure(failure, _))
                if failure.code == ErrorCode::ConstraintViolation =>
            {
                return Err(WorkflowLibraryError::DraftAlreadyExists);
            }
            Err(error) => return Err(error.into()),
            Ok(_) => {
                return Err(WorkflowLibraryError::Integrity(
                    "draft_identity_insert_count".into(),
                ));
            }
        }
        transaction.execute(
            "INSERT INTO workflow_drafts
               (workflow_id, draft_relative_path, generation, checkpoint_sequence,
                head_sequence, definition_digest, layout_digest, state,
                updated_at_unix_millis)
             VALUES (?1, ?2, 1, 0, 0, ?3, ?4, 'editable', ?5)",
            params![
                request.workflow_id,
                relative_draft_path(&request.workflow_id),
                workflow_digest,
                layout_digest,
                request.recorded_at_unix_millis,
            ],
        )?;
        transaction.commit()?;
        self.load_draft(&request.workflow_id)
    }

    pub fn save_draft(&mut self, request: SaveWorkflowDraft) -> Result<WorkflowDraftSaveResult> {
        self.save_draft_with_fault(request, None)
    }

    #[doc(hidden)]
    pub fn save_draft_with_fault_for_test(
        &mut self,
        request: SaveWorkflowDraft,
        fault: WorkflowDraftFault,
    ) -> Result<WorkflowDraftSaveResult> {
        self.save_draft_with_fault(request, Some(fault))
    }

    pub fn load_draft(&mut self, workflow_id: &str) -> Result<WorkflowDraftSnapshot> {
        validate_draft_text(workflow_id, 128, "workflow_id", DraftTextKind::Identifier)?;
        let mut row = self
            .draft_row(workflow_id)?
            .ok_or(WorkflowLibraryError::DraftNotFound)?;
        let recovered_interrupted_edit = self.recover_complete_tail(&mut row)?;
        match self.materialize(&row, row.head_sequence) {
            Ok((workflow_source, layout_source)) => {
                if row.workflow_digest != sha256_hex(&workflow_source)
                    || row.layout_digest != sha256_hex(&layout_source)
                {
                    return Err(WorkflowLibraryError::CorruptDraft(
                        "draft_row_digest".into(),
                    ));
                }
                Ok(snapshot(
                    row,
                    workflow_source,
                    layout_source,
                    recovered_interrupted_edit,
                    false,
                ))
            }
            Err(WorkflowLibraryError::CorruptDraft(code)) => {
                let sequence = corrupt_sequence(&code).ok_or_else(|| {
                    WorkflowLibraryError::CorruptDraft("unrecoverable_draft".into())
                })?;
                let repaired = self.repair_corrupt_tail(row, sequence)?;
                Ok(WorkflowDraftSnapshot {
                    recovered_corrupt_tail: true,
                    recovered_interrupted_edit,
                    ..repaired
                })
            }
            Err(error) => Err(error),
        }
    }

    pub fn load_draft_at(
        &mut self,
        workflow_id: &str,
        sequence: i64,
    ) -> Result<WorkflowDraftSnapshot> {
        let current = self.load_draft(workflow_id)?;
        if sequence < current.checkpoint_sequence || sequence > current.head_sequence {
            return Err(WorkflowLibraryError::InvalidDraft("sequence_not_retained"));
        }
        let row = self
            .draft_row(workflow_id)?
            .ok_or(WorkflowLibraryError::DraftNotFound)?;
        let (workflow_source, layout_source) = self.materialize(&row, sequence)?;
        Ok(WorkflowDraftSnapshot {
            workflow_digest: sha256_hex(&workflow_source),
            layout_digest: sha256_hex(&layout_source),
            workflow_source,
            layout_source,
            head_sequence: sequence,
            recovered_interrupted_edit: false,
            recovered_corrupt_tail: false,
            ..snapshot_metadata(row)
        })
    }

    pub fn retained_draft_sequences(&mut self, workflow_id: &str) -> Result<Vec<i64>> {
        let snapshot = self.load_draft(workflow_id)?;
        Ok((snapshot.checkpoint_sequence..=snapshot.head_sequence).collect())
    }

    fn save_draft_with_fault(
        &mut self,
        request: SaveWorkflowDraft,
        fault: Option<WorkflowDraftFault>,
    ) -> Result<WorkflowDraftSaveResult> {
        validate_save_request(&request)?;
        let current = self.load_draft(&request.workflow_id)?;
        if request.expected_head_sequence != current.head_sequence {
            if let Some(record) = self.change_record(&request.workflow_id, current.head_sequence)?
                && record.edit_id == request.edit_id
                && record.base_sequence == request.expected_head_sequence
                && record.workflow_source.as_bytes() == request.workflow_source
                && record.layout_source.as_bytes() == request.layout_source
            {
                return Ok(WorkflowDraftSaveResult {
                    snapshot: current,
                    duplicate: true,
                });
            }
            return Err(WorkflowLibraryError::DraftConflict {
                expected: request.expected_head_sequence,
                actual: current.head_sequence,
            });
        }

        let sequence = current.head_sequence + 1;
        let record = change_record(&request, sequence)?;
        let root = self.draft_root(&request.workflow_id)?;
        install_change(&root, &record)?;
        if fault == Some(WorkflowDraftFault::AfterChangeFileBeforeDatabaseCommit) {
            return Err(WorkflowLibraryError::InjectedDraftInterruption);
        }

        let changed = self.connection.execute(
            "UPDATE workflow_drafts
             SET generation = generation + 1, head_sequence = ?1,
                 definition_digest = ?2, layout_digest = ?3,
                 state = 'editable', updated_at_unix_millis = ?4
             WHERE workflow_id = ?5 AND head_sequence = ?6",
            params![
                sequence,
                record.workflow_digest,
                record.layout_digest,
                request.recorded_at_unix_millis,
                request.workflow_id,
                request.expected_head_sequence,
            ],
        )?;
        if changed != 1 {
            let actual = self
                .draft_row(&request.workflow_id)?
                .map(|row| row.head_sequence)
                .ok_or(WorkflowLibraryError::DraftNotFound)?;
            return Err(WorkflowLibraryError::DraftConflict {
                expected: request.expected_head_sequence,
                actual,
            });
        }

        self.compact_history_if_needed(&request.workflow_id, &request.edit_id)?;
        Ok(WorkflowDraftSaveResult {
            snapshot: self.load_draft(&request.workflow_id)?,
            duplicate: false,
        })
    }

    fn draft_row(&self, workflow_id: &str) -> Result<Option<DraftRow>> {
        Ok(self
            .connection
            .query_row(
                "SELECT workflow_id, draft_relative_path, generation,
                        checkpoint_sequence, head_sequence,
                        COALESCE(definition_digest, ''), COALESCE(layout_digest, ''), state
                 FROM workflow_drafts WHERE workflow_id = ?1",
                [workflow_id],
                |row| {
                    Ok(DraftRow {
                        workflow_id: row.get(0)?,
                        relative_path: row.get(1)?,
                        generation: row.get(2)?,
                        checkpoint_sequence: row.get(3)?,
                        head_sequence: row.get(4)?,
                        workflow_digest: row.get(5)?,
                        layout_digest: row.get(6)?,
                        state: row.get(7)?,
                    })
                },
            )
            .optional()?)
    }

    fn draft_root(&self, workflow_id: &str) -> Result<PathBuf> {
        validate_draft_text(workflow_id, 128, "workflow_id", DraftTextKind::Identifier)?;
        let database = self
            .database_path
            .as_ref()
            .ok_or(WorkflowLibraryError::InvalidDraft("file_backing_required"))?;
        Ok(database
            .parent()
            .ok_or(WorkflowLibraryError::InvalidDraft("library_root_missing"))?
            .join("Drafts")
            .join(workflow_id))
    }

    fn materialize(&self, row: &DraftRow, target: i64) -> Result<(Vec<u8>, Vec<u8>)> {
        if row.relative_path != relative_draft_path(&row.workflow_id)
            || target < row.checkpoint_sequence
            || target > row.head_sequence
        {
            return Err(WorkflowLibraryError::CorruptDraft(
                "draft_row_bounds".into(),
            ));
        }
        let root = self.draft_root(&row.workflow_id)?;
        let (mut workflow_source, mut layout_source) =
            read_checkpoint(&root, &row.workflow_id, row.checkpoint_sequence)?;
        for sequence in (row.checkpoint_sequence + 1)..=target {
            let record = read_change(&root, sequence).map_err(|_| {
                WorkflowLibraryError::CorruptDraft(format!("change_sequence_{sequence}"))
            })?;
            validate_change_chain(&record, &row.workflow_id, sequence - 1, sequence)?;
            workflow_source = record.workflow_source.into_bytes();
            layout_source = record.layout_source.into_bytes();
        }
        Ok((workflow_source, layout_source))
    }

    fn recover_complete_tail(&mut self, row: &mut DraftRow) -> Result<bool> {
        let root = self.draft_root(&row.workflow_id)?;
        let mut recovered = false;
        loop {
            let sequence = row.head_sequence + 1;
            if !change_path(&root, sequence).exists() {
                break;
            }
            let record = match read_change(&root, sequence) {
                Ok(record) => record,
                Err(_) => {
                    quarantine_change_range(&root, sequence, sequence)?;
                    break;
                }
            };
            if validate_change_chain(&record, &row.workflow_id, row.head_sequence, sequence)
                .is_err()
            {
                quarantine_change_range(&root, sequence, sequence)?;
                break;
            }
            let changed = self.connection.execute(
                "UPDATE workflow_drafts
                 SET generation = generation + 1, head_sequence = ?1,
                     definition_digest = ?2, layout_digest = ?3,
                     updated_at_unix_millis = ?4
                 WHERE workflow_id = ?5 AND head_sequence = ?6",
                params![
                    sequence,
                    record.workflow_digest,
                    record.layout_digest,
                    record.recorded_at_unix_millis,
                    row.workflow_id,
                    row.head_sequence,
                ],
            )?;
            if changed != 1 {
                break;
            }
            row.generation += 1;
            row.head_sequence = sequence;
            row.workflow_digest = record.workflow_digest;
            row.layout_digest = record.layout_digest;
            recovered = true;
        }
        Ok(recovered)
    }

    fn repair_corrupt_tail(
        &mut self,
        row: DraftRow,
        corrupt_at: i64,
    ) -> Result<WorkflowDraftSnapshot> {
        if corrupt_at <= row.checkpoint_sequence || corrupt_at > row.head_sequence {
            return Err(WorkflowLibraryError::CorruptDraft(
                "unrecoverable_checkpoint".into(),
            ));
        }
        let prior_sequence = corrupt_at - 1;
        let (workflow_source, layout_source) = self.materialize(&row, prior_sequence)?;
        let root = self.draft_root(&row.workflow_id)?;
        quarantine_change_range(&root, corrupt_at, row.head_sequence)?;
        let workflow_digest = sha256_hex(&workflow_source);
        let layout_digest = sha256_hex(&layout_source);
        self.connection.execute(
            "UPDATE workflow_drafts
             SET generation = generation + 1, head_sequence = ?1,
                 definition_digest = ?2, layout_digest = ?3,
                 state = 'recovery-required', updated_at_unix_millis = ?4
             WHERE workflow_id = ?5 AND head_sequence = ?6",
            params![
                prior_sequence,
                workflow_digest,
                layout_digest,
                unix_millis(),
                row.workflow_id,
                row.head_sequence,
            ],
        )?;
        let repaired_row = self
            .draft_row(&row.workflow_id)?
            .ok_or(WorkflowLibraryError::DraftNotFound)?;
        Ok(snapshot(
            repaired_row,
            workflow_source,
            layout_source,
            false,
            true,
        ))
    }

    fn change_record(&self, workflow_id: &str, sequence: i64) -> Result<Option<DraftChangeRecord>> {
        let path = change_path(&self.draft_root(workflow_id)?, sequence);
        if !path.exists() {
            return Ok(None);
        }
        Ok(Some(read_change_file(&path)?))
    }

    fn compact_history_if_needed(&mut self, workflow_id: &str, edit_id: &str) -> Result<()> {
        let row = self
            .draft_row(workflow_id)?
            .ok_or(WorkflowLibraryError::DraftNotFound)?;
        if row.head_sequence - row.checkpoint_sequence <= MAXIMUM_DRAFT_CHANGES_BEFORE_COMPACTION {
            return Ok(());
        }
        let checkpoint_sequence = row.head_sequence - RETAINED_DRAFT_CHANGES_AFTER_COMPACTION;
        let (workflow_source, layout_source) = self.materialize(&row, checkpoint_sequence)?;
        let root = self.draft_root(workflow_id)?;
        install_checkpoint(
            &root,
            workflow_id,
            checkpoint_sequence,
            edit_id,
            &workflow_source,
            &layout_source,
        )?;
        let changed = self.connection.execute(
            "UPDATE workflow_drafts SET checkpoint_sequence = ?1
             WHERE workflow_id = ?2 AND checkpoint_sequence = ?3 AND head_sequence = ?4",
            params![
                checkpoint_sequence,
                workflow_id,
                row.checkpoint_sequence,
                row.head_sequence,
            ],
        )?;
        if changed == 1 {
            let _ = cleanup_bounded_history(&root);
        }
        Ok(())
    }
}

fn validate_create_request(request: &CreateWorkflowDraft) -> Result<()> {
    validate_draft_text(
        &request.workflow_id,
        128,
        "workflow_id",
        DraftTextKind::Identifier,
    )?;
    validate_draft_text(&request.edit_id, 128, "edit_id", DraftTextKind::Identifier)?;
    validate_draft_text(&request.session_id, 256, "session_id", DraftTextKind::Plain)?;
    validate_draft_text(&request.package_id, 255, "package_id", DraftTextKind::Plain)?;
    validate_draft_text(&request.name, 160, "name", DraftTextKind::Plain)?;
    if request.summary.len() > 1_000 {
        return Err(WorkflowLibraryError::InvalidDraft("summary"));
    }
    validate_sources(&request.workflow_source, &request.layout_source)?;
    validate_time(request.recorded_at_unix_millis)
}

fn validate_save_request(request: &SaveWorkflowDraft) -> Result<()> {
    validate_draft_text(
        &request.workflow_id,
        128,
        "workflow_id",
        DraftTextKind::Identifier,
    )?;
    validate_draft_text(&request.edit_id, 128, "edit_id", DraftTextKind::Identifier)?;
    validate_draft_text(&request.session_id, 256, "session_id", DraftTextKind::Plain)?;
    if request.expected_head_sequence < 0 {
        return Err(WorkflowLibraryError::InvalidDraft("expected_sequence"));
    }
    validate_sources(&request.workflow_source, &request.layout_source)?;
    validate_time(request.recorded_at_unix_millis)
}

#[derive(Clone, Copy)]
enum DraftTextKind {
    Identifier,
    Plain,
}

fn validate_draft_text(
    value: &str,
    maximum: usize,
    code: &'static str,
    kind: DraftTextKind,
) -> Result<()> {
    let invalid_identifier = matches!(kind, DraftTextKind::Identifier)
        && !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    if value.is_empty()
        || value.len() > maximum
        || value.chars().any(char::is_control)
        || invalid_identifier
    {
        return Err(WorkflowLibraryError::InvalidDraft(code));
    }
    Ok(())
}

fn validate_sources(workflow: &[u8], layout: &[u8]) -> Result<()> {
    for source in [workflow, layout] {
        if source.is_empty()
            || source.len() > MAXIMUM_DRAFT_SOURCE_BYTES
            || std::str::from_utf8(source).is_err()
        {
            return Err(WorkflowLibraryError::InvalidDraft("source_bounds"));
        }
    }
    Ok(())
}

fn validate_time(value: i64) -> Result<()> {
    if value < 0 {
        Err(WorkflowLibraryError::InvalidDraft("recorded_at"))
    } else {
        Ok(())
    }
}

fn change_record(request: &SaveWorkflowDraft, sequence: i64) -> Result<DraftChangeRecord> {
    Ok(DraftChangeRecord {
        format_version: 1,
        workflow_id: request.workflow_id.clone(),
        edit_id: request.edit_id.clone(),
        session_id: request.session_id.clone(),
        base_sequence: request.expected_head_sequence,
        sequence,
        recorded_at_unix_millis: request.recorded_at_unix_millis,
        workflow_source: String::from_utf8(request.workflow_source.clone())
            .map_err(|_| WorkflowLibraryError::InvalidDraft("workflow_utf8"))?,
        layout_source: String::from_utf8(request.layout_source.clone())
            .map_err(|_| WorkflowLibraryError::InvalidDraft("layout_utf8"))?,
        workflow_digest: sha256_hex(&request.workflow_source),
        layout_digest: sha256_hex(&request.layout_source),
    })
}

fn validate_change_chain(
    record: &DraftChangeRecord,
    workflow_id: &str,
    base_sequence: i64,
    sequence: i64,
) -> Result<()> {
    if record.format_version != 1
        || record.workflow_id != workflow_id
        || record.base_sequence != base_sequence
        || record.sequence != sequence
        || record.workflow_digest != sha256_hex(record.workflow_source.as_bytes())
        || record.layout_digest != sha256_hex(record.layout_source.as_bytes())
    {
        return Err(WorkflowLibraryError::CorruptDraft(format!(
            "change_sequence_{sequence}"
        )));
    }
    validate_draft_text(
        &record.edit_id,
        128,
        "stored_edit_id",
        DraftTextKind::Identifier,
    )?;
    validate_draft_text(
        &record.session_id,
        256,
        "stored_session_id",
        DraftTextKind::Plain,
    )?;
    validate_sources(
        record.workflow_source.as_bytes(),
        record.layout_source.as_bytes(),
    )
}

fn install_checkpoint(
    root: &Path,
    workflow_id: &str,
    sequence: i64,
    edit_id: &str,
    workflow_source: &[u8],
    layout_source: &[u8],
) -> Result<()> {
    let checkpoints = root.join("Checkpoints");
    ensure_private_directory(&checkpoints)?;
    let target = checkpoint_path(root, sequence);
    if target.exists() {
        let existing = read_checkpoint(root, workflow_id, sequence)?;
        if existing.0 == workflow_source && existing.1 == layout_source {
            return Ok(());
        }
        return Err(WorkflowLibraryError::CorruptDraft(
            "checkpoint_identity_reused".into(),
        ));
    }
    let staging = checkpoints.join(format!(".{}-{edit_id}.staging", sequence_name(sequence)));
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    ensure_private_directory(&staging)?;
    write_new_private_file(&staging.join("workflow.json"), workflow_source)?;
    write_new_private_file(&staging.join("layout.json"), layout_source)?;
    let manifest = DraftCheckpointManifest {
        format_version: 1,
        workflow_id: workflow_id.to_owned(),
        sequence,
        workflow_digest: sha256_hex(workflow_source),
        layout_digest: sha256_hex(layout_source),
    };
    write_new_private_file(
        &staging.join("manifest.json"),
        &serde_json::to_vec(&manifest)
            .map_err(|_| WorkflowLibraryError::InvalidDraft("checkpoint_manifest"))?,
    )?;
    sync_directory(&staging)?;
    fs::rename(&staging, &target)?;
    sync_directory(&checkpoints)
}

fn read_checkpoint(root: &Path, workflow_id: &str, sequence: i64) -> Result<(Vec<u8>, Vec<u8>)> {
    let directory = checkpoint_path(root, sequence);
    let manifest: DraftCheckpointManifest = serde_json::from_slice(&read_bounded_private_file(
        &directory.join("manifest.json"),
        16 * 1024,
    )?)
    .map_err(|_| WorkflowLibraryError::CorruptDraft("checkpoint_manifest".into()))?;
    let workflow_source =
        read_bounded_private_file(&directory.join("workflow.json"), MAXIMUM_DRAFT_SOURCE_BYTES)?;
    let layout_source =
        read_bounded_private_file(&directory.join("layout.json"), MAXIMUM_DRAFT_SOURCE_BYTES)?;
    if manifest.format_version != 1
        || manifest.workflow_id != workflow_id
        || manifest.sequence != sequence
        || manifest.workflow_digest != sha256_hex(&workflow_source)
        || manifest.layout_digest != sha256_hex(&layout_source)
    {
        return Err(WorkflowLibraryError::CorruptDraft(
            "checkpoint_integrity".into(),
        ));
    }
    validate_sources(&workflow_source, &layout_source)?;
    Ok((workflow_source, layout_source))
}

fn install_change(root: &Path, record: &DraftChangeRecord) -> Result<()> {
    let changes = root.join("Changes");
    ensure_private_directory(&changes)?;
    let target = change_path(root, record.sequence);
    let bytes = serde_json::to_vec(record)
        .map_err(|_| WorkflowLibraryError::InvalidDraft("change_encoding"))?;
    if target.exists() {
        let existing = read_change_file(&target)?;
        if existing == *record {
            return Ok(());
        }
        return Err(WorkflowLibraryError::DraftConflict {
            expected: record.base_sequence,
            actual: record.sequence,
        });
    }
    let temporary = changes.join(format!(
        ".{}-{}.staging",
        sequence_name(record.sequence),
        record.edit_id
    ));
    if temporary.exists() {
        fs::remove_file(&temporary)?;
    }
    write_new_private_file(&temporary, &bytes)?;
    match fs::hard_link(&temporary, &target) {
        Ok(()) => {}
        Err(_error) if target.exists() => {
            fs::remove_file(&temporary)?;
            let existing = read_change_file(&target)?;
            if existing == *record {
                return Ok(());
            }
            return Err(WorkflowLibraryError::DraftConflict {
                expected: record.base_sequence,
                actual: record.sequence,
            });
        }
        Err(error) => return Err(error.into()),
    }
    fs::remove_file(&temporary)?;
    sync_directory(&changes)
}

fn read_change(root: &Path, sequence: i64) -> Result<DraftChangeRecord> {
    read_change_file(&change_path(root, sequence))
}

fn read_change_file(path: &Path) -> Result<DraftChangeRecord> {
    let maximum = MAXIMUM_DRAFT_SOURCE_BYTES * 2 + 64 * 1024;
    serde_json::from_slice(&read_bounded_private_file(path, maximum)?)
        .map_err(|_| WorkflowLibraryError::CorruptDraft("change_encoding".into()))
}

fn quarantine_change_range(root: &Path, first: i64, last: i64) -> Result<()> {
    let recovery = root
        .parent()
        .and_then(Path::parent)
        .ok_or(WorkflowLibraryError::InvalidDraft("recovery_root"))?
        .join("Recovery")
        .join("Drafts")
        .join(
            root.file_name()
                .ok_or(WorkflowLibraryError::InvalidDraft("workflow_root"))?,
        )
        .join(format!("{}-{first}", unix_millis()));
    ensure_private_directory(&recovery)?;
    for sequence in first..=last {
        let source = change_path(root, sequence);
        if source.exists() {
            fs::rename(
                source,
                recovery.join(format!("{}.json", sequence_name(sequence))),
            )?;
        }
    }
    sync_directory(&root.join("Changes"))?;
    sync_directory(&recovery)
}

fn cleanup_bounded_history(root: &Path) -> Result<()> {
    let checkpoints = root.join("Checkpoints");
    let mut sequences = fs::read_dir(&checkpoints)?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().to_str()?.parse::<i64>().ok())
        .collect::<Vec<_>>();
    sequences.sort_unstable();
    if sequences.len() <= 2 {
        return Ok(());
    }
    let retained = sequences.split_off(sequences.len() - 2);
    for obsolete in sequences {
        fs::remove_dir_all(checkpoint_path(root, obsolete))?;
    }
    let oldest_retained = retained[0];
    for entry in fs::read_dir(root.join("Changes"))? {
        let entry = entry?;
        if let Some(stem) = entry.path().file_stem().and_then(|value| value.to_str())
            && let Ok(sequence) = stem.parse::<i64>()
            && sequence <= oldest_retained
        {
            fs::remove_file(entry.path())?;
        }
    }
    sync_directory(&checkpoints)?;
    sync_directory(&root.join("Changes"))
}

fn snapshot(
    row: DraftRow,
    workflow_source: Vec<u8>,
    layout_source: Vec<u8>,
    recovered_interrupted_edit: bool,
    recovered_corrupt_tail: bool,
) -> WorkflowDraftSnapshot {
    WorkflowDraftSnapshot {
        workflow_digest: sha256_hex(&workflow_source),
        layout_digest: sha256_hex(&layout_source),
        workflow_source,
        layout_source,
        recovered_interrupted_edit,
        recovered_corrupt_tail,
        ..snapshot_metadata(row)
    }
}

fn snapshot_metadata(row: DraftRow) -> WorkflowDraftSnapshot {
    WorkflowDraftSnapshot {
        workflow_id: row.workflow_id,
        generation: row.generation,
        checkpoint_sequence: row.checkpoint_sequence,
        head_sequence: row.head_sequence,
        workflow_source: Vec::new(),
        layout_source: Vec::new(),
        workflow_digest: row.workflow_digest,
        layout_digest: row.layout_digest,
        state: row.state,
        recovered_interrupted_edit: false,
        recovered_corrupt_tail: false,
    }
}

fn relative_draft_path(workflow_id: &str) -> String {
    format!("Drafts/{workflow_id}")
}

fn checkpoint_path(root: &Path, sequence: i64) -> PathBuf {
    root.join("Checkpoints").join(sequence_name(sequence))
}

fn change_path(root: &Path, sequence: i64) -> PathBuf {
    root.join("Changes")
        .join(format!("{}.json", sequence_name(sequence)))
}

fn sequence_name(sequence: i64) -> String {
    format!("{sequence:020}")
}

fn corrupt_sequence(code: &str) -> Option<i64> {
    code.strip_prefix("change_sequence_")?.parse().ok()
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
