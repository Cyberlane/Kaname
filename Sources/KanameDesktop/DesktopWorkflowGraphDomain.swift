import CryptoKit
import Foundation

public protocol DesktopWorkflowGraphUUIDIdentityTag: Sendable {
    static var identityKind: String { get }
}

public struct DesktopWorkflowGraphUUIDIdentity<Tag: DesktopWorkflowGraphUUIDIdentityTag>:
    Codable, Comparable, Hashable, Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isUUIDv7(rawValue) else {
            throw DesktopWorkflowGraphIdentityError.invalidUUIDv7(
                kind: Tag.identityKind,
                value: rawValue
            )
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self = try DesktopWorkflowGraphIdentityDecoding.decode(
            from: decoder,
            expectation: "a lowercase UUIDv7 for \(Tag.identityKind)",
            transform: { try Self($0) }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isUUIDv7(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36,
              scalars[8] == "-", scalars[13] == "-", scalars[18] == "-", scalars[23] == "-",
              scalars[14] == "7", "89ab".unicodeScalars.contains(scalars[19]) else {
            return false
        }
        return scalars.enumerated().allSatisfy { index, scalar in
            [8, 13, 18, 23].contains(index) || "0123456789abcdef".unicodeScalars.contains(scalar)
        }
    }
}

public enum DesktopWorkflowIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "workflow"
}

public enum DesktopWorkflowNodeIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "node"
}

public enum DesktopWorkflowEdgeIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "edge"
}

public enum DesktopWorkflowCaseOutputIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "case-output"
}

public enum DesktopWorkflowEntrypointIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "entrypoint"
}

public enum DesktopWorkflowMappingIDTag: DesktopWorkflowGraphUUIDIdentityTag {
    public static let identityKind = "mapping"
}

public typealias DesktopWorkflowID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowIDTag>
public typealias DesktopWorkflowNodeID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowNodeIDTag>
public typealias DesktopWorkflowEdgeID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowEdgeIDTag>
public typealias DesktopWorkflowCaseOutputID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowCaseOutputIDTag>
public typealias DesktopWorkflowEntrypointID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowEntrypointIDTag>
public typealias DesktopWorkflowMappingID = DesktopWorkflowGraphUUIDIdentity<DesktopWorkflowMappingIDTag>

public struct DesktopWorkflowPortID: Codable, Comparable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.range(
            of: #"^[a-z][a-z0-9-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw DesktopWorkflowGraphIdentityError.invalidPortID(rawValue)
        }
        self.rawValue = rawValue
    }

    public static func matchCase(_ caseID: DesktopWorkflowCaseOutputID) throws -> Self {
        try Self("case-\(caseID.rawValue)")
    }

    public init(from decoder: any Decoder) throws {
        self = try DesktopWorkflowGraphIdentityDecoding.decode(
            from: decoder,
            expectation: "a stable lowercase port identifier",
            transform: { try Self($0) }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DesktopWorkflowGraphPortDirection: String, Codable, Sendable {
    case input
    case output
}

public struct DesktopWorkflowGraphNodeIdentity: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowNodeID
    public var key: String
    public var type: String
    public var typeVersion: UInt32
    public var configuration: DesktopWorkflowJSONValue

    public static func define(
        id: DesktopWorkflowNodeID,
        key: String,
        type: String,
        typeVersion: UInt32,
        configuration: DesktopWorkflowJSONValue
    ) -> Self {
        Self(id: id, key: key, type: type, typeVersion: typeVersion, configuration: configuration)
    }
}

public struct DesktopWorkflowGraphPortIdentity: Codable, Equatable, Sendable {
    public var nodeID: DesktopWorkflowNodeID
    public var id: DesktopWorkflowPortID
    public var direction: DesktopWorkflowGraphPortDirection
    public var schemaRef: String

    public static func define(
        nodeID: DesktopWorkflowNodeID,
        id: DesktopWorkflowPortID,
        direction: DesktopWorkflowGraphPortDirection,
        schemaRef: String
    ) -> Self {
        Self(nodeID: nodeID, id: id, direction: direction, schemaRef: schemaRef)
    }
}

public struct DesktopWorkflowGraphCaseOutputIdentity: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowCaseOutputID
    public var nodeID: DesktopWorkflowNodeID
    public var portID: DesktopWorkflowPortID
    public var key: String
    public var label: String

    public static func define(
        id: DesktopWorkflowCaseOutputID,
        nodeID: DesktopWorkflowNodeID,
        key: String,
        label: String
    ) throws -> Self {
        Self(id: id, nodeID: nodeID, portID: try .matchCase(id), key: key, label: label)
    }
}

public struct DesktopWorkflowGraphEntrypointIdentity: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowEntrypointID
    public var nodeID: DesktopWorkflowNodeID
    public var key: String?

    public static func define(
        id: DesktopWorkflowEntrypointID,
        nodeID: DesktopWorkflowNodeID,
        key: String? = nil
    ) -> Self {
        Self(id: id, nodeID: nodeID, key: key)
    }
}

public struct DesktopWorkflowGraphMappingIdentity: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowMappingID
    public var expression: DesktopWorkflowJSONValue

    public static func define(
        id: DesktopWorkflowMappingID,
        expression: DesktopWorkflowJSONValue
    ) -> Self {
        Self(id: id, expression: expression)
    }
}

public struct DesktopWorkflowGraphEndpointIdentity: Codable, Equatable, Sendable {
    public var nodeID: DesktopWorkflowNodeID
    public var portID: DesktopWorkflowPortID

    public static func define(nodeID: DesktopWorkflowNodeID, portID: DesktopWorkflowPortID) -> Self {
        Self(nodeID: nodeID, portID: portID)
    }
}

public struct DesktopWorkflowGraphEdgeIdentity: Codable, Equatable, Sendable {
    public var id: DesktopWorkflowEdgeID
    public var from: DesktopWorkflowGraphEndpointIdentity
    public var to: DesktopWorkflowGraphEndpointIdentity
    public var mappingID: DesktopWorkflowMappingID

    public static func define(
        id: DesktopWorkflowEdgeID,
        from: DesktopWorkflowGraphEndpointIdentity,
        to: DesktopWorkflowGraphEndpointIdentity,
        mappingID: DesktopWorkflowMappingID
    ) -> Self {
        Self(id: id, from: from, to: to, mappingID: mappingID)
    }
}

public struct DesktopWorkflowGraphIdentityDocument: Codable, Equatable, Sendable {
    public var workflowID: DesktopWorkflowID
    public var entrypoints: [DesktopWorkflowGraphEntrypointIdentity]
    public var nodes: [DesktopWorkflowGraphNodeIdentity]
    public var ports: [DesktopWorkflowGraphPortIdentity]
    public var caseOutputs: [DesktopWorkflowGraphCaseOutputIdentity]
    public var mappings: [DesktopWorkflowGraphMappingIdentity]
    public var edges: [DesktopWorkflowGraphEdgeIdentity]

    public static func define(
        workflowID: DesktopWorkflowID,
        entrypoints: [DesktopWorkflowGraphEntrypointIdentity],
        nodes: [DesktopWorkflowGraphNodeIdentity],
        ports: [DesktopWorkflowGraphPortIdentity],
        caseOutputs: [DesktopWorkflowGraphCaseOutputIdentity],
        mappings: [DesktopWorkflowGraphMappingIdentity],
        edges: [DesktopWorkflowGraphEdgeIdentity]
    ) -> Self {
        Self(
            workflowID: workflowID,
            entrypoints: entrypoints,
            nodes: nodes,
            ports: ports,
            caseOutputs: caseOutputs,
            mappings: mappings,
            edges: edges
        )
    }
}

public struct DesktopWorkflowGraphLayoutNode: Codable, Equatable, Sendable {
    public var nodeID: DesktopWorkflowNodeID
    public var x: Double
    public var y: Double

    public static func place(nodeID: DesktopWorkflowNodeID, x: Double, y: Double) -> Self {
        Self(nodeID: nodeID, x: x, y: y)
    }
}

public struct DesktopWorkflowGraphDomainSnapshot: Equatable, Sendable {
    public var graph: DesktopWorkflowGraphIdentityDocument
    public var layout: [DesktopWorkflowGraphLayoutNode]

    public static func assemble(
        graph: DesktopWorkflowGraphIdentityDocument,
        layout: [DesktopWorkflowGraphLayoutNode]
    ) -> Self {
        Self(graph: graph, layout: layout)
    }

    public func semanticIdentityData() throws -> Data {
        try DesktopWorkflowGraphIdentityCodec.canonicalSemanticData(graph)
    }

    public func semanticIdentityDigest() throws -> String {
        DesktopWorkflowGraphIdentityCodec.digest(try semanticIdentityData())
    }

    public func layoutIdentityData() throws -> Data {
        let normalized = layout.sorted { $0.nodeID < $1.nodeID }
        return try DesktopWorkflowGraphIdentityCodec.canonicalData(normalized)
    }
}

public enum DesktopWorkflowGraphIdentityDiagnosticSeverity: String, Codable, Sendable {
    case error
}

public struct DesktopWorkflowGraphIdentityDiagnostic: Codable, Equatable, Sendable {
    public var code: String
    public var severity: DesktopWorkflowGraphIdentityDiagnosticSeverity
    public var pointer: String
    public var message: String
}

public enum DesktopWorkflowGraphIdentityError: Error, Equatable, LocalizedError {
    case invalidUUIDv7(kind: String, value: String)
    case invalidPortID(String)
    case invalidGraph([DesktopWorkflowGraphIdentityDiagnostic])

    public var errorDescription: String? {
        switch self {
        case let .invalidUUIDv7(kind, _):
            "The \(kind) identity must be a lowercase UUIDv7."
        case .invalidPortID:
            "The port identity must be a stable lowercase slug."
        case .invalidGraph:
            "The workflow graph contains blocking identity diagnostics."
        }
    }
}

public enum DesktopWorkflowGraphIdentityCodec {
    public static func canonicalSemanticData(
        _ document: DesktopWorkflowGraphIdentityDocument
    ) throws -> Data {
        let diagnostics = DesktopWorkflowGraphIdentityValidation.diagnostics(document)
        guard diagnostics.isEmpty else {
            throw DesktopWorkflowGraphIdentityError.invalidGraph(diagnostics)
        }
        var normalized = document
        normalized.entrypoints.sort { $0.id < $1.id }
        normalized.nodes.sort { $0.id < $1.id }
        normalized.ports.sort {
            ($0.nodeID.rawValue, $0.id.rawValue) < ($1.nodeID.rawValue, $1.id.rawValue)
        }
        normalized.caseOutputs.sort { $0.id < $1.id }
        normalized.mappings.sort { $0.id < $1.id }
        normalized.edges.sort { $0.id < $1.id }
        return try canonicalData(normalized)
    }

    public static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        try DesktopWorkflowCanonicalJSON.encode(value)
    }
}

public enum DesktopWorkflowGraphIdentityValidation {
    public static func diagnostics(
        _ document: DesktopWorkflowGraphIdentityDocument
    ) -> [DesktopWorkflowGraphIdentityDiagnostic] {
        var diagnostics: [DesktopWorkflowGraphIdentityDiagnostic] = []
        appendDuplicates(document.entrypoints.map(\.id), kind: "entrypoint", to: &diagnostics)
        appendDuplicates(document.nodes.map(\.id), kind: "node", to: &diagnostics)
        appendDuplicates(document.edges.map(\.id), kind: "edge", to: &diagnostics)
        appendDuplicates(document.caseOutputs.map(\.id), kind: "case-output", to: &diagnostics)
        appendDuplicates(document.mappings.map(\.id), kind: "mapping", to: &diagnostics)
        appendDuplicateValues(
            document.nodes.map(\.key),
            code: "identity.node-key.duplicate",
            pointer: "/nodes",
            message: "Every readable node key must be unique within the workflow.",
            to: &diagnostics
        )

        let nodeIDs = Set(document.nodes.map(\.id))
        let mappingIDs = Set(document.mappings.map(\.id))
        let portKeys = Set(document.ports.map { PortKey(nodeID: $0.nodeID, portID: $0.id) })
        if portKeys.count != document.ports.count {
            diagnostics.append(issue(
                code: "identity.port.duplicate",
                pointer: "/ports",
                message: "Port identities must be unique within one node."
            ))
        }

        for (index, entrypoint) in document.entrypoints.enumerated() where !nodeIDs.contains(entrypoint.nodeID) {
            diagnostics.append(issue(
                code: "identity.entrypoint.node-missing",
                pointer: "/entrypoints/\(index)/nodeID",
                message: "Entrypoint references an unknown node identity."
            ))
        }
        for (index, port) in document.ports.enumerated() where !nodeIDs.contains(port.nodeID) {
            diagnostics.append(issue(
                code: "identity.port.node-missing",
                pointer: "/ports/\(index)/nodeID",
                message: "Port references an unknown node identity."
            ))
        }
        for (index, output) in document.caseOutputs.enumerated() {
            if !nodeIDs.contains(output.nodeID) {
                diagnostics.append(issue(
                    code: "identity.case-output.node-missing",
                    pointer: "/caseOutputs/\(index)/nodeID",
                    message: "Case output references an unknown node identity."
                ))
            }
            if (try? DesktopWorkflowPortID.matchCase(output.id)) != output.portID {
                diagnostics.append(issue(
                    code: "identity.case-output.port-unstable",
                    pointer: "/caseOutputs/\(index)/portID",
                    message: "A dynamic case port must be derived from its immutable case identity."
                ))
            }
        }
        for (index, edge) in document.edges.enumerated() {
            appendEndpointDiagnostics(
                edge.from,
                pointer: "/edges/\(index)/from",
                nodeIDs: nodeIDs,
                portKeys: portKeys,
                to: &diagnostics
            )
            appendEndpointDiagnostics(
                edge.to,
                pointer: "/edges/\(index)/to",
                nodeIDs: nodeIDs,
                portKeys: portKeys,
                to: &diagnostics
            )
            if !mappingIDs.contains(edge.mappingID) {
                diagnostics.append(issue(
                    code: "identity.edge.mapping-missing",
                    pointer: "/edges/\(index)/mappingID",
                    message: "Edge references an unknown mapping identity."
                ))
            }
        }
        return diagnostics.sorted { ($0.pointer, $0.code) < ($1.pointer, $1.code) }
    }

    public static func unstableIdentityDiagnostic(
        kind: String,
        value: String,
        pointer: String
    ) -> DesktopWorkflowGraphIdentityDiagnostic? {
        guard (try? identity(kind: kind, value: value)) == nil else { return nil }
        return issue(
            code: "identity.\(kind).unstable",
            pointer: pointer,
            message: "The \(kind) identity must be a lowercase UUIDv7 and cannot come from a label or array position."
        )
    }

    private struct PortKey: Hashable {
        let nodeID: DesktopWorkflowNodeID
        let portID: DesktopWorkflowPortID
    }

    private static func identity(kind: String, value: String) throws -> String {
        switch kind {
        case "workflow": return try DesktopWorkflowID(value).rawValue
        case "node": return try DesktopWorkflowNodeID(value).rawValue
        case "edge": return try DesktopWorkflowEdgeID(value).rawValue
        case "case-output": return try DesktopWorkflowCaseOutputID(value).rawValue
        case "entrypoint": return try DesktopWorkflowEntrypointID(value).rawValue
        case "mapping": return try DesktopWorkflowMappingID(value).rawValue
        default: throw DesktopWorkflowGraphIdentityError.invalidUUIDv7(kind: kind, value: value)
        }
    }

    private static func appendDuplicates<ID: Hashable>(
        _ values: [ID],
        kind: String,
        to diagnostics: inout [DesktopWorkflowGraphIdentityDiagnostic]
    ) {
        appendDuplicateValues(
            values,
            code: "identity.\(kind).duplicate",
            pointer: "/\(kind)s",
            message: "Every \(kind) identity must be unique.",
            to: &diagnostics
        )
    }

    private static func appendDuplicateValues<Value: Hashable>(
        _ values: [Value],
        code: String,
        pointer: String,
        message: String,
        to diagnostics: inout [DesktopWorkflowGraphIdentityDiagnostic]
    ) {
        guard Set(values).count != values.count else { return }
        diagnostics.append(issue(code: code, pointer: pointer, message: message))
    }

    private static func appendEndpointDiagnostics(
        _ endpoint: DesktopWorkflowGraphEndpointIdentity,
        pointer: String,
        nodeIDs: Set<DesktopWorkflowNodeID>,
        portKeys: Set<PortKey>,
        to diagnostics: inout [DesktopWorkflowGraphIdentityDiagnostic]
    ) {
        guard nodeIDs.contains(endpoint.nodeID) else {
            diagnostics.append(issue(
                code: "identity.edge.node-missing",
                pointer: pointer + "/nodeID",
                message: "Edge endpoint references an unknown node identity."
            ))
            return
        }
        guard portKeys.contains(PortKey(nodeID: endpoint.nodeID, portID: endpoint.portID)) else {
            diagnostics.append(issue(
                code: "identity.edge.port-missing",
                pointer: pointer + "/portID",
                message: "Edge endpoint references an unknown port identity on this node."
            ))
            return
        }
    }

    private static func issue(
        code: String,
        pointer: String,
        message: String
    ) -> DesktopWorkflowGraphIdentityDiagnostic {
        .init(code: code, severity: .error, pointer: pointer, message: message)
    }
}

private enum DesktopWorkflowGraphIdentityDecoding {
    static func decode<Value>(
        from decoder: any Decoder,
        expectation: String,
        transform: (String) throws -> Value
    ) throws -> Value {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            return try transform(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected \(expectation)."
            )
        }
    }
}
