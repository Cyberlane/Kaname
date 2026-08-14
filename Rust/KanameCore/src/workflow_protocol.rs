use crate::{
    SCHEMA_MAJOR,
    v1::{
        CompileWorkflowRequest, ImportFrozenWorkspaceRequest, SetWorkflowActivationRequest,
        ValidateWorkflowRequest, WorkflowLibraryQueryRequest, WorkflowRunInspectionQuery,
    },
};
use prost::Message;

pub const MAXIMUM_WORKFLOW_CHECKER_REQUEST_BYTES: usize = 2 * 1024 * 1024;
pub const MAXIMUM_WORKFLOW_JSON_DOCUMENT_BYTES: usize = 512 * 1024;
pub const MAXIMUM_WORKFLOW_DIAGNOSTICS: u32 = 256;
const MAXIMUM_REQUEST_ID_BYTES: usize = 128;

#[derive(Debug, PartialEq, Eq)]
pub enum WorkflowProtocolError {
    RequestOutOfBounds,
    MalformedRequest,
    UnsupportedSchemaMajor,
    InvalidRequestId,
    DocumentOutOfBounds,
    DiagnosticLimitOutOfBounds,
    MissingOperation,
    InspectionLimitOutOfBounds,
}

pub fn decode_validate_request(
    wire: &[u8],
) -> Result<ValidateWorkflowRequest, WorkflowProtocolError> {
    let request: ValidateWorkflowRequest = decode_bounded(wire)?;
    validate_common(
        request.schema_version.as_ref().map(|version| version.major),
        &request.request_id,
        request.maximum_diagnostics,
    )?;
    validate_document(&request.schema_json)?;
    validate_document(&request.instance_json)?;
    Ok(request)
}

pub fn decode_compile_request(
    wire: &[u8],
) -> Result<CompileWorkflowRequest, WorkflowProtocolError> {
    let request: CompileWorkflowRequest = decode_bounded(wire)?;
    validate_common(
        request.schema_version.as_ref().map(|version| version.major),
        &request.request_id,
        request.maximum_diagnostics,
    )?;
    for document in [
        &request.manifest_json,
        &request.schema_bundle_json,
        &request.dependency_lock_json,
        &request.configuration_contract_json,
    ] {
        validate_document(document)?;
    }
    Ok(request)
}

pub fn decode_library_query_request(
    wire: &[u8],
) -> Result<WorkflowLibraryQueryRequest, WorkflowProtocolError> {
    let request: WorkflowLibraryQueryRequest = decode_enveloped(wire)?;
    if request.query.is_none() {
        return Err(WorkflowProtocolError::MissingOperation);
    }
    Ok(request)
}

pub fn decode_activation_request(
    wire: &[u8],
) -> Result<SetWorkflowActivationRequest, WorkflowProtocolError> {
    decode_enveloped(wire)
}

pub fn decode_frozen_workspace_import_request(
    wire: &[u8],
) -> Result<ImportFrozenWorkspaceRequest, WorkflowProtocolError> {
    decode_enveloped(wire)
}

pub fn decode_run_inspection_query(
    wire: &[u8],
) -> Result<WorkflowRunInspectionQuery, WorkflowProtocolError> {
    let request: WorkflowRunInspectionQuery = decode_enveloped(wire)?;
    if request.limit == 0 || request.limit > 100 {
        return Err(WorkflowProtocolError::InspectionLimitOutOfBounds);
    }
    if !request.run_id.is_empty() && request.run_id.len() > 128 {
        return Err(WorkflowProtocolError::RequestOutOfBounds);
    }
    if !request.workflow_id.is_empty() && request.workflow_id.len() > 128 {
        return Err(WorkflowProtocolError::RequestOutOfBounds);
    }
    Ok(request)
}

trait WorkflowEnvelope {
    fn schema_major(&self) -> Option<u32>;
    fn request_id(&self) -> &str;
}

macro_rules! workflow_envelope {
    ($message:ty) => {
        impl WorkflowEnvelope for $message {
            fn schema_major(&self) -> Option<u32> {
                self.schema_version.as_ref().map(|version| version.major)
            }

            fn request_id(&self) -> &str {
                &self.request_id
            }
        }
    };
}

workflow_envelope!(WorkflowLibraryQueryRequest);
workflow_envelope!(SetWorkflowActivationRequest);
workflow_envelope!(ImportFrozenWorkspaceRequest);
workflow_envelope!(WorkflowRunInspectionQuery);

fn decode_enveloped<M>(wire: &[u8]) -> Result<M, WorkflowProtocolError>
where
    M: Message + Default + WorkflowEnvelope,
{
    let request: M = decode_bounded(wire)?;
    validate_envelope(request.schema_major(), request.request_id())?;
    Ok(request)
}

fn decode_bounded<M>(wire: &[u8]) -> Result<M, WorkflowProtocolError>
where
    M: Message + Default,
{
    if wire.is_empty() || wire.len() > MAXIMUM_WORKFLOW_CHECKER_REQUEST_BYTES {
        return Err(WorkflowProtocolError::RequestOutOfBounds);
    }
    M::decode(wire).map_err(|_| WorkflowProtocolError::MalformedRequest)
}

fn validate_common(
    schema_major: Option<u32>,
    request_id: &str,
    maximum_diagnostics: u32,
) -> Result<(), WorkflowProtocolError> {
    validate_envelope(schema_major, request_id)?;
    if maximum_diagnostics == 0 || maximum_diagnostics > MAXIMUM_WORKFLOW_DIAGNOSTICS {
        return Err(WorkflowProtocolError::DiagnosticLimitOutOfBounds);
    }
    Ok(())
}

fn validate_envelope(
    schema_major: Option<u32>,
    request_id: &str,
) -> Result<(), WorkflowProtocolError> {
    if schema_major != Some(SCHEMA_MAJOR) {
        return Err(WorkflowProtocolError::UnsupportedSchemaMajor);
    }
    if request_id.is_empty()
        || request_id.len() > MAXIMUM_REQUEST_ID_BYTES
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(WorkflowProtocolError::InvalidRequestId);
    }
    Ok(())
}

fn validate_document(document: &[u8]) -> Result<(), WorkflowProtocolError> {
    if document.is_empty() || document.len() > MAXIMUM_WORKFLOW_JSON_DOCUMENT_BYTES {
        return Err(WorkflowProtocolError::DocumentOutOfBounds);
    }
    Ok(())
}
