use kaname_core::{
    v1::{
        CompileWorkflowRequest, FrozenWorkflowDraftImport, ImportFrozenWorkspaceRequest,
        SchemaVersion, SetWorkflowActivationRequest, ValidateWorkflowRequest,
        WorkflowLibraryQueryRequest, WorkflowPortfolioQuery, WorkflowRunInspectionQuery,
        workflow_library_query_request,
    },
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
fn library_queries_and_activation_decode_without_accepting_storage_paths() {
    let query = WorkflowLibraryQueryRequest {
        schema_version: version(),
        request_id: "library:portfolio-001".into(),
        query: Some(workflow_library_query_request::Query::Portfolio(
            WorkflowPortfolioQuery {
                alias_key: "active".into(),
            },
        )),
    };
    assert_eq!(
        workflow_protocol::decode_library_query_request(&query.encode_to_vec()).unwrap(),
        query
    );
    let activation = SetWorkflowActivationRequest {
        schema_version: version(),
        request_id: "library:activate-001".into(),
        alias_id: "primary-alias".into(),
        workflow_id: "workflow-one".into(),
        alias_key: "active".into(),
        revision_id: "revision-one".into(),
        expected_generation: 2,
        updated_at_unix_millis: 50,
    };
    assert_eq!(
        workflow_protocol::decode_activation_request(&activation.encode_to_vec()).unwrap(),
        activation
    );
    let frozen = ImportFrozenWorkspaceRequest {
        schema_version: version(),
        request_id: "library:import-001".into(),
        receipt_id: "workspace-receipt".into(),
        source_digest: "a".repeat(64),
        imported_at_unix_millis: 60,
        drafts: vec![FrozenWorkflowDraftImport {
            workflow_id: "workflow-one".into(),
            package_id: "dev.kaname.one".into(),
            name: "One".into(),
            summary: String::new(),
            workflow_json: b"{}".to_vec(),
            layout_json: b"{}".to_vec(),
            comparison_json: b"{}".to_vec(),
            blocked: true,
        }],
    };
    assert_eq!(
        workflow_protocol::decode_frozen_workspace_import_request(&frozen.encode_to_vec()).unwrap(),
        frozen
    );

    let mut missing = query;
    missing.query = None;
    assert_eq!(
        workflow_protocol::decode_library_query_request(&missing.encode_to_vec()),
        Err(WorkflowProtocolError::MissingOperation)
    );
}

#[test]
fn run_inspection_queries_are_bounded_and_path_free() {
    let query = WorkflowRunInspectionQuery {
        schema_version: version(),
        request_id: "runs:recent-001".into(),
        workflow_id: "workflow-one".into(),
        run_id: String::new(),
        limit: 30,
    };
    assert_eq!(
        workflow_protocol::decode_run_inspection_query(&query.encode_to_vec()).unwrap(),
        query
    );
    let mut invalid = query;
    invalid.limit = 101;
    assert_eq!(
        workflow_protocol::decode_run_inspection_query(&invalid.encode_to_vec()),
        Err(WorkflowProtocolError::InspectionLimitOutOfBounds)
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
