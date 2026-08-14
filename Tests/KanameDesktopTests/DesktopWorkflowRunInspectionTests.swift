import Foundation
import KanameDesktop
import KanameProtocol
import Testing

@Suite("Durable workflow run inspection")
struct DesktopWorkflowRunInspectionTests {
    @Test("history loads each run's exact immutable revision after a newer revision exists")
    func exactHistoricalRevision() async throws {
        let transport = HistoricalRunTransport()
        let loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: transport),
            library: DesktopWorkflowV2LibraryClient(transport: transport)
        )

        let history = try await loader.load(requestID: "history:test")

        #expect(history.runs.map(\.run.revisionID) == ["revision-v2", "revision-v1"])
        #expect(history.runs.map { $0.revision?.summary.revisionNumber } == [2, 1])
        #expect(history.runs.map { $0.graph?.name } == ["Version two", "Version one"])
        #expect(history.runs[1].graph?.nodes.first?.name == "Original trigger")
    }

    @Test("node evidence stays grouped and absent values are explained")
    func groupedNodeEvidence() async throws {
        let transport = HistoricalRunTransport()
        let client = DesktopWorkflowRunInspectionClient(transport: transport)
        let page = try await client.runs(runID: "run-v2", limit: 1, requestID: "run:test")
        let run = try #require(page.runs.first)

        #expect(run.inputs(for: "complete").map(\.portID) == ["success"])
        #expect(run.outputs(for: "trigger").map(\.portID) == ["success"])
        #expect(run.traces(for: "trigger").first?.matchedCaseIDs == ["case-five"])
        #expect(run.attempt(for: "trigger")?.status == "succeeded")
        #expect(run.outputs(for: "trigger").first?.value.absenceExplanation != nil)
        #expect(run.outputs(for: "trigger").first?.value.storage?.scope == "job")
        #expect(run.outputs(for: "trigger").first?.value.storage?.logicalKey == "draft")
        #expect(run.outputs(for: "trigger").first?.value.storage?.revision == 2)
        #expect(run.outputs(for: "trigger").first?.value.storage?.previousVersionID == "storage-version-1")
        #expect(run.outputs(for: "trigger").first?.value.storage?.result == "read")
        #expect(run.events.map(\.storePosition) == [11, 12, 13, 14, 15])
    }
}

private actor HistoricalRunTransport:
    DesktopWorkflowRunInspectionTransport,
    DesktopWorkflowLibraryTransport
{
    enum Failure: Error { case unsupported }

    func inspectWorkflowRuns(
        _ request: Kaname_V1_WorkflowRunInspectionQuery,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_WorkflowRunInspectionResponse {
        var response = Kaname_V1_WorkflowRunInspectionResponse()
        response.schemaVersion.major = 1
        response.requestID = request.requestID
        response.projectionHighWaterMark = 15
        let all = [run(id: "run-v2", revision: "revision-v2", digest: "b"),
                   run(id: "run-v1", revision: "revision-v1", digest: "a")]
        response.runs = request.runID.isEmpty ? all : all.filter { $0.runID == request.runID }
        response.absenceReason = response.runs.isEmpty ? "not_found_or_purged" : ""
        return response
    }

    func queryWorkflowLibrary(
        _ request: Kaname_V1_WorkflowLibraryQueryRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_WorkflowLibraryQueryResponse {
        guard case let .revisionContent(query)? = request.query else { throw Failure.unsupported }
        let version: Int64 = query.revisionID == "revision-v1" ? 1 : 2
        let digest = version == 1 ? "a" : "b"
        var summary = Kaname_V1_WorkflowRevisionSummary()
        summary.workflowID = "workflow-one"
        summary.revisionID = query.revisionID
        summary.revisionNumber = version
        summary.releaseVersion = "1.\(version).0"
        summary.createdAtUnixMillis = 1_000 + version
        summary.packageDigest = String(repeating: digest, count: 64)
        summary.executionSupport = .executable
        var content = Kaname_V1_WorkflowRevisionContent()
        content.summary = summary
        let title = version == 1 ? "Version one" : "Version two"
        let nodeName = version == 1 ? "Original trigger" : "Changed trigger"
        content.workflowJson = Data("""
        {"workflowId":"workflow-one","name":"\(title)","graph":{"nodes":[{"id":"trigger","key":"trigger","name":"\(nodeName)","type":"trigger.manual","config":{}},{"id":"complete","key":"complete","name":"Complete","type":"terminal.complete","config":{}}],"edges":[{"id":"edge-one","from":{"nodeId":"trigger","portId":"success"},"to":{"nodeId":"complete","portId":"input"}}]}}
        """.utf8)
        content.layoutJson = Data("""
        {"nodes":[{"nodeId":"trigger","x":80,"y":100},{"nodeId":"complete","x":430,"y":100}]}
        """.utf8)
        content.configurationJson = Data("{}".utf8)
        content.compiledJson = Data("{}".utf8)
        var response = Kaname_V1_WorkflowLibraryQueryResponse()
        response.schemaVersion.major = 1
        response.requestID = request.requestID
        response.revisionContent = content
        return response
    }

    func setWorkflowActivation(
        _: Kaname_V1_SetWorkflowActivationRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_SetWorkflowActivationResponse { throw Failure.unsupported }

    func importFrozenWorkspace(
        _: Kaname_V1_ImportFrozenWorkspaceRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_ImportFrozenWorkspaceResponse { throw Failure.unsupported }

    private func run(id: String, revision: String, digest: String) -> Kaname_V1_WorkflowProjectedRun {
        var value = Kaname_V1_WorkflowProjectedValue()
        value.valueID = "value-\(id)"
        value.contentType = "application/json"
        value.byteCount = 11
        value.sha256 = String(repeating: "c", count: 64)
        value.storageReferenceID = "job-value-\(id)"
        value.availability = "scoped_handle"
        value.storage.handleID = value.storageReferenceID
        value.storage.scope = "job"
        value.storage.logicalKey = "draft"
        value.storage.versionID = "storage-version-2"
        value.storage.revision = 2
        value.storage.previousVersionID = "storage-version-1"
        value.storage.byteCount = value.byteCount
        value.storage.result = "read"
        var attempt = Kaname_V1_WorkflowProjectedAttempt()
        attempt.attemptID = "attempt-\(id)"
        attempt.nodeID = "trigger"
        attempt.attemptNumber = 1
        attempt.status = "succeeded"
        attempt.outcome = "succeeded"
        attempt.startedAtUnixMillis = 1_010
        attempt.settledAtUnixMillis = 1_040
        attempt.startedStorePosition = 12
        attempt.settledStorePosition = 15
        attempt.emissionIds = ["emission-\(id)"]
        var node = Kaname_V1_WorkflowProjectedNodeState()
        node.nodeID = "trigger"
        node.status = "succeeded"
        node.latestAttemptID = attempt.attemptID
        node.latestAttemptNumber = 1
        node.startedAtUnixMillis = 1_010
        node.settledAtUnixMillis = 1_040
        node.lastStorePosition = 15
        var emission = Kaname_V1_WorkflowProjectedEmission()
        emission.emissionID = "emission-\(id)"
        emission.attemptID = attempt.attemptID
        emission.nodeID = "trigger"
        emission.portID = "success"
        emission.value = value
        emission.eventID = "event-emission-\(id)"
        emission.emittedAtUnixMillis = 1_020
        emission.storePosition = 13
        var edge = Kaname_V1_WorkflowProjectedEdgeCheckpoint()
        edge.eventID = "event-edge-\(id)"
        edge.edgeID = "edge-one"
        edge.emissionID = emission.emissionID
        edge.targetNodeID = "complete"
        edge.targetPortID = "input"
        edge.state = "admitted"
        edge.checkpointedAtUnixMillis = 1_030
        edge.storePosition = 14
        var trace = Kaname_V1_WorkflowProjectedMatchTrace()
        trace.eventID = "event-trace-\(id)"
        trace.attemptID = attempt.attemptID
        trace.nodeID = "trigger"
        trace.inputValueID = value.valueID
        trace.evaluatedCaseIds = ["case-five"]
        trace.matchedCaseIds = ["case-five"]
        trace.emittedPortIds = ["success"]
        trace.trace = value
        trace.recordedAtUnixMillis = 1_025
        trace.storePosition = 13
        var projected = Kaname_V1_WorkflowProjectedRun()
        projected.runID = id
        projected.workflowID = "workflow-one"
        projected.revisionID = revision
        projected.packageDigest = String(repeating: digest, count: 64)
        projected.status = "succeeded"
        projected.outcome = "succeeded"
        projected.createdAtUnixMillis = 1_000
        projected.settledAtUnixMillis = 1_040
        projected.firstStorePosition = 11
        projected.lastStorePosition = 15
        projected.attempts = [attempt]
        projected.nodes = [node]
        projected.emissions = [emission]
        projected.edges = [edge]
        projected.matchTraces = [trace]
        projected.events = (11...15).map { position in
            var event = Kaname_V1_WorkflowProjectedEventReference()
            event.eventID = "event-\(id)-\(position)"
            event.kind = "workflow.fixture.\(position)"
            event.storePosition = UInt64(position)
            event.streamSequence = UInt64(position - 10)
            event.occurredAtUnixMillis = 1_000 + Int64(position)
            return event
        }
        return projected
    }
}
