use jsonschema::{Draft, Registry};
use kaname_core::{
    v1::{CompileWorkflowRequest, SchemaVersion, WorkflowCheckOutcome},
    workflow_compiler,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

const NODE_ID: &str = "018f0000-0001-7000-8000-000000000001";

#[derive(Deserialize)]
struct RegistryManifest {
    #[serde(rename = "registryVersion")]
    registry_version: u64,
    #[serde(rename = "executionStatus")]
    execution_status: String,
    #[serde(rename = "nodeTypes")]
    node_types: Vec<NodeTypeRecord>,
}

#[derive(Deserialize)]
struct NodeTypeRecord {
    #[serde(rename = "type")]
    node_type: String,
    #[serde(rename = "typeVersion")]
    type_version: u64,
    executable: bool,
}

#[derive(Deserialize)]
struct CommonGolden {
    schema: String,
    valid: Value,
    invalid: Value,
}

fn schema_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Schema/Workflow/v1")
}

fn fixture_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Fixtures/workflow-v2")
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
                let value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
                output.insert(relative, value);
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
        let id = schema
            .get("$id")
            .and_then(Value::as_str)
            .expect("schema must have an id");
        registry = registry
            .add(id.to_owned(), schema.clone())
            .expect("schema id must be a URI");
    }
    registry
        .prepare()
        .expect("schema registry must resolve entirely offline")
}

fn is_valid(schema: &Value, instance: &Value, registry: &Registry<'_>) -> bool {
    jsonschema::options()
        .with_draft(Draft::Draft202012)
        .should_validate_formats(true)
        .should_ignore_unknown_formats(false)
        .with_registry(registry)
        .build(schema)
        .expect("registered schema must compile")
        .is_valid(instance)
}

fn node(node_type: &str, config: Value) -> Value {
    json!({
        "id": NODE_ID,
        "key": node_type.replace('.', "-"),
        "name": "Synthetic node",
        "type": node_type,
        "typeVersion": 1,
        "config": config
    })
}

#[test]
fn every_schema_is_draft_2020_12_valid_and_resolves_offline() {
    let documents = schema_documents();
    assert!(
        documents.len() == 54,
        "the registry unexpectedly lost schema contracts"
    );
    let mut ids = std::collections::BTreeSet::new();
    for (path, schema) in &documents {
        assert_eq!(
            schema["$schema"], "https://json-schema.org/draft/2020-12/schema",
            "{path}"
        );
        assert!(
            jsonschema::draft202012::meta::is_valid(schema),
            "invalid meta-schema: {path}"
        );
        assert!(
            ids.insert(schema["$id"].as_str().unwrap()),
            "duplicate id in {path}"
        );
    }
    let _ = prepared_registry(&documents);
}

#[test]
fn registry_manifest_and_helper_definitions_have_positive_and_negative_examples() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let manifest: Value =
        serde_json::from_slice(&fs::read(schema_root().join("registry.json")).unwrap()).unwrap();
    assert!(is_valid(
        &documents["registry.schema.json"],
        &manifest,
        &registry
    ));
    let mut invalid_manifest = manifest.as_object().unwrap().clone();
    invalid_manifest.insert("registryVersion".into(), json!(2));
    assert!(!is_valid(
        &documents["registry.schema.json"],
        &Value::Object(invalid_manifest),
        &registry
    ));

    let identifiers = &documents["identifiers.schema.json"];
    let examples = [
        ("uuidV7", json!(NODE_ID), json!("not-a-uuid")),
        ("key", json!("valid-key"), json!("Invalid key")),
        ("packageId", json!("dev.kaname.example"), json!("example")),
        ("schemaRef", json!("dev.kaname.schema/v1"), json!("")),
        (
            "sha256",
            json!("sha256:0000000000000000000000000000000000000000000000000000000000000000"),
            json!("sha256:00"),
        ),
        (
            "jsonPointer",
            json!("/valid/~0pointer"),
            json!("not-a-pointer"),
        ),
    ];
    for (name, valid, invalid) in examples {
        let schema = json!({"$ref": format!("https://schemas.kaname.dev/workflow/v1/identifiers.schema.json#/$defs/{name}")});
        assert!(is_valid(&schema, &valid, &registry), "valid {name}");
        assert!(!is_valid(&schema, &invalid, &registry), "invalid {name}");
    }
    assert!(
        identifiers["$defs"]
            .as_object()
            .is_some_and(|definitions| definitions.len() == 6)
    );
}

#[test]
fn every_registered_node_type_has_closed_valid_and_invalid_goldens() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let manifest: RegistryManifest =
        serde_json::from_slice(&fs::read(schema_root().join("registry.json")).unwrap()).unwrap();
    assert_eq!(manifest.registry_version, 1);
    assert_eq!(manifest.execution_status, "schema-only");
    let goldens: BTreeMap<String, Value> = serde_json::from_slice(
        &fs::read(fixture_root().join("schema-v1-node-goldens.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        manifest
            .node_types
            .iter()
            .map(|record| record.node_type.clone())
            .collect::<std::collections::BTreeSet<_>>(),
        goldens
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>()
    );
    let union = &documents["node.schema.json"];
    for record in &manifest.node_types {
        assert_eq!(record.type_version, 1);
        assert!(!record.executable);
        let node_type = &record.node_type;
        let valid = node(node_type, goldens[node_type].clone());
        let individual_path = format!("nodes/{node_type}.schema.json");
        assert!(
            is_valid(&documents[&individual_path], &valid, &registry),
            "{node_type}"
        );
        assert!(
            is_valid(union, &valid, &registry),
            "union rejected {node_type}"
        );

        let mut invalid = valid.as_object().unwrap().clone();
        invalid.insert("unexpected".into(), Value::Bool(true));
        assert!(!is_valid(
            &documents[&individual_path],
            &Value::Object(invalid),
            &registry
        ));
    }
    let mut wrong_version = node("trigger.manual", json!({}));
    wrong_version["typeVersion"] = json!(2);
    assert!(!is_valid(union, &wrong_version, &registry));
    assert!(!is_valid(
        union,
        &node("unknown.node", json!({})),
        &registry
    ));
}

#[test]
fn every_common_contract_has_a_passing_and_rejected_golden() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let goldens: Vec<CommonGolden> = serde_json::from_slice(
        &fs::read(fixture_root().join("schema-v1-common-goldens.json")).unwrap(),
    )
    .unwrap();
    for golden in goldens {
        let schema = documents
            .get(&golden.schema)
            .unwrap_or_else(|| panic!("missing {}", golden.schema));
        assert!(
            is_valid(schema, &golden.valid, &registry),
            "valid {}",
            golden.schema
        );
        assert!(
            !is_valid(schema, &golden.invalid, &registry),
            "invalid {}",
            golden.schema
        );
    }
}

#[test]
fn workflow_graph_and_node_envelope_are_closed_at_their_boundaries() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let manual = node("trigger.manual", json!({}));
    let graph = json!({
        "entrypoints": [{
            "id": "018f0000-0004-7000-8000-000000000004",
            "nodeId": NODE_ID
        }],
        "nodes": [manual.clone()],
        "edges": []
    });
    let workflow = json!({
        "formatVersion": 1,
        "workflowId": "018f0000-0002-7000-8000-000000000002",
        "packageId": "dev.kaname.synthetic",
        "name": "Synthetic workflow",
        "summary": "Schema qualification only.",
        "graph": graph.clone(),
        "interfaces": {},
        "resources": {},
        "policies": {},
        "storage": {},
        "metadata": {}
    });
    assert!(is_valid(
        &documents["node-envelope.schema.json"],
        &manual,
        &registry
    ));
    let mut invalid_node = manual.as_object().unwrap().clone();
    invalid_node.remove("id");
    assert!(!is_valid(
        &documents["node-envelope.schema.json"],
        &Value::Object(invalid_node),
        &registry
    ));
    assert!(is_valid(&documents["graph.schema.json"], &graph, &registry));
    assert!(is_valid(
        &documents["workflow.schema.json"],
        &workflow,
        &registry
    ));

    let mut invalid_workflow = workflow.as_object().unwrap().clone();
    invalid_workflow.insert("accountId".into(), json!("forbidden-portable-authority"));
    assert!(!is_valid(
        &documents["workflow.schema.json"],
        &Value::Object(invalid_workflow),
        &registry
    ));
    let effect_config: Value = serde_json::from_slice(
        &fs::read(fixture_root().join("schema-v1-node-goldens.json")).unwrap(),
    )
    .unwrap();
    let mut effect = node(
        "effect.connector",
        effect_config["effect.connector"].clone(),
    );
    effect["config"]["authorityGrant"] = json!({
        "accountId": "forbidden-portable-account",
        "expiresAt": 5000
    });
    assert!(
        !is_valid(&documents["node.schema.json"], &effect, &registry),
        "portable effect nodes must not embed live authority grants"
    );
    let invalid_graph =
        json!({"entrypoints": [], "nodes": [manual], "edges": [], "implicitGlobals": {}});
    assert!(!is_valid(
        &documents["graph.schema.json"],
        &invalid_graph,
        &registry
    ));
}

#[test]
fn compiler_output_validates_against_the_published_compiled_contract() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let goldens: Vec<CommonGolden> = serde_json::from_slice(
        &fs::read(fixture_root().join("schema-v1-common-goldens.json")).unwrap(),
    )
    .unwrap();
    let compilation_manifest = goldens
        .iter()
        .find(|golden| golden.schema == "compile-manifest.schema.json")
        .unwrap();
    let dependency_lock = goldens
        .iter()
        .find(|golden| golden.schema == "dependency-lock.schema.json")
        .unwrap();
    let response = workflow_compiler::compile(&CompileWorkflowRequest {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        request_id: "compile:schema-contract".into(),
        manifest_json: serde_json::to_vec(&compilation_manifest.valid).unwrap(),
        schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
        dependency_lock_json: serde_json::to_vec(&dependency_lock.valid).unwrap(),
        configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
        maximum_diagnostics: 64,
    });
    assert_eq!(response.outcome, WorkflowCheckOutcome::Valid as i32);
    let artifact: Value = serde_json::from_slice(&response.compiled_artifact).unwrap();
    assert!(is_valid(
        &documents["compiled.schema.json"],
        &artifact,
        &registry
    ));
}

#[test]
fn lossless_legacy_import_golden_validates_as_a_v1_workflow() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let imported: Value = serde_json::from_slice(
        &fs::read(fixture_root().join("legacy-import-terminal-v1.json")).unwrap(),
    )
    .unwrap();

    assert!(is_valid(
        &documents["workflow.schema.json"],
        &imported,
        &registry
    ));
}

#[test]
fn committed_match_evaluation_traces_validate_against_the_published_contract() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let corpus: Value =
        serde_json::from_slice(&fs::read(fixture_root().join("match-evaluator-v1.json")).unwrap())
            .unwrap();
    let goldens = corpus["goldens"].as_array().unwrap();
    assert_eq!(goldens.len(), 4);
    for golden in goldens {
        assert!(
            is_valid(
                &documents["match-evaluation.schema.json"],
                &golden["expected"],
                &registry
            ),
            "{}",
            golden["id"]
        );
    }
}

#[test]
fn match_all_and_exactly_one_array_conditions_are_closed_schema_contracts() {
    let documents = schema_documents();
    let registry = prepared_registry(&documents);
    let match_node = node(
        "control.match",
        json!({
            "value": {"root": "input", "pointer": ""},
            "hitPolicy": "all",
            "cases": [{
                "id": "018f0000-0002-7000-8000-000000000002",
                "key": "one-review",
                "label": "Exactly one review",
                "when": {
                    "arrayExactlyOne": {
                        "value": {"root": "value", "pointer": "/labels"},
                        "as": "item",
                        "where": {
                            "compare": {
                                "left": {"root": "item", "pointer": ""},
                                "operator": "equal",
                                "right": {"literal": {"type": "string", "value": "review"}}
                            }
                        }
                    }
                }
            }]
        }),
    );
    assert!(is_valid(
        &documents["nodes/control.match.schema.json"],
        &match_node,
        &registry
    ));
    let mut invalid = match_node;
    invalid["config"]["hitPolicy"] = json!("some");
    assert!(!is_valid(
        &documents["nodes/control.match.schema.json"],
        &invalid,
        &registry
    ));
}
