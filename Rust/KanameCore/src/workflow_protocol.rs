use crate::{
    SCHEMA_MAJOR,
    v1::{CompileWorkflowRequest, ValidateWorkflowRequest},
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
    if maximum_diagnostics == 0 || maximum_diagnostics > MAXIMUM_WORKFLOW_DIAGNOSTICS {
        return Err(WorkflowProtocolError::DiagnosticLimitOutOfBounds);
    }
    Ok(())
}

fn validate_document(document: &[u8]) -> Result<(), WorkflowProtocolError> {
    if document.is_empty() || document.len() > MAXIMUM_WORKFLOW_JSON_DOCUMENT_BYTES {
        return Err(WorkflowProtocolError::DocumentOutOfBounds);
    }
    Ok(())
}
