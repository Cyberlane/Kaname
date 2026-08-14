//! Transactional SQLite catalog for editable workflows and immutable revisions.
//!
//! The library stores identities and filesystem-relative bundle references. It
//! never stores credentials, live account bindings, secret values, or runtime
//! execution history. SQL migrations are the compatibility boundary and are
//! applied atomically before any higher-level workflow mutation is available.

use rusqlite::{Connection, ErrorCode, OpenFlags, TransactionBehavior, params};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fmt, fs,
    fs::{File, OpenOptions},
    io,
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

pub(crate) fn is_workflow_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

const INITIAL_MIGRATION_NAME: &str = "0001_initial";
const INITIAL_MIGRATION_SQL: &str = r#"
CREATE TABLE workflow_library_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    checksum TEXT NOT NULL CHECK (length(checksum) = 64),
    applied_at_unix_millis INTEGER NOT NULL CHECK (applied_at_unix_millis >= 0)
) STRICT;

CREATE TABLE workflow_identities (
    workflow_id TEXT PRIMARY KEY CHECK (length(workflow_id) BETWEEN 1 AND 128),
    package_id TEXT NOT NULL CHECK (length(package_id) BETWEEN 1 AND 255),
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
    summary TEXT NOT NULL CHECK (length(summary) <= 1000),
    lifecycle_state TEXT NOT NULL DEFAULT 'draft'
        CHECK (lifecycle_state IN ('draft', 'published', 'disabled', 'unsupported')),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= created_at_unix_millis)
) STRICT;

CREATE UNIQUE INDEX workflow_identities_package_id
    ON workflow_identities(package_id);
CREATE INDEX workflow_identities_updated
    ON workflow_identities(updated_at_unix_millis DESC, workflow_id);

CREATE TABLE workflow_revisions (
    revision_id TEXT PRIMARY KEY CHECK (length(revision_id) BETWEEN 1 AND 128),
    workflow_id TEXT NOT NULL REFERENCES workflow_identities(workflow_id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
    bundle_relative_path TEXT NOT NULL CHECK (
        length(bundle_relative_path) BETWEEN 1 AND 1024
        AND substr(bundle_relative_path, 1, 1) <> '/'
        AND instr(bundle_relative_path, '..') = 0
    ),
    definition_digest TEXT NOT NULL CHECK (length(definition_digest) = 64),
    layout_digest TEXT NOT NULL CHECK (length(layout_digest) = 64),
    schema_bundle_digest TEXT NOT NULL CHECK (length(schema_bundle_digest) = 64),
    dependency_lock_digest TEXT NOT NULL CHECK (length(dependency_lock_digest) = 64),
    validation_digest TEXT NOT NULL CHECK (length(validation_digest) = 64),
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    format_version INTEGER NOT NULL CHECK (format_version > 0),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    UNIQUE(workflow_id, revision_id),
    UNIQUE(workflow_id, revision_number),
    UNIQUE(workflow_id, package_digest)
) STRICT;

CREATE INDEX workflow_revisions_workflow_created
    ON workflow_revisions(workflow_id, revision_number DESC);

CREATE TABLE workflow_drafts (
    workflow_id TEXT PRIMARY KEY REFERENCES workflow_identities(workflow_id) ON DELETE CASCADE,
    base_revision_id TEXT,
    draft_relative_path TEXT NOT NULL CHECK (
        length(draft_relative_path) BETWEEN 1 AND 1024
        AND substr(draft_relative_path, 1, 1) <> '/'
        AND instr(draft_relative_path, '..') = 0
    ),
    generation INTEGER NOT NULL CHECK (generation > 0),
    checkpoint_sequence INTEGER NOT NULL DEFAULT 0 CHECK (checkpoint_sequence >= 0),
    head_sequence INTEGER NOT NULL DEFAULT 0 CHECK (head_sequence >= checkpoint_sequence),
    definition_digest TEXT CHECK (definition_digest IS NULL OR length(definition_digest) = 64),
    layout_digest TEXT CHECK (layout_digest IS NULL OR length(layout_digest) = 64),
    state TEXT NOT NULL DEFAULT 'editable'
        CHECK (state IN ('editable', 'conflicted', 'recovery-required', 'unsupported')),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= 0),
    FOREIGN KEY (workflow_id, base_revision_id)
        REFERENCES workflow_revisions(workflow_id, revision_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE activation_aliases (
    alias_id TEXT PRIMARY KEY CHECK (length(alias_id) BETWEEN 1 AND 128),
    workflow_id TEXT NOT NULL REFERENCES workflow_identities(workflow_id) ON DELETE CASCADE,
    alias_key TEXT NOT NULL CHECK (length(alias_key) BETWEEN 1 AND 128),
    revision_id TEXT,
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= 0),
    UNIQUE(workflow_id, alias_key),
    FOREIGN KEY (workflow_id, revision_id)
        REFERENCES workflow_revisions(workflow_id, revision_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE package_registrations (
    registration_id TEXT PRIMARY KEY CHECK (length(registration_id) BETWEEN 1 AND 128),
    package_id TEXT NOT NULL CHECK (length(package_id) BETWEEN 1 AND 255),
    release_version TEXT NOT NULL CHECK (length(release_version) BETWEEN 1 AND 128),
    workflow_id TEXT NOT NULL REFERENCES workflow_identities(workflow_id) ON DELETE RESTRICT,
    revision_id TEXT,
    package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('local', 'import', 'builtin', 'registry')),
    registration_state TEXT NOT NULL DEFAULT 'registered'
        CHECK (registration_state IN ('registered', 'disabled', 'unsupported', 'quarantined')),
    registered_at_unix_millis INTEGER NOT NULL CHECK (registered_at_unix_millis >= 0),
    UNIQUE(package_id, release_version, package_digest),
    FOREIGN KEY (workflow_id, revision_id)
        REFERENCES workflow_revisions(workflow_id, revision_id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX package_registrations_package
    ON package_registrations(package_id, registered_at_unix_millis DESC);

CREATE TABLE import_receipts (
    receipt_id TEXT PRIMARY KEY CHECK (length(receipt_id) BETWEEN 1 AND 128),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('legacy-definition', 'workspace-snapshot', 'package')),
    source_digest TEXT NOT NULL CHECK (length(source_digest) = 64),
    workflow_id TEXT REFERENCES workflow_identities(workflow_id) ON DELETE SET NULL,
    draft_generation INTEGER CHECK (draft_generation IS NULL OR draft_generation > 0),
    outcome TEXT NOT NULL CHECK (outcome IN ('created', 'duplicate', 'blocked', 'failed')),
    loss_report_digest TEXT CHECK (loss_report_digest IS NULL OR length(loss_report_digest) = 64),
    imported_at_unix_millis INTEGER NOT NULL CHECK (imported_at_unix_millis >= 0),
    UNIQUE(source_kind, source_digest)
) STRICT;

CREATE INDEX import_receipts_workflow_time
    ON import_receipts(workflow_id, imported_at_unix_millis DESC);
"#;
pub const WORKFLOW_LIBRARY_SCHEMA_VERSION: i64 = 1;

const REQUIRED_TABLES: [&str; 7] = [
    "activation_aliases",
    "import_receipts",
    "package_registrations",
    "workflow_drafts",
    "workflow_identities",
    "workflow_library_migrations",
    "workflow_revisions",
];

#[derive(Debug)]
pub enum WorkflowLibraryError {
    Database(rusqlite::Error),
    Io(io::Error),
    CorruptDatabase,
    UnsupportedNewerSchema { found: i64, supported: i64 },
    Integrity(String),
    UnsafePath(&'static str),
    InjectedMigrationInterruption,
    DraftNotFound,
    DraftAlreadyExists,
    DraftConflict { expected: i64, actual: i64 },
    InvalidDraft(&'static str),
    CorruptDraft(String),
    InjectedDraftInterruption,
    WorkflowCompilationFailed(Vec<String>),
    PublicationConflict(String),
    InvalidRevisionBundle(String),
    InjectedPublicationInterruption(&'static str),
    RevisionHistory(String),
    ActivationConflict { expected: i64, actual: i64 },
    InjectedActivationInterruption,
    InvalidImport(&'static str),
    ImportConflict(String),
}

impl fmt::Display for WorkflowLibraryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => write!(formatter, "workflow library database: {error}"),
            Self::Io(error) => write!(formatter, "workflow library filesystem: {error}"),
            Self::CorruptDatabase => formatter.write_str("workflow_library_corrupt"),
            Self::UnsupportedNewerSchema { found, supported } => write!(
                formatter,
                "workflow_library_schema_newer: found {found}, supported {supported}"
            ),
            Self::Integrity(code) => write!(formatter, "workflow library integrity: {code}"),
            Self::UnsafePath(code) => write!(formatter, "workflow library path: {code}"),
            Self::InjectedMigrationInterruption => {
                formatter.write_str("workflow_library_migration_interrupted")
            }
            Self::DraftNotFound => formatter.write_str("workflow_draft_not_found"),
            Self::DraftAlreadyExists => formatter.write_str("workflow_draft_already_exists"),
            Self::DraftConflict { expected, actual } => write!(
                formatter,
                "workflow_draft_conflict: expected {expected}, actual {actual}"
            ),
            Self::InvalidDraft(code) => write!(formatter, "workflow draft invalid: {code}"),
            Self::CorruptDraft(code) => write!(formatter, "workflow draft corrupt: {code}"),
            Self::InjectedDraftInterruption => formatter.write_str("workflow_draft_interrupted"),
            Self::WorkflowCompilationFailed(codes) => {
                write!(
                    formatter,
                    "workflow_compilation_failed: {}",
                    codes.join(",")
                )
            }
            Self::PublicationConflict(code) => {
                write!(formatter, "workflow publication conflict: {code}")
            }
            Self::InvalidRevisionBundle(code) => {
                write!(formatter, "workflow revision bundle invalid: {code}")
            }
            Self::InjectedPublicationInterruption(stage) => {
                write!(formatter, "workflow publication interrupted: {stage}")
            }
            Self::RevisionHistory(code) => write!(formatter, "workflow revision history: {code}"),
            Self::ActivationConflict { expected, actual } => write!(
                formatter,
                "workflow activation conflict: expected {expected}, actual {actual}"
            ),
            Self::InjectedActivationInterruption => {
                formatter.write_str("workflow_activation_interrupted")
            }
            Self::InvalidImport(code) => write!(formatter, "workflow import invalid: {code}"),
            Self::ImportConflict(code) => write!(formatter, "workflow import conflict: {code}"),
        }
    }
}

impl std::error::Error for WorkflowLibraryError {}

impl From<rusqlite::Error> for WorkflowLibraryError {
    fn from(value: rusqlite::Error) -> Self {
        match &value {
            rusqlite::Error::SqliteFailure(failure, _)
                if matches!(
                    failure.code,
                    ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase
                ) =>
            {
                Self::CorruptDatabase
            }
            _ => Self::Database(value),
        }
    }
}

impl From<io::Error> for WorkflowLibraryError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

pub type Result<T> = std::result::Result<T, WorkflowLibraryError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowLibraryMigrationFault {
    AfterSchemaStatements,
}

pub struct WorkflowLibraryStore {
    pub(crate) connection: Connection,
    pub(crate) database_path: Option<PathBuf>,
}

impl WorkflowLibraryStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_path(path.as_ref(), None)
    }

    pub fn open_in_memory() -> Result<Self> {
        let connection = Connection::open_in_memory()?;
        Self::initialize(connection, None, None)
    }

    #[doc(hidden)]
    pub fn open_with_migration_fault_for_test(
        path: impl AsRef<Path>,
        fault: WorkflowLibraryMigrationFault,
    ) -> Result<Self> {
        Self::open_path(path.as_ref(), Some(fault))
    }

    pub fn schema_version(&self) -> Result<i64> {
        Ok(self
            .connection
            .pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    pub fn database_path(&self) -> Option<&Path> {
        self.database_path.as_deref()
    }

    pub fn integrity_check(&self) -> Result<()> {
        verify_integrity(&self.connection)
    }

    pub fn table_names(&self) -> Result<BTreeSet<String>> {
        table_names(&self.connection)
    }

    fn open_path(path: &Path, fault: Option<WorkflowLibraryMigrationFault>) -> Result<Self> {
        prepare_database_path(path)?;
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
        )?;
        protect_private_path(path, PrivatePathKind::File)?;
        Self::initialize(connection, Some(path.to_path_buf()), fault)
    }

    fn initialize(
        mut connection: Connection,
        database_path: Option<PathBuf>,
        fault: Option<WorkflowLibraryMigrationFault>,
    ) -> Result<Self> {
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "trusted_schema", "OFF")?;

        let existing_version = schema_version(&connection)?;
        if existing_version > WORKFLOW_LIBRARY_SCHEMA_VERSION {
            return Err(WorkflowLibraryError::UnsupportedNewerSchema {
                found: existing_version,
                supported: WORKFLOW_LIBRARY_SCHEMA_VERSION,
            });
        }
        quick_check(&connection)?;

        if existing_version < WORKFLOW_LIBRARY_SCHEMA_VERSION {
            migrate(&mut connection, existing_version, fault)?;
        }

        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        verify_integrity(&connection)?;

        Ok(Self {
            connection,
            database_path,
        })
    }
}

fn migrate(
    connection: &mut Connection,
    existing_version: i64,
    fault: Option<WorkflowLibraryMigrationFault>,
) -> Result<()> {
    if existing_version != 0 {
        return Err(WorkflowLibraryError::Integrity(format!(
            "missing_migration_from_{existing_version}"
        )));
    }

    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(INITIAL_MIGRATION_SQL)?;
    if fault == Some(WorkflowLibraryMigrationFault::AfterSchemaStatements) {
        return Err(WorkflowLibraryError::InjectedMigrationInterruption);
    }
    transaction.execute(
        "INSERT INTO workflow_library_migrations
           (version, name, checksum, applied_at_unix_millis)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            WORKFLOW_LIBRARY_SCHEMA_VERSION,
            INITIAL_MIGRATION_NAME,
            initial_migration_checksum(),
            unix_millis(),
        ],
    )?;
    transaction.pragma_update(None, "user_version", WORKFLOW_LIBRARY_SCHEMA_VERSION)?;
    transaction.commit()?;
    Ok(())
}

fn verify_integrity(connection: &Connection) -> Result<()> {
    quick_check(connection)?;
    let version = schema_version(connection)?;
    if version != WORKFLOW_LIBRARY_SCHEMA_VERSION {
        return Err(WorkflowLibraryError::Integrity(format!(
            "schema_version_{version}"
        )));
    }

    let tables = table_names(connection)?;
    for required in REQUIRED_TABLES {
        if !tables.contains(required) {
            return Err(WorkflowLibraryError::Integrity(format!(
                "missing_table_{required}"
            )));
        }
    }

    let migration: (String, String) = connection.query_row(
        "SELECT name, checksum FROM workflow_library_migrations WHERE version = ?1",
        [WORKFLOW_LIBRARY_SCHEMA_VERSION],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    if migration.0 != INITIAL_MIGRATION_NAME || migration.1 != initial_migration_checksum() {
        return Err(WorkflowLibraryError::Integrity(
            "migration_receipt_mismatch".into(),
        ));
    }
    let migration_count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM workflow_library_migrations",
        [],
        |row| row.get(0),
    )?;
    if migration_count != WORKFLOW_LIBRARY_SCHEMA_VERSION {
        return Err(WorkflowLibraryError::Integrity(
            "migration_receipt_count".into(),
        ));
    }

    let foreign_key_violation: Option<String> = connection
        .query_row(
            "SELECT \"table\" FROM pragma_foreign_key_check LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if foreign_key_violation.is_some() {
        return Err(WorkflowLibraryError::Integrity(
            "foreign_key_violation".into(),
        ));
    }
    Ok(())
}

fn quick_check(connection: &Connection) -> Result<()> {
    let status: String = connection.pragma_query_value(None, "quick_check", |row| row.get(0))?;
    if status != "ok" {
        return Err(WorkflowLibraryError::CorruptDatabase);
    }
    Ok(())
}

fn schema_version(connection: &Connection) -> Result<i64> {
    Ok(connection.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

fn table_names(connection: &Connection) -> Result<BTreeSet<String>> {
    let mut statement = connection.prepare(
        "SELECT name FROM sqlite_schema
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
         ORDER BY name",
    )?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

fn initial_migration_checksum() -> String {
    hex::encode(Sha256::digest(INITIAL_MIGRATION_SQL.as_bytes()))
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

pub(crate) fn prepare_database_path(path: &Path) -> Result<()> {
    if path.as_os_str().is_empty() || path.file_name().is_none() {
        return Err(WorkflowLibraryError::UnsafePath("invalid_database_path"));
    }
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(WorkflowLibraryError::UnsafePath(
                "database_must_be_regular_file",
            ));
        }
        #[cfg(unix)]
        if metadata.nlink() != 1 {
            return Err(WorkflowLibraryError::UnsafePath(
                "database_must_not_have_hard_links",
            ));
        }
    }

    let parent = path
        .parent()
        .ok_or(WorkflowLibraryError::UnsafePath("database_parent_missing"))?;
    fs::create_dir_all(parent)?;
    protect_private_path(parent, PrivatePathKind::Directory)
}

#[derive(Clone, Copy)]
pub(crate) enum PrivatePathKind {
    File,
    Directory,
}

pub(crate) fn protect_private_path(path: &Path, kind: PrivatePathKind) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    let expected_type = match kind {
        PrivatePathKind::File => metadata.is_file(),
        PrivatePathKind::Directory => metadata.is_dir(),
    };
    if metadata.file_type().is_symlink() || !expected_type {
        return Err(WorkflowLibraryError::UnsafePath(
            "private_path_type_mismatch",
        ));
    }
    #[cfg(unix)]
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(match kind {
            PrivatePathKind::File => 0o600,
            PrivatePathKind::Directory => 0o700,
        }),
    )?;
    Ok(())
}

pub(crate) fn ensure_private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    protect_private_path(path, PrivatePathKind::Directory)
}

pub(crate) fn write_new_private_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let file = write_new_private_file_unflushed(path, bytes)?;
    file.sync_all()?;
    Ok(())
}

pub(crate) fn write_new_private_file_unflushed(path: &Path, bytes: &[u8]) -> Result<File> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    protect_private_path(path, PrivatePathKind::File)?;
    Ok(file)
}

pub(crate) fn read_bounded_private_file(path: &Path, maximum: usize) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() || metadata.len() as usize > maximum
    {
        return Err(WorkflowLibraryError::Integrity(
            "private_file_bounds".into(),
        ));
    }
    Ok(fs::read(path)?)
}

pub(crate) fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all()?;
    Ok(())
}

use rusqlite::OptionalExtension;
