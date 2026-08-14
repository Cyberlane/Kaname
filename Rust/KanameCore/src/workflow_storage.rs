//! Durable logical isolation above the physical workflow object store.
//!
//! Namespace ownership, typed value versions, optimistic writes, and quotas
//! live here. The physical SHA-256 layout remains private and may deduplicate
//! bytes across namespaces without granting cross-namespace access.

use crate::{
    private_filesystem::{self, PrivateFilesystemError, PrivatePathKind},
    workflow_canonical,
    workflow_library::is_workflow_identifier,
    workflow_object_store::{
        WorkflowObjectManifest, WorkflowObjectStore, WorkflowObjectStoreError,
        WorkflowObjectStoreQuota,
    },
};
use rusqlite::{
    Connection, ErrorCode, OpenFlags, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, error::Error, fmt, io::Write, path::Path};

const STORAGE_SCHEMA_VERSION: i64 = 1;
const MAXIMUM_INLINE_JSON_BYTES: usize = 64 * 1024;
const MAXIMUM_LIST_LIMIT: u32 = 500;
const MAXIMUM_ACCOUNT_BINDINGS: usize = 32;

const STORAGE_SCHEMA: &str = r#"
CREATE TABLE workflow_storage_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    checksum TEXT NOT NULL CHECK (length(checksum) = 64)
) STRICT;

CREATE TABLE storage_namespaces (
    scope_kind TEXT NOT NULL CHECK (scope_kind IN ('run', 'case', 'installation', 'account_binding')),
    scope_id TEXT NOT NULL CHECK (length(scope_id) BETWEEN 1 AND 128),
    installation_id TEXT CHECK (installation_id IS NULL OR length(installation_id) BETWEEN 1 AND 128),
    maximum_item_count INTEGER NOT NULL CHECK (maximum_item_count > 0),
    maximum_total_bytes INTEGER NOT NULL CHECK (maximum_total_bytes > 0),
    maximum_value_bytes INTEGER NOT NULL CHECK (maximum_value_bytes > 0),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    PRIMARY KEY (scope_kind, scope_id)
) STRICT;

CREATE TABLE storage_entries (
    entry_id TEXT PRIMARY KEY CHECK (length(entry_id) BETWEEN 1 AND 128),
    scope_kind TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    logical_key TEXT NOT NULL CHECK (length(logical_key) BETWEEN 1 AND 512),
    schema_ref TEXT,
    media_type TEXT NOT NULL CHECK (length(media_type) BETWEEN 1 AND 255),
    classification TEXT NOT NULL CHECK (classification IN ('private', 'sensitive', 'restricted')),
    current_version_id TEXT,
    current_revision INTEGER NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    updated_at_unix_millis INTEGER NOT NULL CHECK (updated_at_unix_millis >= created_at_unix_millis),
    UNIQUE (scope_kind, scope_id, logical_key),
    FOREIGN KEY (scope_kind, scope_id) REFERENCES storage_namespaces(scope_kind, scope_id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX storage_entries_scope_key
ON storage_entries(scope_kind, scope_id, logical_key);

CREATE TABLE storage_versions (
    version_id TEXT PRIMARY KEY CHECK (length(version_id) BETWEEN 1 AND 128),
    entry_id TEXT NOT NULL REFERENCES storage_entries(entry_id) ON DELETE RESTRICT,
    revision INTEGER NOT NULL CHECK (revision > 0),
    value_kind TEXT NOT NULL CHECK (value_kind IN ('inline_json', 'object')),
    inline_canonical_json BLOB,
    blob_digest TEXT,
    byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
    sha256 TEXT NOT NULL CHECK (length(sha256) = 64),
    created_by_attempt_id TEXT NOT NULL CHECK (length(created_by_attempt_id) BETWEEN 1 AND 128),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    CHECK (
        (value_kind = 'inline_json' AND inline_canonical_json IS NOT NULL AND blob_digest IS NULL)
        OR (value_kind = 'object' AND inline_canonical_json IS NULL AND blob_digest IS NOT NULL AND length(blob_digest) = 64)
    ),
    UNIQUE (entry_id, revision)
) STRICT;

CREATE TABLE blob_references (
    reference_id TEXT PRIMARY KEY CHECK (length(reference_id) BETWEEN 1 AND 128),
    blob_digest TEXT NOT NULL CHECK (length(blob_digest) = 64),
    scope_kind TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    entry_id TEXT NOT NULL REFERENCES storage_entries(entry_id) ON DELETE RESTRICT,
    version_id TEXT NOT NULL REFERENCES storage_versions(version_id) ON DELETE RESTRICT,
    purpose TEXT NOT NULL CHECK (purpose IN ('value', 'file', 'artifact')),
    created_at_unix_millis INTEGER NOT NULL CHECK (created_at_unix_millis >= 0),
    UNIQUE (entry_id, version_id),
    FOREIGN KEY (scope_kind, scope_id) REFERENCES storage_namespaces(scope_kind, scope_id) ON DELETE RESTRICT
) STRICT;

CREATE INDEX blob_references_digest ON blob_references(blob_digest);

CREATE TABLE storage_command_receipts (
    command_id TEXT PRIMARY KEY CHECK (length(command_id) BETWEEN 1 AND 128),
    request_digest TEXT NOT NULL CHECK (length(request_digest) = 64),
    response_json BLOB NOT NULL,
    committed_at_unix_millis INTEGER NOT NULL CHECK (committed_at_unix_millis >= 0)
) STRICT;
"#;

pub type Result<T> = std::result::Result<T, WorkflowStorageError>;

#[derive(Debug)]
pub enum WorkflowStorageError {
    Database(rusqlite::Error),
    Io(std::io::Error),
    ObjectStore(WorkflowObjectStoreError),
    UnsafePath(&'static str),
    UnsupportedNewerSchema { found: i64, supported: i64 },
    Invalid(&'static str),
    AccessDenied(&'static str),
    NotFound(&'static str),
    Conflict { expected: u64, actual: u64 },
    QuotaExceeded(&'static str),
    Integrity(&'static str),
}

impl fmt::Display for WorkflowStorageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => write!(formatter, "workflow storage database: {error}"),
            Self::Io(error) => write!(formatter, "workflow storage filesystem: {error}"),
            Self::ObjectStore(error) => write!(formatter, "workflow storage object: {error}"),
            Self::UnsafePath(code) => write!(formatter, "workflow storage path: {code}"),
            Self::UnsupportedNewerSchema { found, supported } => write!(
                formatter,
                "workflow storage schema newer: found {found}, supported {supported}"
            ),
            Self::Invalid(code) => write!(formatter, "workflow storage invalid: {code}"),
            Self::AccessDenied(code) => write!(formatter, "workflow storage denied: {code}"),
            Self::NotFound(code) => write!(formatter, "workflow storage missing: {code}"),
            Self::Conflict { expected, actual } => write!(
                formatter,
                "workflow storage conflict: expected {expected}, actual {actual}"
            ),
            Self::QuotaExceeded(code) => write!(formatter, "workflow storage quota: {code}"),
            Self::Integrity(code) => write!(formatter, "workflow storage integrity: {code}"),
        }
    }
}

impl Error for WorkflowStorageError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Database(error) => Some(error),
            Self::Io(error) => Some(error),
            Self::ObjectStore(error) => Some(error),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for WorkflowStorageError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Database(value)
    }
}

impl From<std::io::Error> for WorkflowStorageError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<PrivateFilesystemError> for WorkflowStorageError {
    fn from(value: PrivateFilesystemError) -> Self {
        value.fold(Self::Io, Self::UnsafePath, Self::Integrity)
    }
}

impl From<WorkflowObjectStoreError> for WorkflowStorageError {
    fn from(value: WorkflowObjectStoreError) -> Self {
        Self::ObjectStore(value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowStorageScopeKind {
    Job,
    Case,
    Installation,
    AccountBinding,
}

impl WorkflowStorageScopeKind {
    const fn database_value(self) -> &'static str {
        match self {
            Self::Job => "run",
            Self::Case => "case",
            Self::Installation => "installation",
            Self::AccountBinding => "account_binding",
        }
    }

    fn from_database(value: &str) -> Result<Self> {
        match value {
            "run" => Ok(Self::Job),
            "case" => Ok(Self::Case),
            "installation" => Ok(Self::Installation),
            "account_binding" => Ok(Self::AccountBinding),
            _ => Err(WorkflowStorageError::Integrity("scope_kind")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageNamespace {
    pub kind: WorkflowStorageScopeKind,
    pub owner_id: String,
    pub installation_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageNamespaceQuota {
    pub maximum_item_count: u64,
    pub maximum_total_bytes: u64,
    pub maximum_value_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageAccessContext {
    pub run_id: Option<String>,
    pub case_id: Option<String>,
    pub installation_id: String,
    pub account_binding_ids: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkflowStorageValueInput {
    InlineCanonicalJson { bytes: Vec<u8> },
    Object { digest: String, byte_count: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageWriteRequest {
    pub command_id: String,
    pub access: WorkflowStorageAccessContext,
    pub namespace: WorkflowStorageNamespace,
    pub entry_id: String,
    pub version_id: String,
    pub reference_id: Option<String>,
    pub logical_key: String,
    pub expected_revision: u64,
    pub schema_ref: Option<String>,
    pub media_type: String,
    pub classification: String,
    pub purpose: String,
    pub value: WorkflowStorageValueInput,
    pub created_by_attempt_id: String,
    pub created_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageHandle {
    pub handle_id: String,
    pub entry_id: String,
    pub version_id: String,
    pub scope_kind: WorkflowStorageScopeKind,
    pub logical_key: String,
    pub revision: u64,
    pub schema_ref: Option<String>,
    pub media_type: String,
    pub classification: String,
    pub value_kind: String,
    pub byte_count: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStorageWriteReceipt {
    pub handle: WorkflowStorageHandle,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkflowStorageNamespaceUsage {
    pub item_count: u64,
    pub version_count: u64,
    pub byte_count: u64,
}

pub struct WorkflowScopedStorage {
    connection: Connection,
    object_store: WorkflowObjectStore,
}

struct PreparedValue {
    kind: &'static str,
    inline_json: Option<Vec<u8>>,
    blob_digest: Option<String>,
    byte_count: u64,
    sha256: String,
}

struct EntryRow {
    entry_id: String,
    schema_ref: Option<String>,
    media_type: String,
    classification: String,
    current_revision: u64,
}

impl WorkflowScopedStorage {
    pub fn open(
        object_root: impl AsRef<Path>,
        object_quota: WorkflowObjectStoreQuota,
    ) -> Result<Self> {
        let object_root = object_root.as_ref();
        if object_root.as_os_str().is_empty() || object_root.file_name().is_none() {
            return Err(WorkflowStorageError::UnsafePath("object_root_invalid"));
        }
        let object_store = WorkflowObjectStore::open(object_root, object_quota)?;
        let database_path = object_root.join("workflow-storage.sqlite");
        prepare_database_path(&database_path)?;
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let mut connection =
            Connection::open_with_flags(&database_path, flags).map_err(|error| match &error {
                rusqlite::Error::SqliteFailure(failure, _)
                    if failure.code == ErrorCode::NotADatabase =>
                {
                    WorkflowStorageError::Integrity("database_corrupt")
                }
                _ => WorkflowStorageError::Database(error),
            })?;
        private_filesystem::protect_path(&database_path, PrivatePathKind::File)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.pragma_update(None, "trusted_schema", "OFF")?;
        let existing = schema_version(&connection)?;
        if existing > STORAGE_SCHEMA_VERSION {
            return Err(WorkflowStorageError::UnsupportedNewerSchema {
                found: existing,
                supported: STORAGE_SCHEMA_VERSION,
            });
        }
        if existing == 0 {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute_batch(STORAGE_SCHEMA)?;
            transaction.execute(
                "INSERT INTO workflow_storage_migrations (version, checksum) VALUES (?1, ?2)",
                params![STORAGE_SCHEMA_VERSION, schema_checksum()],
            )?;
            transaction.pragma_update(None, "user_version", STORAGE_SCHEMA_VERSION)?;
            transaction.commit()?;
        }
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "FULL")?;
        verify_database(&connection)?;
        Ok(Self {
            connection,
            object_store,
        })
    }

    pub fn register_namespace(
        &mut self,
        namespace: WorkflowStorageNamespace,
        quota: WorkflowStorageNamespaceQuota,
        created_at_unix_millis: i64,
    ) -> Result<bool> {
        validate_namespace(&namespace)?;
        validate_namespace_quota(quota)?;
        if created_at_unix_millis < 0 {
            return Err(WorkflowStorageError::Invalid("created_at"));
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        type NamespaceRow = (Option<String>, i64, i64, i64, i64);
        let existing: Option<NamespaceRow> = transaction
            .query_row(
                "SELECT installation_id, maximum_item_count, maximum_total_bytes,
                        maximum_value_bytes, created_at_unix_millis
                 FROM storage_namespaces WHERE scope_kind = ?1 AND scope_id = ?2",
                params![namespace.kind.database_value(), namespace.owner_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()?;
        if let Some(existing) = existing {
            if existing.0 != namespace.installation_id
                || projected_u64(existing.1)? != quota.maximum_item_count
                || projected_u64(existing.2)? != quota.maximum_total_bytes
                || projected_u64(existing.3)? != quota.maximum_value_bytes
                || existing.4 != created_at_unix_millis
            {
                return Err(WorkflowStorageError::Integrity("namespace_identity_reuse"));
            }
            transaction.commit()?;
            return Ok(true);
        }
        transaction.execute(
            "INSERT INTO storage_namespaces
               (scope_kind, scope_id, installation_id, maximum_item_count,
                maximum_total_bytes, maximum_value_bytes, created_at_unix_millis)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                namespace.kind.database_value(),
                namespace.owner_id,
                namespace.installation_id,
                sql_u64(quota.maximum_item_count)?,
                sql_u64(quota.maximum_total_bytes)?,
                sql_u64(quota.maximum_value_bytes)?,
                created_at_unix_millis,
            ],
        )?;
        transaction.commit()?;
        Ok(false)
    }

    pub fn write_value(
        &mut self,
        request: WorkflowStorageWriteRequest,
    ) -> Result<WorkflowStorageWriteReceipt> {
        validate_write_request(&request)?;
        let prepared = self.prepare_value(&request.value)?;
        let request_digest = canonical_digest(&request)?;
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some((stored_digest, response_json)) = transaction
            .query_row(
                "SELECT request_digest, response_json FROM storage_command_receipts
                 WHERE command_id = ?1",
                [&request.command_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)),
            )
            .optional()?
        {
            if stored_digest != request_digest {
                return Err(WorkflowStorageError::Integrity("command_identity_reuse"));
            }
            let mut receipt: WorkflowStorageWriteReceipt =
                serde_json::from_slice(&response_json)
                    .map_err(|_| WorkflowStorageError::Integrity("command_receipt"))?;
            receipt.duplicate = true;
            transaction.commit()?;
            return Ok(receipt);
        }

        let quota = authorize_namespace(&transaction, &request.access, &request.namespace)?;
        if prepared.byte_count > quota.maximum_value_bytes {
            return Err(WorkflowStorageError::QuotaExceeded("value_bytes"));
        }
        let existing = entry_row(&transaction, &request.namespace, &request.logical_key)?;
        let actual_revision = existing.as_ref().map_or(0, |entry| entry.current_revision);
        if request.expected_revision != actual_revision {
            return Err(WorkflowStorageError::Conflict {
                expected: request.expected_revision,
                actual: actual_revision,
            });
        }
        if let Some(entry) = &existing
            && (entry.entry_id != request.entry_id
                || entry.schema_ref != request.schema_ref
                || entry.media_type != request.media_type
                || entry.classification != request.classification)
        {
            return Err(WorkflowStorageError::Integrity("entry_contract_drift"));
        }
        let usage = namespace_usage(&transaction, &request.namespace)?;
        if existing.is_none() && usage.item_count >= quota.maximum_item_count {
            return Err(WorkflowStorageError::QuotaExceeded("item_count"));
        }
        if usage
            .byte_count
            .checked_add(prepared.byte_count)
            .is_none_or(|value| value > quota.maximum_total_bytes)
        {
            return Err(WorkflowStorageError::QuotaExceeded("total_bytes"));
        }
        let revision = actual_revision
            .checked_add(1)
            .ok_or(WorkflowStorageError::Integrity("revision_overflow"))?;
        if existing.is_none() {
            transaction.execute(
                "INSERT INTO storage_entries
                   (entry_id, scope_kind, scope_id, logical_key, schema_ref, media_type,
                    classification, current_version_id, current_revision,
                    created_at_unix_millis, updated_at_unix_millis)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, 0, ?8, ?8)",
                params![
                    request.entry_id,
                    request.namespace.kind.database_value(),
                    request.namespace.owner_id,
                    request.logical_key,
                    request.schema_ref,
                    request.media_type,
                    request.classification,
                    request.created_at_unix_millis,
                ],
            )?;
        }
        transaction.execute(
            "INSERT INTO storage_versions
               (version_id, entry_id, revision, value_kind, inline_canonical_json,
                blob_digest, byte_count, sha256, created_by_attempt_id, created_at_unix_millis)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                request.version_id,
                request.entry_id,
                sql_u64(revision)?,
                prepared.kind,
                prepared.inline_json,
                prepared.blob_digest,
                sql_u64(prepared.byte_count)?,
                prepared.sha256,
                request.created_by_attempt_id,
                request.created_at_unix_millis,
            ],
        )?;
        if let Some(digest) = &prepared.blob_digest {
            transaction.execute(
                "INSERT INTO blob_references
                   (reference_id, blob_digest, scope_kind, scope_id, entry_id, version_id,
                    purpose, created_at_unix_millis)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    request.reference_id,
                    digest,
                    request.namespace.kind.database_value(),
                    request.namespace.owner_id,
                    request.entry_id,
                    request.version_id,
                    request.purpose,
                    request.created_at_unix_millis,
                ],
            )?;
        }
        let updated = transaction.execute(
            "UPDATE storage_entries SET current_version_id = ?1, current_revision = ?2,
                    updated_at_unix_millis = ?3 WHERE entry_id = ?4 AND current_revision = ?5",
            params![
                request.version_id,
                sql_u64(revision)?,
                request.created_at_unix_millis,
                request.entry_id,
                sql_u64(actual_revision)?,
            ],
        )?;
        if updated != 1 {
            return Err(WorkflowStorageError::Integrity("entry_update"));
        }
        let handle = WorkflowStorageHandle {
            handle_id: request.version_id.clone(),
            entry_id: request.entry_id.clone(),
            version_id: request.version_id,
            scope_kind: request.namespace.kind,
            logical_key: request.logical_key,
            revision,
            schema_ref: request.schema_ref,
            media_type: request.media_type,
            classification: request.classification,
            value_kind: prepared.kind.into(),
            byte_count: prepared.byte_count,
            sha256: prepared.sha256,
        };
        let receipt = WorkflowStorageWriteReceipt {
            handle,
            duplicate: false,
        };
        let response_json = serde_json_canonicalizer::to_vec(&receipt)
            .map_err(|_| WorkflowStorageError::Integrity("command_receipt_encoding"))?;
        transaction.execute(
            "INSERT INTO storage_command_receipts
               (command_id, request_digest, response_json, committed_at_unix_millis)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                request.command_id,
                request_digest,
                response_json,
                request.created_at_unix_millis,
            ],
        )?;
        transaction.commit()?;
        Ok(receipt)
    }

    pub fn inspect_handle(
        &self,
        access: &WorkflowStorageAccessContext,
        handle_id: &str,
    ) -> Result<WorkflowStorageHandle> {
        validate_access(access)?;
        validate_identifier(handle_id, "handle_id")?;
        let projected = projected_handle(&self.connection, handle_id)?
            .ok_or(WorkflowStorageError::NotFound("handle"))?;
        authorize_namespace(&self.connection, access, &projected.0)?;
        Ok(projected.1)
    }

    pub fn copy_value(
        &self,
        access: &WorkflowStorageAccessContext,
        handle_id: &str,
        maximum_bytes: u64,
        destination: &mut impl Write,
    ) -> Result<WorkflowStorageHandle> {
        let handle = self.inspect_handle(access, handle_id)?;
        if handle.byte_count > maximum_bytes {
            return Err(WorkflowStorageError::QuotaExceeded("read_bytes"));
        }
        let value: (Option<Vec<u8>>, Option<String>) = self.connection.query_row(
            "SELECT inline_canonical_json, blob_digest FROM storage_versions WHERE version_id = ?1",
            [handle_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        match value {
            (Some(bytes), None) => destination.write_all(&bytes)?,
            (None, Some(digest)) => {
                self.object_store
                    .copy_to(&digest, maximum_bytes, destination)?;
            }
            _ => return Err(WorkflowStorageError::Integrity("value_contract")),
        }
        Ok(handle)
    }

    pub fn list_current(
        &self,
        access: &WorkflowStorageAccessContext,
        namespace: &WorkflowStorageNamespace,
        prefix: Option<&str>,
        limit: u32,
    ) -> Result<Vec<WorkflowStorageHandle>> {
        validate_access(access)?;
        validate_namespace(namespace)?;
        if limit == 0 || limit > MAXIMUM_LIST_LIMIT {
            return Err(WorkflowStorageError::Invalid("list_limit"));
        }
        authorize_namespace(&self.connection, access, namespace)?;
        let prefix = prefix.unwrap_or("");
        if !prefix.is_empty() {
            validate_logical_prefix(prefix)?;
        }
        let escaped = prefix
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_");
        let mut statement = self.connection.prepare(
            "SELECT current_version_id FROM storage_entries
             WHERE scope_kind = ?1 AND scope_id = ?2 AND logical_key LIKE ?3 ESCAPE '\\'
             ORDER BY logical_key, entry_id LIMIT ?4",
        )?;
        let ids = statement
            .query_map(
                params![
                    namespace.kind.database_value(),
                    namespace.owner_id,
                    format!("{escaped}%"),
                    i64::from(limit),
                ],
                |row| row.get::<_, String>(0),
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        ids.into_iter()
            .map(|id| {
                projected_handle(&self.connection, &id)?
                    .map(|value| value.1)
                    .ok_or(WorkflowStorageError::Integrity("current_handle_missing"))
            })
            .collect()
    }

    pub fn usage(
        &self,
        access: &WorkflowStorageAccessContext,
        namespace: &WorkflowStorageNamespace,
    ) -> Result<WorkflowStorageNamespaceUsage> {
        validate_access(access)?;
        validate_namespace(namespace)?;
        authorize_namespace(&self.connection, access, namespace)?;
        namespace_usage(&self.connection, namespace)
    }

    pub fn verify_integrity(&self) -> Result<()> {
        verify_database(&self.connection)?;
        let mut statement = self.connection.prepare(
            "SELECT value_kind, inline_canonical_json, blob_digest, byte_count, sha256
             FROM storage_versions ORDER BY version_id",
        )?;
        type ValueRow = (String, Option<Vec<u8>>, Option<String>, i64, String);
        let values = statement
            .query_map([], |row| -> rusqlite::Result<ValueRow> {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        for value in values {
            let byte_count = projected_u64(value.3)?;
            match (value.0.as_str(), value.1, value.2) {
                ("inline_json", Some(bytes), None) => {
                    let canonical = workflow_canonical::canonicalize(&bytes)
                        .map_err(|_| WorkflowStorageError::Integrity("inline_json"))?;
                    if canonical.canonical_bytes != bytes
                        || bytes.len() as u64 != byte_count
                        || raw_canonical_digest(&canonical.sha256)? != value.4
                    {
                        return Err(WorkflowStorageError::Integrity("inline_value"));
                    }
                }
                ("object", None, Some(digest)) => {
                    let manifest = self.object_store.verify(&digest)?;
                    if manifest.byte_count != byte_count || manifest.digest != value.4 {
                        return Err(WorkflowStorageError::Integrity("object_value"));
                    }
                }
                _ => return Err(WorkflowStorageError::Integrity("value_contract")),
            }
        }
        Ok(())
    }

    fn prepare_value(&self, value: &WorkflowStorageValueInput) -> Result<PreparedValue> {
        match value {
            WorkflowStorageValueInput::InlineCanonicalJson { bytes } => {
                if bytes.len() > MAXIMUM_INLINE_JSON_BYTES {
                    return Err(WorkflowStorageError::QuotaExceeded("inline_bytes"));
                }
                let canonical = workflow_canonical::canonicalize(bytes)
                    .map_err(|_| WorkflowStorageError::Invalid("inline_json"))?;
                if canonical.canonical_bytes != *bytes {
                    return Err(WorkflowStorageError::Invalid("inline_not_canonical"));
                }
                Ok(PreparedValue {
                    kind: "inline_json",
                    inline_json: Some(bytes.clone()),
                    blob_digest: None,
                    byte_count: bytes.len() as u64,
                    sha256: raw_canonical_digest(&canonical.sha256)?,
                })
            }
            WorkflowStorageValueInput::Object { digest, byte_count } => {
                let manifest = self.object_store.verify(digest)?;
                verify_object_manifest(&manifest, *byte_count)?;
                Ok(PreparedValue {
                    kind: "object",
                    inline_json: None,
                    blob_digest: Some(manifest.digest.clone()),
                    byte_count: manifest.byte_count,
                    sha256: manifest.digest,
                })
            }
        }
    }
}

fn prepare_database_path(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or(WorkflowStorageError::UnsafePath("database_parent"))?;
    private_filesystem::ensure_directory(parent)?;
    if path.exists() {
        private_filesystem::file_metadata(path)?;
    }
    Ok(())
}

fn schema_version(connection: &Connection) -> Result<i64> {
    connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(Into::into)
}

fn schema_checksum() -> String {
    hex::encode(Sha256::digest(STORAGE_SCHEMA.as_bytes()))
}

fn verify_database(connection: &Connection) -> Result<()> {
    let quick: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if quick != "ok" {
        return Err(WorkflowStorageError::Integrity("quick_check"));
    }
    if schema_version(connection)? != STORAGE_SCHEMA_VERSION {
        return Err(WorkflowStorageError::Integrity("schema_version"));
    }
    let checksum: String = connection.query_row(
        "SELECT checksum FROM workflow_storage_migrations WHERE version = ?1",
        [STORAGE_SCHEMA_VERSION],
        |row| row.get(0),
    )?;
    if checksum != schema_checksum() {
        return Err(WorkflowStorageError::Integrity("migration_checksum"));
    }
    let foreign_keys: i64 = connection
        .query_row("PRAGMA foreign_key_check", [], |_| Ok(1))
        .optional()?
        .unwrap_or(0);
    if foreign_keys != 0 {
        return Err(WorkflowStorageError::Integrity("foreign_keys"));
    }
    let invalid_current: i64 = connection.query_row(
        "SELECT COUNT(*) FROM storage_entries e
         LEFT JOIN storage_versions v ON v.version_id = e.current_version_id
         WHERE e.current_revision <= 0 OR e.current_version_id IS NULL
            OR v.entry_id IS NULL OR v.entry_id <> e.entry_id OR v.revision <> e.current_revision",
        [],
        |row| row.get(0),
    )?;
    if invalid_current != 0 {
        return Err(WorkflowStorageError::Integrity("current_versions"));
    }
    let invalid_references: i64 = connection.query_row(
        "SELECT COUNT(*) FROM storage_versions v
         JOIN storage_entries e ON e.entry_id = v.entry_id
         LEFT JOIN blob_references b ON b.version_id = v.version_id
         WHERE (v.value_kind = 'object' AND (
                  b.reference_id IS NULL OR b.blob_digest <> v.blob_digest
                  OR b.entry_id <> v.entry_id OR b.scope_kind <> e.scope_kind OR b.scope_id <> e.scope_id
               ))
            OR (v.value_kind = 'inline_json' AND b.reference_id IS NOT NULL)",
        [],
        |row| row.get(0),
    )?;
    if invalid_references != 0 {
        return Err(WorkflowStorageError::Integrity("blob_references"));
    }
    Ok(())
}

fn validate_namespace(namespace: &WorkflowStorageNamespace) -> Result<()> {
    validate_identifier(&namespace.owner_id, "scope_id")?;
    if let Some(installation_id) = &namespace.installation_id {
        validate_identifier(installation_id, "installation_id")?;
    }
    match namespace.kind {
        WorkflowStorageScopeKind::Job | WorkflowStorageScopeKind::Case => {
            if namespace.installation_id.is_none() {
                return Err(WorkflowStorageError::Invalid("namespace_installation"));
            }
        }
        WorkflowStorageScopeKind::Installation => {
            if namespace.installation_id.as_deref() != Some(&namespace.owner_id) {
                return Err(WorkflowStorageError::Invalid("installation_owner"));
            }
        }
        WorkflowStorageScopeKind::AccountBinding => {
            if namespace.installation_id.is_some() {
                return Err(WorkflowStorageError::Invalid("account_installation"));
            }
        }
    }
    Ok(())
}

fn validate_namespace_quota(quota: WorkflowStorageNamespaceQuota) -> Result<()> {
    if quota.maximum_item_count == 0
        || quota.maximum_total_bytes == 0
        || quota.maximum_value_bytes == 0
        || quota.maximum_value_bytes > quota.maximum_total_bytes
    {
        return Err(WorkflowStorageError::Invalid("namespace_quota"));
    }
    sql_u64(quota.maximum_item_count)?;
    sql_u64(quota.maximum_total_bytes)?;
    sql_u64(quota.maximum_value_bytes)?;
    Ok(())
}

fn validate_access(access: &WorkflowStorageAccessContext) -> Result<()> {
    validate_identifier(&access.installation_id, "access_installation")?;
    if let Some(run_id) = &access.run_id {
        validate_identifier(run_id, "access_run")?;
    }
    if let Some(case_id) = &access.case_id {
        validate_identifier(case_id, "access_case")?;
    }
    if access.account_binding_ids.len() > MAXIMUM_ACCOUNT_BINDINGS {
        return Err(WorkflowStorageError::Invalid("access_account_count"));
    }
    for account in &access.account_binding_ids {
        validate_identifier(account, "access_account")?;
    }
    Ok(())
}

fn validate_write_request(request: &WorkflowStorageWriteRequest) -> Result<()> {
    validate_access(&request.access)?;
    validate_namespace(&request.namespace)?;
    for (value, code) in [
        (&request.command_id, "command_id"),
        (&request.entry_id, "entry_id"),
        (&request.version_id, "version_id"),
        (&request.created_by_attempt_id, "attempt_id"),
    ] {
        validate_identifier(value, code)?;
    }
    validate_logical_key(&request.logical_key)?;
    if request.media_type.is_empty()
        || request.media_type.len() > 255
        || !request
            .media_type
            .bytes()
            .all(|byte| byte.is_ascii_graphic())
    {
        return Err(WorkflowStorageError::Invalid("media_type"));
    }
    if !matches!(
        request.classification.as_str(),
        "private" | "sensitive" | "restricted"
    ) {
        return Err(WorkflowStorageError::Invalid("classification"));
    }
    if !matches!(request.purpose.as_str(), "value" | "file" | "artifact") {
        return Err(WorkflowStorageError::Invalid("purpose"));
    }
    if request.created_at_unix_millis < 0
        || request.schema_ref.as_ref().is_some_and(|value| {
            value.is_empty() || value.len() > 512 || value.chars().any(char::is_control)
        })
    {
        return Err(WorkflowStorageError::Invalid("write_metadata"));
    }
    match (&request.value, &request.reference_id) {
        (WorkflowStorageValueInput::InlineCanonicalJson { .. }, None) => {}
        (WorkflowStorageValueInput::Object { .. }, Some(reference)) => {
            validate_identifier(reference, "reference_id")?;
        }
        _ => return Err(WorkflowStorageError::Invalid("reference_contract")),
    }
    Ok(())
}

fn validate_identifier(value: &str, code: &'static str) -> Result<()> {
    if !is_workflow_identifier(value, 128) {
        return Err(WorkflowStorageError::Invalid(code));
    }
    Ok(())
}

fn validate_logical_key(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 512
        || value.starts_with('/')
        || value.ends_with('/')
        || value.contains('\\')
        || value.chars().any(char::is_control)
        || value
            .split('/')
            .any(|component| component.is_empty() || matches!(component, "." | ".."))
    {
        return Err(WorkflowStorageError::Invalid("logical_key"));
    }
    Ok(())
}

fn validate_logical_prefix(value: &str) -> Result<()> {
    let components = value.split('/').collect::<Vec<_>>();
    if value.len() > 512
        || value.starts_with('/')
        || value.contains('\\')
        || value.chars().any(char::is_control)
        || components.iter().enumerate().any(|(index, component)| {
            matches!(*component, "." | "..")
                || (component.is_empty() && index + 1 != components.len())
        })
    {
        return Err(WorkflowStorageError::Invalid("logical_prefix"));
    }
    Ok(())
}

fn authorize_namespace(
    connection: &Connection,
    access: &WorkflowStorageAccessContext,
    namespace: &WorkflowStorageNamespace,
) -> Result<WorkflowStorageNamespaceQuota> {
    validate_access(access)?;
    validate_namespace(namespace)?;
    type NamespaceRow = (Option<String>, i64, i64, i64);
    let row: NamespaceRow = connection
        .query_row(
            "SELECT installation_id, maximum_item_count, maximum_total_bytes,
                    maximum_value_bytes FROM storage_namespaces
             WHERE scope_kind = ?1 AND scope_id = ?2",
            params![namespace.kind.database_value(), namespace.owner_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?
        .ok_or(WorkflowStorageError::NotFound("namespace"))?;
    if row.0 != namespace.installation_id {
        return Err(WorkflowStorageError::Integrity("namespace_binding"));
    }
    let allowed = match namespace.kind {
        WorkflowStorageScopeKind::Job => {
            access.run_id.as_deref() == Some(&namespace.owner_id)
                && namespace.installation_id.as_deref() == Some(&access.installation_id)
        }
        WorkflowStorageScopeKind::Case => {
            access.case_id.as_deref() == Some(&namespace.owner_id)
                && namespace.installation_id.as_deref() == Some(&access.installation_id)
        }
        WorkflowStorageScopeKind::Installation => namespace.owner_id == access.installation_id,
        WorkflowStorageScopeKind::AccountBinding => {
            access.account_binding_ids.contains(&namespace.owner_id)
        }
    };
    if !allowed {
        return Err(WorkflowStorageError::AccessDenied("namespace"));
    }
    Ok(WorkflowStorageNamespaceQuota {
        maximum_item_count: projected_u64(row.1)?,
        maximum_total_bytes: projected_u64(row.2)?,
        maximum_value_bytes: projected_u64(row.3)?,
    })
}

fn entry_row(
    transaction: &Transaction<'_>,
    namespace: &WorkflowStorageNamespace,
    logical_key: &str,
) -> Result<Option<EntryRow>> {
    type Row = (String, Option<String>, String, String, i64);
    let row: Option<Row> = transaction
        .query_row(
            "SELECT entry_id, schema_ref, media_type, classification, current_revision
             FROM storage_entries WHERE scope_kind = ?1 AND scope_id = ?2 AND logical_key = ?3",
            params![
                namespace.kind.database_value(),
                namespace.owner_id,
                logical_key
            ],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()?;
    row.map(|row| {
        Ok(EntryRow {
            entry_id: row.0,
            schema_ref: row.1,
            media_type: row.2,
            classification: row.3,
            current_revision: projected_u64(row.4)?,
        })
    })
    .transpose()
}

fn namespace_usage(
    connection: &Connection,
    namespace: &WorkflowStorageNamespace,
) -> Result<WorkflowStorageNamespaceUsage> {
    let row: (i64, i64, i64) = connection.query_row(
        "SELECT
            (SELECT COUNT(*) FROM storage_entries WHERE scope_kind = ?1 AND scope_id = ?2),
            (SELECT COUNT(*) FROM storage_versions v JOIN storage_entries e ON e.entry_id = v.entry_id
             WHERE e.scope_kind = ?1 AND e.scope_id = ?2),
            (SELECT COALESCE(SUM(v.byte_count), 0) FROM storage_versions v
             JOIN storage_entries e ON e.entry_id = v.entry_id
             WHERE e.scope_kind = ?1 AND e.scope_id = ?2)",
        params![namespace.kind.database_value(), namespace.owner_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    Ok(WorkflowStorageNamespaceUsage {
        item_count: projected_u64(row.0)?,
        version_count: projected_u64(row.1)?,
        byte_count: projected_u64(row.2)?,
    })
}

fn projected_handle(
    connection: &Connection,
    version_id: &str,
) -> Result<Option<(WorkflowStorageNamespace, WorkflowStorageHandle)>> {
    type Row = (
        String,
        String,
        Option<String>,
        String,
        String,
        String,
        Option<String>,
        String,
        String,
        i64,
        String,
        i64,
        String,
    );
    let row: Option<Row> = connection
        .query_row(
            "SELECT e.scope_kind, e.scope_id, n.installation_id, e.entry_id, v.version_id,
                    e.logical_key, e.schema_ref, e.media_type, e.classification, v.revision,
                    v.value_kind, v.byte_count, v.sha256
             FROM storage_versions v
             JOIN storage_entries e ON e.entry_id = v.entry_id
             JOIN storage_namespaces n ON n.scope_kind = e.scope_kind AND n.scope_id = e.scope_id
             WHERE v.version_id = ?1",
            [version_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                ))
            },
        )
        .optional()?;
    row.map(|row| {
        let scope_kind = WorkflowStorageScopeKind::from_database(&row.0)?;
        Ok((
            WorkflowStorageNamespace {
                kind: scope_kind,
                owner_id: row.1,
                installation_id: row.2,
            },
            WorkflowStorageHandle {
                handle_id: row.4.clone(),
                entry_id: row.3,
                version_id: row.4,
                scope_kind,
                logical_key: row.5,
                revision: projected_u64(row.9)?,
                schema_ref: row.6,
                media_type: row.7,
                classification: row.8,
                value_kind: row.10,
                byte_count: projected_u64(row.11)?,
                sha256: row.12,
            },
        ))
    })
    .transpose()
}

fn verify_object_manifest(manifest: &WorkflowObjectManifest, byte_count: u64) -> Result<()> {
    if manifest.byte_count != byte_count {
        return Err(WorkflowStorageError::Integrity("object_byte_count"));
    }
    Ok(())
}

fn canonical_digest(value: &impl Serialize) -> Result<String> {
    let bytes = serde_json_canonicalizer::to_vec(value)
        .map_err(|_| WorkflowStorageError::Invalid("request_encoding"))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

fn raw_canonical_digest(value: &str) -> Result<String> {
    let raw = value
        .strip_prefix("sha256:")
        .ok_or(WorkflowStorageError::Integrity("canonical_digest"))?;
    if raw.len() != 64
        || !raw
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(WorkflowStorageError::Integrity("canonical_digest"));
    }
    Ok(raw.into())
}

fn projected_u64(value: i64) -> Result<u64> {
    value
        .try_into()
        .map_err(|_| WorkflowStorageError::Integrity("negative_integer"))
}

fn sql_u64(value: u64) -> Result<i64> {
    value
        .try_into()
        .map_err(|_| WorkflowStorageError::Invalid("integer_out_of_range"))
}
