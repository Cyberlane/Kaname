use crate::{
    SCHEMA_MAJOR,
    v1::{
        CompileWorkflowRequest, CompileWorkflowResponse, SchemaVersion, WorkflowArtifactDigests,
        WorkflowCheckOutcome, WorkflowDiagnostic, WorkflowDiagnosticSeverity,
        WorkflowSourceLocation,
    },
    workflow_canonical,
    workflow_retention::WorkflowRunRetentionPolicy,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

const DATA_SCHEMA: &str = "dev.kaname.workflow.data/v1";
const ERROR_SCHEMA: &str = "dev.kaname.workflow.error/v1";
const ANY_SCHEMA: &str = "dev.kaname.workflow.any/v1";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompilationManifest {
    compile_manifest_version: u32,
    workflow: Workflow,
    layout: Value,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Workflow {
    format_version: u32,
    workflow_id: String,
    package_id: String,
    name: String,
    summary: String,
    graph: Graph,
    interfaces: Value,
    resources: BTreeMap<String, String>,
    policies: BTreeMap<String, Policy>,
    storage: BTreeMap<String, StorageDeclaration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    retention: Option<Value>,
    metadata: Value,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Graph {
    entrypoints: Vec<Entrypoint>,
    nodes: Vec<Node>,
    edges: Vec<Edge>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entrypoint {
    id: String,
    node_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Node {
    id: String,
    key: String,
    name: String,
    #[serde(rename = "type")]
    node_type: String,
    type_version: u32,
    config: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    policy_refs: Option<PolicyReferences>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    annotations: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PolicyReferences {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    retry: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    timeout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    concurrency: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    authority: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Edge {
    id: String,
    from: Endpoint,
    to: Endpoint,
    mapping_id: String,
    mapping: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ignored: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Endpoint {
    node_id: String,
    port_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Policy {
    key: String,
    #[serde(rename = "type")]
    policy_type: String,
    type_version: u32,
    config: Value,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StorageDeclaration {
    key: String,
    scope: String,
    kind: String,
    schema_ref: String,
    maximum_bytes: u64,
    classification: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    conflict_policy: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DependencyLock {
    lock_version: u32,
    dependencies: Vec<Dependency>,
}

#[derive(Debug, Clone, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Dependency {
    kind: String,
    id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    digest: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PortContract {
    id: String,
    key: String,
    label: String,
    direction: PortDirection,
    cardinality: PortCardinality,
    schema_ref: String,
    required: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum PortDirection {
    Input,
    Output,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum PortCardinality {
    One,
    Many,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompiledArtifact<'a> {
    compiled_format_version: u32,
    workflow_id: &'a str,
    package_id: &'a str,
    definition_digest: &'a str,
    layout_digest: &'a str,
    schema_bundle_digest: &'a str,
    dependency_lock_digest: &'a str,
    configuration_contract_digest: &'a str,
    entrypoints: Vec<&'a Entrypoint>,
    interfaces: &'a Value,
    nodes: Vec<CompiledNode<'a>>,
    edges: Vec<&'a Edge>,
    resources: &'a BTreeMap<String, String>,
    policies: &'a BTreeMap<String, Policy>,
    storage: &'a BTreeMap<String, StorageDeclaration>,
    retention: WorkflowRunRetentionPolicy,
    dependencies: Vec<&'a Dependency>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompiledNode<'a> {
    id: &'a str,
    key: &'a str,
    name: &'a str,
    #[serde(rename = "type")]
    node_type: &'a str,
    type_version: u32,
    execution_availability: &'static str,
    config: &'a Value,
    ports: &'a [PortContract],
}

#[derive(Clone, Eq, Ord, PartialEq, PartialOrd)]
struct CompilerDiagnostic {
    source_id: &'static str,
    pointer: String,
    code: &'static str,
    summary: &'static str,
}

pub fn compile(request: &CompileWorkflowRequest) -> CompileWorkflowResponse {
    let mut diagnostics = Vec::new();
    let manifest = decode_document::<CompilationManifest>(
        &request.manifest_json,
        "compile-manifest.json",
        &mut diagnostics,
    );
    let dependency_lock = decode_document::<DependencyLock>(
        &request.dependency_lock_json,
        "dependency-lock.json",
        &mut diagnostics,
    );
    let schema_bundle = decode_value(
        &request.schema_bundle_json,
        "schema-bundle.json",
        &mut diagnostics,
    );
    let configuration_contract = decode_value(
        &request.configuration_contract_json,
        "configuration-contract.json",
        &mut diagnostics,
    );

    let mut compiled_artifact = Vec::new();
    let mut digests = WorkflowArtifactDigests::default();
    if let (Some(mut manifest), Some(mut lock), Some(schema_bundle), Some(configuration_contract)) = (
        manifest,
        dependency_lock,
        schema_bundle,
        configuration_contract,
    ) {
        if manifest.compile_manifest_version != 1 || manifest.workflow.format_version != 1 {
            diagnostics.push(CompilerDiagnostic::new(
                "document.version.unsupported",
                "compile-manifest.json",
                "",
                "The compilation manifest or workflow format version is unsupported.",
            ));
        }
        if lock.lock_version != 1 {
            diagnostics.push(CompilerDiagnostic::new(
                "dependency.lock.version-unsupported",
                "dependency-lock.json",
                "/lockVersion",
                "The dependency lock version is unsupported.",
            ));
        }
        lock.dependencies.sort();
        let port_sets = compile_graph(&manifest.workflow, &lock, &mut diagnostics);
        if diagnostics.is_empty() {
            manifest
                .workflow
                .graph
                .entrypoints
                .sort_by(|left, right| left.id.cmp(&right.id));
            manifest
                .workflow
                .graph
                .nodes
                .sort_by(|left, right| left.id.cmp(&right.id));
            manifest
                .workflow
                .graph
                .edges
                .sort_by(|left, right| left.id.cmp(&right.id));
            match emit_compiled_artifact(
                &manifest,
                &lock,
                &schema_bundle,
                &configuration_contract,
                &port_sets,
            ) {
                Ok((artifact, resolved_digests)) => {
                    compiled_artifact = artifact;
                    digests = resolved_digests;
                }
                Err(()) => diagnostics.push(CompilerDiagnostic::new(
                    "compiled.artifact.encoding-failed",
                    "compiled.json",
                    "",
                    "The canonical compiled artifact could not be encoded within its bounds.",
                )),
            }
        }
    }

    diagnostics.sort();
    diagnostics.dedup();
    let diagnostic_count = diagnostics.len();
    let maximum = request.maximum_diagnostics as usize;
    diagnostics.truncate(maximum);
    let outcome = if diagnostic_count == 0 {
        WorkflowCheckOutcome::Valid
    } else {
        WorkflowCheckOutcome::Invalid
    };
    CompileWorkflowResponse {
        schema_version: Some(SchemaVersion {
            major: SCHEMA_MAJOR,
            minor: 0,
        }),
        request_id: request.request_id.clone(),
        outcome: outcome as i32,
        diagnostics: diagnostics.into_iter().map(Into::into).collect(),
        diagnostics_truncated: diagnostic_count > maximum,
        compiled_artifact,
        digests: Some(digests),
    }
}

fn emit_compiled_artifact(
    manifest: &CompilationManifest,
    lock: &DependencyLock,
    schema_bundle: &Value,
    configuration_contract: &Value,
    port_sets: &BTreeMap<String, Vec<PortContract>>,
) -> Result<(Vec<u8>, WorkflowArtifactDigests), ()> {
    let definition = canonical_value(&manifest.workflow)?;
    let layout = canonical_value(&manifest.layout)?;
    let schemas = canonical_value(schema_bundle)?;
    let dependencies = canonical_value(lock)?;
    let configuration = canonical_value(configuration_contract)?;
    let mut digests = WorkflowArtifactDigests {
        definition_digest: definition.sha256,
        layout_digest: layout.sha256,
        schema_bundle_digest: schemas.sha256,
        dependency_lock_digest: dependencies.sha256,
        configuration_contract_digest: configuration.sha256,
        compiled_artifact_digest: String::new(),
    };
    let entrypoints = manifest
        .workflow
        .graph
        .entrypoints
        .iter()
        .collect::<Vec<_>>();
    let compiled_nodes = manifest
        .workflow
        .graph
        .nodes
        .iter()
        .map(|node| {
            let ports = port_sets.get(&node.id).ok_or(())?;
            Ok(CompiledNode {
                id: &node.id,
                key: &node.key,
                name: &node.name,
                node_type: &node.node_type,
                type_version: node.type_version,
                execution_availability: execution_availability(node),
                config: &node.config,
                ports,
            })
        })
        .collect::<Result<Vec<_>, ()>>()?;
    let edges = manifest.workflow.graph.edges.iter().collect::<Vec<_>>();
    let dependencies = lock.dependencies.iter().collect::<Vec<_>>();
    let retention =
        WorkflowRunRetentionPolicy::from_optional_json(manifest.workflow.retention.as_ref())
            .map_err(|_| ())?;
    let artifact = CompiledArtifact {
        compiled_format_version: 1,
        workflow_id: &manifest.workflow.workflow_id,
        package_id: &manifest.workflow.package_id,
        definition_digest: &digests.definition_digest,
        layout_digest: &digests.layout_digest,
        schema_bundle_digest: &digests.schema_bundle_digest,
        dependency_lock_digest: &digests.dependency_lock_digest,
        configuration_contract_digest: &digests.configuration_contract_digest,
        entrypoints,
        interfaces: &manifest.workflow.interfaces,
        nodes: compiled_nodes,
        edges,
        resources: &manifest.workflow.resources,
        policies: &manifest.workflow.policies,
        storage: &manifest.workflow.storage,
        retention,
        dependencies,
    };
    let compiled = canonical_value(&artifact)?;
    digests.compiled_artifact_digest = compiled.sha256;
    Ok((compiled.canonical_bytes, digests))
}

fn execution_availability(node: &Node) -> &'static str {
    match node.node_type.as_str() {
        "trigger.manual" | "terminal.complete" | "terminal.fail"
            if node.config.as_object().is_some_and(Map::is_empty) =>
        {
            "executable"
        }
        "data.validate" | "data.case-context" => "executable",
        "compute.capability"
            if string_field(&node.config, "capabilityId").is_some()
                && string_field(&node.config, "version").is_some()
                && node.config.get("input") == Some(&serde_json::json!({"whole": true}))
                && string_field(&node.config, "outputSchemaRef").is_some()
                && node
                    .config
                    .get("configuration")
                    .is_none_or(Value::is_object) =>
        {
            "executable"
        }
        "compute.llm"
            if string_field(&node.config, "modelClass").is_some()
                && string_field(&node.config, "instructions").is_some()
                && node.config.get("prompt") == Some(&serde_json::json!({"whole": true}))
                && array_field(&node.config, "tools").is_some()
                && string_field(&node.config, "outputSchemaRef").is_some()
                && string_field(&node.config, "reasoningEffort").is_some()
                && node
                    .config
                    .get("temperatureMilli")
                    .and_then(Value::as_u64)
                    .is_some()
                && node
                    .config
                    .get("maximumContextBytes")
                    .and_then(Value::as_u64)
                    .is_some()
                && node
                    .config
                    .get("maximumOutputTokens")
                    .and_then(Value::as_u64)
                    .is_some() =>
        {
            "executable"
        }
        "control.subflow"
            if string_field(&node.config, "packageId").is_some()
                && string_field(&node.config, "revisionDigest").is_some()
                && string_field(&node.config, "entrypoint").is_some()
                && node.config.get("input") == Some(&serde_json::json!({"whole": true})) =>
        {
            "executable"
        }
        "storage.read" => "executable",
        "storage.promote" => "executable",
        "storage.write"
            if node.config.get("operation").and_then(Value::as_str) == Some("delete-reference")
                || node
                    .config
                    .get("value")
                    .and_then(|value| value.get("root"))
                    .and_then(Value::as_str)
                    == Some("input") =>
        {
            "executable"
        }
        "control.match"
            if matches!(
                node.config.get("hitPolicy").and_then(Value::as_str),
                Some("first" | "unique")
            ) =>
        {
            "executable"
        }
        "control.parallel" => "executable",
        "control.for-each" => "executable",
        "control.retry" => "executable",
        "control.wait" => "executable",
        "control.join"
            if matches!(
                node.config.get("policy").and_then(Value::as_str),
                Some("all" | "any" | "quorum")
            ) =>
        {
            "executable"
        }
        _ => "schema-only",
    }
}

fn compile_graph(
    workflow: &Workflow,
    dependency_lock: &DependencyLock,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) -> BTreeMap<String, Vec<PortContract>> {
    let graph = &workflow.graph;
    validate_unique_graph_identities(graph, diagnostics);
    let node_indices = graph
        .nodes
        .iter()
        .enumerate()
        .map(|(index, node)| (node.id.as_str(), index))
        .collect::<BTreeMap<_, _>>();
    let mut port_sets = BTreeMap::new();
    for (index, node) in graph.nodes.iter().enumerate() {
        match ports_for(node) {
            Ok(ports) => {
                port_sets.insert(node.id.clone(), ports);
            }
            Err(code) => diagnostics.push(CompilerDiagnostic::new(
                code,
                "workflow.json",
                format!("/graph/nodes/{index}/config"),
                "The node type, version, or dynamic port configuration is not registered.",
            )),
        }
    }

    let mut entry_nodes = BTreeSet::new();
    for (index, entrypoint) in graph.entrypoints.iter().enumerate() {
        if node_indices.contains_key(entrypoint.node_id.as_str()) {
            entry_nodes.insert(entrypoint.node_id.as_str());
        } else {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.entrypoint.missing",
                "workflow.json",
                format!("/graph/entrypoints/{index}/nodeId"),
                "The entrypoint references a node that does not exist.",
            ));
        }
    }

    let mut outgoing = BTreeMap::<&str, Vec<(usize, &Edge)>>::new();
    let mut incoming = BTreeMap::<&str, Vec<(usize, &Edge)>>::new();
    for (index, edge) in graph.edges.iter().enumerate() {
        outgoing
            .entry(edge.from.node_id.as_str())
            .or_default()
            .push((index, edge));
        incoming
            .entry(edge.to.node_id.as_str())
            .or_default()
            .push((index, edge));
        validate_edge(index, edge, &node_indices, &port_sets, diagnostics);
    }

    let reachable = reachable_nodes(&entry_nodes, &outgoing);
    for (index, node) in graph.nodes.iter().enumerate() {
        if !reachable.contains(node.id.as_str()) {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.node.unreachable",
                "workflow.json",
                format!("/graph/nodes/{index}"),
                "The node is not reachable from any entrypoint.",
            ));
        }
    }

    validate_terminals(graph, &reachable, &outgoing, diagnostics);
    validate_required_ports(graph, &incoming, &outgoing, &port_sets, diagnostics);
    validate_fan_out(graph, &outgoing, &port_sets, diagnostics);
    validate_joins(graph, &incoming, diagnostics);
    validate_iteration_and_retry(graph, &incoming, &outgoing, diagnostics);
    validate_cycles(graph, &reachable, diagnostics);
    validate_storage(workflow, diagnostics);
    validate_dependencies(workflow, dependency_lock, diagnostics);
    validate_policy_references(workflow, diagnostics);
    validate_authority(workflow, diagnostics);
    port_sets
}

fn validate_unique_graph_identities(graph: &Graph, diagnostics: &mut Vec<CompilerDiagnostic>) {
    let checks = [
        (
            "identity.entrypoint.duplicate",
            "/graph/entrypoints",
            graph
                .entrypoints
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
        ),
        (
            "identity.node.duplicate",
            "/graph/nodes",
            graph
                .nodes
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
        ),
        (
            "identity.node-key.duplicate",
            "/graph/nodes",
            graph
                .nodes
                .iter()
                .map(|item| item.key.as_str())
                .collect::<Vec<_>>(),
        ),
        (
            "identity.edge.duplicate",
            "/graph/edges",
            graph
                .edges
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
        ),
        (
            "identity.mapping.duplicate",
            "/graph/edges",
            graph
                .edges
                .iter()
                .map(|item| item.mapping_id.as_str())
                .collect::<Vec<_>>(),
        ),
    ];
    for (code, pointer, values) in checks {
        if values.iter().copied().collect::<BTreeSet<_>>().len() != values.len() {
            diagnostics.push(CompilerDiagnostic::new(
                code,
                "workflow.json",
                pointer,
                "Graph identities and readable node keys must be unique within their scope.",
            ));
        }
    }
}

fn validate_edge(
    index: usize,
    edge: &Edge,
    nodes: &BTreeMap<&str, usize>,
    port_sets: &BTreeMap<String, Vec<PortContract>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (endpoint, role) in [(&edge.from, "from"), (&edge.to, "to")] {
        if !nodes.contains_key(endpoint.node_id.as_str()) {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.edge.node.missing",
                "workflow.json",
                format!("/graph/edges/{index}/{role}/nodeId"),
                "The edge endpoint references a node that does not exist.",
            ));
        }
    }
    let source = find_port(port_sets, &edge.from);
    let destination = find_port(port_sets, &edge.to);
    if source.is_none() {
        diagnostics.push(CompilerDiagnostic::new(
            "graph.edge.port.missing",
            "workflow.json",
            format!("/graph/edges/{index}/from/portId"),
            "The source port is not declared by the node registry.",
        ));
    }
    if destination.is_none() {
        diagnostics.push(CompilerDiagnostic::new(
            "graph.edge.port.missing",
            "workflow.json",
            format!("/graph/edges/{index}/to/portId"),
            "The destination port is not declared by the node registry.",
        ));
    }
    if let (Some(source), Some(destination)) = (source, destination) {
        if source.direction != PortDirection::Output
            || destination.direction != PortDirection::Input
        {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.edge.direction.invalid",
                "workflow.json",
                format!("/graph/edges/{index}"),
                "An edge must connect an output port to an input port.",
            ));
        }
        if source.schema_ref != destination.schema_ref && destination.schema_ref != ANY_SCHEMA {
            diagnostics.push(CompilerDiagnostic::new(
                "mapping.type.incompatible",
                "workflow.json",
                format!("/graph/edges/{index}/mapping"),
                "The mapping cannot produce the destination port schema.",
            ));
        }
        if source.cardinality == PortCardinality::Many
            && destination.cardinality == PortCardinality::One
        {
            diagnostics.push(CompilerDiagnostic::new(
                "mapping.cardinality.incompatible",
                "workflow.json",
                format!("/graph/edges/{index}/mapping"),
                "A many-valued output requires a many-valued destination.",
            ));
        }
    }
}

fn validate_terminals(
    graph: &Graph,
    reachable: &BTreeSet<&str>,
    outgoing: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    let has_terminal = graph.nodes.iter().any(|node| {
        reachable.contains(node.id.as_str()) && node.node_type.starts_with("terminal.")
    });
    if !has_terminal {
        diagnostics.push(CompilerDiagnostic::new(
            "graph.terminal.missing",
            "workflow.json",
            "/graph/nodes",
            "Every published graph needs a reachable terminal node.",
        ));
    }
    for (index, node) in graph.nodes.iter().enumerate() {
        let outgoing_count = outgoing.get(node.id.as_str()).map_or(0, Vec::len);
        if node.node_type.starts_with("terminal.") && outgoing_count > 0 {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.terminal.outgoing",
                "workflow.json",
                format!("/graph/nodes/{index}"),
                "A terminal node cannot have outgoing edges.",
            ));
        } else if reachable.contains(node.id.as_str())
            && !node.node_type.starts_with("terminal.")
            && outgoing_count == 0
        {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.node.nonterminal-sink",
                "workflow.json",
                format!("/graph/nodes/{index}"),
                "A reachable non-terminal node cannot silently end execution.",
            ));
        }
    }
}

fn validate_required_ports(
    graph: &Graph,
    incoming: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    outgoing: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    port_sets: &BTreeMap<String, Vec<PortContract>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (index, node) in graph.nodes.iter().enumerate() {
        let connected = incoming
            .get(node.id.as_str())
            .into_iter()
            .flat_map(|edges| edges.iter().map(|(_, edge)| edge.to.port_id.as_str()))
            .collect::<BTreeSet<_>>();
        let emitted = outgoing
            .get(node.id.as_str())
            .into_iter()
            .flat_map(|edges| edges.iter().map(|(_, edge)| edge.from.port_id.as_str()))
            .collect::<BTreeSet<_>>();
        if let Some(ports) = port_sets.get(&node.id) {
            for port in ports {
                if port.direction == PortDirection::Input
                    && port.required
                    && !connected.contains(port.id.as_str())
                    && !graph
                        .entrypoints
                        .iter()
                        .any(|entrypoint| entrypoint.node_id == node.id)
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.input.required-missing",
                        "workflow.json",
                        format!("/graph/nodes/{index}"),
                        "A required input port is not connected.",
                    ));
                }
                if port.direction == PortDirection::Output
                    && port.required
                    && !emitted.contains(port.id.as_str())
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.output.required-missing",
                        "workflow.json",
                        format!("/graph/nodes/{index}"),
                        "A required output port is neither connected nor explicitly ignored.",
                    ));
                }
            }
        }
    }
}

fn validate_fan_out(
    graph: &Graph,
    outgoing: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    port_sets: &BTreeMap<String, Vec<PortContract>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (index, node) in graph.nodes.iter().enumerate() {
        let mut counts = BTreeMap::<&str, usize>::new();
        for (_, edge) in outgoing.get(node.id.as_str()).into_iter().flatten() {
            *counts.entry(edge.from.port_id.as_str()).or_default() += 1;
        }
        if let Some(ports) = port_sets.get(&node.id) {
            for port in ports {
                if port.direction == PortDirection::Output
                    && port.cardinality == PortCardinality::One
                    && counts.get(port.id.as_str()).copied().unwrap_or(0) > 1
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.output.fanout",
                        "workflow.json",
                        format!("/graph/nodes/{index}"),
                        "A single-valued output cannot fan out to multiple edges.",
                    ));
                }
            }
        }
    }
}

fn validate_joins(
    graph: &Graph,
    incoming: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (index, node) in graph.nodes.iter().enumerate() {
        if node.node_type != "control.join" {
            continue;
        }
        let branch_count = incoming
            .get(node.id.as_str())
            .into_iter()
            .flatten()
            .filter(|(_, edge)| edge.to.port_id == "branches")
            .count();
        if branch_count < 2 {
            diagnostics.push(CompilerDiagnostic::new(
                "graph.join.inputs-insufficient",
                "workflow.json",
                format!("/graph/nodes/{index}"),
                "A join requires at least two branch inputs.",
            ));
        }
        if string_field(&node.config, "policy") == Some("quorum") {
            let quorum = integer_field(&node.config, "quorum").unwrap_or(0) as usize;
            if quorum == 0 || quorum > branch_count {
                diagnostics.push(CompilerDiagnostic::new(
                    "graph.join.quorum-invalid",
                    "workflow.json",
                    format!("/graph/nodes/{index}/config/quorum"),
                    "The join quorum must be within the connected branch count.",
                ));
            }
        }
    }
}

fn validate_iteration_and_retry(
    graph: &Graph,
    incoming: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    outgoing: &BTreeMap<&str, Vec<(usize, &Edge)>>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (index, node) in graph.nodes.iter().enumerate() {
        match node.node_type.as_str() {
            "control.for-each" => {
                let item_edges = outgoing
                    .get(node.id.as_str())
                    .into_iter()
                    .flatten()
                    .filter(|(_, edge)| edge.from.port_id == "item")
                    .count();
                let success_returns = incoming
                    .get(node.id.as_str())
                    .into_iter()
                    .flatten()
                    .filter(|(_, edge)| edge.to.port_id == "item-success")
                    .count();
                if item_edges != 1 || success_returns != 1 {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.iteration.body-invalid",
                        "workflow.json",
                        format!("/graph/nodes/{index}"),
                        "For each requires one item body edge and one explicit item-success return edge.",
                    ));
                }
                let maximum_items = integer_field(&node.config, "maximumItems").unwrap_or(0);
                let maximum_concurrency =
                    integer_field(&node.config, "maximumConcurrency").unwrap_or(0);
                if maximum_items < 1
                    || maximum_concurrency < 1
                    || maximum_concurrency > maximum_items
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.iteration.bounds-invalid",
                        "workflow.json",
                        format!("/graph/nodes/{index}/config"),
                        "For each concurrency must be positive and cannot exceed its explicit item bound.",
                    ));
                }
            }
            "control.retry" => {
                let retry_edges = outgoing
                    .get(node.id.as_str())
                    .into_iter()
                    .flatten()
                    .filter(|(_, edge)| edge.from.port_id == "retry")
                    .collect::<Vec<_>>();
                if retry_edges.len() == 1 {
                    let target = graph
                        .nodes
                        .iter()
                        .find(|candidate| candidate.id == retry_edges[0].1.to.node_id);
                    if target.is_none_or(|target| !retry_safe_node(target)) {
                        diagnostics.push(CompilerDiagnostic::new(
                            "graph.retry.target-not-idempotent",
                            "workflow.json",
                            format!("/graph/nodes/{index}"),
                            "Retry must target a pure operation or an effect with required idempotency.",
                        ));
                    }
                }
                let initial = node
                    .config
                    .get("backoff")
                    .and_then(|value| value.get("initialSeconds"))
                    .and_then(Value::as_f64);
                let maximum = node
                    .config
                    .get("backoff")
                    .and_then(|value| value.get("maximumSeconds"))
                    .and_then(Value::as_f64);
                if initial
                    .zip(maximum)
                    .is_none_or(|(initial, maximum)| initial <= 0.0 || initial > maximum)
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "graph.retry.backoff-invalid",
                        "workflow.json",
                        format!("/graph/nodes/{index}/config/backoff"),
                        "Retry initial backoff must be positive and no greater than its maximum.",
                    ));
                }
            }
            _ => {}
        }
    }
}

fn retry_safe_node(node: &Node) -> bool {
    matches!(
        node.node_type.as_str(),
        "data.map"
            | "data.validate"
            | "data.case-context"
            | "storage.read"
            | "control.decision"
            | "control.match"
    ) || (node.node_type == "effect.connector"
        && string_field(&node.config, "idempotency") == Some("required"))
}

fn validate_cycles(
    graph: &Graph,
    reachable: &BTreeSet<&str>,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    let adjacency = graph
        .nodes
        .iter()
        .map(|node| {
            let targets = graph
                .edges
                .iter()
                .filter(|edge| edge.from.node_id == node.id)
                .map(|edge| edge.to.node_id.as_str())
                .collect::<Vec<_>>();
            (node.id.as_str(), targets)
        })
        .collect::<BTreeMap<_, _>>();
    for component in strongly_connected_components(&adjacency) {
        let self_cycle = component.len() == 1
            && adjacency
                .get(component[0])
                .into_iter()
                .flatten()
                .any(|target| *target == component[0]);
        if component.len() < 2 && !self_cycle {
            continue;
        }
        if !component.iter().any(|id| reachable.contains(id)) {
            continue;
        }
        let controllers = component
            .iter()
            .filter_map(|id| graph.nodes.iter().find(|node| node.id == *id))
            .filter(|node| {
                matches!(
                    node.node_type.as_str(),
                    "control.retry" | "control.for-each"
                )
            })
            .collect::<Vec<_>>();
        if controllers.len() != 1 {
            let first = component
                .iter()
                .filter_map(|id| graph.nodes.iter().position(|node| node.id == *id))
                .min()
                .unwrap_or(0);
            diagnostics.push(CompilerDiagnostic::new(
                "graph.cycle.unbounded",
                "workflow.json",
                format!("/graph/nodes/{first}"),
                "A cycle requires exactly one explicit bounded retry or for-each controller.",
            ));
        }
    }
}

fn validate_storage(workflow: &Workflow, diagnostics: &mut Vec<CompilerDiagnostic>) {
    for (index, node) in workflow.graph.nodes.iter().enumerate() {
        match node.node_type.as_str() {
            "storage.read" | "storage.write" => {
                let scope = string_field(&node.config, "scope");
                let key = string_field(&node.config, "key");
                let declaration = key.and_then(|key| workflow.storage.get(key));
                if declaration.is_none()
                    || declaration.is_some_and(|value| Some(value.scope.as_str()) != scope)
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "storage.declaration.missing",
                        "workflow.json",
                        format!("/graph/nodes/{index}/config/key"),
                        "The storage access is not covered by a matching scope and key declaration.",
                    ));
                }
            }
            "storage.promote" => {
                let from = string_field(&node.config, "from");
                let to = string_field(&node.config, "to");
                let source = string_field(&node.config, "sourceKey")
                    .and_then(|key| workflow.storage.get(key));
                let destination = string_field(&node.config, "destinationKey")
                    .and_then(|key| workflow.storage.get(key));
                if source.is_none()
                    || destination.is_none()
                    || source.is_some_and(|value| Some(value.scope.as_str()) != from)
                    || destination.is_some_and(|value| Some(value.scope.as_str()) != to)
                    || scope_rank(from) >= scope_rank(to)
                    || source
                        .zip(destination)
                        .is_some_and(|(source, destination)| {
                            source.kind != destination.kind
                                || source.schema_ref != destination.schema_ref
                                || classification_rank(&destination.classification)
                                    < classification_rank(&source.classification)
                                || destination
                                    .conflict_policy
                                    .as_deref()
                                    .is_some_and(|policy| {
                                        Some(policy) != string_field(&node.config, "conflictPolicy")
                                    })
                        })
                {
                    diagnostics.push(CompilerDiagnostic::new(
                        "storage.promotion.invalid",
                        "workflow.json",
                        format!("/graph/nodes/{index}/config"),
                        "Storage promotion must move between declared keys toward a longer-lived scope.",
                    ));
                }
            }
            _ => {}
        }
    }
}

fn validate_dependencies(
    workflow: &Workflow,
    lock: &DependencyLock,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) {
    for (index, node) in workflow.graph.nodes.iter().enumerate() {
        let requirements = dependency_requirements(node);
        for requirement in requirements {
            let found = lock.dependencies.iter().any(|dependency| {
                dependency.kind == requirement.kind
                    && dependency.id == requirement.id
                    && requirement
                        .version
                        .as_ref()
                        .is_none_or(|version| dependency.version.as_ref() == Some(version))
                    && requirement
                        .digest
                        .as_ref()
                        .is_none_or(|digest| &dependency.digest == digest)
            });
            if !found {
                diagnostics.push(CompilerDiagnostic::new(
                    "dependency.pin.missing",
                    "dependency-lock.json",
                    "/dependencies",
                    "A node dependency is absent or does not match its exact version or digest pin.",
                ));
                diagnostics.push(CompilerDiagnostic::new(
                    "dependency.node.unresolved",
                    "workflow.json",
                    format!("/graph/nodes/{index}/config"),
                    "The node references a dependency that is not pinned by the lock.",
                ));
            }
        }
    }
}

fn validate_policy_references(workflow: &Workflow, diagnostics: &mut Vec<CompilerDiagnostic>) {
    for (index, node) in workflow.graph.nodes.iter().enumerate() {
        let Some(references) = &node.policy_refs else {
            continue;
        };
        for (kind, key) in [
            ("retry", references.retry.as_ref()),
            ("timeout", references.timeout.as_ref()),
            ("concurrency", references.concurrency.as_ref()),
            ("authority", references.authority.as_ref()),
        ] {
            let Some(key) = key else { continue };
            if !workflow
                .policies
                .get(key)
                .is_some_and(|policy| policy.policy_type == kind && policy.type_version == 1)
            {
                diagnostics.push(CompilerDiagnostic::new(
                    "policy.reference.invalid",
                    "workflow.json",
                    format!("/graph/nodes/{index}/policyRefs/{kind}"),
                    "The policy reference does not resolve to the required policy type and version.",
                ));
            }
        }
    }
    for (key, policy) in &workflow.policies {
        if &policy.key != key {
            diagnostics.push(CompilerDiagnostic::new(
                "policy.key.mismatch",
                "workflow.json",
                format!("/policies/{key}/key"),
                "The policy map key must match the policy's persisted key.",
            ));
        }
    }
    for (key, declaration) in &workflow.storage {
        if &declaration.key != key {
            diagnostics.push(CompilerDiagnostic::new(
                "storage.key.mismatch",
                "workflow.json",
                format!("/storage/{key}/key"),
                "The storage map key must match the declaration's persisted key.",
            ));
        }
    }
}

fn validate_authority(workflow: &Workflow, diagnostics: &mut Vec<CompilerDiagnostic>) {
    for (index, node) in workflow.graph.nodes.iter().enumerate() {
        if !node.node_type.starts_with("effect.") {
            continue;
        }
        let authority = node
            .policy_refs
            .as_ref()
            .and_then(|references| references.authority.as_ref())
            .and_then(|key| workflow.policies.get(key));
        if !authority
            .is_some_and(|policy| policy.policy_type == "authority" && policy.type_version == 1)
        {
            diagnostics.push(CompilerDiagnostic::new(
                "effect.authority.undeclared",
                "workflow.json",
                format!("/graph/nodes/{index}/policyRefs/authority"),
                "An effect node requires an explicit authority policy reference.",
            ));
        }
    }
}

struct DependencyRequirement {
    kind: &'static str,
    id: String,
    version: Option<String>,
    digest: Option<String>,
}

fn dependency_requirements(node: &Node) -> Vec<DependencyRequirement> {
    match node.node_type.as_str() {
        "compute.capability" => single_dependency_requirement(
            "capability",
            string_field(&node.config, "capabilityId"),
            string_field(&node.config, "version"),
            None,
        ),
        "compute.llm" => array_field(&node.config, "tools")
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|id| DependencyRequirement {
                kind: "tool",
                id: id.to_owned(),
                version: None,
                digest: None,
            })
            .collect(),
        "control.subflow" => single_dependency_requirement(
            "subflow",
            string_field(&node.config, "packageId"),
            None,
            string_field(&node.config, "revisionDigest"),
        ),
        "effect.connector" => single_dependency_requirement(
            "connector",
            string_field(&node.config, "connectorClass"),
            None,
            None,
        ),
        _ => Vec::new(),
    }
}

fn single_dependency_requirement(
    kind: &'static str,
    id: Option<&str>,
    version: Option<&str>,
    digest: Option<&str>,
) -> Vec<DependencyRequirement> {
    let Some(id) = id else { return Vec::new() };
    vec![DependencyRequirement {
        kind,
        id: id.to_owned(),
        version: version.map(str::to_owned),
        digest: digest.map(str::to_owned),
    }]
}

fn ports_for(node: &Node) -> Result<Vec<PortContract>, &'static str> {
    if node.type_version != 1 || !registered_types().contains(node.node_type.as_str()) {
        return Err("registry.node.unknown-version");
    }
    let input = || {
        port(
            "input",
            PortDirection::Input,
            PortCardinality::One,
            DATA_SCHEMA,
            true,
        )
    };
    let success = || {
        port(
            "success",
            PortDirection::Output,
            PortCardinality::One,
            DATA_SCHEMA,
            true,
        )
    };
    let error = || {
        port(
            "error",
            PortDirection::Output,
            PortCardinality::One,
            ERROR_SCHEMA,
            false,
        )
    };
    let mut ports = if node.node_type.starts_with("trigger.") {
        vec![success()]
    } else if node.node_type.starts_with("terminal.") {
        let schema = match node.node_type.as_str() {
            "terminal.fail" => ERROR_SCHEMA,
            "terminal.cancel" => ANY_SCHEMA,
            _ => DATA_SCHEMA,
        };
        vec![port(
            "input",
            PortDirection::Input,
            PortCardinality::One,
            schema,
            true,
        )]
    } else {
        match node.node_type.as_str() {
            "control.match" | "control.parallel" => vec![input(), error()],
            "control.decision" => vec![
                input(),
                port(
                    "matched",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                port(
                    "not-matched",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                error(),
            ],
            "control.join" => vec![
                port(
                    "branches",
                    PortDirection::Input,
                    PortCardinality::Many,
                    DATA_SCHEMA,
                    true,
                ),
                success(),
                error(),
            ],
            "control.retry" => vec![
                port(
                    "error",
                    PortDirection::Input,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
                port(
                    "retry",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                port(
                    "exhausted",
                    PortDirection::Output,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
                port(
                    "unknown",
                    PortDirection::Output,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
            ],
            "control.reconcile" => vec![
                port(
                    "unknown",
                    PortDirection::Input,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
                success(),
                port(
                    "failure",
                    PortDirection::Output,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
                port(
                    "still-unknown",
                    PortDirection::Output,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    true,
                ),
            ],
            "control.wait" => vec![
                input(),
                port(
                    "resumed",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                port(
                    "expired",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    false,
                ),
                error(),
            ],
            "data.case-context" => vec![input(), success()],
            "control.for-each" => vec![
                input(),
                port(
                    "item-success",
                    PortDirection::Input,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                port(
                    "item-error",
                    PortDirection::Input,
                    PortCardinality::One,
                    ERROR_SCHEMA,
                    false,
                ),
                port(
                    "item",
                    PortDirection::Output,
                    PortCardinality::One,
                    DATA_SCHEMA,
                    true,
                ),
                success(),
                error(),
            ],
            _ => vec![input(), success(), error()],
        }
    };
    match node.node_type.as_str() {
        "control.match" => append_case_ports(&mut ports, &node.config, true)?,
        "control.parallel" => append_case_ports(&mut ports, &node.config, false)?,
        _ => {}
    }
    let unique = ports
        .iter()
        .map(|port| port.id.as_str())
        .collect::<BTreeSet<_>>();
    if unique.len() != ports.len() {
        return Err("registry.node.dynamic-ports-invalid");
    }
    Ok(ports)
}

fn append_case_ports(
    ports: &mut Vec<PortContract>,
    config: &Value,
    include_otherwise: bool,
) -> Result<(), &'static str> {
    let field = if include_otherwise {
        "cases"
    } else {
        "branches"
    };
    let values = array_field(config, field).ok_or("registry.node.dynamic-ports-invalid")?;
    for value in values {
        ports.push(case_port(
            value
                .as_object()
                .ok_or("registry.node.dynamic-ports-invalid")?,
        )?);
    }
    if include_otherwise && let Some(otherwise) = object_field(config, "otherwise") {
        ports.push(case_port(otherwise)?);
    }
    Ok(())
}

fn case_port(value: &Map<String, Value>) -> Result<PortContract, &'static str> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or("registry.node.dynamic-ports-invalid")?;
    let key = value
        .get("key")
        .and_then(Value::as_str)
        .ok_or("registry.node.dynamic-ports-invalid")?;
    let label = value
        .get("label")
        .and_then(Value::as_str)
        .ok_or("registry.node.dynamic-ports-invalid")?;
    let mut contract = port(
        &format!("case-{id}"),
        PortDirection::Output,
        PortCardinality::One,
        DATA_SCHEMA,
        true,
    );
    contract.key = key.to_owned();
    contract.label = label.to_owned();
    Ok(contract)
}

fn port(
    id: &str,
    direction: PortDirection,
    cardinality: PortCardinality,
    schema_ref: &str,
    required: bool,
) -> PortContract {
    PortContract {
        id: id.to_owned(),
        key: id.to_owned(),
        label: port_label(id),
        direction,
        cardinality,
        schema_ref: schema_ref.to_owned(),
        required,
    }
}

fn port_label(id: &str) -> String {
    id.split('-')
        .map(|part| {
            let mut characters = part.chars();
            characters
                .next()
                .map(|first| first.to_uppercase().collect::<String>() + characters.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn registered_types() -> BTreeSet<&'static str> {
    [
        "trigger.manual",
        "trigger.event",
        "trigger.schedule",
        "data.map",
        "data.validate",
        "data.case-context",
        "data.register-artifact",
        "storage.read",
        "storage.write",
        "storage.promote",
        "compute.capability",
        "compute.llm",
        "control.decision",
        "control.match",
        "control.for-each",
        "control.parallel",
        "control.join",
        "control.retry",
        "control.reconcile",
        "control.wait",
        "control.subflow",
        "control.human-review",
        "effect.connector",
        "terminal.complete",
        "terminal.fail",
        "terminal.cancel",
    ]
    .into_iter()
    .collect()
}

fn reachable_nodes<'a>(
    entries: &BTreeSet<&'a str>,
    outgoing: &BTreeMap<&'a str, Vec<(usize, &'a Edge)>>,
) -> BTreeSet<&'a str> {
    let mut reachable = entries.clone();
    let mut queue = entries.iter().copied().collect::<VecDeque<_>>();
    while let Some(node_id) = queue.pop_front() {
        for (_, edge) in outgoing.get(node_id).into_iter().flatten() {
            if reachable.insert(edge.to.node_id.as_str()) {
                queue.push_back(edge.to.node_id.as_str());
            }
        }
    }
    reachable
}

fn strongly_connected_components<'a>(
    adjacency: &BTreeMap<&'a str, Vec<&'a str>>,
) -> Vec<Vec<&'a str>> {
    struct State<'a> {
        next_index: usize,
        indices: BTreeMap<&'a str, usize>,
        low_links: BTreeMap<&'a str, usize>,
        stack: Vec<&'a str>,
        on_stack: BTreeSet<&'a str>,
        components: Vec<Vec<&'a str>>,
    }
    fn visit<'a>(
        node: &'a str,
        adjacency: &BTreeMap<&'a str, Vec<&'a str>>,
        state: &mut State<'a>,
    ) {
        let index = state.next_index;
        state.next_index += 1;
        state.indices.insert(node, index);
        state.low_links.insert(node, index);
        state.stack.push(node);
        state.on_stack.insert(node);
        for neighbor in adjacency.get(node).into_iter().flatten().copied() {
            if !state.indices.contains_key(neighbor) {
                visit(neighbor, adjacency, state);
                state
                    .low_links
                    .insert(node, state.low_links[node].min(state.low_links[neighbor]));
            } else if state.on_stack.contains(neighbor) {
                state
                    .low_links
                    .insert(node, state.low_links[node].min(state.indices[neighbor]));
            }
        }
        if state.low_links[node] == state.indices[node] {
            let mut component = Vec::new();
            while let Some(member) = state.stack.pop() {
                state.on_stack.remove(member);
                component.push(member);
                if member == node {
                    break;
                }
            }
            component.sort();
            state.components.push(component);
        }
    }
    let mut state = State {
        next_index: 0,
        indices: BTreeMap::new(),
        low_links: BTreeMap::new(),
        stack: Vec::new(),
        on_stack: BTreeSet::new(),
        components: Vec::new(),
    };
    for node in adjacency.keys().copied() {
        if !state.indices.contains_key(node) {
            visit(node, adjacency, &mut state);
        }
    }
    state.components.sort();
    state.components
}

fn find_port<'a>(
    port_sets: &'a BTreeMap<String, Vec<PortContract>>,
    endpoint: &Endpoint,
) -> Option<&'a PortContract> {
    port_sets
        .get(&endpoint.node_id)?
        .iter()
        .find(|port| port.id == endpoint.port_id)
}

fn decode_document<T: for<'de> Deserialize<'de>>(
    bytes: &[u8],
    source_id: &'static str,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) -> Option<T> {
    serde_json::from_slice(bytes)
        .map_err(|_| {
            diagnostics.push(CompilerDiagnostic::new(
                "document.malformed",
                source_id,
                "",
                "The document is not valid bounded JSON for this compiler contract.",
            ));
        })
        .ok()
}

fn decode_value(
    bytes: &[u8],
    source_id: &'static str,
    diagnostics: &mut Vec<CompilerDiagnostic>,
) -> Option<Value> {
    decode_document(bytes, source_id, diagnostics)
}

fn canonical_value(
    value: &impl Serialize,
) -> Result<workflow_canonical::WorkflowCanonicalReport, ()> {
    let bytes = serde_json::to_vec(value).map_err(|_| ())?;
    workflow_canonical::canonicalize(&bytes).map_err(|_| ())
}

fn string_field<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value.as_object()?.get(field)?.as_str()
}

fn integer_field(value: &Value, field: &str) -> Option<u64> {
    value.as_object()?.get(field)?.as_u64()
}

fn array_field<'a>(value: &'a Value, field: &str) -> Option<&'a Vec<Value>> {
    value.as_object()?.get(field)?.as_array()
}

fn object_field<'a>(value: &'a Value, field: &str) -> Option<&'a Map<String, Value>> {
    value.as_object()?.get(field)?.as_object()
}

fn scope_rank(scope: Option<&str>) -> u8 {
    match scope {
        Some("job") => 1,
        Some("case") => 2,
        Some("workflow") => 3,
        _ => u8::MAX,
    }
}

fn classification_rank(classification: &str) -> u8 {
    match classification {
        "public" => 1,
        "internal" => 2,
        "private" => 3,
        "restricted" => 4,
        _ => 0,
    }
}

impl CompilerDiagnostic {
    fn new(
        code: &'static str,
        source_id: &'static str,
        pointer: impl Into<String>,
        summary: &'static str,
    ) -> Self {
        Self {
            source_id,
            pointer: pointer.into(),
            code,
            summary,
        }
    }
}

impl From<CompilerDiagnostic> for WorkflowDiagnostic {
    fn from(value: CompilerDiagnostic) -> Self {
        WorkflowDiagnostic {
            code: value.code.to_owned(),
            severity: WorkflowDiagnosticSeverity::Error as i32,
            summary: value.summary.to_owned(),
            instance_pointer: value.pointer.clone(),
            schema_pointer: String::new(),
            location: Some(WorkflowSourceLocation {
                source_id: value.source_id.to_owned(),
                json_pointer: value.pointer,
                start: None,
                end: None,
            }),
        }
    }
}
