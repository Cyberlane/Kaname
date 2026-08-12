import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowHostFrameworkTests {
    private let objectSchema = #"{"type":"object","required":["needsReview","value"],"properties":{"needsReview":{"type":"boolean"},"value":{"type":"string"}},"additionalProperties":false}"#

    @Test
    func typedGraphRoutesToSchemaDrivenReviewAndResumesDurably() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-graph-review")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, now: 10_000)
        let review = DesktopWorkflowReviewContract(
            title: "Review the proposed value",
            summary: "Approve, reject, or edit the structured result.",
            inputSchema: objectSchema,
            outputSchema: objectSchema,
            actions: [
                .init(id: "reject", label: "Reject", kind: .reject),
                .init(id: "edit", label: "Save edit", kind: .edit),
                .init(id: "approve", label: "Approve", kind: .approve, isPrimary: true),
            ]
        )
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.typed-review", name: "Typed review",
            summary: "Synthetic typed graph fixture.", icon: "arrow.triangle.branch",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [
                .init(
                    id: "route", name: "Route", kind: .branch,
                    transitions: [
                        .init(
                            outcome: .matched, targetStepID: "review",
                            predicates: [.init(pointer: "/needsReview", operation: .equals, value: "1")]
                        ),
                        .init(outcome: .notMatched, targetStepID: "complete"),
                    ]
                ),
                .init(
                    id: "review", name: "Review", kind: .humanReview,
                    transitions: [
                        .init(outcome: .approved, targetStepID: "complete"),
                        .init(outcome: .rejected, targetStepID: "complete"),
                        .init(outcome: .edited, targetStepID: "complete"),
                    ],
                    reviewContract: review
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(), correlationSummary: "Manual", contextSummary: "Synthetic",
            completionSummary: "A terminal graph node completed"
        )
        try install(manifest, into: model)
        let run = try prepareRun(model: model, workflowID: manifest.id, now: 10_000)
        let input = Data(#"{"needsReview":true,"value":"draft"}"#.utf8)
        let runtime = DesktopWorkflowRuntime(model: model, invoker: UnavailableInvoker())

        #expect(await runtime.executeNext(runID: run.runID, input: input) == .completedStep(stepID: "route", output: input))
        #expect(await runtime.executeNext(runID: run.runID, input: input) == .waiting(
            stepID: "review", reason: "Human review is required before this run can continue."
        ))
        let request = try #require(model.pendingWorkflowReviews.first)
        #expect(request.proposedValueDigest == DesktopWorkflowStructuredValue.digest(input))
        _ = try #require(model.recordWorkflowValidation(
            workItemID: run.workItemID, episodeID: run.episodeID, runID: run.runID,
            validatorID: "fixture.validator", validatorRevision: "1.0.0", targetID: "draft",
            severity: .blocking, outcome: .passed, summary: "The original draft passed."
        ))
        #expect(model.resolveWorkflowReview(id: request.id, actionID: "edit", value: input, reviewer: "Fixture reviewer"))
        #expect(model.snapshot.operations.workflows.validations.first?.outcome == .notRun)
        #expect(model.snapshot.operations.workflows.validations.first?.waiverDecisionID == nil)
        #expect(await runtime.executeUntilBlocked(runID: run.runID, initialInput: input) == .completedRun)
        #expect(model.snapshot.operations.workflows.transitionRecords.map(\.fromStepID) == ["route", "review"])
        #expect(model.snapshot.operations.workflows.reviewRequests.first?.state == .resolved)
    }

    @Test
    func correlatedEventResolvesDurableWaitAndResumesExistingRun() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-resumable-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, now: 20_000)
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.wait", name: "Wait fixture",
            summary: "Synthetic durable subscription fixture.", icon: "clock.arrow.circlepath",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.email],
            steps: [
                .init(
                    id: "wait", name: "Wait for reply", kind: .waitForEmail,
                    transitions: [
                        .init(outcome: .succeeded, targetStepID: "complete"),
                        .init(outcome: .timedOut, targetStepID: "complete"),
                    ],
                    waitContract: .init(
                        connectorID: "kaname.gmail", source: "gmail", accountPointer: "/account",
                        conversationPointer: "/conversation", correlationPointer: "/correlation", timeoutSeconds: 600
                    )
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(permissions: [.emailRead]), correlationSummary: "Exact correlation token",
            contextSummary: "Current episode", completionSummary: "A matching event resumes the run"
        )
        try install(manifest, into: model)
        let run = try prepareRun(model: model, workflowID: manifest.id, now: 20_000)
        let input = Data(#"{"account":"account-1","conversation":"thread-1","correlation":"case-42"}"#.utf8)
        let runtime = DesktopWorkflowRuntime(model: model, invoker: UnavailableInvoker())
        #expect(await runtime.executeNext(runID: run.runID, input: input) == .waiting(
            stepID: "wait", reason: "The run is waiting for a correlated email episode."
        ))
        let wait = try #require(model.activeWorkflowWaits.first)
        #expect(wait.correlationValue == "case-42")
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "gmail", accountID: "account-1", conversationID: "thread-1", messageID: "message-2",
            cursor: "cursor-2", payloadDigest: "payload", deduplicationKey: "event-2"
        ))
        let eventPayload = Data(#"{"correlation":"case-42","message":"reply"}"#.utf8)
        #expect(model.resolveWorkflowWaitSubscriptions(eventID: eventID, payload: eventPayload) == [wait.id])
        #expect(await runtime.executeUntilBlocked(runID: run.runID, initialInput: eventPayload) == .completedRun)
        #expect(model.snapshot.operations.workflows.waitSubscriptions.first?.state == .resolved)
        #expect(model.snapshot.operations.workflows.waitSubscriptions.first?.resolvedEventID == eventID)
    }

    @Test
    func declaredFailureEdgePreservesErrorAndContinuesWithoutRetrying() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-error-route")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, now: 25_000)
        let capabilityID = "org.example.missing-input"
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.error-route", name: "Error route",
            summary: "Synthetic handled-failure fixture.", icon: "exclamationmark.arrow.triangle.2.circlepath",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [
                .init(
                    id: "load", name: "Load required state", kind: .invokeTool, capabilityID: capabilityID,
                    retryLimit: 0, isIdempotent: true,
                    stateInputs: [.init(namespace: "fixture", key: "missing", required: true)],
                    transitions: [
                        .init(outcome: .succeeded, targetStepID: "complete"),
                        .init(outcome: .failed, targetStepID: "complete"),
                    ]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(capabilityIDs: [capabilityID]), correlationSummary: "Manual",
            contextSummary: "Synthetic", completionSummary: "Handled failure reaches the terminal node"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [capabilityID], enable: true
        )
        let run = try prepareRun(model: model, workflowID: manifest.id, now: 25_000)
        let runtime = DesktopWorkflowRuntime(model: model, invoker: UnavailableInvoker())
        #expect(await runtime.executeUntilBlocked(runID: run.runID, initialInput: Data("{}".utf8)) == .completedRun)
        #expect(model.snapshot.operations.workflows.stepAttempts.first?.state == .failed)
        #expect(model.snapshot.operations.workflows.transitionRecords.first?.outcome == .failed)
        #expect(model.snapshot.operations.workflows.runs.first?.state == .completed)
    }

    @Test
    func workflowDatasetUsesSchemaUniqueKeysAndOptimisticRevision() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-dataset")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, now: 30_000)
        let rowSchema = #"{"type":"object","required":["id","name"],"properties":{"id":{"type":"string"},"name":{"type":"string"}},"additionalProperties":false}"#
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.dataset", name: "Dataset fixture",
            summary: "Synthetic dataset fixture.", icon: "tablecells", version: "1.0.0",
            source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [.init(id: "complete", name: "Complete", kind: .complete)], permissions: .init(),
            correlationSummary: "Manual", contextSummary: "Synthetic", completionSummary: "Stored",
            datasets: [.init(
                id: "contacts", name: "Contacts", rowSchema: rowSchema,
                uniqueKeyPointers: ["/id"], indexPointers: ["/name"], maximumRows: 10
            )]
        )
        try install(manifest, into: model)
        let run = try prepareRun(model: model, workflowID: manifest.id, now: 30_000)
        let first = Data(#"{"id":"1","name":"First"}"#.utf8)
        #expect(try model.upsertWorkflowDataset(
            workflowID: manifest.id, runID: run.runID,
            mutation: .request(datasetID: "contacts", scopeID: manifest.id, expectedRevision: 0, rows: [first])
        ) == 1)
        #expect(throws: DesktopWorkflowHostFrameworkError.datasetConflict) {
            try model.upsertWorkflowDataset(
                workflowID: manifest.id, runID: run.runID,
                mutation: .request(datasetID: "contacts", scopeID: manifest.id, expectedRevision: 0, rows: [first])
            )
        }
        let updated = Data(#"{"id":"1","name":"Updated"}"#.utf8)
        #expect(try model.upsertWorkflowDataset(
            workflowID: manifest.id, runID: run.runID,
            mutation: .request(datasetID: "contacts", scopeID: manifest.id, expectedRevision: 1, rows: [updated])
        ) == 2)
        let row = try #require(model.workflowDatasetRows(
            workflowID: manifest.id, datasetID: "contacts", scopeID: manifest.id
        ).first)
        #expect(row.value == updated)
        #expect(row.revision == 2)
    }

    @Test
    func connectorEffectUsesPredicateBoundGrantAndReconcilesKnownOutcome() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-connector")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root, now: 40_000)
        let manifest = connectorManifest()
        try install(manifest, into: model)
        let run = try prepareRun(model: model, workflowID: manifest.id, now: 40_000)
        let grantID = try #require(model.createWorkflowAuthorityGrant(
            workflowID: manifest.id, connectorID: "org.example.connector", effectKind: "archive",
            accountIDs: ["account-1"],
            targetPredicates: [.init(pointer: "/sender", operation: .equals, value: "sender@example.com")],
            requiresManualRun: true, maximumItemsPerExecution: 5,
            postcondition: "The connector must verify that the item is no longer in the inbox.",
            expiresAtUnixMillis: 50_000
        ))
        let coordinator = DesktopWorkflowEffectCoordinator(model: model)
        coordinator.register(SyntheticConnector())
        let scopedRequest = DesktopWorkflowEffectRequest(
            workflowID: manifest.id, workItemID: run.workItemID, episodeID: run.episodeID,
            runID: run.runID, stepID: "effect", connectorID: "org.example.connector",
            effectKind: "archive", accountID: "account-1",
            target: Data(#"{"sender":"sender@example.com","id":"message-1"}"#.utf8),
            payload: Data("{}".utf8), artifactDigests: [], itemCount: 1, manuallyInitiated: true
        )
        let effectID = try await coordinator.preview(scopedRequest)
        #expect(model.snapshot.operations.workflows.effectPreviews.first?.authorityGrantID == grantID)
        let receipt = try await coordinator.execute(effectID: effectID)
        #expect(receipt.outcomeKnown && receipt.succeeded)
        #expect(model.snapshot.operations.workflows.effects.first?.state == .reconciled)
        #expect(model.snapshot.operations.workflows.authorityGrants.first?.useCount == 1)
    }

    @Test
    func extensionManifestRejectsUnsafeComponentPaths() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-extension")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Synthetic.kanameextension", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("Workflows", isDirectory: true),
            withIntermediateDirectories: true
        )
        let component = Data("{}".utf8)
        let valid = DesktopWorkflowExtensionManifest(
            schemaVersion: 1, id: "org.example.extension", name: "Synthetic extension", version: "1.0.0",
            source: "Kaname tests", license: "MIT",
            components: [.init(
                kind: .workflow, path: "Workflows/example.workflow.json",
                sha256: DesktopWorkflowStructuredValue.digest(component)
            )]
        )
        let data = try JSONEncoder().encode(valid)
        #expect(try DesktopWorkflowExtensionCodec.decode(data) == valid)
        try data.write(to: package.appendingPathComponent(DesktopWorkflowExtensionStore.manifestFilename))
        try component.write(to: package.appendingPathComponent("Workflows/example.workflow.json"))
        let inspection = try DesktopWorkflowExtensionStore().inspectPackage(at: package)
        #expect(inspection.manifest == valid)
        #expect(inspection.totalBytes == data.count + component.count)
        try Data("undeclared".utf8).write(to: package.appendingPathComponent(".hidden"))
        #expect(throws: DesktopWorkflowHostFrameworkError.self) {
            try DesktopWorkflowExtensionStore().inspectPackage(at: package)
        }
        try FileManager.default.removeItem(at: package.appendingPathComponent(".hidden"))
        var invalid = valid
        invalid.components[0].path = "../escape"
        #expect(throws: DesktopWorkflowHostFrameworkError.self) {
            try DesktopWorkflowExtensionCodec.validate(invalid)
        }
    }

    @Test
    func shippedV2ExampleIsAValidDomainNeutralHostPackage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/Workflows/generic-case-review.workflow.json")
        let packageData = try Data(contentsOf: url)
        let manifest = try DesktopWorkflowPackageCodec.decode(
            packageData, registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers
        )
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.steps.contains { $0.reviewContract != nil })
        #expect(manifest.steps.contains { $0.waitContract != nil })
        #expect(manifest.datasets?.map(\.id) == ["case-index"])
        #expect(manifest.source == "Kaname synthetic example")
    }

    @Test
    func executionEvidenceIsBoundedAndPrivacyFiltered() {
        let evidence = DesktopWorkflowCapabilityExecutionEvidence(
            standardOutput: "authorization: Bearer private-token user@example.com /Users/private/work",
            standardError: "api_key=super-secret",
            elapsedMilliseconds: 42
        )
        #expect(!evidence.standardOutput.contains("private-token"))
        #expect(!evidence.standardOutput.contains("user@example.com"))
        #expect(!evidence.standardOutput.contains("/Users/private"))
        #expect(!evidence.standardError.contains("super-secret"))
        #expect(evidence.elapsedMilliseconds == 42)
    }

    @Test
    func agentPolicyMustUseReviewedRegisteredCapabilities() throws {
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.agent", name: "Agent fixture",
            summary: "Synthetic bounded agent fixture.", icon: "cpu",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [
                .init(
                    id: "agent", name: "Analyze", kind: .agent,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")],
                    executionPolicy: .init(maximumAttempts: 1),
                    agentPolicy: .init(allowedCapabilityIDs: ["kaname.model.structured"])
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(), correlationSummary: "Manual", contextSummary: "Synthetic",
            completionSummary: "The bounded agent completes"
        )
        #expect(throws: DesktopWorkflowPackageError.self) {
            try DesktopWorkflowPackageCodec.validate(
                manifest, registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers
            )
        }
    }

    private func makeModel(root: URL, now: Int64) -> DesktopAppModel {
        DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { now }
        )
    }

    private func connectorManifest() -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.connector", name: "Connector fixture",
            summary: "Synthetic connector boundary fixture.", icon: "bolt.horizontal.circle",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [
                .init(
                    id: "effect", name: "Apply connector effect", kind: .effect, isIdempotent: false,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(permissions: [.externalEffects]), correlationSummary: "Manual", contextSummary: "Exact target",
            completionSummary: "Connector reconciles the effect"
        )
    }

    private func install(_ manifest: DesktopWorkflowPackageManifest, into model: DesktopAppModel) throws {
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [], enable: true
        )
    }

    private func prepareRun(
        model: DesktopAppModel,
        workflowID: String,
        now: Int64
    ) throws -> (workItemID: String, episodeID: String, runID: String) {
        let workItemID = try #require(model.createWorkflowWorkItem(
            workflowID: workflowID, title: "Fixture", goal: "Exercise the generic host"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "fixture", deduplicationKey: "fixture-\(workflowID)-\(now)"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workItemID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Fixture", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workItemID, episodeID: episodeID, request: "Run fixture", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(
            workItemID: workItemID, episodeID: episodeID, contextSnapshotID: contextID
        ))
        return (workItemID, episodeID, runID)
    }
}

private struct UnavailableInvoker: DesktopWorkflowCapabilityInvoking {
    func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        throw DesktopWorkflowCapabilityError.executionUnavailable
    }
}

private struct SyntheticConnector: DesktopWorkflowConnector {
    let identifier = "org.example.connector"

    func preview(_ request: DesktopWorkflowEffectRequest) async throws -> DesktopWorkflowEffectPreview {
        DesktopWorkflowEffectPreview(
            title: "Archive one item", summary: "Remove the exact synthetic item from the inbox.",
            exactTarget: "account-1/message-1", structuredTarget: request.target,
            itemCount: request.itemCount, consequences: ["The item leaves the inbox."], reversible: true
        )
    }

    func execute(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        .result(remoteReceipt: "receipt-1", outcomeKnown: true, succeeded: true, detail: "Postcondition verified.")
    }

    func reconcile(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        .result(remoteReceipt: "receipt-1", outcomeKnown: true, succeeded: true, detail: "Postcondition verified.")
    }
}
