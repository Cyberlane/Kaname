//! Private, content-addressed storage for workflow bytes.
//!
//! This layer owns physical integrity and deduplication only. Logical scope,
//! ownership, retention, and opaque workflow handles are added above it; no
//! public API in this module exposes a host filesystem path.

use crate::private_filesystem::{
    self, PrivateFilesystemError, directory_metadata as private_directory_metadata,
    ensure_directory as ensure_private_directory, file_metadata as private_file_metadata,
    make_immutable_file, read_bounded_file as read_bounded_private_file, sync_directory,
    write_new_file as write_new_private_file, write_new_file_unflushed,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    error::Error,
    fmt,
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MANIFEST_FORMAT_VERSION: u32 = 1;
const COPY_BUFFER_BYTES: usize = 128 * 1024;
const MAXIMUM_MANIFEST_BYTES: u64 = 16 * 1024;

pub type Result<T> = std::result::Result<T, WorkflowObjectStoreError>;

#[derive(Debug)]
pub enum WorkflowObjectStoreError {
    Io(std::io::Error),
    UnsafePath(&'static str),
    InvalidArgument(&'static str),
    QuotaExceeded(&'static str),
    ChecksumMismatch,
    Integrity(&'static str),
    Interrupted(&'static str),
}

impl fmt::Display for WorkflowObjectStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "object_store_io:{error}"),
            Self::UnsafePath(code) => write!(formatter, "object_store_unsafe_path:{code}"),
            Self::InvalidArgument(code) => write!(formatter, "object_store_invalid:{code}"),
            Self::QuotaExceeded(code) => write!(formatter, "object_store_quota:{code}"),
            Self::ChecksumMismatch => formatter.write_str("object_store_checksum_mismatch"),
            Self::Integrity(code) => write!(formatter, "object_store_integrity:{code}"),
            Self::Interrupted(code) => write!(formatter, "object_store_interrupted:{code}"),
        }
    }
}

impl Error for WorkflowObjectStoreError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for WorkflowObjectStoreError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<PrivateFilesystemError> for WorkflowObjectStoreError {
    fn from(value: PrivateFilesystemError) -> Self {
        match value {
            PrivateFilesystemError::Io(error) => Self::Io(error),
            PrivateFilesystemError::UnsafePath(code) => Self::UnsafePath(code),
            PrivateFilesystemError::Bounds(code) => Self::QuotaExceeded(code),
        }
    }
}

impl From<serde_json::Error> for WorkflowObjectStoreError {
    fn from(_: serde_json::Error) -> Self {
        Self::Integrity("manifest_json")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkflowObjectStoreQuota {
    pub maximum_object_bytes: u64,
    pub maximum_total_bytes: u64,
    pub maximum_object_count: u64,
}

impl WorkflowObjectStoreQuota {
    pub const fn local_default() -> Self {
        Self {
            maximum_object_bytes: 1024 * 1024 * 1024,
            maximum_total_bytes: 10 * 1024 * 1024 * 1024,
            maximum_object_count: 100_000,
        }
    }

    fn validate(self) -> Result<Self> {
        if self.maximum_object_bytes == 0
            || self.maximum_total_bytes < self.maximum_object_bytes
            || self.maximum_object_count == 0
        {
            return Err(WorkflowObjectStoreError::InvalidArgument("quota_contract"));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowObjectManifest {
    pub object_format_version: u32,
    pub algorithm: String,
    pub digest: String,
    pub byte_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredWorkflowObject {
    pub manifest: WorkflowObjectManifest,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkflowObjectStoreUsage {
    pub object_count: u64,
    pub byte_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowObjectRecoveryReport {
    pub staged_writes_quarantined: u64,
    pub invalid_objects_quarantined: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowObjectGarbageCollectionReceipt {
    pub retained_object_count: u64,
    pub quarantined_object_count: u64,
    pub quarantined_byte_count: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowObjectStoreFault {
    AfterDataFsyncBeforePromotion,
    AfterObjectPromotionBeforeManifest,
    AfterManifestPromotion,
}

pub struct WorkflowObjectStore {
    root: PathBuf,
    quota: WorkflowObjectStoreQuota,
}

pub struct WorkflowObjectWrite {
    staging_directory: PathBuf,
    data_path: PathBuf,
    file: Option<File>,
    hasher: Sha256,
    byte_count: u64,
    expected_digest: Option<String>,
    quota: WorkflowObjectStoreQuota,
}

impl WorkflowObjectStore {
    pub fn open(root: impl AsRef<Path>, quota: WorkflowObjectStoreQuota) -> Result<Self> {
        let root = root.as_ref();
        if root.as_os_str().is_empty() || root.file_name().is_none() {
            return Err(WorkflowObjectStoreError::UnsafePath("root_invalid"));
        }
        let quota = quota.validate()?;
        ensure_private_directory(root)?;
        ensure_private_directory(&root.join("sha256"))?;
        ensure_private_directory(&root.join("Manifests").join("sha256"))?;
        ensure_private_directory(&root.join("Staging"))?;
        ensure_private_directory(&root.join("Recovery").join("Staging"))?;
        ensure_private_directory(&root.join("Recovery").join("Objects"))?;
        Ok(Self {
            root: root.to_path_buf(),
            quota,
        })
    }

    pub fn begin_write(
        &self,
        write_id: &str,
        expected_digest: Option<&str>,
    ) -> Result<WorkflowObjectWrite> {
        validate_write_id(write_id)?;
        let expected_digest = expected_digest.map(normalize_digest).transpose()?;
        let staging_directory = self.root.join("Staging").join(write_id);
        fs::create_dir(&staging_directory).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                WorkflowObjectStoreError::InvalidArgument("write_id_in_use")
            } else {
                error.into()
            }
        })?;
        private_filesystem::protect_path(
            &staging_directory,
            private_filesystem::PrivatePathKind::Directory,
        )?;
        sync_directory(&self.root.join("Staging"))?;
        let data_path = staging_directory.join("object.partial");
        let file = write_new_file_unflushed(&data_path, &[])?;
        Ok(WorkflowObjectWrite {
            staging_directory,
            data_path,
            file: Some(file),
            hasher: Sha256::new(),
            byte_count: 0,
            expected_digest,
            quota: self.quota,
        })
    }

    pub fn finalize(&self, write: WorkflowObjectWrite) -> Result<StoredWorkflowObject> {
        self.finalize_inner(write, None)
    }

    #[doc(hidden)]
    pub fn finalize_with_fault_for_test(
        &self,
        write: WorkflowObjectWrite,
        fault: WorkflowObjectStoreFault,
    ) -> Result<StoredWorkflowObject> {
        self.finalize_inner(write, Some(fault))
    }

    fn finalize_inner(
        &self,
        mut write: WorkflowObjectWrite,
        fault: Option<WorkflowObjectStoreFault>,
    ) -> Result<StoredWorkflowObject> {
        let mut file = write
            .file
            .take()
            .ok_or(WorkflowObjectStoreError::Integrity("write_closed"))?;
        file.flush()?;
        file.sync_all()?;
        drop(file);
        sync_directory(&write.staging_directory)?;
        if fault == Some(WorkflowObjectStoreFault::AfterDataFsyncBeforePromotion) {
            return Err(WorkflowObjectStoreError::Interrupted("after_data_fsync"));
        }

        let digest = hex::encode(write.hasher.clone().finalize());
        if write
            .expected_digest
            .as_deref()
            .is_some_and(|value| value != digest)
        {
            self.quarantine_staging(&write.staging_directory, "checksum")?;
            return Err(WorkflowObjectStoreError::ChecksumMismatch);
        }
        let manifest = WorkflowObjectManifest {
            object_format_version: MANIFEST_FORMAT_VERSION,
            algorithm: "sha256".into(),
            digest: digest.clone(),
            byte_count: write.byte_count,
        };
        let object_path = self.object_path(&digest)?;
        let manifest_path = self.manifest_path(&digest)?;
        ensure_private_directory(
            object_path
                .parent()
                .ok_or(WorkflowObjectStoreError::UnsafePath("object_parent"))?,
        )?;
        ensure_private_directory(
            manifest_path
                .parent()
                .ok_or(WorkflowObjectStoreError::UnsafePath("manifest_parent"))?,
        )?;

        if object_path.exists() || manifest_path.exists() {
            let existing = self.verify(&digest)?;
            if existing != manifest {
                return Err(WorkflowObjectStoreError::Integrity("digest_collision"));
            }
            fs::remove_dir_all(&write.staging_directory)?;
            sync_directory(&self.root.join("Staging"))?;
            return Ok(StoredWorkflowObject {
                manifest,
                duplicate: true,
            });
        }

        let usage = self.usage()?;
        if usage.object_count >= self.quota.maximum_object_count {
            return Err(WorkflowObjectStoreError::QuotaExceeded("object_count"));
        }
        if usage
            .byte_count
            .checked_add(write.byte_count)
            .is_none_or(|total| total > self.quota.maximum_total_bytes)
        {
            return Err(WorkflowObjectStoreError::QuotaExceeded("total_bytes"));
        }

        let manifest_bytes = canonical_manifest(&manifest)?;
        let staged_manifest = write.staging_directory.join("manifest.partial");
        write_new_private_file(&staged_manifest, &manifest_bytes)?;
        sync_directory(&write.staging_directory)?;
        fs::rename(&write.data_path, &object_path)?;
        make_immutable_file(&object_path)?;
        sync_directory(object_path.parent().expect("validated object parent"))?;
        if fault == Some(WorkflowObjectStoreFault::AfterObjectPromotionBeforeManifest) {
            return Err(WorkflowObjectStoreError::Interrupted(
                "after_object_promotion",
            ));
        }
        fs::rename(&staged_manifest, &manifest_path)?;
        make_immutable_file(&manifest_path)?;
        sync_directory(manifest_path.parent().expect("validated manifest parent"))?;
        if fault == Some(WorkflowObjectStoreFault::AfterManifestPromotion) {
            return Err(WorkflowObjectStoreError::Interrupted(
                "after_manifest_promotion",
            ));
        }
        let verified = self.verify(&digest)?;
        if verified != manifest {
            return Err(WorkflowObjectStoreError::Integrity("promotion_mismatch"));
        }
        fs::remove_dir(&write.staging_directory)?;
        sync_directory(&self.root.join("Staging"))?;
        Ok(StoredWorkflowObject {
            manifest,
            duplicate: false,
        })
    }

    pub fn verify(&self, digest: &str) -> Result<WorkflowObjectManifest> {
        let digest = normalize_digest(digest)?;
        let object_path = self.object_path(&digest)?;
        let manifest_path = self.manifest_path(&digest)?;
        let manifest_bytes = read_bounded_private_file(&manifest_path, MAXIMUM_MANIFEST_BYTES)?;
        let canonical = serde_json_canonicalizer::to_vec(&serde_json::from_slice::<
            serde_json::Value,
        >(&manifest_bytes)?)
        .map_err(|_| WorkflowObjectStoreError::Integrity("manifest_canonicalization"))?;
        if canonical != manifest_bytes {
            return Err(WorkflowObjectStoreError::Integrity(
                "manifest_not_canonical",
            ));
        }
        let manifest: WorkflowObjectManifest = serde_json::from_slice(&manifest_bytes)?;
        if manifest.object_format_version != MANIFEST_FORMAT_VERSION
            || manifest.algorithm != "sha256"
            || manifest.digest != digest
        {
            return Err(WorkflowObjectStoreError::Integrity("manifest_contract"));
        }
        let metadata = private_file_metadata(&object_path)?;
        if metadata.len() != manifest.byte_count
            || stream_digest(&object_path, self.quota.maximum_object_bytes)? != digest
        {
            return Err(WorkflowObjectStoreError::Integrity("object_digest"));
        }
        Ok(manifest)
    }

    pub fn copy_to(
        &self,
        digest: &str,
        maximum_bytes: u64,
        destination: &mut impl Write,
    ) -> Result<WorkflowObjectManifest> {
        let manifest = self.verify(digest)?;
        if manifest.byte_count > maximum_bytes {
            return Err(WorkflowObjectStoreError::QuotaExceeded("read_bytes"));
        }
        let mut source = File::open(self.object_path(&manifest.digest)?)?;
        let mut buffer = vec![0_u8; COPY_BUFFER_BYTES];
        let mut copied = 0_u64;
        loop {
            let count = source.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            destination.write_all(&buffer[..count])?;
            copied = copied
                .checked_add(count as u64)
                .ok_or(WorkflowObjectStoreError::Integrity("read_overflow"))?;
        }
        if copied != manifest.byte_count {
            return Err(WorkflowObjectStoreError::Integrity("read_length"));
        }
        Ok(manifest)
    }

    pub fn usage(&self) -> Result<WorkflowObjectStoreUsage> {
        let manifests = self.inventory()?;
        manifests.values().try_fold(
            WorkflowObjectStoreUsage {
                object_count: 0,
                byte_count: 0,
            },
            |usage, manifest| {
                Ok(WorkflowObjectStoreUsage {
                    object_count: usage
                        .object_count
                        .checked_add(1)
                        .ok_or(WorkflowObjectStoreError::Integrity("count_overflow"))?,
                    byte_count: usage
                        .byte_count
                        .checked_add(manifest.byte_count)
                        .ok_or(WorkflowObjectStoreError::Integrity("usage_overflow"))?,
                })
            },
        )
    }

    pub fn recover(&self) -> Result<WorkflowObjectRecoveryReport> {
        let mut report = WorkflowObjectRecoveryReport {
            staged_writes_quarantined: 0,
            invalid_objects_quarantined: 0,
        };
        for entry in sorted_directory_entries(&self.root.join("Staging"))? {
            if !private_directory_metadata(&entry)?.is_dir() {
                return Err(WorkflowObjectStoreError::UnsafePath("staging_entry"));
            }
            self.quarantine_staging(&entry, "interrupted")?;
            report.staged_writes_quarantined += 1;
        }

        let candidates = self.candidate_digests()?;
        for digest in candidates {
            if self.verify(&digest).is_err() {
                self.quarantine_object(&digest, "invalid")?;
                report.invalid_objects_quarantined += 1;
            }
        }
        Ok(report)
    }

    pub fn quarantine_unreferenced(
        &self,
        live_digests: &BTreeSet<String>,
    ) -> Result<WorkflowObjectGarbageCollectionReceipt> {
        let live = live_digests
            .iter()
            .map(|digest| normalize_digest(digest))
            .collect::<Result<BTreeSet<_>>>()?;
        let inventory = self.inventory()?;
        if !live.is_subset(&inventory.keys().cloned().collect()) {
            return Err(WorkflowObjectStoreError::Integrity("live_object_missing"));
        }
        let mut receipt = WorkflowObjectGarbageCollectionReceipt {
            retained_object_count: live.len() as u64,
            quarantined_object_count: 0,
            quarantined_byte_count: 0,
        };
        for (digest, manifest) in inventory {
            if !live.contains(&digest) {
                self.quarantine_object(&digest, "unreferenced")?;
                receipt.quarantined_object_count += 1;
                receipt.quarantined_byte_count = receipt
                    .quarantined_byte_count
                    .checked_add(manifest.byte_count)
                    .ok_or(WorkflowObjectStoreError::Integrity("gc_overflow"))?;
            }
        }
        Ok(receipt)
    }

    fn inventory(&self) -> Result<std::collections::BTreeMap<String, WorkflowObjectManifest>> {
        self.candidate_digests()?
            .into_iter()
            .map(|digest| self.verify(&digest).map(|manifest| (digest, manifest)))
            .collect()
    }

    fn candidate_digests(&self) -> Result<BTreeSet<String>> {
        let mut digests = BTreeSet::new();
        collect_digest_names(&self.root.join("sha256"), false, &mut digests)?;
        collect_digest_names(
            &self.root.join("Manifests").join("sha256"),
            true,
            &mut digests,
        )?;
        Ok(digests)
    }

    fn object_path(&self, digest: &str) -> Result<PathBuf> {
        let digest = normalize_digest(digest)?;
        Ok(self.root.join("sha256").join(&digest[..2]).join(digest))
    }

    fn manifest_path(&self, digest: &str) -> Result<PathBuf> {
        let digest = normalize_digest(digest)?;
        Ok(self
            .root
            .join("Manifests")
            .join("sha256")
            .join(&digest[..2])
            .join(format!("{digest}.json")))
    }

    fn quarantine_staging(&self, source: &Path, reason: &str) -> Result<()> {
        let name = source
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or(WorkflowObjectStoreError::UnsafePath("staging_name"))?;
        let target = unique_recovery_path(
            &self.root.join("Recovery").join("Staging"),
            &format!("{reason}-{name}"),
        )?;
        fs::rename(source, target)?;
        sync_directory(&self.root.join("Staging"))?;
        sync_directory(&self.root.join("Recovery").join("Staging"))?;
        Ok(())
    }

    fn quarantine_object(&self, digest: &str, reason: &str) -> Result<()> {
        let digest = normalize_digest(digest)?;
        let recovery = unique_recovery_path(
            &self.root.join("Recovery").join("Objects"),
            &format!("{reason}-{digest}"),
        )?;
        ensure_private_directory(&recovery)?;
        let object = self.object_path(&digest)?;
        let manifest = self.manifest_path(&digest)?;
        if object.exists() {
            fs::rename(&object, recovery.join("object"))?;
            sync_directory(object.parent().expect("validated object parent"))?;
        }
        if manifest.exists() {
            fs::rename(&manifest, recovery.join("manifest.json"))?;
            sync_directory(manifest.parent().expect("validated manifest parent"))?;
        }
        sync_directory(&recovery)?;
        sync_directory(&self.root.join("Recovery").join("Objects"))?;
        Ok(())
    }
}

impl WorkflowObjectWrite {
    pub fn write_chunk(&mut self, bytes: &[u8]) -> Result<()> {
        let next = self
            .byte_count
            .checked_add(bytes.len() as u64)
            .ok_or(WorkflowObjectStoreError::QuotaExceeded("object_bytes"))?;
        if next > self.quota.maximum_object_bytes {
            return Err(WorkflowObjectStoreError::QuotaExceeded("object_bytes"));
        }
        self.file
            .as_mut()
            .ok_or(WorkflowObjectStoreError::Integrity("write_closed"))?
            .write_all(bytes)?;
        self.hasher.update(bytes);
        self.byte_count = next;
        Ok(())
    }

    pub const fn byte_count(&self) -> u64 {
        self.byte_count
    }
}

fn canonical_manifest(manifest: &WorkflowObjectManifest) -> Result<Vec<u8>> {
    serde_json_canonicalizer::to_vec(manifest)
        .map_err(|_| WorkflowObjectStoreError::Integrity("manifest_encoding"))
}

fn normalize_digest(value: &str) -> Result<String> {
    let digest = value.strip_prefix("sha256:").unwrap_or(value);
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(WorkflowObjectStoreError::InvalidArgument("digest"));
    }
    Ok(digest.to_owned())
}

fn validate_write_id(value: &str) -> Result<()> {
    if !(8..=96).contains(&value.len())
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err(WorkflowObjectStoreError::InvalidArgument("write_id"));
    }
    Ok(())
}

fn collect_digest_names(root: &Path, manifests: bool, target: &mut BTreeSet<String>) -> Result<()> {
    for shard in sorted_directory_entries(root)? {
        let name = shard
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or(WorkflowObjectStoreError::UnsafePath("shard_name"))?
            .to_owned();
        if name.len() != 2
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            || !private_directory_metadata(&shard)?.is_dir()
        {
            return Err(WorkflowObjectStoreError::Integrity("shard_contract"));
        }
        for path in sorted_directory_entries(&shard)? {
            private_file_metadata(&path)?;
            let file_name = path
                .file_name()
                .and_then(|value| value.to_str())
                .ok_or(WorkflowObjectStoreError::UnsafePath("object_name"))?;
            let digest = if manifests {
                file_name
                    .strip_suffix(".json")
                    .ok_or(WorkflowObjectStoreError::Integrity("manifest_name"))?
            } else {
                file_name
            };
            let digest = normalize_digest(digest)?;
            if !digest.starts_with(&name) {
                return Err(WorkflowObjectStoreError::Integrity("shard_mismatch"));
            }
            target.insert(digest);
        }
    }
    Ok(())
}

fn stream_digest(path: &Path, maximum_bytes: u64) -> Result<String> {
    let metadata = private_file_metadata(path)?;
    if metadata.len() > maximum_bytes {
        return Err(WorkflowObjectStoreError::QuotaExceeded("object_bytes"));
    }
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; COPY_BUFFER_BYTES];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn sorted_directory_entries(path: &Path) -> Result<Vec<PathBuf>> {
    private_directory_metadata(path)?;
    let mut entries = fs::read_dir(path)?
        .map(|entry| entry.map(|value| value.path()))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    entries.sort();
    Ok(entries)
}

fn unique_recovery_path(root: &Path, suffix: &str) -> Result<PathBuf> {
    ensure_private_directory(root)?;
    let millis = unix_millis();
    for sequence in 0..10_000_u32 {
        let candidate = root.join(format!("{millis}-{sequence:04}-{suffix}"));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(WorkflowObjectStoreError::Integrity(
        "recovery_name_exhausted",
    ))
}

fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
