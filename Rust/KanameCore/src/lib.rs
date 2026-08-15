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
pub mod workflow_drafts;
pub mod workflow_executor;
pub mod workflow_import;
pub mod workflow_library;
pub mod workflow_llm;
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
    let root = application_support_root.as_ref();
    if root.as_os_str().is_empty() || root.file_name().is_none() {
        return Err(workflow_library::WorkflowLibraryError::UnsafePath(
            "application_support_root_invalid",
        ));
    }
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
    let root = application_support_root.as_ref();
    if root.as_os_str().is_empty() || root.file_name().is_none() {
        return Err(workflow_object_store::WorkflowObjectStoreError::UnsafePath(
            "application_support_root_invalid",
        ));
    }
    workflow_object_store::WorkflowObjectStore::open(root.join("Objects"), quota)
}

/// Opens scoped workflow storage and its private content-addressed byte layer.
pub fn open_workflow_scoped_storage(
    application_support_root: impl AsRef<std::path::Path>,
    object_quota: workflow_object_store::WorkflowObjectStoreQuota,
) -> workflow_storage::Result<workflow_storage::WorkflowScopedStorage> {
    let root = application_support_root.as_ref();
    if root.as_os_str().is_empty() || root.file_name().is_none() {
        return Err(workflow_storage::WorkflowStorageError::UnsafePath(
            "application_support_root_invalid",
        ));
    }
    workflow_storage::WorkflowScopedStorage::open(root.join("Objects"), object_quota)
}
