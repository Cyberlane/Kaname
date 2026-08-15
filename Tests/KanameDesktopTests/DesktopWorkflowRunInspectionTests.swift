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
        #expect(history.runs[1].run.subflows.first?.status == "called")
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
        #expect(run.outputs(for: "trigger").first?.value.storage?.sourceVersionID == "job-version-source")
        #expect(run.outputs(for: "trigger").first?.value.storage?.result == "read")
        #expect(run.attempt(for: "trigger")?.executionTokenID == "token-run-v2")
        #expect(run.executionTokens.first?.status == "completed")
        #expect(run.executionTokens.first?.iterationNodeID == "trigger")
        #expect(run.executionTokens.first?.iterationIndex == 0)
        #expect(run.iterations.first?.maximumConcurrency == 2)
        #expect(run.iterations.first?.failedExecutionTokenIDs == ["token-failed"])
        #expect(run.retries.first?.decision == "scheduled")
        #expect(run.retries.first?.eligibleAtUnixMillis == 2_000)
        #expect(run.waits.first?.kind == "reply")
        #expect(run.waits.first?.decision == "resumed")
        #expect(run.waits.first?.revisionID == "revision-v2")
        #expect(run.waitSignals.first?.signalID == "signal-run-v2")
        #expect(run.episode?.caseID == "case-kay-42")
        #expect(run.episode?.ordinal == 2)
        #expect(run.episode?.priorEpisodeID == "episode-run-v1")
        #expect(run.episode?.inputs.first?.portID == "input")
        #expect(run.episode?.compiledContext.id == "context-run-v2")
        #expect(run.subflows.first?.nodeID == "trigger")
        #expect(run.subflows.first?.childWorkflowID == "workflow-child")
        #expect(run.subflows.first?.childRevisionID == "revision-child-v1")
        #expect(run.subflows.first?.childPackageDigest == String(repeating: "f", count: 64))
        #expect(run.subflows.first?.childCommandID == "command-child-run-v2")
        #expect(run.subflows.first?.outcome == "succeeded")
        #expect(run.subflows.first?.output?.id == "value-run-v2")
        #expect(run.capabilityAttempts.first?.capabilityID == "dev.kaname.synthetic")
        #expect(run.capabilityAttempts.first?.outcome == "succeeded")
        #expect(run.capabilityAttempts.first?.logs.first?.message == "Validated typed output")
        #expect(run.capabilityAttempts.first?.artifactOutputs.first?.handleID == "job-value-run-v2")
        #expect(run.capabilityAttempts.first?.receiptID == "receipt-run-v2")
        #expect(run.llmAttempts.first?.settings.modelID == "synthetic-model")
        #expect(run.llmAttempts.first?.messages.map(\.role) == ["system", "developer", "user"])
        #expect(run.llmAttempts.first?.compilationReport.redactionCount == 2)
        #expect(run.llmAttempts.first?.output?.id == "llm-output-run-v2")
        #expect(run.llmAttempts.first?.toolDefinitions.first?.toolID == "synthetic.search")
        #expect(run.llmAttempts.first?.toolCalls.first?.durationMilliseconds == 3)
        #expect(run.llmAttempts.first?.responseMessages.first?.kind == "tool_result")
        #expect(run.llmAttempts.first?.usage?.totalTokens == 170)
        #expect(run.llmAttempts.first?.validation?.status == "succeeded")
        #expect(run.llmAttempts.first?.providerReceipt?.requestID == "provider-request-run-v2")
        #expect(run.effectAuthorities.first?.effectID == "effect-run-v2")
        #expect(run.effectAuthorities.first?.status == "reconciled_applied")
        #expect(run.effectAuthorities.first?.connectorClass == "dev.kaname.email")
        #expect(run.effectAuthorities.first?.actorID == "owner-local")
        #expect(run.effectAuthorities.first?.grantID == "grant-effect-run-v2")
        #expect(run.effectAuthorities.first?.dispatch?.registration.bindingID == "binding-installation-email")
        #expect(run.effectAuthorities.first?.dispatch?.outcome == "unknown")
        #expect(run.effectAuthorities.first?.reconciliation?.outcome == "applied")
        #expect(run.effectAuthorities.first?.reconciliation?.observationCount == 1)
        #expect(run.events.map(\.storePosition) == [11, 12, 13, 14, 15, 16, 17, 18])
        #expect(run.retentionPolicy.mode == "duration")
        #expect(run.retentionPolicy.days == 30)
        #expect(run.retentionPolicy.summary == "Keep for 30 days")
        #expect(run.purgePreview.manualEligible)
        #expect(run.purgePreview.affectedAttemptIDs == ["attempt-run-v2"])
        #expect(run.purgePreview.affectedValueIDs == ["value-run-v2"])
        #expect(run.purgePreview.affectedFileHandleIDs == ["job-value-run-v2"])
        #expect(run.purgePreview.retainedPromotedHandleIDs == ["workflow-value-run-v2"])
        #expect(run.purgePreview.affectedEffectIDs == ["effect-run-v2"])
    }

    @Test("LLM inspection presentation stays collapsed, searchable, bounded, and compact-aware")
    func llmInspectionPresentationContract() async throws {
        let client = DesktopWorkflowRunInspectionClient(transport: HistoricalRunTransport())
        let page = try await client.runs(
            runID: "run-v2", limit: 1, requestID: "run:llm-presentation"
        )
        let llm = try #require(page.runs.first?.llmAttempts.first)
        let groupID = "\(llm.id):calls"

        #expect(!DesktopWorkflowLlmInspectionPresentation.isGroupExpanded(
            groupID: groupID, explicitlyExpandedGroupIDs: [], searchText: ""
        ))
        #expect(DesktopWorkflowLlmInspectionPresentation.isGroupExpanded(
            groupID: groupID, explicitlyExpandedGroupIDs: [], searchText: "search"
        ))
        #expect(DesktopWorkflowLlmInspectionPresentation.includes(
            searchText: "bounded", fields: [llm.toolCalls[0].toolID, "Bounded result"]
        ))
        #expect(!DesktopWorkflowLlmInspectionPresentation.includes(
            searchText: "remote secret", fields: [llm.toolCalls[0].toolID]
        ))
        #expect(DesktopWorkflowLlmInspectionPresentation
            .structuredText(llm.responseMessages[0].content)
            .contains(#""summarized":true"#))
        #expect(DesktopWorkflowLlmInspectionPresentation.layout(for: 1_049) == .compact)
        #expect(DesktopWorkflowLlmInspectionPresentation.layout(for: 1_050) == .wide)
    }

    @Test("manual purge binds the reviewed digest and accepts only a tombstone receipt")
    func manualPurgeContract() async throws {
        let page = try await DesktopWorkflowRunInspectionClient(
            transport: HistoricalRunTransport()
        ).runs(runID: "run-v2", limit: 1, requestID: "run:purge-source")
        let run = try #require(page.runs.first)
        let receipt = try await DesktopWorkflowRunPurgeClient(
            transport: PurgeTransport()
        ).purge(run, requestID: "purge:run-v2", requestedAtUnixMillis: 2_000)

        #expect(receipt.tombstone.runID == "run-v2")
        #expect(receipt.tombstone.previewEvidenceDigest == run.purgePreview.evidenceDigest)
        #expect(receipt.tombstone.historicalRevisionRetained)
        #expect(receipt.compactedJournalEventCount == 8)
    }
}

private actor PurgeTransport: DesktopWorkflowRunPurgeTransport {
    func purgeWorkflowRun(
        _ request: Kaname_V1_PurgeWorkflowRunRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_PurgeWorkflowRunResponse {
        var tombstone = Kaname_V1_WorkflowRunPurged()
        tombstone.runID = request.runID
        tombstone.purgeCommandID = request.requestID
        tombstone.workflowID = "workflow-one"
        tombstone.revisionID = "revision-v2"
        tombstone.packageDigest = String(repeating: "b", count: 64)
        tombstone.mode = request.mode
        tombstone.previewEvidenceDigest = request.expectedPreviewEvidenceDigest
        tombstone.sourceFirstStorePosition = 11
        tombstone.sourceLastStorePosition = 18
        tombstone.sourceEventCount = 8
        tombstone.affectedAttemptCount = 1
        tombstone.affectedValueCount = 1
        tombstone.affectedFileHandleCount = 1
        tombstone.historicalRevisionRetained = true
        tombstone.affectedEffectAuthorityCount = 1
        var receipt = Kaname_V1_WorkflowRunPurgeReceipt()
        receipt.purgeEventID = "purge-event-run-v2"
        receipt.purgeStorePosition = 19
        receipt.tombstone = tombstone
        receipt.compactedJournalEventCount = 8
        var response = Kaname_V1_PurgeWorkflowRunResponse()
        response.schemaVersion.major = 1
        response.requestID = request.requestID
        response.receipt = receipt
        response.projectionHighWaterMark = 19
        return response
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
        value.storage.sourceVersionID = "job-version-source"
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
        attempt.executionTokenID = "token-\(id)"
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
        emission.executionTokenID = attempt.executionTokenID
        var edge = Kaname_V1_WorkflowProjectedEdgeCheckpoint()
        edge.eventID = "event-edge-\(id)"
        edge.edgeID = "edge-one"
        edge.emissionID = emission.emissionID
        edge.targetNodeID = "complete"
        edge.targetPortID = "input"
        edge.state = "admitted"
        edge.checkpointedAtUnixMillis = 1_030
        edge.storePosition = 14
        edge.executionTokenID = attempt.executionTokenID
        var token = Kaname_V1_WorkflowProjectedExecutionToken()
        token.executionTokenID = attempt.executionTokenID
        token.status = "completed"
        token.outcome = "completed"
        token.terminalNodeID = "complete"
        token.iterationNodeID = "trigger"
        token.iterationIndex = 0
        token.iterationCount = 2
        token.createdStorePosition = 11
        token.settledStorePosition = 15
        var iteration = Kaname_V1_WorkflowProjectedIteration()
        iteration.iterationNodeID = "trigger"
        iteration.parentExecutionTokenID = "token-parent"
        iteration.controllerAttemptID = attempt.attemptID
        iteration.inputValueID = value.valueID
        iteration.inputSha256 = value.sha256
        iteration.itemCount = 2
        iteration.maximumItems = 4
        iteration.maximumConcurrency = 2
        iteration.failurePolicy = "collect"
        iteration.decision = "succeeded"
        iteration.resumedExecutionTokenID = "token-resumed"
        iteration.expectedExecutionTokenIds = [token.executionTokenID, "token-failed"]
        iteration.succeededExecutionTokenIds = [token.executionTokenID]
        iteration.failedExecutionTokenIds = ["token-failed"]
        iteration.output = value
        iteration.plannedStorePosition = 12
        iteration.evaluatedStorePosition = 15
        var retry = Kaname_V1_WorkflowProjectedRetryEvaluation()
        retry.retryNodeID = "trigger"
        retry.executionTokenID = token.executionTokenID
        retry.controllerAttemptID = "attempt-retry-(id)"
        retry.failedAttemptID = attempt.attemptID
        retry.targetNodeID = "trigger"
        retry.errorCode = "connector.timeout"
        retry.decision = "scheduled"
        retry.nextAttemptNumber = 2
        retry.maximumAttempts = 3
        retry.delayMilliseconds = 1_000
        retry.eligibleAtUnixMillis = 2_000
        retry.retryInput = value
        retry.error = value
        retry.storePosition = 15
        var correlation = Kaname_V1_WorkflowWaitCorrelation()
        correlation.key = "input:/caseId"
        correlation.sha256 = String(repeating: "d", count: 64)
        var wait = Kaname_V1_WorkflowProjectedWait()
        wait.subscriptionID = "subscription-\(id)"
        wait.waitNodeID = "trigger"
        wait.executionTokenID = token.executionTokenID
        wait.controllerAttemptID = attempt.attemptID
        wait.workflowID = "workflow-one"
        wait.revisionID = revision
        wait.packageDigest = String(repeating: digest, count: 64)
        wait.kind = "reply"
        wait.ownerKind = "workflow"
        wait.ownerID = "workflow-one"
        wait.correlation = [correlation]
        wait.inputValueID = value.valueID
        wait.inputSha256 = value.sha256
        wait.status = "resumed"
        wait.decision = "resumed"
        wait.resolvingSignalID = "signal-\(id)"
        wait.output = value
        wait.expiresAtUnixMillis = 2_000
        wait.subscribedStorePosition = 12
        wait.resolvedStorePosition = 15
        var waitSignal = Kaname_V1_WorkflowProjectedWaitSignal()
        waitSignal.signalID = "signal-\(id)"
        waitSignal.signalCommandID = "command-signal-\(id)"
        waitSignal.kind = "reply"
        waitSignal.ownerKind = "workflow"
        waitSignal.ownerID = "workflow-one"
        waitSignal.correlation = [correlation]
        waitSignal.value = value
        waitSignal.recordedAtUnixMillis = 1_035
        waitSignal.storePosition = 14
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
        projected.lastStorePosition = id == "run-v2" ? 18 : 15
        projected.attempts = [attempt]
        projected.nodes = [node]
        projected.emissions = [emission]
        projected.edges = [edge]
        projected.matchTraces = [trace]
        projected.executionTokens = [token]
        projected.iterations = [iteration]
        projected.retries = [retry]
        projected.waits = [wait]
        projected.waitSignals = [waitSignal]
        var subflow = Kaname_V1_WorkflowProjectedSubflow()
        subflow.invocationID = "subflow-\(id)"
        subflow.attemptID = attempt.attemptID
        subflow.executionTokenID = token.executionTokenID
        subflow.nodeID = "trigger"
        subflow.childRunID = "child-\(id)"
        subflow.childWorkflowID = "workflow-child"
        subflow.childRevisionID = "revision-child-v1"
        subflow.childPackageID = "dev.kaname.workflow.child"
        subflow.childPackageDigest = String(repeating: "f", count: 64)
        subflow.entrypoint = "start"
        subflow.input = value
        subflow.status = id == "run-v2" ? "settled" : "called"
        if id == "run-v2" {
            subflow.outcome = "succeeded"
            subflow.output = value
            subflow.childFinalEmissionIds = [emission.emissionID]
            subflow.settledStorePosition = 15
            subflow.settledAtUnixMillis = 1_705_000_000_015
        }
        subflow.childCommandID = "command-child-\(id)"
        subflow.calledAtUnixMillis = 1_705_000_000_012
        subflow.calledStorePosition = 12
        projected.subflows = [subflow]
        if id == "run-v2" {
            var configuration = Kaname_V1_WorkflowProjectedValue()
            configuration.valueID = "configuration-run-v2"
            configuration.contentType = "application/json"
            configuration.availability = "inline"
            configuration.inlineCanonicalJson = Data(#"{"mode":"strict"}"#.utf8)
            configuration.byteCount = UInt64(configuration.inlineCanonicalJson.count)
            configuration.sha256 = String(repeating: "9", count: 64)
            var artifact = Kaname_V1_WorkflowProjectedCapabilityArtifactHandle()
            artifact.handleID = value.storageReferenceID
            artifact.role = "normalized-document"
            artifact.value = value
            var log = Kaname_V1_WorkflowCapabilityLogEntry()
            log.sequence = 1
            log.level = "info"
            log.message = "Validated typed output"
            log.offsetMilliseconds = 4
            var capability = Kaname_V1_WorkflowProjectedCapabilityAttempt()
            capability.invocationID = "capability-run-v2"
            capability.attemptID = attempt.attemptID
            capability.executionTokenID = token.executionTokenID
            capability.nodeID = "trigger"
            capability.capabilityID = "dev.kaname.synthetic"
            capability.version = "1.0.0"
            capability.packageDigest = String(repeating: "7", count: 64)
            capability.configurationContractDigest = String(repeating: "8", count: 64)
            capability.inputSchemaDigest = String(repeating: "6", count: 64)
            capability.outputSchemaDigest = String(repeating: "5", count: 64)
            capability.outputSchemaRef = "dev.kaname.output/v1"
            capability.configuration = configuration
            capability.input = value
            capability.status = "settled"
            capability.outcome = "succeeded"
            capability.output = value
            capability.artifactOutputs = [artifact]
            capability.logs = [log]
            capability.timeoutMilliseconds = 1_000
            capability.deadlineUnixMillis = 2_000
            capability.elapsedMilliseconds = 4
            capability.receiptID = "receipt-run-v2"
            capability.providerRunReference = "provider-run-v2"
            capability.idempotencyKey = capability.invocationID
            capability.startedAtUnixMillis = 1_000
            capability.settledAtUnixMillis = 1_004
            capability.startedStorePosition = 12
            capability.settledStorePosition = 13
            projected.capabilityAttempts = [capability]
            var llmContent = Kaname_V1_WorkflowProjectedValue()
            llmContent.valueID = "llm-context-run-v2"
            llmContent.contentType = "application/json"
            llmContent.availability = "inline"
            llmContent.inlineCanonicalJson = Data(#"{"text":"[redacted]"}"#.utf8)
            llmContent.byteCount = UInt64(llmContent.inlineCanonicalJson.count)
            llmContent.sha256 = String(repeating: "4", count: 64)
            let groupSpecifications = [
                ("system-policy", "system_policy", "System policy", "system"),
                ("workflow-instructions", "workflow_instructions", "Workflow instructions", "developer"),
                ("current-input", "current_input", "Current input", "user"),
            ]
            var groups: [Kaname_V1_WorkflowProjectedLlmContextGroup] = []
            var messages: [Kaname_V1_WorkflowProjectedLlmMessage] = []
            for (index, specification) in groupSpecifications.enumerated() {
                var group = Kaname_V1_WorkflowProjectedLlmContextGroup()
                group.groupID = specification.0
                group.kind = specification.1
                group.title = specification.2
                group.provenance = "Recorded workflow context"
                group.content = llmContent
                group.originalByteCount = llmContent.byteCount
                group.retainedByteCount = llmContent.byteCount
                group.redactionCount = index == 2 ? 2 : 0
                groups.append(group)
                var message = Kaname_V1_WorkflowProjectedLlmMessage()
                message.messageID = "llm-message-\(index + 1)"
                message.sequence = UInt32(index + 1)
                message.role = specification.3
                message.contextGroupID = specification.0
                message.summary = specification.2
                message.content = llmContent
                message.estimatedTokens = 8
                message.redactionCount = group.redactionCount
                messages.append(message)
            }
            var settings = Kaname_V1_WorkflowLlmModelSettings()
            settings.modelClass = "reasoning"
            settings.providerID = "synthetic-provider"
            settings.modelID = "synthetic-model"
            settings.modelRevision = "revision-2026-08-15"
            settings.reasoningEffort = "medium"
            settings.temperatureMilli = 200
            settings.maximumContextBytes = 32_768
            settings.maximumOutputTokens = 512
            settings.conversationScope = "case"
            var report = Kaname_V1_WorkflowLlmCompilationReport()
            report.originalGroupCount = UInt32(groups.count)
            report.retainedGroupCount = UInt32(groups.count)
            report.originalByteCount = UInt64(groups.count) * llmContent.byteCount
            report.retainedByteCount = report.originalByteCount
            report.redactionCount = 2
            report.redactionReasons = ["sensitive-field"]
            var llmOutput = Kaname_V1_WorkflowProjectedValue()
            llmOutput.valueID = "llm-output-run-v2"
            llmOutput.contentType = "application/json"
            llmOutput.availability = "inline"
            llmOutput.inlineCanonicalJson = Data(#"{"summary":"Safe result"}"#.utf8)
            llmOutput.byteCount = UInt64(llmOutput.inlineCanonicalJson.count)
            llmOutput.sha256 = String(repeating: "3", count: 64)
            var llm = Kaname_V1_WorkflowProjectedLlmAttempt()
            llm.invocationID = "llm-run-v2"
            llm.attemptID = attempt.attemptID
            llm.executionTokenID = token.executionTokenID
            llm.nodeID = "trigger"
            llm.settings = settings
            llm.contextDigest = String(repeating: "2", count: 64)
            llm.contextGroups = groups
            llm.messages = messages
            llm.priorEpisodeIds = ["episode-run-v1"]
            llm.attachments = [artifact]
            llm.compilationReport = report
            llm.outputSchemaRef = "dev.kaname.llm/output-v1"
            llm.outputSchemaDigest = String(repeating: "1", count: 64)
            llm.input = value
            llm.status = "settled"
            llm.outcome = "succeeded"
            llm.output = llmOutput
            llm.timeoutMilliseconds = 1_000
            llm.deadlineUnixMillis = 2_000
            llm.elapsedMilliseconds = 7
            llm.receiptID = "receipt-llm-run-v2"
            llm.providerRunReference = "provider-llm-run-v2"
            llm.idempotencyKey = llm.invocationID
            llm.startedAtUnixMillis = 1_000
            llm.settledAtUnixMillis = 1_007
            llm.startedStorePosition = 14
            llm.settledStorePosition = 15
            var tool = Kaname_V1_WorkflowLlmToolDefinition()
            tool.toolID = "synthetic.search"
            tool.version = "1.0.0"
            tool.packageDigest = String(repeating: "a", count: 64)
            tool.description_p = "Search the bounded synthetic fixture"
            tool.inputSchemaRef = "dev.kaname.tool/search-input-v1"
            tool.inputSchemaDigest = String(repeating: "b", count: 64)
            tool.outputSchemaRef = "dev.kaname.tool/search-output-v1"
            tool.outputSchemaDigest = String(repeating: "c", count: 64)
            llm.toolDefinitions = [tool]
            var toolCall = Kaname_V1_WorkflowProjectedLlmToolCall()
            toolCall.callID = "call-search-run-v2"
            toolCall.sequence = 1
            toolCall.toolID = tool.toolID
            toolCall.status = "succeeded"
            toolCall.input = llmContent
            toolCall.output = llmContent
            toolCall.durationMilliseconds = 3
            llm.toolCalls = [toolCall]
            var responseMessage = Kaname_V1_WorkflowProjectedLlmResponseMessage()
            responseMessage.messageID = "response-message-run-v2"
            responseMessage.sequence = 1
            responseMessage.role = "tool"
            responseMessage.kind = "tool_result"
            responseMessage.summary = "Bounded tool result"
            var summarizedContent = Kaname_V1_WorkflowProjectedValue()
            summarizedContent.valueID = "llm-response-summary-run-v2"
            summarizedContent.contentType = "application/json"
            summarizedContent.availability = "inline"
            summarizedContent.inlineCanonicalJson = Data(
                #"{"originalByteCount":30000,"sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","summarized":true}"#.utf8
            )
            summarizedContent.byteCount = UInt64(summarizedContent.inlineCanonicalJson.count)
            summarizedContent.sha256 = String(repeating: "9", count: 64)
            responseMessage.content = summarizedContent
            responseMessage.toolCallID = toolCall.callID
            llm.responseMessages = [responseMessage]
            llm.usage.inputTokens = 120
            llm.usage.cachedInputTokens = 20
            llm.usage.outputTokens = 40
            llm.usage.reasoningTokens = 10
            llm.usage.totalTokens = 170
            llm.usage.toolCallCount = 1
            llm.usage.costCurrency = "USD"
            llm.usage.totalCostMicros = 235
            llm.validation.status = "succeeded"
            llm.validation.schemaRef = llm.outputSchemaRef
            llm.validation.schemaDigest = llm.outputSchemaDigest
            llm.providerReceipt.requestID = "provider-request-run-v2"
            llm.providerReceipt.responseID = "provider-response-run-v2"
            llm.providerReceipt.receiptID = llm.receiptID
            llm.providerReceipt.providerRunReference = llm.providerRunReference
            llm.providerReceipt.metadataDigest = String(repeating: "d", count: 64)
            projected.llmAttempts = [llm]
            var intent = Kaname_V1_WorkflowEffectIntent()
            intent.effectID = "effect-run-v2"
            intent.runID = id
            intent.runTokenID = "run-token-run-v2"
            intent.attemptID = attempt.attemptID
            intent.executionTokenID = token.executionTokenID
            intent.nodeID = attempt.nodeID
            intent.workflowID = "workflow-one"
            intent.revisionID = revision
            intent.connectorClass = "dev.kaname.email"
            intent.action = "draft-reply"
            intent.accountBindingID = "binding-email-primary"
            intent.destinationFingerprint = String(repeating: "4", count: 64)
            intent.inputDigest = String(repeating: "5", count: 64)
            intent.idempotencyKey = "effect-idempotency-run-v2"
            var preview = Kaname_V1_WorkflowEffectPreview()
            preview.summary = "Create the reviewed draft"
            preview.consequence = "A provider draft will be created"
            preview.reversible = true
            preview.destinationFingerprint = intent.destinationFingerprint
            preview.previewDigest = String(repeating: "6", count: 64)
            var approval = Kaname_V1_ApprovalRequest()
            approval.approvalID = "approval-effect-run-v2"
            approval.actionKind = "workflow.effect"
            approval.targetID = intent.effectID
            approval.targetRevision = revision
            approval.effectDigest = Data(repeating: 0x07, count: 32)
            approval.consequence = preview.consequence
            approval.reversible = preview.reversible
            approval.expiresAtUnixMillis = 5_000
            approval.fingerprint = Data(repeating: 0x08, count: 32)
            approval.approvalPayloadVersion = 1
            var proposal = Kaname_V1_WorkflowEffectProposed()
            proposal.intent = intent
            proposal.intentDigest = String(repeating: "7", count: 64)
            proposal.preview = preview
            proposal.approvalRequest = approval
            var resolution = Kaname_V1_ApprovalResolution()
            resolution.approvalID = approval.approvalID
            resolution.decision = .approve
            resolution.expectedFingerprint = approval.fingerprint
            resolution.actorID = "owner-local"
            resolution.deviceID = "device-local"
            var authorization = Kaname_V1_WorkflowEffectAuthorized()
            authorization.runID = id
            authorization.runTokenID = intent.runTokenID
            authorization.effectID = intent.effectID
            authorization.grantID = "grant-effect-run-v2"
            authorization.resolution = resolution
            authorization.approvalFingerprint = approval.fingerprint
            authorization.intentDigest = proposal.intentDigest
            authorization.previewDigest = preview.previewDigest
            authorization.destinationFingerprint = intent.destinationFingerprint
            authorization.idempotencyKey = intent.idempotencyKey
            authorization.expiresAtUnixMillis = approval.expiresAtUnixMillis
            var registration = Kaname_V1_WorkflowEffectConnectorRegistration()
            registration.connectorClass = intent.connectorClass
            registration.version = "1.0.0"
            registration.packageDigest = String(repeating: "a", count: 64)
            registration.bindingID = "binding-installation-email"
            registration.accountBindingID = intent.accountBindingID
            registration.allowedActions = [intent.action]
            registration.idempotent = true
            registration.supportsReconciliation = true
            registration.registrationDigest = String(repeating: "b", count: 64)
            var dispatchStarted = Kaname_V1_WorkflowEffectDispatchStarted()
            dispatchStarted.runID = id
            dispatchStarted.runTokenID = intent.runTokenID
            dispatchStarted.effectID = intent.effectID
            dispatchStarted.dispatchID = "dispatch-effect-run-v2"
            dispatchStarted.grantID = authorization.grantID
            dispatchStarted.intentDigest = proposal.intentDigest
            dispatchStarted.previewDigest = preview.previewDigest
            dispatchStarted.destinationFingerprint = intent.destinationFingerprint
            dispatchStarted.idempotencyKey = intent.idempotencyKey
            dispatchStarted.registration = registration
            dispatchStarted.deadlineUnixMillis = 4_000
            var unknownReceipt = Kaname_V1_WorkflowEffectReceipt()
            unknownReceipt.receiptID = "receipt-effect-unknown"
            unknownReceipt.providerReference = "provider-effect-run-v2"
            unknownReceipt.outcome = .unknown
            unknownReceipt.evidenceDigest = String(repeating: "c", count: 64)
            var dispatchSettled = Kaname_V1_WorkflowEffectDispatchSettled()
            dispatchSettled.runID = id
            dispatchSettled.runTokenID = intent.runTokenID
            dispatchSettled.effectID = intent.effectID
            dispatchSettled.dispatchID = dispatchStarted.dispatchID
            dispatchSettled.grantID = authorization.grantID
            dispatchSettled.outcome = .unknown
            dispatchSettled.errorCode = "connector.timeout_after_send"
            dispatchSettled.receipt = unknownReceipt
            dispatchSettled.elapsedMilliseconds = 50
            dispatchSettled.idempotencyKey = intent.idempotencyKey
            var appliedReceipt = Kaname_V1_WorkflowEffectReceipt()
            appliedReceipt.receiptID = "receipt-effect-applied"
            appliedReceipt.providerReference = "provider-effect-run-v2"
            appliedReceipt.outcome = .applied
            appliedReceipt.evidenceDigest = String(repeating: "d", count: 64)
            var reconciliation = Kaname_V1_WorkflowEffectReconciled()
            reconciliation.runID = id
            reconciliation.runTokenID = intent.runTokenID
            reconciliation.effectID = intent.effectID
            reconciliation.dispatchID = dispatchStarted.dispatchID
            reconciliation.reconciliationID = "reconciliation-effect-run-v2"
            reconciliation.outcome = .applied
            reconciliation.receipt = appliedReceipt
            reconciliation.elapsedMilliseconds = 10
            reconciliation.idempotencyKey = intent.idempotencyKey
            var authority = Kaname_V1_WorkflowProjectedEffectAuthority()
            authority.proposal = proposal
            authority.status = "reconciled_applied"
            authority.authorization = authorization
            authority.proposedAtUnixMillis = 2_000
            authority.authorizedAtUnixMillis = 3_000
            authority.proposedStorePosition = 14
            authority.authorizedStorePosition = 15
            authority.dispatchStarted = dispatchStarted
            authority.dispatchSettled = dispatchSettled
            authority.reconciliation = reconciliation
            authority.dispatchStartedAtUnixMillis = 3_100
            authority.dispatchSettledAtUnixMillis = 3_150
            authority.reconciledAtUnixMillis = 3_200
            authority.dispatchStartedStorePosition = 16
            authority.dispatchSettledStorePosition = 17
            authority.reconciledStorePosition = 18
            authority.reconciliationCount = 1
            projected.effectAuthorities = [authority]
            var context = Kaname_V1_WorkflowProjectedValue()
            context.valueID = "context-run-v2"
            context.contentType = "application/json"
            context.availability = "inline"
            context.inlineCanonicalJson = Data(#"{"priorEpisodes":[{"episodeId":"episode-run-v1"}]}"#.utf8)
            context.byteCount = UInt64(context.inlineCanonicalJson.count)
            context.sha256 = String(repeating: "e", count: 64)
            var input = Kaname_V1_WorkflowProjectedInputBinding()
            input.portID = "input"
            input.value = value
            var episode = Kaname_V1_WorkflowProjectedCaseEpisode()
            episode.installationID = "installation-kay"
            episode.caseID = "case-kay-42"
            episode.episodeID = "episode-run-v2"
            episode.ordinal = 2
            episode.kind = "correction"
            episode.priorEpisodeID = "episode-run-v1"
            episode.triggerKind = "email.received"
            episode.triggerEventID = "email-correction"
            episode.inputs = [input]
            episode.compiledContext = context
            episode.sourceEpisodeIds = ["episode-run-v1"]
            episode.sourceEventIds = ["event-run-v1"]
            episode.startedStorePosition = 11
            projected.episode = episode
        }
        projected.events = (11...(id == "run-v2" ? 18 : 15)).map { position in
            var event = Kaname_V1_WorkflowProjectedEventReference()
            event.eventID = "event-\(id)-\(position)"
            event.kind = "workflow.fixture.\(position)"
            event.storePosition = UInt64(position)
            event.streamSequence = UInt64(position - 10)
            event.occurredAtUnixMillis = 1_000 + Int64(position)
            return event
        }
        projected.retentionPolicy.mode = .duration
        projected.retentionPolicy.days = 30
        projected.purgePreview.manualEligible = true
        projected.purgePreview.automaticEligible = false
        projected.purgePreview.automaticEligibleAtUnixMillis = 2_592_001_040
        projected.purgePreview.affectedAttemptIds = [attempt.attemptID]
        projected.purgePreview.affectedValueIds = [value.valueID]
        projected.purgePreview.affectedFileHandleIds = [value.storage.handleID]
        projected.purgePreview.retainedPromotedHandleIds = ["workflow-value-\(id)"]
        projected.purgePreview.affectedValueBytes = value.byteCount
        projected.purgePreview.affectedEffectIds = id == "run-v2" ? ["effect-run-v2"] : []
        projected.purgePreview.evidenceDigest = String(repeating: "0", count: 64)
        return projected
    }
}
