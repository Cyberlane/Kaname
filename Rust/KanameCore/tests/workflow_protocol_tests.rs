use kaname_core::{
    v1::{CompileWorkflowRequest, SchemaVersion, ValidateWorkflowRequest},
    workflow_protocol::{self, WorkflowProtocolError},
};
use prost::Message;

fn version() -> Option<SchemaVersion> {
    Some(SchemaVersion { major: 1, minor: 0 })
}

fn validate_request() -> ValidateWorkflowRequest {
    ValidateWorkflowRequest {
        schema_version: version(),
        request_id: "validate:synthetic-001".into(),
        schema_json: br#"{"type":"object"}"#.to_vec(),
        instance_json: br#"{"name":"Synthetic"}"#.to_vec(),
        maximum_diagnostics: 64,
    }
}

fn compile_request() -> CompileWorkflowRequest {
    CompileWorkflowRequest {
        schema_version: version(),
        request_id: "compile:synthetic-001".into(),
        manifest_json: br#"{"formatVersion":1}"#.to_vec(),
        schema_bundle_json: br#"{"schemas":[]}"#.to_vec(),
        dependency_lock_json: br#"{"dependencies":{}}"#.to_vec(),
        configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
        maximum_diagnostics: 64,
    }
}

#[test]
fn validate_and_compile_requests_decode_with_explicit_bounds() {
    let validate = validate_request();
    assert_eq!(
        workflow_protocol::decode_validate_request(&validate.encode_to_vec()).unwrap(),
        validate
    );
    let compile = compile_request();
    assert_eq!(
        workflow_protocol::decode_compile_request(&compile.encode_to_vec()).unwrap(),
        compile
    );
}

#[test]
fn malformed_oversized_and_semantically_invalid_requests_fail_closed() {
    assert_eq!(
        workflow_protocol::decode_validate_request(&[]),
        Err(WorkflowProtocolError::RequestOutOfBounds)
    );
    assert_eq!(
        workflow_protocol::decode_validate_request(&[0x0a]),
        Err(WorkflowProtocolError::MalformedRequest)
    );
    let oversized = vec![0; workflow_protocol::MAXIMUM_WORKFLOW_CHECKER_REQUEST_BYTES + 1];
    assert_eq!(
        workflow_protocol::decode_validate_request(&oversized),
        Err(WorkflowProtocolError::RequestOutOfBounds)
    );
    let mut request = validate_request();
    request.schema_version.as_mut().unwrap().major = 2;
    assert_eq!(
        workflow_protocol::decode_validate_request(&request.encode_to_vec()),
        Err(WorkflowProtocolError::UnsupportedSchemaMajor)
    );
    request = validate_request();
    request.request_id = "contains private whitespace".into();
    assert_eq!(
        workflow_protocol::decode_validate_request(&request.encode_to_vec()),
        Err(WorkflowProtocolError::InvalidRequestId)
    );
    request = validate_request();
    request.maximum_diagnostics = 257;
    assert_eq!(
        workflow_protocol::decode_validate_request(&request.encode_to_vec()),
        Err(WorkflowProtocolError::DiagnosticLimitOutOfBounds)
    );
    request = validate_request();
    request.instance_json = vec![b' '; workflow_protocol::MAXIMUM_WORKFLOW_JSON_DOCUMENT_BYTES + 1];
    assert_eq!(
        workflow_protocol::decode_validate_request(&request.encode_to_vec()),
        Err(WorkflowProtocolError::DocumentOutOfBounds)
    );
}

#[test]
fn a_future_unknown_field_is_ignored_without_broadening_authority() {
    let mut wire = compile_request().encode_to_vec();
    wire.extend_from_slice(&[0xa0, 0x06, 0x01]);
    let decoded = workflow_protocol::decode_compile_request(&wire).unwrap();
    assert_eq!(decoded.request_id, "compile:synthetic-001");
    assert_eq!(decoded.maximum_diagnostics, 64);
}
