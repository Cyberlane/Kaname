import CryptoKit
import Foundation
import Testing
@testable import KanameDesktop

@Suite
@MainActor
struct DesktopWorkflowPackageEcosystemTests {
    @Test
    func starterCatalogIsProviderNeutralSeparatedAndDeterministicallyQualified() throws {
        let manifests = DesktopWorkflowStarterCatalog.manifests
        let suites = DesktopWorkflowStarterCatalog.fixtureSuites
        #expect(manifests.count == 15)
        #expect(Set(manifests.map(\.id)).count == 15)
        #expect(suites.count == 15)
        #expect(Set(suites.map(\.workflowID)) == Set(manifests.map(\.id)))

        for manifest in manifests {
            try DesktopWorkflowPackageCodec.validate(manifest, registeredCapabilityIDs: [])
            let data = try DesktopWorkflowPackageCodec.canonicalData(manifest)
            #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("gmail"))
            let suite = try #require(suites.first { $0.workflowID == manifest.id })
            let run = try DesktopWorkflowSimulationEngine.run(
                workflowID: manifest.id, workflowRevisionID: "synthetic-revision",
                manifestDigest: DesktopWorkflowPackageCodec.digest(data), installationID: nil,
                dependencyLockRevisionID: nil, dependencyLockDigest: nil,
                suite: suite, scenarioID: "synthetic-happy-path", timestamp: 1
            )
            #expect(run.outcome == .passed, "\(manifest.id) did not pass its workflow fixture")
            #expect(DesktopWorkflowSimulationEngine.replay(run))
        }

        let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        let newsletter = try #require(byID["dev.kaname.synthetic.f6-newsletter"])
        let outbound = try #require(byID["dev.kaname.synthetic.f7-outbound-mail"])
        let filters = try #require(byID["dev.kaname.synthetic.f8-filter-rules"])
        #expect(newsletter.permissions.permissions.contains(.network))
        #expect(outbound.permissions.permissions.contains(.emailSend))
        #expect(filters.permissions.permissions.contains(.externalEffects))
        #expect([newsletter, outbound, filters].allSatisfy { manifest in
            (manifest.dependencies ?? []).allSatisfy { $0.id.contains(".s") && !$0.id.contains(".f") }
        })
    }

    @Test
    func syntheticMigrationFixtureDoesNotStopAtFirstHundredMailItems() throws {
        let firstPage = (0..<100).map { index in
            DesktopWorkflowFakeMailItem(
                id: "synthetic-message-\(index)", accountID: "synthetic-account",
                conversationID: "synthetic-conversation-\(index)", sender: "sender@example.invalid",
                subject: "Synthetic message \(index)"
            )
        }
        let finalItem = DesktopWorkflowFakeMailItem(
            id: "synthetic-message-100", accountID: "synthetic-account",
            conversationID: "synthetic-conversation-100", sender: "sender@example.invalid",
            subject: "Synthetic message 100"
        )
        var scenario = DesktopWorkflowFixtureCase(
            id: "more-than-one-page", name: "More than one hundred messages",
            inputJSON: #"{"query":"synthetic complete bounded search"}"#,
            mailPages: [
                .init(id: "page-1", items: firstPage, nextCursor: "page-2"),
                .init(id: "page-2", items: [finalItem]),
            ],
            expectation: .init(outputDigest: "", timelineKinds: [])
        )
        var suite = DesktopWorkflowFixtureSuite(
            id: "synthetic-pagination-regression", workflowID: "synthetic-mail-review",
            workflowVersion: "1.0.0", cases: [scenario]
        )
        let prototype = try DesktopWorkflowSimulationEngine.run(
            workflowID: suite.workflowID, workflowRevisionID: "synthetic-revision",
            manifestDigest: String(repeating: "a", count: 64), installationID: nil,
            dependencyLockRevisionID: nil, dependencyLockDigest: nil,
            suite: suite, scenarioID: scenario.id, timestamp: 1
        )
        scenario.expectation = .init(
            outputDigest: prototype.outputDigest,
            timelineKinds: prototype.timeline.map(\.kind)
        )
        suite.cases = [scenario]

        let run = try DesktopWorkflowSimulationEngine.run(
            workflowID: suite.workflowID, workflowRevisionID: "synthetic-revision",
            manifestDigest: String(repeating: "a", count: 64), installationID: nil,
            dependencyLockRevisionID: nil, dependencyLockDigest: nil,
            suite: suite, scenarioID: scenario.id, timestamp: 2
        )
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(run.outputJSON.utf8)) as? [String: Any]
        )
        let itemIDs = try #require(output["mailItemIDs"] as? [String])
        #expect(run.outcome == .passed)
        #expect(itemIDs.count == 101)
        #expect(itemIDs.contains("synthetic-message-100"))
        #expect(run.timeline.filter { $0.kind == "mail.page" }.count == 2)
    }

    @Test
    func signedTemplatesRejectTamperingAndPersistExactVerification() throws {
        let model = DesktopAppModel(store: EcosystemMemoryStore(), now: { 10_000 })
        let manifest = try #require(DesktopWorkflowStarterCatalog.subflowManifests.first)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let envelope = try DesktopWorkflowTemplateCodec.sign(
            manifest: manifest, signerID: "dev.kaname.starters", privateKey: key
        )
        let fingerprint = envelope.signature.publicKeyFingerprint
        let envelopeData = try JSONEncoder().encode(envelope)
        let revisionID = try model.installSignedWorkflowTemplate(
            envelopeData: envelopeData, registeredCapabilityIDs: [],
            trustedSignerFingerprints: [fingerprint]
        )
        let verification = try #require(model.snapshot.operations.workflows.templateVerifications.first)
        #expect(verification.workflowRevisionID == revisionID)
        #expect(verification.publicKeyFingerprint == fingerprint)

        let subflowID = try model.installSignedWorkflowSubflow(
            envelopeData: envelopeData,
            inputSchema: #"{"type":"object"}"#,
            outputSchema: #"{"type":"object"}"#,
            trustedSignerFingerprints: [fingerprint]
        )
        #expect(subflowID == "\(manifest.id)@\(manifest.version)")
        #expect(model.snapshot.operations.workflows.subflows.contains { $0.id == subflowID && $0.enabled })

        var tampered = envelope
        tampered.signature.manifestDigest = String(repeating: "0", count: 64)
        #expect(throws: DesktopWorkflowTemplateError.digestMismatch) {
            try DesktopWorkflowTemplateCodec.verify(tampered, trustedSignerFingerprints: [fingerprint])
        }
        #expect(throws: DesktopWorkflowTemplateError.untrustedSigner) {
            try DesktopWorkflowTemplateCodec.verify(envelope, trustedSignerFingerprints: [String(repeating: "f", count: 64)])
        }
    }

    @Test
    func exactDependencyLockFlowsIntoRuntimeSimulationAndMigrationEvidence() throws {
        let store = EcosystemMemoryStore()
        let model = DesktopAppModel(store: store, now: { 20_000 })
        let manifest = try #require(DesktopWorkflowStarterCatalog.flowManifests.first)
        let revisionID = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: []
        )
        let installation = try #require(model.workflowInstallations(workflowID: manifest.id).first)
        let locks = DesktopWorkflowStarterCatalog.dependencyLocks(for: manifest)
        #expect(locks.count == 6)
        #expect(try model.reviseWorkflowInstallation(
            id: installation.id, configuration: Data("{}".utf8), bindings: [],
            dependencyLock: locks, capturePolicy: .init(), retentionPolicy: .init()
        ))
        #expect(model.setWorkflowInstallationEnabled(id: installation.id, enabled: true))
        #expect(model.setWorkflowEnabled(id: manifest.id, enabled: true))
        let lockedInstallation = try #require(model.workflowInstallations(workflowID: manifest.id).first)
        let lock = try #require(model.snapshot.operations.workflows.dependencyLockRevisions.first {
            $0.id == lockedInstallation.currentDependencyLockRevisionID
        })

        let workItemID = try #require(model.createWorkflowWorkItem(
            workflowID: manifest.id, title: "Synthetic", goal: "Verify exact locks"
        ))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "synthetic-account", conversationID: nil,
            messageID: nil, cursor: nil, payloadDigest: "synthetic",
            deduplicationKey: "ecosystem-runtime"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workItemID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Synthetic", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workItemID, episodeID: episodeID, request: "Run", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(
            workItemID: workItemID, episodeID: episodeID, contextSnapshotID: contextID,
            installationID: installation.id
        ))
        let runtimeRun = try #require(model.snapshot.operations.workflows.runs.first { $0.id == runID })
        #expect(runtimeRun.workflowRevisionID == revisionID)
        #expect(runtimeRun.installationID == installation.id)
        #expect(runtimeRun.dependencyLockRevisionID == lock.id)
        #expect(model.nextWorkflowStep(runID: runID)?.id == "execute")

        let suite = try #require(DesktopWorkflowStarterCatalog.fixtureSuites.first { $0.workflowID == manifest.id })
        let simulationID = try model.simulateWorkflowFixture(
            workflowID: manifest.id, installationID: installation.id,
            suite: suite, scenarioID: "synthetic-happy-path"
        )
        let simulation = try #require(model.snapshot.operations.workflows.simulationRuns.first { $0.id == simulationID })
        #expect(simulation.workflowRevisionID == revisionID)
        #expect(simulation.dependencyLockRevisionID == lock.id)
        #expect(simulation.dependencyLockDigest == lock.digest)

        let assessmentID = try #require(model.createWorkflowMigrationAssessment(
            workflowID: manifest.id, requiredScenarioIDs: ["synthetic-happy-path"],
            installationID: installation.id
        ))
        _ = try model.recordWorkflowMigrationComparison(
            assessmentID: assessmentID, simulationRunID: simulationID,
            legacySourceRevision: "legacy-fixture@abc123", legacyOutputJSON: simulation.outputJSON
        )
        try model.advanceWorkflowMigration(id: assessmentID, to: .shadow)
        #expect(model.snapshot.operations.workflows.migrationAssessments.first { $0.id == assessmentID }?.stage == .shadow)
    }

    @Test
    func advancementRejectsStaleVersionLockAndEditedEvidence() throws {
        let store = EcosystemMemoryStore()
        let model = DesktopAppModel(store: store, now: { 30_000 })
        let manifest = try #require(DesktopWorkflowStarterCatalog.flowManifests.first)
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest), registeredCapabilityIDs: []
        )
        let installation = try #require(model.workflowInstallations(workflowID: manifest.id).first)
        let locks = DesktopWorkflowStarterCatalog.dependencyLocks(for: manifest)
        #expect(try model.reviseWorkflowInstallation(
            id: installation.id, configuration: Data("{}".utf8), bindings: [], dependencyLock: locks,
            capturePolicy: .init(), retentionPolicy: .init()
        ))
        let suite = try #require(DesktopWorkflowStarterCatalog.fixtureSuites.first { $0.workflowID == manifest.id })
        let simulationID = try model.simulateWorkflowFixture(
            workflowID: manifest.id, installationID: installation.id,
            suite: suite, scenarioID: "synthetic-happy-path"
        )
        let simulation = try #require(model.snapshot.operations.workflows.simulationRuns.first { $0.id == simulationID })
        let assessmentID = try #require(model.createWorkflowMigrationAssessment(
            workflowID: manifest.id, requiredScenarioIDs: [simulation.scenarioID], installationID: installation.id
        ))
        _ = try model.recordWorkflowMigrationComparison(
            assessmentID: assessmentID, simulationRunID: simulationID,
            legacySourceRevision: "legacy@1", legacyOutputJSON: simulation.outputJSON
        )

        #expect(try model.reviseWorkflowInstallation(
            id: installation.id, configuration: Data("{}".utf8), bindings: [],
            dependencyLock: locks + [.init(
                componentID: "dev.kaname.synthetic.optional", kind: .connector,
                version: "1.0.0", digest: String(repeating: "c", count: 64)
            )], capturePolicy: .init(), retentionPolicy: .init()
        ))
        #expect(throws: DesktopWorkflowOperationalError.self) {
            try model.advanceWorkflowMigration(id: assessmentID, to: .shadow)
        }

        var decoded = try JSONDecoder().decode(DesktopAppSnapshot.self, from: try #require(store.data))
        decoded.operations.workflows.migrationComparisons[0].evidenceDigest = String(repeating: "0", count: 64)
        store.data = try JSONEncoder().encode(decoded)
        let restored = DesktopAppModel(store: store, now: { 30_001 })
        #expect(throws: DesktopWorkflowOperationalError.self) {
            try restored.advanceWorkflowMigration(id: assessmentID, to: .shadow)
        }
    }

    @Test
    func installationUpgradeRollbackAndEncryptedTransferStayOffline() throws {
        let source = DesktopAppModel(store: EcosystemMemoryStore(), now: { 40_000 })
        let original = try #require(DesktopWorkflowStarterCatalog.subflowManifests.first)
        let originalID = try source.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(original), registeredCapabilityIDs: []
        )
        let installation = try #require(source.workflowInstallations(workflowID: original.id).first)
        let updated = reversioned(original, version: "2.0.0", permissions: [.externalEffects])
        let updatedID = try source.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(updated), registeredCapabilityIDs: []
        )
        let diff = try #require(source.previewWorkflowUpgrade(installationID: installation.id, toRevisionID: updatedID))
        #expect(diff.permissionBroadening)
        #expect(try source.upgradeWorkflowInstallation(installationID: installation.id, toRevisionID: updatedID))
        #expect(source.workflowInstallations(workflowID: original.id).first { $0.id == installation.id }?.workflowRevisionID == updatedID)
        #expect(try source.rollbackWorkflowInstallation(installationID: installation.id, toRevisionID: originalID))
        #expect(source.workflowInstallations(workflowID: original.id).first { $0.id == installation.id }?.workflowRevisionID == originalID)
        #expect(source.workflowInstallations(workflowID: original.id).first { $0.id == installation.id }?.enabled == false)

        let passphrase = "correct horse battery staple"
        let encrypted = try source.exportWorkflowInstallation(workflowID: original.id, passphrase: passphrase)
        let target = DesktopAppModel(store: EcosystemMemoryStore(), now: { 40_001 })
        let payload = try target.previewWorkflowInstallation(encrypted, passphrase: passphrase)
        _ = try target.importWorkflowInstallation(payload, registeredCapabilityIDs: [])
        #expect(target.workflowInstallations(workflowID: original.id).allSatisfy { !$0.enabled })
    }

    private func reversioned(
        _ manifest: DesktopWorkflowPackageManifest,
        version: String,
        permissions: [DesktopWorkflowPermission]
    ) -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: manifest.schemaVersion, id: manifest.id, name: manifest.name,
            summary: manifest.summary, icon: manifest.icon, version: version,
            source: manifest.source, license: manifest.license, triggers: manifest.triggers,
            steps: [
                .init(
                    id: "execute", name: manifest.name, kind: .effect,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(permissions: permissions),
            correlationSummary: manifest.correlationSummary,
            contextSummary: manifest.contextSummary, completionSummary: manifest.completionSummary,
            bindingSlots: manifest.bindingSlots, providerFeatures: manifest.providerFeatures,
            hostCompatibility: manifest.hostCompatibility, dependencies: manifest.dependencies,
            publisher: manifest.publisher,
            provenance: .init(sourceURL: manifest.provenance?.sourceURL, sourceRevision: "synthetic-catalog-v2")
        )
    }
}

private final class EcosystemMemoryStore: DesktopStateStoring {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
