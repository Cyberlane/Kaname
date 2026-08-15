//! Rust-owned control-plane schema boundary.
//!
//! This module is generated from the same canonical proto files as the Swift
//! `KanameProtocol` target. No generated source is hand-maintained here.

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/kaname.v1.rs"));
}

pub mod fake_provider;
pub mod journal;
pub mod mobile;
pub mod policy;
pub(crate) mod private_filesystem;
pub mod workflow_canonical;
pub mod workflow_capabilities;
pub mod workflow_compiler;
pub mod workflow_connector_observation;
pub mod workflow_drafts;
pub mod workflow_effect_authority;
pub mod workflow_effect_connector;
pub mod workflow_executor;
pub mod workflow_import;
pub mod workflow_library;
pub mod workflow_llm;
pub mod workflow_mail;
pub mod workflow_mail_artifacts;
pub mod workflow_mail_feedback;
pub mod workflow_mail_review;
pub mod workflow_match;
pub mod workflow_object_store;
pub mod workflow_projection;
pub mod workflow_protocol;
pub mod workflow_publication;
pub mod workflow_purge;
pub mod workflow_retention;
pub mod workflow_runtime;
pub mod workflow_schema;
pub mod workflow_storage;
pub mod workflow_versions;

pub const SCHEMA_MAJOR: u32 = 1;
pub const MAXIMUM_ENVELOPE_BYTES: usize = 64 * 1024;

fn checked_application_support_root(
    application_support_root: &std::path::Path,
) -> Result<&std::path::Path, &'static str> {
    if application_support_root.as_os_str().is_empty()
        || application_support_root.file_name().is_none()
    {
        return Err("application_support_root_invalid");
    }
    Ok(application_support_root)
}

fn open_object_backed_store<T, E>(
    application_support_root: &std::path::Path,
    quota: workflow_object_store::WorkflowObjectStoreQuota,
    invalid_path: fn(&'static str) -> E,
    open: impl FnOnce(
        std::path::PathBuf,
        workflow_object_store::WorkflowObjectStoreQuota,
    ) -> Result<T, E>,
) -> Result<T, E> {
    let root = checked_application_support_root(application_support_root).map_err(invalid_path)?;
    open(root.join("Objects"), quota)
}

/// Opens the workflow catalog at its stable application-support location.
///
/// Callers provide the already selected Kaname application-support root; the
/// library owns only `Workflows/workflow-library.sqlite` beneath that root.
/// This keeps channel and test isolation in the host while preventing callers
/// from inventing a second durable filename or mixing the catalog into the
/// runtime journal.
pub fn open_workflow_library(
    application_support_root: impl AsRef<std::path::Path>,
) -> workflow_library::Result<workflow_library::WorkflowLibraryStore> {
    let root = checked_application_support_root(application_support_root.as_ref())
        .map_err(workflow_library::WorkflowLibraryError::UnsafePath)?;
    workflow_library::WorkflowLibraryStore::open(
        root.join("Workflows").join("workflow-library.sqlite"),
    )
}

/// Opens the workflow content-addressed store at its single stable location.
///
/// The caller selects only the Kaname application-support root. Object paths,
/// staging paths, and recovery paths remain private implementation details.
pub fn open_workflow_object_store(
    application_support_root: impl AsRef<std::path::Path>,
    quota: workflow_object_store::WorkflowObjectStoreQuota,
) -> workflow_object_store::Result<workflow_object_store::WorkflowObjectStore> {
    open_object_backed_store(
        application_support_root.as_ref(),
        quota,
        workflow_object_store::WorkflowObjectStoreError::UnsafePath,
        workflow_object_store::WorkflowObjectStore::open,
    )
}

/// Opens scoped workflow storage and its private content-addressed byte layer.
pub fn open_workflow_scoped_storage(
    application_support_root: impl AsRef<std::path::Path>,
    object_quota: workflow_object_store::WorkflowObjectStoreQuota,
) -> workflow_storage::Result<workflow_storage::WorkflowScopedStorage> {
    open_object_backed_store(
        application_support_root.as_ref(),
        object_quota,
        workflow_storage::WorkflowStorageError::UnsafePath,
        workflow_storage::WorkflowScopedStorage::open,
    )
}
