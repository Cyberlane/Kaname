import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowTransferTests {
    private let capabilities: Set<String> = ["kaname.email.draft"]

    @Test
    func canonicalPackageRoundTripsWithoutInstallationState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 1_000 }
        )
        let manifest = makeManifest()
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: capabilities
        )

        let exported = try model.exportWorkflowPackage(workflowID: manifest.id)
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)
        #expect(exported == canonical)
        let text = String(decoding: exported, as: UTF8.self)
        #expect(!text.contains("workItems"))
        #expect(!text.contains("account-private"))
    }

    @Test
    func encryptedInstallationRequiresPassphraseAndImportsWithAuthorityDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-workflow-transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceStore = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("source/Desktop/workspace.json")
        )
        let source = DesktopAppModel(store: sourceStore, now: { 2_000 })
        let manifest = makeManifest()
        _ = try source.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: capabilities,
            enable: true
        )
        let bindingID = try #require(source.bindWorkflowTrigger(
            workflowID: manifest.id,
            trigger: .email,
            source: "gmail",
            accountIDs: ["account-private"],
            sourceFilter: "from:example.invalid",
            enabled: true
        ))
        let workItemID = try #require(source.createWorkflowWorkItem(
            workflowID: manifest.id,
            title: "Private correction",
            goal: "Produce an updated document"
        ))
        let eventID = try #require(source.observeWorkflowExternalEvent(
            source: "gmail",
            accountID: "account-private",
            conversationID: "thread-private",
            messageID: "message-private",
            cursor: "cursor-private",
            payloadDigest: "payload-digest",
            deduplicationKey: "dedupe-private"
        ))
        let episodeID = try #require(source.createWorkflowEpisode(
            workItemID: workItemID,
            sourceEventID: eventID,
            sourceMessageID: "message-private",
            intent: .correction,
            summary: "Replace the previous document",
            deltaSummary: "Output changed"
        ))
        let contextID = try #require(source.compileWorkflowContext(
            workItemID: workItemID,
            episodeID: episodeID,
            request: "Produce the requested update.",
            references: []
        ))
        let runID = try #require(source.queueWorkflowRun(
            workItemID: workItemID,
            episodeID: episodeID,
            contextSnapshotID: contextID
        ))
        let effectID = try #require(source.proposeWorkflowEffect(
            workItemID: workItemID,
            episodeID: episodeID,
            runID: runID,
            stepID: "draft",
            kind: "email-draft",
            accountID: "account-private",
            exactTarget: "draft:private",
            contentDigest: "content-digest",
            attachmentDigests: []
        ))

        let passphrase = "correct horse battery staple"
        let encrypted = try source.exportWorkflowInstallation(workflowID: manifest.id, passphrase: passphrase)
        #expect(throws: DesktopWorkflowTransferError.invalidPassphrase) {
            try source.previewWorkflowInstallation(encrypted, passphrase: "incorrect passphrase")
        }

        let targetStore = FileDesktopStateStore(
            fileURL: root.appendingPathComponent("target/Desktop/workspace.json")
        )
        let target = DesktopAppModel(store: targetStore, now: { 3_000 })
        let payload = try target.previewWorkflowInstallation(encrypted, passphrase: passphrase)
        #expect(payload.state.workItems.count == 1)
        _ = try target.importWorkflowInstallation(payload, registeredCapabilityIDs: capabilities)

        let definition = try #require(target.workflowDefinitions.first)
        #expect(definition.enabled == false)
        let importedBinding = try #require(target.snapshot.operations.workflows.triggerBindings.first { $0.id == bindingID })
        #expect(importedBinding.enabled == false)
        #expect(importedBinding.lastCursor == nil)
        let importedRun = try #require(target.snapshot.operations.workflows.runs.first { $0.id == runID })
        #expect(importedRun.state == .cancelled)
        let importedEffect = try #require(target.snapshot.operations.workflows.effects.first { $0.id == effectID })
        #expect(importedEffect.state == .cancelled)
        #expect(importedEffect.approvalID == nil)
        #expect(target.snapshot.operations.workflows.workItems.first?.state == .needsAttention)
        #expect(target.snapshot.operations.audit.last?.action == "installation-imported")
    }

    @Test
    func installationImportRefusesExistingWorkflowIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 1_000 }
        )
        let manifest = makeManifest()
        let data = try DesktopWorkflowPackageCodec.canonicalData(manifest)
        _ = try source.installWorkflowPackage(manifestData: data, registeredCapabilityIDs: capabilities)
        let encrypted = try source.exportWorkflowInstallation(
            workflowID: manifest.id,
            passphrase: "a sufficiently long passphrase"
        )
        let payload = try source.previewWorkflowInstallation(encrypted, passphrase: "a sufficiently long passphrase")
        #expect(throws: DesktopWorkflowTransferError.installationConflict) {
            try source.importWorkflowInstallation(payload, registeredCapabilityIDs: capabilities)
        }
    }

    private func makeManifest() -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 1,
            id: "test.portable-workflow",
            name: "Portable workflow",
            summary: "A synthetic portable workflow",
            icon: "shippingbox",
            version: "1.0.0",
            source: "Synthetic test",
            license: "MIT",
            triggers: [.manual, .email],
            steps: [
                .init(
                    id: "draft",
                    name: "Create draft",
                    kind: .createEmailDraft,
                    capabilityID: "kaname.email.draft",
                    retryLimit: 0,
                    isIdempotent: true
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(
                permissions: [.emailDraft],
                capabilityIDs: ["kaname.email.draft"]
            ),
            correlationSummary: "Manual or exact email binding",
            contextSummary: "Current request and verified facts",
            completionSummary: "A local draft is ready"
        )
    }

    private func temporaryDirectory() throws -> URL {
        try TestTemporaryDirectory.make(prefix: "kaname-workflow-transfer-tests")
    }
}
