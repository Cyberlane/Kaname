use kaname_core::{
    v1::{CompileWorkflowRequest, SchemaVersion, WorkflowCheckOutcome},
    workflow_compiler,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{fs, path::Path};

const WORKFLOW_ID: &str = "018f1000-0001-7000-8000-000000000001";
const ENTRY_ID: &str = "018f1000-0002-7000-8000-000000000002";
const START_ID: &str = "018f1000-0003-7000-8000-000000000003";
const END_ID: &str = "018f1000-0004-7000-8000-000000000004";
const EDGE_ID: &str = "018f1000-0005-7000-8000-000000000005";
const MAPPING_ID: &str = "018f1000-0006-7000-8000-000000000006";
const EXTRA_ID: &str = "018f1000-0007-7000-8000-000000000007";
const EXTRA_EDGE_ID: &str = "018f1000-0008-7000-8000-000000000008";
const EXTRA_MAPPING_ID: &str = "018f1000-0009-7000-8000-000000000009";
const FAIL_ID: &str = "018f1000-0010-7000-8000-000000000010";
const FAIL_EDGE_ID: &str = "018f1000-0011-7000-8000-000000000011";
const FAIL_MAPPING_ID: &str = "018f1000-0012-7000-8000-000000000012";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CompilerInvariantCorpus {
    fixture_version: u32,
    privacy_class: String,
    invalid_expectations: Vec<InvalidExpectation>,
    required_invariant_codes: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InvalidExpectation {
    scenario_id: String,
    code: String,
    source_id: String,
    json_pointer: String,
}

fn node(id: &str, key: &str, node_type: &str, config: Value) -> Value {
    json!({
        "id": id,
        "key": key,
        "name": key,
        "type": node_type,
        "typeVersion": 1,
        "config": config
    })
}

fn edge(id: &str, mapping_id: &str, from: (&str, &str), to: (&str, &str)) -> Value {
    json!({
        "id": id,
        "from": {"nodeId": from.0, "portId": from.1},
        "to": {"nodeId": to.0, "portId": to.1},
        "mappingId": mapping_id,
        "mapping": {"whole": true}
    })
}

fn valid_workflow() -> Value {
    json!({
        "formatVersion": 1,
        "workflowId": WORKFLOW_ID,
        "packageId": "dev.kaname.compiler-fixture",
        "name": "Compiler fixture",
        "summary": "Synthetic and effect free.",
        "graph": {
            "entrypoints": [{"id": ENTRY_ID, "nodeId": START_ID}],
            "nodes": [
                node(START_ID, "start", "trigger.manual", json!({})),
                node(END_ID, "complete", "terminal.complete", json!({}))
            ],
            "edges": [edge(EDGE_ID, MAPPING_ID, (START_ID, "success"), (END_ID, "input"))]
        },
        "interfaces": {},
        "resources": {},
        "policies": {},
        "storage": {},
        "metadata": {}
    })
}

fn request(workflow: Value, dependencies: Value) -> CompileWorkflowRequest {
    CompileWorkflowRequest {
        schema_version: Some(SchemaVersion { major: 1, minor: 0 }),
        request_id: "compile:fixture".into(),
        manifest_json: serde_json::to_vec(&json!({
            "compileManifestVersion": 1,
            "workflow": workflow,
            "layout": {"nodes": []}
        }))
        .unwrap(),
        schema_bundle_json: br#"{"bundleVersion":1,"schemas":[]}"#.to_vec(),
        dependency_lock_json: serde_json::to_vec(&dependencies).unwrap(),
        configuration_contract_json: br#"{"type":"object"}"#.to_vec(),
        maximum_diagnostics: 256,
    }
}

fn empty_lock() -> Value {
    json!({"lockVersion": 1, "dependencies": []})
}

fn diagnostic_pairs(response: &kaname_core::v1::CompileWorkflowResponse) -> Vec<(&str, &str)> {
    response
        .diagnostics
        .iter()
        .map(|diagnostic| {
            (
                diagnostic.code.as_str(),
                diagnostic.instance_pointer.as_str(),
            )
        })
        .collect()
}

fn invariant_corpus() -> CompilerInvariantCorpus {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Fixtures/workflow-v2/compiler-invariants.json");
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[test]
fn valid_graph_compiles_to_deterministic_canonical_artifact_and_digests() {
    let workflow = valid_workflow();
    let first = workflow_compiler::compile(&request(workflow.clone(), empty_lock()));
    assert_eq!(first.outcome, WorkflowCheckOutcome::Valid as i32);
    assert!(first.diagnostics.is_empty());
    assert!(!first.compiled_artifact.is_empty());
    let artifact: Value = serde_json::from_slice(&first.compiled_artifact).unwrap();
    assert_eq!(artifact["workflowId"], WORKFLOW_ID);
    assert_eq!(artifact["nodes"].as_array().unwrap().len(), 2);
    assert!(artifact["nodes"][0]["ports"].is_array());
    let digests = first.digests.as_ref().unwrap();
    for digest in [
        &digests.definition_digest,
        &digests.layout_digest,
        &digests.schema_bundle_digest,
        &digests.dependency_lock_digest,
        &digests.configuration_contract_digest,
        &digests.compiled_artifact_digest,
    ] {
        assert!(digest.starts_with("sha256:"));
        assert_eq!(digest.len(), 71);
    }

    let mut reordered = workflow;
    reordered["graph"]["nodes"]
        .as_array_mut()
        .unwrap()
        .reverse();
    let second = workflow_compiler::compile(&request(reordered, empty_lock()));
    assert_eq!(first.compiled_artifact, second.compiled_artifact);
    assert_eq!(first.digests, second.digests);
}

#[test]
fn malformed_unknown_and_non_i_json_inputs_fail_closed_without_an_artifact() {
    let mut unknown = valid_workflow();
    unknown["graph"]["nodes"][0]["undeclared"] = json!(true);
    let unknown_result = workflow_compiler::compile(&request(unknown, empty_lock()));
    assert_eq!(unknown_result.outcome, WorkflowCheckOutcome::Invalid as i32);
    assert_eq!(unknown_result.diagnostics[0].code, "document.malformed");
    assert!(unknown_result.compiled_artifact.is_empty());

    let mut unsafe_integer = valid_workflow();
    unsafe_integer["metadata"]["unsafe"] = json!(9_007_199_254_740_992_u64);
    let unsafe_result = workflow_compiler::compile(&request(unsafe_integer, empty_lock()));
    assert_eq!(unsafe_result.outcome, WorkflowCheckOutcome::Invalid as i32);
    assert_eq!(
        unsafe_result.diagnostics[0].code,
        "compiled.artifact.encoding-failed"
    );
    assert!(unsafe_result.compiled_artifact.is_empty());
}

#[test]
fn wfp000_invalid_fixtures_produce_exact_codes_and_locations() {
    let mut missing_entrypoint = valid_workflow();
    missing_entrypoint["graph"]["entrypoints"][0]["nodeId"] = json!(EXTRA_ID);

    let mut unreachable = valid_workflow();
    unreachable["graph"]["nodes"]
        .as_array_mut()
        .unwrap()
        .push(node(EXTRA_ID, "orphan", "terminal.cancel", json!({})));

    let mut incompatible = valid_workflow();
    incompatible["graph"]["nodes"][1] = node(END_ID, "retry", "control.retry", json!({}));
    incompatible["graph"]["edges"][0]["to"]["portId"] = json!("error");

    let mut cycle = valid_workflow();
    cycle["graph"]["nodes"] = json!([
        node(START_ID, "a", "data.map", json!({})),
        node(END_ID, "b", "data.map", json!({}))
    ]);
    cycle["graph"]["edges"] = json!([
        edge(
            EDGE_ID,
            MAPPING_ID,
            (START_ID, "success"),
            (END_ID, "input")
        ),
        edge(
            EXTRA_EDGE_ID,
            EXTRA_MAPPING_ID,
            (END_ID, "success"),
            (START_ID, "input")
        )
    ]);

    let mut undeclared_effect = valid_workflow();
    undeclared_effect["graph"]["nodes"] = json!([node(
        START_ID,
        "effect",
        "effect.connector",
        json!({"connectorClass":"dev.kaname.synthetic"})
    )]);
    undeclared_effect["graph"]["edges"] = json!([]);
    let connector_lock = json!({
        "lockVersion": 1,
        "dependencies": [{
            "kind": "connector",
            "id": "dev.kaname.synthetic",
            "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        }]
    });

    let cases = [
        ("W2-021", missing_entrypoint, empty_lock()),
        ("W2-022", unreachable, empty_lock()),
        ("W2-023", incompatible, empty_lock()),
        ("W2-024", cycle, empty_lock()),
        ("W2-025", undeclared_effect, connector_lock),
    ];
    let corpus = invariant_corpus();
    assert_eq!(corpus.fixture_version, 1);
    assert_eq!(corpus.privacy_class, "synthetic-public");
    assert_eq!(corpus.invalid_expectations.len(), cases.len());
    for (scenario_id, workflow, dependencies) in cases {
        let expectation = corpus
            .invalid_expectations
            .iter()
            .find(|expectation| expectation.scenario_id == scenario_id)
            .unwrap();
        let response = workflow_compiler::compile(&request(workflow, dependencies));
        assert_eq!(response.outcome, WorkflowCheckOutcome::Invalid as i32);
        let diagnostic = response
            .diagnostics
            .iter()
            .find(|diagnostic| {
                diagnostic.code == expectation.code
                    && diagnostic.instance_pointer == expectation.json_pointer
            })
            .unwrap_or_else(|| {
                panic!(
                    "missing {} at {}: {:?}",
                    expectation.code,
                    expectation.json_pointer,
                    diagnostic_pairs(&response)
                )
            });
        assert_eq!(
            diagnostic.location.as_ref().unwrap().source_id,
            expectation.source_id
        );
        assert!(response.compiled_artifact.is_empty());
    }
}

#[test]
fn compiler_checks_storage_dependencies_joins_fanout_and_bounded_cycles() {
    let required_codes = invariant_corpus()
        .required_invariant_codes
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
    for code in [
        "dependency.node.unresolved",
        "graph.cycle.unbounded",
        "graph.entrypoint.missing",
        "graph.input.required-missing",
        "graph.join.inputs-insufficient",
        "graph.node.unreachable",
        "graph.output.fanout",
        "graph.output.required-missing",
        "graph.terminal.missing",
        "mapping.type.incompatible",
        "storage.declaration.missing",
        "storage.promotion.invalid",
        "effect.authority.undeclared",
    ] {
        assert!(required_codes.contains(code));
    }
    let mut storage = valid_workflow();
    storage["graph"]["nodes"].as_array_mut().unwrap().insert(
        1,
        node(
            EXTRA_ID,
            "write",
            "storage.write",
            json!({"scope":"job","key":"scratch"}),
        ),
    );
    storage["graph"]["edges"] = json!([
        edge(
            EDGE_ID,
            MAPPING_ID,
            (START_ID, "success"),
            (EXTRA_ID, "input")
        ),
        edge(
            EXTRA_EDGE_ID,
            EXTRA_MAPPING_ID,
            (EXTRA_ID, "success"),
            (END_ID, "input")
        )
    ]);
    let storage_result = workflow_compiler::compile(&request(storage, empty_lock()));
    assert!(
        diagnostic_pairs(&storage_result)
            .contains(&("storage.declaration.missing", "/graph/nodes/1/config/key"))
    );

    let mut dependency = valid_workflow();
    dependency["graph"]["nodes"][0] = node(
        START_ID,
        "capability",
        "compute.capability",
        json!({"capabilityId":"dev.kaname.synthetic","version":"1.2.3"}),
    );
    let dependency_result = workflow_compiler::compile(&request(dependency, empty_lock()));
    assert!(
        diagnostic_pairs(&dependency_result)
            .contains(&("dependency.node.unresolved", "/graph/nodes/0/config"))
    );

    let mut fanout = valid_workflow();
    fanout["graph"]["nodes"].as_array_mut().unwrap().push(node(
        EXTRA_ID,
        "cancel",
        "terminal.cancel",
        json!({}),
    ));
    fanout["graph"]["edges"].as_array_mut().unwrap().push(edge(
        EXTRA_EDGE_ID,
        EXTRA_MAPPING_ID,
        (START_ID, "success"),
        (EXTRA_ID, "input"),
    ));
    let fanout_result = workflow_compiler::compile(&request(fanout, empty_lock()));
    assert!(diagnostic_pairs(&fanout_result).contains(&("graph.output.fanout", "/graph/nodes/0")));

    let mut join = valid_workflow();
    join["graph"]["nodes"][0] = node(
        START_ID,
        "join",
        "control.join",
        json!({"policy":"all","cancelRemaining":false}),
    );
    join["graph"]["edges"][0]["from"]["portId"] = json!("success");
    let join_result = workflow_compiler::compile(&request(join, empty_lock()));
    assert!(
        diagnostic_pairs(&join_result)
            .contains(&("graph.join.inputs-insufficient", "/graph/nodes/0"))
    );

    let bounded = bounded_retry_workflow();
    let lock = json!({
        "lockVersion": 1,
        "dependencies": [{
            "kind": "connector",
            "id": "dev.kaname.synthetic",
            "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
        }]
    });
    let mut unsafe_retry = bounded.clone();
    unsafe_retry["graph"]["nodes"][0]["config"] = json!({"connectorClass":"dev.kaname.synthetic"});
    let unsafe_retry_result = workflow_compiler::compile(&request(unsafe_retry, lock.clone()));
    assert!(
        diagnostic_pairs(&unsafe_retry_result)
            .contains(&("graph.retry.target-not-idempotent", "/graph/nodes/1"))
    );

    let bounded_result = workflow_compiler::compile(&request(bounded, lock));
    assert_eq!(bounded_result.outcome, WorkflowCheckOutcome::Valid as i32);
    assert!(
        !diagnostic_pairs(&bounded_result)
            .iter()
            .any(|(code, _)| *code == "graph.cycle.unbounded")
    );
}

fn bounded_retry_workflow() -> Value {
    let retry_id = EXTRA_ID;
    let authority = json!({
        "key": "effect-authority",
        "type": "authority",
        "typeVersion": 1,
        "config": {"authorityClass":"synthetic","approval":"always","reversible":false}
    });
    json!({
        "formatVersion": 1,
        "workflowId": WORKFLOW_ID,
        "packageId": "dev.kaname.bounded-retry",
        "name": "Bounded retry",
        "summary": "Synthetic and effect free.",
        "graph": {
            "entrypoints": [{"id": ENTRY_ID, "nodeId": START_ID}],
            "nodes": [
                {
                    "id": START_ID,
                    "key": "effect",
                    "name": "effect",
                    "type": "effect.connector",
                    "typeVersion": 1,
                    "config": {"connectorClass":"dev.kaname.synthetic","idempotency":"required"},
                    "policyRefs": {"authority":"effect-authority"}
                },
                node(retry_id, "retry", "control.retry", json!({
                    "maximumAttempts":3,
                    "retryOn":["TRANSIENT"],
                    "backoff":{"mode":"fixed","initialSeconds":1,"maximumSeconds":60,"jitter":"none"}
                })),
                node(END_ID, "complete", "terminal.complete", json!({})),
                node(FAIL_ID, "failed", "terminal.fail", json!({}))
            ],
            "edges": [
                edge(EDGE_ID, MAPPING_ID, (START_ID, "error"), (retry_id, "error")),
                edge(EXTRA_EDGE_ID, EXTRA_MAPPING_ID, (retry_id, "retry"), (START_ID, "input")),
                edge(
                    "018f1000-0013-7000-8000-000000000013",
                    "018f1000-0014-7000-8000-000000000014",
                    (START_ID, "success"),
                    (END_ID, "input")
                ),
                edge(
                    FAIL_EDGE_ID,
                    FAIL_MAPPING_ID,
                    (retry_id, "exhausted"),
                    (FAIL_ID, "input")
                ),
                edge(
                    "018f1000-0015-7000-8000-000000000015",
                    "018f1000-0016-7000-8000-000000000016",
                    (retry_id, "unknown"),
                    (FAIL_ID, "input")
                )
            ]
        },
        "interfaces": {},
        "resources": {},
        "policies": {"effect-authority": authority},
        "storage": {},
        "metadata": {}
    })
}
