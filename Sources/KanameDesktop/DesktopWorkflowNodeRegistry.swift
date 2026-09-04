import Foundation

public enum DesktopWorkflowNodeExecutionAvailability: String, Codable, Sendable {
    case schemaOnly
    case executable
}

/// Plain-language readings of the compiler's downgrade condition codes so the
/// Builder can say why a node will not execute as configured.
public enum DesktopWorkflowDowngradeConditionPresentation {
    public static func text(for condition: String) -> String {
        switch condition {
        case "empty_configuration_required":
            "This node takes no configuration; remove the extra settings."
        case "event_trigger_contract_not_executable":
            "Set an event contract (for example mail.message.received) and leave correlation empty."
        case "schedule_trigger_contract_not_executable":
            "Set a valid interval or calendar schedule."
        case "mapping_not_executable":
            "The mapping uses a form the executor cannot evaluate; use whole, pointer, or literal mappings."
        case "capability_contract_incomplete":
            "Choose a capability, version, input mapping, and output schema."
        case "llm_contract_incomplete":
            "Set the model class, instructions, prompt mapping, output schema, and limits."
        case "subflow_contract_incomplete":
            "Pick a published child workflow revision and map its inputs."
        case "storage_write_not_executable":
            "Set the storage scope, key mapping, and value mapping."
        case "match_policy_not_executable":
            "Add at least one case with an evaluable condition and a default."
        case "join_policy_not_executable":
            "Set the join policy and threshold to match the incoming branches."
        case "decision_condition_not_executable":
            "Write the condition with exists, equals, or another supported test."
        case "reconciliation_contract_incomplete":
            "Set the probe mapping, attempts, and delay for reconciliation."
        case "human_review_contract_incomplete":
            "Set the review prompt, options, and expiry."
        case "connector_contract_incomplete":
            "Choose the connector, action, and input mapping for this effect."
        case "artifact_contract_incomplete":
            "Set the artifact kind and content mapping."
        case "cancel_reason_not_executable":
            "Give the cancellation a reason mapping."
        case "error_mapping_not_executable":
            "Give the failure an error mapping."
        case "node_type_not_executable":
            "The executor does not run this node type yet."
        default:
            "The compiler reported \(condition.replacingOccurrences(of: "_", with: " "))."
        }
    }
}

public struct DesktopWorkflowNodeTypeMigration: Codable, Equatable, Sendable {
    public var fromTypeVersion: UInt32
    public var migrationID: String
}

public enum DesktopWorkflowDynamicPortRule: String, Codable, Sendable {
    case matchCases
    case parallelBranches
}

public struct DesktopWorkflowNodePortTemplate: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowPortID
    public var direction: DesktopWorkflowGraphPortDirection
    public var cardinality: DesktopWorkflowGraphPortCardinality
    public var schemaRef: String
    public var required: Bool

    static func define(
        _ id: String,
        direction: DesktopWorkflowGraphPortDirection,
        cardinality: DesktopWorkflowGraphPortCardinality = .one,
        schemaRef: String,
        required: Bool = true
    ) throws -> Self {
        Self(
            id: try DesktopWorkflowPortID(id),
            direction: direction,
            cardinality: cardinality,
            schemaRef: schemaRef,
            required: required
        )
    }
}

public struct DesktopWorkflowNodeTypeRegistration: Codable, Equatable, Sendable {
    public var type: String
    public var typeVersion: UInt32
    public var configurationSchemaRef: String
    public var availability: DesktopWorkflowNodeExecutionAvailability
    public var staticPorts: [DesktopWorkflowNodePortTemplate]
    public var dynamicPortRule: DesktopWorkflowDynamicPortRule?
    public var migrations: [DesktopWorkflowNodeTypeMigration]
}

public enum DesktopWorkflowNodeRegistryError: Error, Equatable, LocalizedError {
    case duplicateTypeVersion
    case unknownTypeVersion(type: String, version: UInt32)
    case invalidDynamicPortConfiguration(type: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTypeVersion:
            "The node registry contains a duplicate type and version."
        case let .unknownTypeVersion(type, version):
            "Node type \(type) version \(version) is not registered."
        case let .invalidDynamicPortConfiguration(type):
            "Node type \(type) has invalid dynamic port configuration."
        }
    }
}

public struct DesktopWorkflowNodeRegistry: Sendable {
    public static let dataSchemaRef = "dev.kaname.workflow.data/v1"
    public static let errorSchemaRef = "dev.kaname.workflow.error/v1"
    public static let controlSchemaRef = "dev.kaname.workflow.control/v1"
    public static let anySchemaRef = "dev.kaname.workflow.any/v1"

    public let registrations: [DesktopWorkflowNodeTypeRegistration]
    private let registrationsByKey: [String: DesktopWorkflowNodeTypeRegistration]

    public init(registrations: [DesktopWorkflowNodeTypeRegistration]) throws {
        let pairs = registrations.map { (Self.key(type: $0.type, version: $0.typeVersion), $0) }
        guard Dictionary(grouping: pairs, by: \.0).values.allSatisfy({ $0.count == 1 }) else {
            throw DesktopWorkflowNodeRegistryError.duplicateTypeVersion
        }
        self.registrations = registrations.sorted {
            ($0.type, $0.typeVersion) < ($1.type, $1.typeVersion)
        }
        registrationsByKey = Dictionary(uniqueKeysWithValues: pairs)
    }

    public func registration(
        type: String,
        version: UInt32
    ) throws -> DesktopWorkflowNodeTypeRegistration {
        guard let registration = registrationsByKey[Self.key(type: type, version: version)] else {
            throw DesktopWorkflowNodeRegistryError.unknownTypeVersion(type: type, version: version)
        }
        return registration
    }

    public func ports(
        for node: DesktopWorkflowGraphNodeIdentity
    ) throws -> [DesktopWorkflowGraphPortIdentity] {
        let registration = try registration(type: node.type, version: node.typeVersion)
        var templates = registration.staticPorts
        if let rule = registration.dynamicPortRule {
            templates.append(contentsOf: try dynamicPorts(rule: rule, node: node))
        }
        guard Set(templates.map(\.id)).count == templates.count else {
            throw DesktopWorkflowNodeRegistryError.invalidDynamicPortConfiguration(type: node.type)
        }
        var resolved: [DesktopWorkflowGraphPortIdentity] = []
        for template in templates {
            resolved.append(.define(
                nodeID: node.id,
                id: template.id,
                direction: template.direction,
                cardinality: template.cardinality,
                schemaRef: template.schemaRef,
                required: template.required
            ))
        }
        return resolved
    }

    public static func builtInSchemaOnlyV1() throws -> Self {
        let configurationDefinitions = [
            "trigger.manual": "manual", "trigger.event": "event", "trigger.schedule": "schedule",
            "data.map": "map", "data.validate": "validate", "data.case-context": "empty",
            "data.register-artifact": "registerArtifact",
            "storage.read": "storageRead", "storage.write": "storageWrite", "storage.promote": "storagePromote",
            "compute.capability": "capability", "compute.llm": "llm", "control.decision": "decision",
            "control.match": "match", "control.for-each": "forEach", "control.parallel": "parallel",
            "control.join": "join", "control.retry": "retry", "control.reconcile": "reconcile",
            "control.wait": "wait", "control.subflow": "subflow", "control.human-review": "humanReview",
            "effect.connector": "connectorEffect", "terminal.complete": "complete",
            "terminal.fail": "fail", "terminal.cancel": "cancel",
        ]
        let records = try configurationDefinitions.map { type, definition in
            let profile = try portProfile(for: type)
            return DesktopWorkflowNodeTypeRegistration(
                type: type,
                typeVersion: 1,
                configurationSchemaRef: "node-config.schema.json#/$defs/\(definition)",
                availability: .schemaOnly,
                staticPorts: profile.staticPorts,
                dynamicPortRule: profile.dynamicRule,
                migrations: []
            )
        }
        return try Self(registrations: records)
    }

    private struct PortProfile {
        let staticPorts: [DesktopWorkflowNodePortTemplate]
        let dynamicRule: DesktopWorkflowDynamicPortRule?
    }

    private static func portProfile(for type: String) throws -> PortProfile {
        func port(
            _ id: String,
            _ direction: DesktopWorkflowGraphPortDirection,
            _ schema: String,
            required: Bool = true,
            cardinality: DesktopWorkflowGraphPortCardinality = .one
        ) throws -> DesktopWorkflowNodePortTemplate {
            try .define(
                id,
                direction: direction,
                cardinality: cardinality,
                schemaRef: schema,
                required: required
            )
        }
        if type.hasPrefix("trigger.") {
            return try PortProfile(
                staticPorts: [port("success", .output, dataSchemaRef)],
                dynamicRule: nil
            )
        }
        if type.hasPrefix("terminal.") {
            let schema = switch type {
            case "terminal.fail": errorSchemaRef
            case "terminal.cancel": anySchemaRef
            default: dataSchemaRef
            }
            return try PortProfile(
                staticPorts: [port("input", .input, schema)],
                dynamicRule: nil
            )
        }
        switch type {
        case "control.match":
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: .matchCases
            )
        case "control.parallel":
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: .parallelBranches
            )
        case "control.decision":
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("matched", .output, dataSchemaRef),
                    port("not-matched", .output, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: nil
            )
        case "control.join":
            return try PortProfile(
                staticPorts: [
                    port("branches", .input, dataSchemaRef, cardinality: .many),
                    port("success", .output, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: nil
            )
        case "control.retry":
            return try PortProfile(
                staticPorts: [
                    port("error", .input, errorSchemaRef),
                    port("retry", .output, dataSchemaRef),
                    port("exhausted", .output, errorSchemaRef),
                ],
                dynamicRule: nil
            )
        case "control.reconcile":
            return try PortProfile(
                staticPorts: [
                    port("unknown", .input, errorSchemaRef),
                    port("success", .output, dataSchemaRef),
                    port("failure", .output, errorSchemaRef),
                    port("still-unknown", .output, errorSchemaRef),
                ],
                dynamicRule: nil
            )
        case "control.wait":
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("resumed", .output, dataSchemaRef),
                    port("expired", .output, dataSchemaRef, required: false),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: nil
            )
        case "control.for-each":
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("item", .output, dataSchemaRef, cardinality: .many),
                    port("success", .output, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: nil
            )
        default:
            return try PortProfile(
                staticPorts: [
                    port("input", .input, dataSchemaRef),
                    port("success", .output, dataSchemaRef),
                    port("error", .output, errorSchemaRef, required: false),
                ],
                dynamicRule: nil
            )
        }
    }

    private func dynamicPorts(
        rule: DesktopWorkflowDynamicPortRule,
        node: DesktopWorkflowGraphNodeIdentity
    ) throws -> [DesktopWorkflowNodePortTemplate] {
        guard case let .object(configuration) = node.configuration else {
            throw DesktopWorkflowNodeRegistryError.invalidDynamicPortConfiguration(type: node.type)
        }
        let values: [DesktopWorkflowJSONValue]
        switch rule {
        case .matchCases:
            guard case let .array(cases)? = configuration["cases"] else {
                throw DesktopWorkflowNodeRegistryError.invalidDynamicPortConfiguration(type: node.type)
            }
            values = cases + (configuration["otherwise"].map { [$0] } ?? [])
        case .parallelBranches:
            guard case let .array(branches)? = configuration["branches"] else {
                throw DesktopWorkflowNodeRegistryError.invalidDynamicPortConfiguration(type: node.type)
            }
            values = branches
        }
        return try values.map { value in
            guard case let .object(port) = value,
                  case let .string(rawID)? = port["id"] else {
                throw DesktopWorkflowNodeRegistryError.invalidDynamicPortConfiguration(type: node.type)
            }
            let caseID = try DesktopWorkflowCaseOutputID(rawID)
            return try .define(
                DesktopWorkflowPortID.matchCase(caseID).rawValue,
                direction: .output,
                schemaRef: Self.dataSchemaRef
            )
        }
    }

    private static func key(type: String, version: UInt32) -> String {
        "\(type)@\(version)"
    }
}

public enum DesktopWorkflowNodeRegistryValidation {
    public static func diagnostics(
        graph: DesktopWorkflowGraphIdentityDocument,
        registry: DesktopWorkflowNodeRegistry
    ) -> [DesktopWorkflowGraphIdentityDiagnostic] {
        var diagnostics: [DesktopWorkflowGraphIdentityDiagnostic] = []
        var expectedByNode: [DesktopWorkflowNodeID: [DesktopWorkflowGraphPortIdentity]] = [:]
        for (index, node) in graph.nodes.enumerated() {
            do {
                expectedByNode[node.id] = try registry.ports(for: node)
            } catch DesktopWorkflowNodeRegistryError.unknownTypeVersion {
                diagnostics.append(issue(
                    "registry.node.unknown-version",
                    "/nodes/\(index)/typeVersion",
                    "Node type and version are not registered."
                ))
            } catch {
                diagnostics.append(issue(
                    "registry.node.dynamic-ports-invalid",
                    "/nodes/\(index)/config",
                    "Dynamic port configuration is invalid."
                ))
            }
        }
        for (nodeID, expected) in expectedByNode {
            let declared = graph.ports.filter { $0.nodeID == nodeID }
            let declaredByID = declared.reduce(
                into: [DesktopWorkflowPortID: DesktopWorkflowGraphPortIdentity]()
            ) { result, port in
                if result[port.id] == nil {
                    result[port.id] = port
                }
            }
            let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
            for port in expected where declaredByID[port.id] == nil {
                diagnostics.append(issue(
                    "registry.port.missing",
                    "/ports",
                    "Registry port \(port.id.rawValue) is missing from the compiled port set."
                ))
            }
            for port in declared where expectedByID[port.id] == nil {
                diagnostics.append(issue(
                    "registry.port.orphan",
                    "/ports",
                    "Port \(port.id.rawValue) is not declared by the node registry."
                ))
            }
            for port in expected where declaredByID[port.id].map({ $0 != port }) == true {
                diagnostics.append(issue(
                    "registry.port.contract-mismatch",
                    "/ports",
                    "Port \(port.id.rawValue) does not match its registry contract."
                ))
            }
            for port in expected where port.direction == .input && port.required {
                let connected = graph.edges.contains {
                    $0.to.nodeID == nodeID && $0.to.portID == port.id
                }
                if !connected {
                    diagnostics.append(issue(
                        "registry.input.required-missing",
                        "/ports",
                        "Required input \(port.id.rawValue) is not connected."
                    ))
                }
            }
        }
        let ports = graph.ports.reduce(
            into: [PortKey: DesktopWorkflowGraphPortIdentity]()
        ) { result, port in
            let key = PortKey(nodeID: port.nodeID, portID: port.id)
            if result[key] == nil {
                result[key] = port
            }
        }
        for (index, edge) in graph.edges.enumerated() {
            guard let source = ports[PortKey(nodeID: edge.from.nodeID, portID: edge.from.portID)],
                  let destination = ports[PortKey(nodeID: edge.to.nodeID, portID: edge.to.portID)] else {
                continue
            }
            if source.direction != .output || destination.direction != .input {
                diagnostics.append(issue(
                    "registry.edge.direction-invalid",
                    "/edges/\(index)",
                    "Edges must connect an output port to an input port."
                ))
            }
            if source.schemaRef != destination.schemaRef
                && destination.schemaRef != DesktopWorkflowNodeRegistry.anySchemaRef {
                diagnostics.append(issue(
                    "registry.mapping.illegal-coercion",
                    "/edges/\(index)/mappingID",
                    "The mapping cannot coerce the source schema into the destination schema."
                ))
            }
            if source.cardinality == .many && destination.cardinality == .one {
                diagnostics.append(issue(
                    "registry.mapping.cardinality-incompatible",
                    "/edges/\(index)/mappingID",
                    "A many-valued output requires an explicitly many-valued input."
                ))
            }
        }
        return diagnostics.sorted { ($0.pointer, $0.code, $0.message) < ($1.pointer, $1.code, $1.message) }
    }

    private struct PortKey: Hashable {
        let nodeID: DesktopWorkflowNodeID
        let portID: DesktopWorkflowPortID
    }

    private static func issue(
        _ code: String,
        _ pointer: String,
        _ message: String
    ) -> DesktopWorkflowGraphIdentityDiagnostic {
        .init(code: code, severity: .error, pointer: pointer, message: message)
    }
}
