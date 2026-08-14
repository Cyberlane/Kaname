import Foundation
import KanameProtocol
import SwiftProtobuf
import Testing

struct WorkflowProtocolContractTests {
    @Test
    func diagnosticLocationsAndArtifactDigestsRoundTripExactly() throws {
        var start = Kaname_V1_WorkflowSourcePosition()
        start.byteOffset = 18
        start.line = 2
        start.column = 4
        var end = Kaname_V1_WorkflowSourcePosition()
        end.byteOffset = 29
        end.line = 2
        end.column = 15
        var location = Kaname_V1_WorkflowSourceLocation()
        location.sourceID = "manifest.json"
        location.jsonPointer = "/graph/nodes/0"
        location.start = start
        location.end = end
        var diagnostic = Kaname_V1_WorkflowDiagnostic()
        diagnostic.code = "workflow.node.type_unknown"
        diagnostic.severity = .error
        diagnostic.summary = "The node type is not registered."
        diagnostic.instancePointer = "/graph/nodes/0/type"
        diagnostic.schemaPointer = "/properties/type/enum"
        diagnostic.location = location
        var digests = Kaname_V1_WorkflowArtifactDigests()
        digests.definitionDigest = "sha256:definition"
        digests.layoutDigest = "sha256:layout"
        digests.schemaBundleDigest = "sha256:schema"
        digests.dependencyLockDigest = "sha256:dependencies"
        digests.configurationContractDigest = "sha256:configuration"
        digests.compiledArtifactDigest = "sha256:artifact"
        var response = Kaname_V1_CompileWorkflowResponse()
        response.schemaVersion = schemaVersion()
        response.requestID = "compile:synthetic-001"
        response.outcome = .invalid
        response.diagnostics = [diagnostic]
        response.digests = digests

        let decoded = try Kaname_V1_CompileWorkflowResponse(
            serializedBytes: response.serializedData()
        )
        #expect(decoded == response)
        #expect(decoded.diagnostics[0].location.start.byteOffset == 18)
        #expect(decoded.diagnostics[0].location.end.column == 15)
        #expect(decoded.digests.compiledArtifactDigest == "sha256:artifact")
    }

    @Test
    func swiftPreservesAFutureUnknownRequestField() throws {
        var request = Kaname_V1_ValidateWorkflowRequest()
        request.schemaVersion = schemaVersion()
        request.requestID = "validate:synthetic-001"
        request.schemaJson = Data(#"{"type":"object"}"#.utf8)
        request.instanceJson = Data(#"{"name":"Synthetic"}"#.utf8)
        request.maximumDiagnostics = 64
        var futureWire = try request.serializedData()
        futureWire.append(contentsOf: [0xa0, 0x06, 0x01])

        let decoded = try Kaname_V1_ValidateWorkflowRequest(serializedBytes: futureWire)
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.maximumDiagnostics == 64)
        #expect(try decoded.serializedData() == futureWire)
    }

    @Test
    func workflowLibraryQueriesAndActivationRoundTripWithoutStorageAuthority() throws {
        var portfolio = Kaname_V1_WorkflowPortfolioQuery()
        portfolio.aliasKey = "active"
        var query = Kaname_V1_WorkflowLibraryQueryRequest()
        query.schemaVersion = schemaVersion()
        query.requestID = "library:portfolio-001"
        query.query = .portfolio(portfolio)

        let decodedQuery = try Kaname_V1_WorkflowLibraryQueryRequest(
            serializedBytes: query.serializedData()
        )
        #expect(decodedQuery == query)
        #expect(decodedQuery.portfolio.aliasKey == "active")

        var activation = Kaname_V1_SetWorkflowActivationRequest()
        activation.schemaVersion = schemaVersion()
        activation.requestID = "library:activate-001"
        activation.aliasID = "primary-alias"
        activation.workflowID = "workflow-one"
        activation.aliasKey = "active"
        activation.revisionID = "revision-six"
        activation.expectedGeneration = 5
        activation.updatedAtUnixMillis = 1_786_685_000_000
        var futureWire = try activation.serializedData()
        futureWire.append(contentsOf: [0xa0, 0x06, 0x01])

        let decodedActivation = try Kaname_V1_SetWorkflowActivationRequest(
            serializedBytes: futureWire
        )
        #expect(decodedActivation.revisionID == "revision-six")
        #expect(decodedActivation.expectedGeneration == 5)
        #expect(try decodedActivation.serializedData() == futureWire)
    }

    @Test
    func frozenWorkspaceImportCarriesSanitizedDraftsWithoutAFilePath() throws {
        var draft = Kaname_V1_FrozenWorkflowDraftImport()
        draft.workflowID = "workflow-one"
        draft.packageID = "dev.kaname.one"
        draft.name = "One"
        draft.workflowJson = Data(#"{"workflowId":"workflow-one"}"#.utf8)
        draft.layoutJson = Data(#"{"nodes":[]}"#.utf8)
        draft.comparisonJson = Data(#"{"blocking":true}"#.utf8)
        draft.blocked = true
        var request = Kaname_V1_ImportFrozenWorkspaceRequest()
        request.schemaVersion = schemaVersion()
        request.requestID = "library:import-001"
        request.receiptID = "workspace-receipt"
        request.sourceDigest = String(repeating: "a", count: 64)
        request.importedAtUnixMillis = 100
        request.drafts = [draft]

        let decoded = try Kaname_V1_ImportFrozenWorkspaceRequest(
            serializedBytes: request.serializedData()
        )
        #expect(decoded == request)
        #expect(decoded.drafts[0].blocked)
        #expect(decoded.drafts[0].workflowJson == draft.workflowJson)
    }

    @Test
    func workflowRuntimeCommandsAndEventsRoundTripAsTypedPayloads() throws {
        let value = runtimeValue(id: "value-five", json: #"{"value":5}"#)
        var input = Kaname_V1_WorkflowInputBinding()
        input.portID = "input"
        input.value = value
        var request = Kaname_V1_RequestWorkflowRun()
        request.runID = "run-one"
        request.workflowID = "workflow-one"
        request.revisionID = "revision-six"
        request.packageDigest = String(repeating: "a", count: 64)
        request.triggerKind = "manual"
        request.inputs = [input]
        var cancel = Kaname_V1_CancelWorkflowRun()
        cancel.runID = request.runID
        cancel.runTokenID = "run-token-one"
        cancel.reasonCode = "owner-requested"
        var token = Kaname_V1_WorkflowRunTokenCreated()
        token.runID = request.runID
        token.runTokenID = cancel.runTokenID
        token.requestCommandID = "command-run-one"
        token.workflowID = request.workflowID
        token.revisionID = request.revisionID
        token.packageDigest = request.packageDigest
        var started = Kaname_V1_WorkflowAttemptStarted()
        started.runID = request.runID
        started.runTokenID = token.runTokenID
        started.attemptID = "attempt-one"
        started.nodeID = "match-route"
        started.attemptNumber = 1
        var emitted = Kaname_V1_WorkflowPortEmitted()
        emitted.runID = request.runID
        emitted.runTokenID = token.runTokenID
        emitted.emissionID = "emission-five"
        emitted.attemptID = started.attemptID
        emitted.nodeID = started.nodeID
        emitted.portID = "case-five"
        emitted.value = value
        var edge = Kaname_V1_WorkflowEdgeCheckpointed()
        edge.runID = request.runID
        edge.runTokenID = token.runTokenID
        edge.edgeID = "edge-five"
        edge.emissionID = emitted.emissionID
        edge.targetNodeID = "complete"
        edge.targetPortID = "input"
        edge.state = .admitted
        var trace = Kaname_V1_WorkflowMatchTraceRecorded()
        trace.runID = request.runID
        trace.runTokenID = token.runTokenID
        trace.attemptID = started.attemptID
        trace.nodeID = started.nodeID
        trace.inputValueID = value.valueID
        trace.evaluatedCaseIds = ["case-five"]
        trace.matchedCaseIds = ["case-five"]
        trace.emittedPortIds = ["case-five"]
        trace.trace = runtimeValue(id: "trace-five", json: #"{"matched":"case-five"}"#)
        var attemptSettled = Kaname_V1_WorkflowAttemptSettled()
        attemptSettled.runID = request.runID
        attemptSettled.runTokenID = token.runTokenID
        attemptSettled.attemptID = started.attemptID
        attemptSettled.nodeID = started.nodeID
        attemptSettled.attemptNumber = 1
        attemptSettled.outcome = .succeeded
        attemptSettled.emissionIds = [emitted.emissionID]
        var cancellation = Kaname_V1_WorkflowRunCancellationRequested()
        cancellation.runID = request.runID
        cancellation.runTokenID = token.runTokenID
        cancellation.cancelCommandID = "command-cancel-one"
        cancellation.reasonCode = "owner-requested"
        var settled = Kaname_V1_WorkflowRunSettled()
        settled.runID = request.runID
        settled.runTokenID = token.runTokenID
        settled.outcome = .succeeded
        settled.finalEmissionIds = [emitted.emissionID]

        try roundTrip(request)
        try roundTrip(cancel)
        try roundTrip(token)
        try roundTrip(started)
        try roundTrip(emitted)
        try roundTrip(edge)
        try roundTrip(trace)
        try roundTrip(attemptSettled)
        try roundTrip(cancellation)
        try roundTrip(settled)
        let requestWire = try request.serializedData()
        #expect(!String(decoding: requestWire, as: UTF8.self).contains("workspace_path"))
        #expect(!String(decoding: requestWire, as: UTF8.self).contains("credential"))
    }

    @Test
    func malformedWireFailsWithoutProducingAPartialRequest() {
        #expect(throws: (any Error).self) {
            _ = try Kaname_V1_CompileWorkflowRequest(serializedBytes: [0x0a])
        }
    }

    @Test
    func clientRequestIDPreflightMatchesTheIngressCharacterContract() {
        #expect(WorkflowProtocolClientPreflight.acceptsRequestID("compile:job_1.2-alpha"))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID(""))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID("contains space"))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID("日本語"))
        #expect(WorkflowProtocolClientPreflight.acceptsRequestID(String(repeating: "a", count: 128)))
        #expect(!WorkflowProtocolClientPreflight.acceptsRequestID(String(repeating: "a", count: 129)))
    }

    private func schemaVersion() -> Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }

    private func runtimeValue(id: String, json: String) -> Kaname_V1_WorkflowValueReference {
        let data = Data(json.utf8)
        var value = Kaname_V1_WorkflowValueReference()
        value.valueID = id
        value.contentType = "application/json"
        value.byteCount = UInt64(data.count)
        value.sha256 = String(repeating: "a", count: 64)
        value.inlineCanonicalJson = data
        return value
    }

    private func roundTrip<M: SwiftProtobuf.Message & Equatable>(_ message: M) throws {
        let decoded = try M(serializedBytes: message.serializedData())
        #expect(decoded == message)
    }
}
