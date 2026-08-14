import Foundation
import KanameLocalCore
import KanameProtocol

public protocol DesktopWorkflowRunInspectionTransport: Sendable {
    func inspectWorkflowRuns(
        _ request: Kaname_V1_WorkflowRunInspectionQuery,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_WorkflowRunInspectionResponse
}

extension LocalCoreRunner: DesktopWorkflowRunInspectionTransport {}

public enum DesktopWorkflowRunInspectionError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedResponse
}

public struct DesktopWorkflowProjectedValue: Equatable, Sendable {
    public let id: String
    public let contentType: String
    public let byteCount: UInt64
    public let sha256: String
    public let inlineCanonicalJSON: Data?
    public let storageReferenceID: String?
    public let availability: String
    public let storage: DesktopWorkflowStorageValueMetadata?

    public var absenceExplanation: String? {
        guard inlineCanonicalJSON == nil else { return nil }
        if availability == "scoped_handle" {
            return "The value is retained behind an opaque scoped handle. Its host storage path is never exposed."
        }
        return availability == "storage_unavailable"
            ? "The value metadata is retained, but its stored content is not available in this history view."
            : "The value content was not retained."
    }
}

public struct DesktopWorkflowStorageValueMetadata: Equatable, Sendable {
    public let handleID: String?
    public let scope: String
    public let logicalKey: String
    public let versionID: String?
    public let revision: UInt64?
    public let previousVersionID: String?
    public let byteCount: UInt64
    public let result: String
}

public struct DesktopWorkflowProjectedAttempt: Identifiable, Equatable, Sendable {
    public let id: String
    public let nodeID: String
    public let number: UInt32
    public let status: String
    public let outcome: String?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let emissionIDs: [String]
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let startedStorePosition: UInt64
    public let settledStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedNode: Identifiable, Equatable, Sendable {
    public var id: String { nodeID }
    public let nodeID: String
    public let status: String
    public let latestAttemptID: String
    public let latestAttemptNumber: UInt32
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let lastStorePosition: UInt64
}

public struct DesktopWorkflowProjectedEmission: Identifiable, Equatable, Sendable {
    public let id: String
    public let attemptID: String
    public let nodeID: String
    public let portID: String
    public let value: DesktopWorkflowProjectedValue
    public let eventID: String
    public let emittedAtUnixMillis: Int64
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedEdge: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let edgeID: String
    public let emissionID: String
    public let targetNodeID: String
    public let targetPortID: String
    public let state: String
    public let checkpointedAtUnixMillis: Int64
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedMatchTrace: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let attemptID: String
    public let nodeID: String
    public let inputValueID: String
    public let evaluatedCaseIDs: [String]
    public let matchedCaseIDs: [String]
    public let emittedPortIDs: [String]
    public let trace: DesktopWorkflowProjectedValue
    public let recordedAtUnixMillis: Int64
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedEvent: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let kind: String
    public let storePosition: UInt64
    public let streamSequence: UInt64
    public let occurredAtUnixMillis: Int64
}

public struct DesktopDurableWorkflowRun: Identifiable, Equatable, Sendable {
    public var id: String { runID }
    public let runID: String
    public let workflowID: String
    public let revisionID: String
    public let packageDigest: String
    public let status: String
    public let outcome: String?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let createdAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let firstStorePosition: UInt64
    public let lastStorePosition: UInt64
    public let attempts: [DesktopWorkflowProjectedAttempt]
    public let nodes: [DesktopWorkflowProjectedNode]
    public let emissions: [DesktopWorkflowProjectedEmission]
    public let edges: [DesktopWorkflowProjectedEdge]
    public let matchTraces: [DesktopWorkflowProjectedMatchTrace]
    public let events: [DesktopWorkflowProjectedEvent]

    public func attempt(for nodeID: String) -> DesktopWorkflowProjectedAttempt? {
        attempts.filter { $0.nodeID == nodeID }.max { $0.number < $1.number }
    }

    public func inputs(for nodeID: String) -> [DesktopWorkflowProjectedEmission] {
        let emissionIDs = Set(edges.filter {
            $0.targetNodeID == nodeID && $0.state == "admitted"
        }.map(\.emissionID))
        return emissions.filter { emissionIDs.contains($0.id) }
    }

    public func outputs(for nodeID: String) -> [DesktopWorkflowProjectedEmission] {
        emissions.filter { $0.nodeID == nodeID }
    }

    public func traces(for nodeID: String) -> [DesktopWorkflowProjectedMatchTrace] {
        matchTraces.filter { $0.nodeID == nodeID }
    }
}

public struct DesktopWorkflowRunInspectionPage: Equatable, Sendable {
    public let projectionHighWaterMark: UInt64
    public let runs: [DesktopDurableWorkflowRun]
    public let absenceReason: String?
}

public struct DesktopWorkflowHistoricalNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let type: String
    public let configurationJSON: Data
    public let x: Double
    public let y: Double
}

public struct DesktopWorkflowHistoricalEdge: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceNodeID: String
    public let sourcePortID: String
    public let targetNodeID: String
    public let targetPortID: String
}

public struct DesktopWorkflowHistoricalGraph: Equatable, Sendable {
    public let name: String
    public let nodes: [DesktopWorkflowHistoricalNode]
    public let edges: [DesktopWorkflowHistoricalEdge]
}

public struct DesktopWorkflowRunSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { run.id }
    public let run: DesktopDurableWorkflowRun
    public let revision: DesktopWorkflowV2RevisionContent?
    public let graph: DesktopWorkflowHistoricalGraph?
    public let revisionAbsenceReason: String?
}

public struct DesktopWorkflowRunHistorySnapshot: Equatable, Sendable {
    public let projectionHighWaterMark: UInt64
    public let runs: [DesktopWorkflowRunSnapshot]
    public let absenceReason: String?
}

public struct DesktopWorkflowRunHistoryLoader: Sendable {
    private let inspection: DesktopWorkflowRunInspectionClient
    private let library: DesktopWorkflowV2LibraryClient

    public init(
        inspection: DesktopWorkflowRunInspectionClient,
        library: DesktopWorkflowV2LibraryClient
    ) {
        self.inspection = inspection
        self.library = library
    }

    public func load(limit: UInt32 = 30, requestID: String) async throws -> DesktopWorkflowRunHistorySnapshot {
        let page = try await inspection.runs(limit: limit, requestID: requestID)
        var revisions: [String: DesktopWorkflowV2RevisionContent?] = [:]
        var snapshots: [DesktopWorkflowRunSnapshot] = []
        for (index, run) in page.runs.enumerated() {
            let content: DesktopWorkflowV2RevisionContent?
            if let cached = revisions[run.revisionID] {
                content = cached
            } else {
                content = try? await library.revision(
                    revisionID: run.revisionID,
                    requestID: "\(requestID):revision:\(index)"
                )
                revisions[run.revisionID] = content
            }
            let valid = content.flatMap { revision in
                revision.summary.workflowID == run.workflowID
                    && revision.summary.revisionID == run.revisionID
                    && revision.summary.packageDigest == run.packageDigest ? revision : nil
            }
            snapshots.append(DesktopWorkflowRunSnapshot(
                run: run,
                revision: valid,
                graph: valid.flatMap(Self.historicalGraph),
                revisionAbsenceReason: valid == nil
                    ? "The immutable workflow revision for this run is unavailable or failed its identity check."
                    : nil
            ))
        }
        return DesktopWorkflowRunHistorySnapshot(
            projectionHighWaterMark: page.projectionHighWaterMark,
            runs: snapshots,
            absenceReason: page.absenceReason
        )
    }

    private static func historicalGraph(
        _ revision: DesktopWorkflowV2RevisionContent
    ) -> DesktopWorkflowHistoricalGraph? {
        guard let root = try? JSONSerialization.jsonObject(with: revision.workflowJSON) as? [String: Any],
              let graph = root["graph"] as? [String: Any],
              let rawNodes = graph["nodes"] as? [[String: Any]],
              let rawEdges = graph["edges"] as? [[String: Any]] else { return nil }
        let positions = layoutPositions(revision.layoutJSON)
        let nodes = rawNodes.compactMap { node -> DesktopWorkflowHistoricalNode? in
            guard let id = node["id"] as? String,
                  let type = node["type"] as? String else { return nil }
            let configuration = node["config"] ?? [:]
            guard JSONSerialization.isValidJSONObject(configuration),
                  let configurationJSON = try? JSONSerialization.data(
                    withJSONObject: configuration,
                    options: [.sortedKeys]
                  ) else { return nil }
            let position = positions[id] ?? (Double(nodesFallbackIndex(id, in: rawNodes)) * 280 + 80, 110)
            return DesktopWorkflowHistoricalNode(
                id: id,
                key: node["key"] as? String ?? id,
                name: node["name"] as? String ?? type,
                type: type,
                configurationJSON: configurationJSON,
                x: position.0,
                y: position.1
            )
        }
        let edges = rawEdges.compactMap { edge -> DesktopWorkflowHistoricalEdge? in
            guard let id = edge["id"] as? String,
                  let from = edge["from"] as? [String: Any],
                  let to = edge["to"] as? [String: Any],
                  let sourceNodeID = from["nodeId"] as? String,
                  let sourcePortID = from["portId"] as? String,
                  let targetNodeID = to["nodeId"] as? String,
                  let targetPortID = to["portId"] as? String else { return nil }
            return DesktopWorkflowHistoricalEdge(
                id: id,
                sourceNodeID: sourceNodeID,
                sourcePortID: sourcePortID,
                targetNodeID: targetNodeID,
                targetPortID: targetPortID
            )
        }
        guard nodes.count == rawNodes.count, edges.count == rawEdges.count else { return nil }
        return DesktopWorkflowHistoricalGraph(
            name: root["name"] as? String ?? "Workflow",
            nodes: nodes,
            edges: edges
        )
    }

    private static func layoutPositions(_ data: Data) -> [String: (Double, Double)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let rawNodes: [[String: Any]]
        if let object = root as? [String: Any] {
            rawNodes = object["nodes"] as? [[String: Any]] ?? []
        } else {
            rawNodes = root as? [[String: Any]] ?? []
        }
        return Dictionary(uniqueKeysWithValues: rawNodes.compactMap { node in
            guard let id = (node["nodeId"] ?? node["id"]) as? String,
                  let x = numeric(node["x"]), let y = numeric(node["y"]) else { return nil }
            return (id, (x, y))
        })
    }

    private static func numeric(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func nodesFallbackIndex(_ id: String, in nodes: [[String: Any]]) -> Int {
        nodes.firstIndex { $0["id"] as? String == id } ?? 0
    }
}

public struct DesktopWorkflowRunInspectionClient: Sendable {
    private let transport: any DesktopWorkflowRunInspectionTransport
    private let timeout: TimeInterval

    public init(
        transport: any DesktopWorkflowRunInspectionTransport,
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func runs(
        workflowID: String? = nil,
        runID: String? = nil,
        limit: UInt32 = 30,
        requestID: String
    ) async throws -> DesktopWorkflowRunInspectionPage {
        guard !requestID.isEmpty,
              limit > 0, limit <= 100,
              workflowID?.count ?? 0 <= 128,
              runID?.count ?? 0 <= 128 else {
            throw DesktopWorkflowRunInspectionError.invalidRequest
        }
        var request = Kaname_V1_WorkflowRunInspectionQuery()
        request.schemaVersion.major = 1
        request.requestID = requestID
        request.workflowID = workflowID ?? ""
        request.runID = runID ?? ""
        request.limit = limit
        let response = try await transport.inspectWorkflowRuns(request, timeout: timeout)
        guard response.schemaVersion.major == 1,
              response.requestID == requestID else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowRunInspectionPage(
            projectionHighWaterMark: response.projectionHighWaterMark,
            runs: try response.runs.map(Self.run),
            absenceReason: response.absenceReason.nilIfEmpty
        )
    }

    private static func run(_ run: Kaname_V1_WorkflowProjectedRun) throws -> DesktopDurableWorkflowRun {
        guard !run.runID.isEmpty,
              !run.workflowID.isEmpty,
              !run.revisionID.isEmpty,
              run.packageDigest.count == 64,
              !run.status.isEmpty,
              run.firstStorePosition > 0,
              run.lastStorePosition >= run.firstStorePosition else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopDurableWorkflowRun(
            runID: run.runID,
            workflowID: run.workflowID,
            revisionID: run.revisionID,
            packageDigest: run.packageDigest,
            status: run.status,
            outcome: run.outcome.nilIfEmpty,
            errorCode: run.errorCode.nilIfEmpty,
            error: try run.hasError ? value(run.error) : nil,
            createdAtUnixMillis: run.createdAtUnixMillis,
            settledAtUnixMillis: run.settledAtUnixMillis > 0 ? run.settledAtUnixMillis : nil,
            firstStorePosition: run.firstStorePosition,
            lastStorePosition: run.lastStorePosition,
            attempts: try run.attempts.map(attempt),
            nodes: try run.nodes.map(node),
            emissions: try run.emissions.map(emission),
            edges: try run.edges.map(edge),
            matchTraces: try run.matchTraces.map(matchTrace),
            events: try run.events.map(event)
        )
    }

    private static func value(_ value: Kaname_V1_WorkflowProjectedValue) throws -> DesktopWorkflowProjectedValue {
        guard !value.valueID.isEmpty,
              !value.contentType.isEmpty,
              value.sha256.count == 64,
              !value.availability.isEmpty else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedValue(
            id: value.valueID,
            contentType: value.contentType,
            byteCount: value.byteCount,
            sha256: value.sha256,
            inlineCanonicalJSON: value.inlineCanonicalJson.isEmpty ? nil : value.inlineCanonicalJson,
            storageReferenceID: value.storageReferenceID.nilIfEmpty,
            availability: value.availability,
            storage: try value.hasStorage ? storage(value.storage) : nil
        )
    }

    private static func storage(
        _ storage: Kaname_V1_WorkflowStorageValueMetadata
    ) throws -> DesktopWorkflowStorageValueMetadata {
        guard !storage.scope.isEmpty,
              !storage.logicalKey.isEmpty,
              !storage.result.isEmpty else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let summary = storage.result == "listed" || storage.result == "missing"
        guard summary || (!storage.handleID.isEmpty && !storage.versionID.isEmpty && storage.revision > 0) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowStorageValueMetadata(
            handleID: storage.handleID.nilIfEmpty,
            scope: storage.scope,
            logicalKey: storage.logicalKey,
            versionID: storage.versionID.nilIfEmpty,
            revision: storage.revision > 0 ? storage.revision : nil,
            previousVersionID: storage.previousVersionID.nilIfEmpty,
            byteCount: storage.byteCount,
            result: storage.result
        )
    }

    private static func attempt(_ item: Kaname_V1_WorkflowProjectedAttempt) throws -> DesktopWorkflowProjectedAttempt {
        guard !item.attemptID.isEmpty, !item.nodeID.isEmpty, item.attemptNumber > 0,
              !item.status.isEmpty, item.startedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedAttempt(
            id: item.attemptID, nodeID: item.nodeID, number: item.attemptNumber,
            status: item.status, outcome: item.outcome.nilIfEmpty,
            errorCode: item.errorCode.nilIfEmpty, error: try item.hasError ? value(item.error) : nil,
            emissionIDs: item.emissionIds, startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            startedStorePosition: item.startedStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil
        )
    }

    private static func node(_ item: Kaname_V1_WorkflowProjectedNodeState) throws -> DesktopWorkflowProjectedNode {
        guard !item.nodeID.isEmpty, !item.status.isEmpty, !item.latestAttemptID.isEmpty,
              item.latestAttemptNumber > 0, item.lastStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedNode(
            nodeID: item.nodeID, status: item.status, latestAttemptID: item.latestAttemptID,
            latestAttemptNumber: item.latestAttemptNumber,
            startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            lastStorePosition: item.lastStorePosition
        )
    }

    private static func emission(_ item: Kaname_V1_WorkflowProjectedEmission) throws -> DesktopWorkflowProjectedEmission {
        guard !item.emissionID.isEmpty, !item.attemptID.isEmpty, !item.nodeID.isEmpty,
              !item.portID.isEmpty, item.hasValue, !item.eventID.isEmpty, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEmission(
            id: item.emissionID, attemptID: item.attemptID, nodeID: item.nodeID,
            portID: item.portID, value: try value(item.value), eventID: item.eventID,
            emittedAtUnixMillis: item.emittedAtUnixMillis, storePosition: item.storePosition
        )
    }

    private static func edge(_ item: Kaname_V1_WorkflowProjectedEdgeCheckpoint) throws -> DesktopWorkflowProjectedEdge {
        guard !item.eventID.isEmpty, !item.edgeID.isEmpty, !item.emissionID.isEmpty,
              !item.targetNodeID.isEmpty, !item.targetPortID.isEmpty,
              !item.state.isEmpty, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEdge(
            eventID: item.eventID, edgeID: item.edgeID, emissionID: item.emissionID,
            targetNodeID: item.targetNodeID, targetPortID: item.targetPortID,
            state: item.state, checkpointedAtUnixMillis: item.checkpointedAtUnixMillis,
            storePosition: item.storePosition
        )
    }

    private static func matchTrace(_ item: Kaname_V1_WorkflowProjectedMatchTrace) throws -> DesktopWorkflowProjectedMatchTrace {
        guard !item.eventID.isEmpty, !item.attemptID.isEmpty, !item.nodeID.isEmpty,
              !item.inputValueID.isEmpty, item.hasTrace, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedMatchTrace(
            eventID: item.eventID, attemptID: item.attemptID, nodeID: item.nodeID,
            inputValueID: item.inputValueID, evaluatedCaseIDs: item.evaluatedCaseIds,
            matchedCaseIDs: item.matchedCaseIds, emittedPortIDs: item.emittedPortIds,
            trace: try value(item.trace), recordedAtUnixMillis: item.recordedAtUnixMillis,
            storePosition: item.storePosition
        )
    }

    private static func event(_ item: Kaname_V1_WorkflowProjectedEventReference) throws -> DesktopWorkflowProjectedEvent {
        guard !item.eventID.isEmpty, !item.kind.isEmpty,
              item.storePosition > 0, item.streamSequence > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEvent(
            eventID: item.eventID, kind: item.kind, storePosition: item.storePosition,
            streamSequence: item.streamSequence, occurredAtUnixMillis: item.occurredAtUnixMillis
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
