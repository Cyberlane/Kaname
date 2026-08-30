use jsonschema::{Draft, Registry};
use kaname_core::{
    v1::{CompileWorkflowRequest, SchemaVersion, WorkflowCheckOutcome},
    workflow_compiler, workflow_executor,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExecutabilityCrosswalk {
    fixture_version: u32,
    privacy_class: String,
    executor_edge_downgrade_code: String,
    node_types: Vec<NodeCrosswalk>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NodeCrosswalk {
    #[serde(rename = "type")]
    node_type: String,
    type_version: u32,
    executor_admitted: bool,
    builder_availability: String,
    executable_config: Value,
    downgrade_cases: Vec<DowngradeCase>,
}

#[derive(Deserialize)]
struct DowngradeCase {
    condition: String,
    config: Value,
}

fn crosswalk() -> ExecutabilityCrosswalk {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Fixtures/workflow-v2/executability-crosswalk.json");
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn schema_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Schema/Workflow/v1")
}

fn schema_documents() -> BTreeMap<String, Value> {
    fn visit(directory: &Path, root: &Path, output: &mut BTreeMap<String, Value>) {
        let mut entries = fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        entries.sort();
        for path in entries {
            if path.is_dir() {
                visit(&path, root, output);
            } else if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".schema.json"))
            {
                let relative = path
                    .strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .to_string();
                output.insert(
                    relative,
                    serde_json::from_slice(&fs::read(path).unwrap()).unwrap(),
                );
            }
        }
    }
    let root = schema_root();
    let mut output = BTreeMap::new();
    visit(&root, &root, &mut output);
    output
}

fn prepared_registry(documents: &BTreeMap<String, Value>) -> Registry<'static> {
    let mut registry = Registry::new();
    for schema in documents.values() {
        let id = schema.get("$id").and_then(Value::as_str).unwrap();
        registry = registry.add(id.to_owned(), schema.clone()).unwrap();
    }
    registry.prepare().unwrap()
}

fn node_envelope(node: &NodeCrosswalk, config: Value) -> Value {
    json!({
        "id": "018f7000-0001-7000-8000-000000000001",
        "key": node.node_type.replace('.', "-"),
        "name": "Crosswalk fixture",
        "type": node.node_type,
        "typeVersion": node.type_version,
        "config": config
    })
}

fn compiler_request(fail_config: Value) -> CompileWorkflowRequest {
    let workflow = json!({
        "formatVersion": 1,
        "workflowId": "018f7100-0001-7000-8000-000000000001",
        "packageId": "dev.kaname.executability-crosswalk",
        "name": "Executability crosswalk",
        "summary": "Synthetic compiler and executor admission proof.",
        "graph": {
            "entrypoints": [{
                "id": "018f7100-0002-7000-8000-000000000002",
                "nodeId": "018f7100-0003-7000-8000-000000000003"
            }],
            "nodes": [
                {
                    "id": "018f7100-0003-7000-8000-000000000003",
                    "key": "start",
                    "name": "Start",
                    "type": "trigger.manual",
                    "typeVersion": 1,
                    "config": {}
                },
                {
                    "id": "018f7100-0004-7000-8000-000000000004",
                    "key": "validate",
                    "name": "Validate",
                    "type": "data.validate",
                    "typeVersion": 1,
                    "config": {"schemaRef":"dev.kaname.schema/input/v1"}
                },
                {
                    "id": "018f7100-0005-7000-8000-000000000005",
                    "key": "complete",
                    "name": "Complete",
                    "type": "terminal.complete",
                    "typeVersion": 1,
                    "config": {}
                },
                {
                    "id": "018f7100-0006-7000-8000-000000000006",
                    "key": "fail",
                    "name": "Fail",
                    "type": "terminal.fail",
                    "typeVersion": 1,
                    "config": fail_config
                }
            ],
            "edges": [
                {
                    "id": "018f7100-0007-7000-8000-000000000007",
                    "from": {"nodeId":"018f7100-0003-7000-8000-000000000003","portId":"success"},
                    "to": {"nodeId":"018f7100-0004-7000-8000-000000000004","portId":"input"},
                    "mappingId": "018f7100-0010-7000-8000-000000000010",
                    "mapping": {"whole":true}
                },
                {
                    "id": "018f7100-0008-7000-8000-000000000008",
                    "from": {"nodeId":"018f7100-0004-7000-8000-000000000004","portId":"success"},
                    "to": {"nodeId":"018f7100-0005-7000-8000-000000000005","portId":"input"},
                    "mappingId": "018f7100-0011-7000-8000-000000000011",
                    "mapping": {"whole":true}
                },
                {
                    "id": "018f7100-0009-7000-8000-000000000009",
                    "from": {"nodeId":"018f7100-0004-7000-8000-000000000004","portId":"error"},
                    "to": {"nodeId":"018f7100-0006-7000-8000-000000000006","portId":"input"},
                    "mappingId": "018f7100-0012-7000-8000-000000000012",
                    "mapping": {"whole":true}
                }
            ]
        },
        "interfaces": {},
        "resources": {},
        "policies": {},
        "storage": {},
        "metadata": {}
    });
    CompileWorkflowRequest {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        request_id: "compile:executability-crosswalk".into(),
        manifest_json: serde_json::to_vec(&json!({
            "compileManifestVersion": 1,
            "workflow": workflow,
            "layout": {"nodes": []}
        }))
        .unwrap(),
        schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
        dependency_lock_json: br#"{"lockVersion":1,"dependencies":[]}"#.to_vec(),
        configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
        maximum_diagnostics: 256,
    }
}

#[test]
fn executability_crosswalk_matches_executor_and_compiler_contracts() {
    let crosswalk = crosswalk();
    let schema_documents = schema_documents();
    let schema_registry = prepared_registry(&schema_documents);
    assert_eq!(crosswalk.fixture_version, 1);
    assert_eq!(crosswalk.privacy_class, "synthetic-public");
    assert_eq!(
        crosswalk.executor_edge_downgrade_code,
        workflow_executor::EDGE_MAPPING_NOT_EXECUTABLE_CODE
    );

    let fixture_types = crosswalk
        .node_types
        .iter()
        .map(|node| node.node_type.as_str())
        .collect::<BTreeSet<_>>();
    let executor_types = workflow_executor::EXECUTOR_ADMITTED_NODE_TYPES
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    assert_eq!(fixture_types, executor_types);
    assert_eq!(fixture_types.len(), crosswalk.node_types.len());
    assert_eq!(
        executor_types.len(),
        workflow_executor::EXECUTOR_ADMITTED_NODE_TYPES.len()
    );

    for node in &crosswalk.node_types {
        assert_eq!(node.type_version, 1, "{}", node.node_type);
        assert!(node.executor_admitted, "{}", node.node_type);
        assert_eq!(
            node.builder_availability, "schema-only",
            "{}",
            node.node_type
        );
        let schema_path = format!("nodes/{}.schema.json", node.node_type);
        let validator = jsonschema::options()
            .with_draft(Draft::Draft202012)
            .should_validate_formats(true)
            .should_ignore_unknown_formats(false)
            .with_registry(&schema_registry)
            .build(&schema_documents[&schema_path])
            .unwrap();
        assert!(
            validator.is_valid(&node_envelope(node, node.executable_config.clone())),
            "schema rejected executable config for {}",
            node.node_type
        );

        let executable = workflow_compiler::node_execution_availability(
            &node.node_type,
            &node.executable_config,
        );
        assert_eq!(executable.availability, "executable", "{}", node.node_type);
        assert_eq!(executable.downgrade_condition, None, "{}", node.node_type);

        for downgrade in &node.downgrade_cases {
            let availability =
                workflow_compiler::node_execution_availability(&node.node_type, &downgrade.config);
            assert_eq!(
                availability.availability, "schema-only",
                "{}:{}",
                node.node_type, downgrade.condition
            );
            assert_eq!(
                availability.downgrade_condition,
                Some(downgrade.condition.as_str()),
                "{}",
                node.node_type
            );
        }
    }

    let unknown = workflow_compiler::node_execution_availability("unknown.node", &Value::Null);
    assert_eq!(unknown.availability, "schema-only");
    assert_eq!(
        unknown.downgrade_condition,
        Some("node_type_not_executable")
    );

    let terminal_fail = crosswalk
        .node_types
        .iter()
        .find(|node| node.node_type == "terminal.fail")
        .unwrap();
    let compiled =
        workflow_compiler::compile(&compiler_request(terminal_fail.executable_config.clone()));
    assert_eq!(compiled.outcome, WorkflowCheckOutcome::Valid as i32);
    assert!(compiled.diagnostics.is_empty());
    let artifact: Value = serde_json::from_slice(&compiled.compiled_artifact).unwrap();
    let fail = artifact["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["type"] == "terminal.fail")
        .unwrap();
    assert_eq!(fail["executionAvailability"], "executable");
    workflow_executor::validate_compiled_source_node_admission(&compiled.compiled_artifact)
        .unwrap();

    let downgraded = workflow_compiler::compile(&compiler_request(json!({})));
    assert_eq!(downgraded.outcome, WorkflowCheckOutcome::Valid as i32);
    let error =
        workflow_executor::validate_compiled_source_node_admission(&downgraded.compiled_artifact)
            .unwrap_err();
    assert!(matches!(
        error,
        workflow_executor::WorkflowExecutionError::Unsupported(code)
            if code == "node:terminal.fail"
    ));
}
