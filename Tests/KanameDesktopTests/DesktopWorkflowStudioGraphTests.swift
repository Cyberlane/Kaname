import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowStudioGraphTests {
    @Test
    func branchedManifestRoundTripsWithoutLinearizingAndSupportsUndoRedo() throws {
        let model = try makeModel(prefix: "kaname-studio-graph")
        let draftID = try #require(model.createWorkflowStudioDraft(name: "Imported", summary: "Fixture"))
        let manifest = branchedManifest()
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)

        #expect(model.replaceWorkflowStudioDraftSource(
            id: draftID,
            source: try #require(String(data: canonical, encoding: .utf8))
        ))
        #expect(model.workflowStudioCanonicalSource(draftID: draftID)?.data(using: .utf8) == canonical)

        let imported = try #require(model.snapshot.operations.workflows.studioDrafts.first { $0.id == draftID })
        let originalSteps = imported.steps
        var editedSteps = originalSteps
        editedSteps[0].name = "Classify inbox event"
        #expect(model.updateWorkflowStudioDraft(
            id: draftID,
            triggerKinds: imported.triggerKinds,
            steps: editedSteps,
            permissions: imported.permissions,
            subflows: imported.subflows,
            canvasPositions: imported.canvasPositions,
            manifestMetadata: imported.manifestMetadata
        ))
        #expect(model.undoWorkflowStudioDraft(id: draftID))
        #expect(model.snapshot.operations.workflows.studioDrafts.first { $0.id == draftID }?.steps == originalSteps)
        #expect(model.redoWorkflowStudioDraft(id: draftID))
        let redone = try #require(model.snapshot.operations.workflows.studioDrafts.first { $0.id == draftID })
        #expect(redone.steps == editedSteps)
        #expect(redone.steps[0].transitions == originalSteps[0].transitions)
    }

    @Test
    func typedReferencesRejectForwardSourcesAndAcceptPriorOutputs() {
        let schema = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}"#
        let mapping = DesktopWorkflowDataMapping(
            id: "message",
            targetPointer: "/message",
            reference: .init(id: "classified", source: .stepOutput, sourceID: "classify", pointer: "/message", schema: schema)
        )
        let classify = DesktopWorkflowStepDefinition(
            id: "classify", name: "Classify", kind: .classifyEvent,
            transitions: [.init(outcome: .always, targetStepID: "review")]
        )
        let review = DesktopWorkflowStepDefinition(
            id: "review", name: "Review", kind: .validate,
            transitions: [.init(outcome: .always, targetStepID: "complete")],
            inputMappings: [mapping]
        )
        let complete = DesktopWorkflowStepDefinition(id: "complete", name: "Complete", kind: .complete)

        #expect(DesktopWorkflowStudioValidation.diagnostics(
            steps: [classify, review, complete], metadata: .newDraft
        ).isEmpty)
        #expect(DesktopWorkflowStudioValidation.diagnostics(
            steps: [review, classify, complete], metadata: .newDraft
        ).contains { $0.path.hasSuffix("/reference/sourceID") })
    }

    @Test
    func boundedBatchPersistsPerItemProgressAndRunProjection() async throws {
        let model = try makeModel(prefix: "kaname-studio-batch")
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2,
            id: "org.example.batch",
            name: "Batch fixture",
            summary: "Exercises durable item receipts.",
            icon: "square.stack.3d.up",
            version: "1.0.0",
            source: "Synthetic fixture",
            license: "MIT",
            triggers: [.manual],
            steps: [
                .init(
                    id: "items", name: "Process items", kind: .forEach,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")],
                    batchPolicy: .init(maximumItems: 4, maximumConcurrency: 2, aggregation: .requireAll)
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(),
            correlationSummary: "Manual fixture",
            contextSummary: "Frozen test input",
            completionSummary: "Every item completed"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [],
            enable: true
        )
        let runID = try makeRun(model: model, workflowID: manifest.id)
        let runtime = DesktopWorkflowRuntime(model: model, invoker: UnusedWorkflowInvoker())
        let input = Data(#"{"items":[{"id":1},{"id":2},{"id":3}]}"#.utf8)

        let first = await runtime.executeNext(runID: runID, input: input)
        guard case .completedStep(stepID: "items", _) = first else {
            Issue.record("Expected the batch step to complete, got \(first)")
            return
        }
        #expect(await runtime.executeNext(runID: runID, input: input) == .completedRun)
        let items = model.snapshot.operations.workflows.batchItems.filter { $0.runID == runID }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.state == .succeeded && $0.attempt == 1 && $0.outputDigest != nil })
        let projection = model.workflowRunProjection(runID: runID)
        #expect(projection.first { $0.stepID == "items" }?.state == .succeeded)
        #expect(projection.first { $0.stepID == "items" }?.completedItems == 3)
        #expect(DesktopWorkflowRunNodeState.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(model.queueWorkflowDebugRun(
            priorRunID: runID, action: .retryFailedStep, stepID: "items"
        ) == nil)
        let checkpointRunID = try #require(model.queueWorkflowDebugRun(
            priorRunID: runID, action: .restartFromCheckpoint, stepID: "items"
        ))
        let checkpointRun = try #require(model.snapshot.operations.workflows.runs.first { $0.id == checkpointRunID })
        #expect(checkpointRun.retryMode == .exactReplay)
        #expect(checkpointRun.startStepID == "complete")
        #expect(model.queueWorkflowDebugRun(priorRunID: runID, action: .reprocessCurrentRevision) != nil)
    }

    private func makeModel(prefix: String) throws -> DesktopAppModel {
        let root = try TestTemporaryDirectory.make(prefix: prefix)
        return DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 10_000 }
        )
    }

    private func makeRun(model: DesktopAppModel, workflowID: String) throws -> String {
        let workID = try #require(model.createWorkflowWorkItem(
            workflowID: workflowID, title: "Batch", goal: "Process bounded items"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "input", deduplicationKey: UUID().uuidString
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Run", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "Process", references: []
        ))
        return try #require(model.queueWorkflowRun(
            workItemID: workID, episodeID: episodeID, contextSnapshotID: contextID
        ))
    }

    private func branchedManifest() -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 3,
            id: "org.example.branched",
            name: "Branched fixture",
            summary: "Preserves explicit graph semantics.",
            icon: "arrow.triangle.branch",
            version: "1.0.0",
            source: "Synthetic fixture",
            license: "MIT",
            triggers: [.manual],
            steps: [
                .init(
                    id: "classify", name: "Classify", kind: .classifyEvent,
                    transitions: [
                        .init(
                            outcome: .matched,
                            targetStepID: "review",
                            predicates: [.init(pointer: "/needsReview", operation: .equals, value: "true")]
                        ),
                        .init(outcome: .notMatched, targetStepID: "complete"),
                    ]
                ),
                .init(
                    id: "review", name: "Review", kind: .humanReview,
                    transitions: [
                        .init(outcome: .approved, targetStepID: "complete"),
                        .init(outcome: .rejected, targetStepID: "complete"),
                    ],
                    reviewContract: .init(
                        title: "Review classification",
                        summary: "Confirm the structured result.",
                        inputSchema: #"{"type":"object"}"#,
                        outputSchema: #"{"type":"object"}"#,
                        actions: [
                            .init(id: "approve", label: "Approve", kind: .approve, isPrimary: true),
                            .init(id: "reject", label: "Reject", kind: .reject),
                        ]
                    )
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(),
            correlationSummary: "Manual fixture",
            contextSummary: "Frozen input",
            completionSummary: "A terminal branch completed",
            hostCompatibility: .init(minimumWorkspaceSchema: 24),
            publisher: .init(name: "Fixture author", identifier: "fixture.author"),
            provenance: .init(buildSystem: "Kaname tests")
        )
    }
}

private struct UnusedWorkflowInvoker: DesktopWorkflowCapabilityInvoking {
    func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        throw DesktopWorkflowCapabilityError.executionUnavailable
    }
}
