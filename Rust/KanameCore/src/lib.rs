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
pub mod workflow_canonical;
pub mod workflow_compiler;
pub mod workflow_drafts;
pub mod workflow_library;
pub mod workflow_match;
pub mod workflow_protocol;
pub mod workflow_publication;
pub mod workflow_schema;
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
