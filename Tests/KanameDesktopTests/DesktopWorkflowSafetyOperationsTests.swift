import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowSafetyOperationsTests {
    @Test
    func purgeRemovesOnlySettledOrdinaryBytesAndRecordsRetainedReasons() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 80_000 }
        )
        let manifest = basicManifest(id: "org.example.retention")
        try DesktopWorkflowTestSupport.install(manifest, into: model)
        let run = try DesktopWorkflowTestSupport.prepareRun(model: model, workflowID: manifest.id, nonce: "standing")
        let storage = try #require(model.workflowStorage(workflowID: manifest.id))
        let ordinaryBytes = Data("ordinary private content".utf8)
        let promotedBytes = Data("promoted private content".utf8)
        let ordinary = try storage.importArtifact(
            data: ordinaryBytes, filename: "ordinary.txt", mediaType: "text/plain", createdAtUnixMillis: 80_000
        )
        let promoted = try storage.importArtifact(
            data: promotedBytes, filename: "promoted.txt", mediaType: "text/plain", createdAtUnixMillis: 80_000
        )
        #expect(model.bindWorkflowArtifactRole(
            workflowID: manifest.id, workItemID: run.workItemID, episodeID: run.episodeID,
            role: "ordinary-output", artifact: ordinary, createdByRunID: run.runID
        ) != nil)
        #expect(model.bindWorkflowArtifactRole(
            workflowID: manifest.id, workItemID: run.workItemID, episodeID: run.episodeID,
            role: "durable-output", artifact: promoted, createdByRunID: run.runID
        ) != nil)
        #expect(model.promoteWorkflowContent(
            workflowID: manifest.id, artifactDigest: promoted.sha256,
            reason: "Explicitly retained as the accepted durable deliverable."
        ))
        #expect(model.closeWorkflowWorkItem(id: run.workItemID, accepted: true))
        let plan = try #require(model.previewWorkflowPurge(workflowID: manifest.id, mode: .manual))
        #expect(plan.eligibleDigests == [ordinary.sha256])
        #expect(plan.eligibleBytes == ordinaryBytes.count)
        #expect(plan.retained[promoted.sha256] == "Explicitly promoted durable artifact.")

        let receiptID = try #require(try model.executeWorkflowPurge(plan, storage: storage))
        #expect(throws: DesktopWorkflowStorageError.artifactUnavailable) {
            try storage.artifactData(sha256: ordinary.sha256)
        }
        #expect(try storage.artifactData(sha256: promoted.sha256) == promotedBytes)
        let receipt = try #require(model.snapshot.operations.workflows.purgeReceipts.first { $0.id == receiptID })
        #expect(receipt.removedBytes == ordinaryBytes.count)
        #expect(receipt.retainedCountsByReason["Explicitly promoted durable artifact."] == 1)
        let encodedReceipt = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        #expect(!encodedReceipt.contains("ordinary private content"))
        #expect(!encodedReceipt.contains("promoted private content"))
    }

    @Test
    func interruptedBatchRequiresReconciliationAndFailedItemsRequireExplicitRetry() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-batch-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 90_000 }
        )
        let manifest = batchManifest()
        try DesktopWorkflowTestSupport.install(manifest, into: model)
        let run = try DesktopWorkflowTestSupport.prepareRun(model: model, workflowID: manifest.id, nonce: "batch")
        let records = try model.prepareWorkflowBatch(
            runID: run.runID, stepID: "batch", input: Data(#"{"items":[{"id":1},{"id":2}]}"#.utf8)
        )
        #expect(model.updateWorkflowBatchItem(id: records[0].id, state: .running))
        #expect(model.updateWorkflowBatchItem(id: records[1].id, state: .failed, error: "Synthetic failure"))
        #expect(model.recoverInterruptedWorkflowBatch(runID: run.runID, stepID: "batch") == 1)
        #expect(model.snapshot.operations.workflows.batchItems.first { $0.id == records[0].id }?.state == .unknown)
        #expect(!model.retryFailedWorkflowBatchItems(ids: [records[0].id]))
        #expect(model.retryFailedWorkflowBatchItems(ids: [records[1].id]))
        #expect(model.reconcileUnknownWorkflowBatchItem(
            id: records[0].id, outcomeKnown: false, succeeded: false, detail: "Provider still inconclusive"
        ))
        #expect(model.snapshot.operations.workflows.batchItems.first { $0.id == records[0].id }?.state == .unknown)
        #expect(model.reconcileUnknownWorkflowBatchItem(
            id: records[0].id, outcomeKnown: true, succeeded: true,
            outputDigest: DesktopWorkflowStructuredValue.digest(Data("verified".utf8)), detail: "Verified remotely"
        ))
        #expect(model.snapshot.operations.workflows.batchItems.first { $0.id == records[0].id }?.state == .succeeded)
    }

    private func basicManifest(id: String) -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 1, id: id, name: "Safety fixture", summary: "Synthetic safety fixture.",
            icon: "lock.shield", version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [.init(id: "complete", name: "Complete", kind: .complete)], permissions: .init(),
            correlationSummary: "Manual", contextSummary: "Synthetic", completionSummary: "Complete"
        )
    }

    private func batchManifest() -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: "org.example.batch-recovery", name: "Batch fixture",
            summary: "Synthetic batch recovery fixture.", icon: "square.stack.3d.up",
            version: "1.0.0", source: "Kaname tests", license: "MIT", triggers: [.manual],
            steps: [
                .init(
                    id: "batch", name: "Batch", kind: .forEach,
                    transitions: [
                        .init(outcome: .succeeded, targetStepID: "complete"),
                        .init(outcome: .failed, targetStepID: "complete"),
                    ],
                    batchPolicy: .init(itemsPointer: "/items", maximumItems: 10, maximumConcurrency: 1)
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(), correlationSummary: "Manual", contextSummary: "Synthetic",
            completionSummary: "Batch complete"
        )
    }

}
