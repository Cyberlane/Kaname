import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowOperationsTests {
    @Test
    func triggerHealthBacksOffAndEscalatesWithoutLosingLastSuccess() throws {
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: OperationsMemoryStore(), now: { clock })
        try installFixtureWorkflow(model, triggers: [.email])
        let bindingID = try #require(model.bindWorkflowTrigger(
            workflowID: "org.example.operations", trigger: .email, source: "gmail",
            accountIDs: ["account-a"], sourceFilter: "from:example.test", enabled: true
        ))
        #expect(model.recordWorkflowTriggerSuccess(bindingID: bindingID, accountID: "account-a", cursorLagEstimate: 2))
        clock = 2_000
        #expect(model.recordWorkflowTriggerFailure(
            bindingID: bindingID, code: "temporary", summary: "Retry later", accountID: "account-a"
        ))
        clock = 3_000
        _ = model.recordWorkflowTriggerFailure(bindingID: bindingID, code: "temporary", summary: "Retry later")
        clock = 4_000
        _ = model.recordWorkflowTriggerFailure(bindingID: bindingID, code: "temporary", summary: "Retry later")
        let health = try #require(model.workflowTriggerHealth.first)
        #expect(health.state == .actionRequired)
        #expect(health.lastSuccessAtUnixMillis == 1_000)
        #expect(health.consecutiveFailures == 3)
        #expect(health.nextAttemptAtUnixMillis == 124_000)
        #expect(model.snapshot.operations.audit.contains { $0.domain == "workflow-trigger" && $0.action == "action-required" })
        #expect(model.advanceWorkflowTriggerCursor(id: bindingID, cursor: "remote-cursor"))
        #expect(model.rebaselineWorkflowTrigger(id: bindingID))
        #expect(model.workflowTriggerBindings().first?.lastCursor == nil)
        #expect(model.workflowTriggerHealth.first?.state == .unknown)
        #expect(model.snapshot.operations.audit.contains {
            $0.domain == "workflow-trigger" && $0.action == "rebaseline-requested"
        })
    }

    @Test
    func protectedOwnershipBlocksOtherWorkflowAndOverrideIsAudited() throws {
        let model = DesktopAppModel(store: OperationsMemoryStore(), now: { 1_000 })
        try installFixtureWorkflow(model)
        try installFixtureWorkflow(model, id: "org.example.other")
        let first = model.claimWorkflowConversation(
            workflowID: "org.example.operations", accountID: "account-a",
            conversationID: "thread-a", mode: .protected
        )
        guard case .acquired = first else { Issue.record("Expected protected claim"); return }
        #expect(model.claimWorkflowConversation(
            workflowID: "org.example.other", accountID: "account-a",
            conversationID: "thread-a", mode: .sharedObservation
        ) == .blocked(ownerWorkflowID: "org.example.operations", mode: .protected))
        let overridden = model.claimWorkflowConversation(
            workflowID: "org.example.other", accountID: "account-a",
            conversationID: "thread-a", mode: .exclusive,
            overrideReason: "Owner-approved correction routing"
        )
        guard case .acquired = overridden else { Issue.record("Expected explicit override"); return }
        #expect(model.snapshot.operations.audit.contains { $0.domain == "workflow-ownership" && $0.action == "overridden" })
    }

    @Test
    func connectorAndRendererStayDisabledUntilArtifactQualificationPasses() throws {
        let model = DesktopAppModel(store: OperationsMemoryStore(), now: { 1_000 })
        let digest = String(repeating: "a", count: 64)
        let capability = DesktopWorkflowCapabilityInstallationRecord(
            capabilityID: "org.example.adapter", version: "1.0.0", name: "Adapter",
            summary: "Synthetic", runtime: .isolatedProcess, trust: .localDigest,
            packageDigest: digest, executableDigest: digest, designatedRequirement: nil,
            permissions: .init(capabilityIDs: ["org.example.adapter"]), deterministic: true,
            idempotent: true, enabled: false, lastTestedAtUnixMillis: nil,
            lastTestPassed: false, installedAtUnixMillis: 1_000
        )
        #expect(model.registerWorkflowCapabilityInstallation(capability))
        #expect(model.registerWorkflowConnector(
            package: .init(
                schemaVersion: 1, connectorID: capability.capabilityID,
                capabilityID: capability.capabilityID, version: capability.version,
                name: "Synthetic connector", effectKinds: ["sync"],
                allowedHosts: ["api.example.test"], secretSlots: ["token"],
                maximumHTTPCalls: 2, maximumResponseBytes: 1_024
            ), capability: capability
        ))
        #expect(model.registerWorkflowRenderer(
            package: .init(
                schemaVersion: 1, rendererID: capability.capabilityID,
                capabilityID: capability.capabilityID, version: capability.version,
                name: "Synthetic renderer", mediaTypes: ["application/test"],
                supportsRecalculation: true, supportsRangeSelection: true
            ), capability: capability
        ))
        let connectorID = try #require(model.snapshot.operations.workflows.connectorInstallations.first?.id)
        let rendererID = try #require(model.snapshot.operations.workflows.rendererInstallations.first?.id)
        #expect(!model.setWorkflowConnectorEnabled(id: connectorID, enabled: true))
        #expect(!model.setWorkflowRendererEnabled(id: rendererID, enabled: true))
        let run = DesktopWorkflowQualificationRunRecord(
            id: "qualification", componentID: capability.capabilityID,
            componentVersion: capability.version, fixtureName: "artifact round trip",
            artifactDigests: [digest], stateDigest: digest, contextDigest: digest,
            outputDigest: digest, outputArtifactDigests: [digest],
            assertions: [.init(id: "artifact", label: "Artifact", passed: true, detail: "Matched")],
            outcome: .passed, elapsedMilliseconds: 10, executedAtUnixMillis: 2_000
        )
        #expect(model.recordWorkflowQualification(run))
        #expect(model.setWorkflowRendererEnabled(id: rendererID, enabled: true))
        #expect(model.bindWorkflowConnector(
            connectorID: capability.capabilityID, accountID: nil,
            secretReferences: ["token": "keychain-reference"],
            grantedHosts: ["api.example.test"], grantedEffectKinds: ["sync"]
        ) != nil)
        #expect(model.setWorkflowConnectorEnabled(id: connectorID, enabled: true))
    }

    @Test
    func studioFlattensPinnedSubflowAndPublishesDisabled() throws {
        let model = DesktopAppModel(store: OperationsMemoryStore(), now: { 1_000 })
        let subflow = fixtureManifest(id: "org.example.subflow", triggers: [.manual])
        #expect(model.installWorkflowSubflow(
            manifest: subflow,
            inputSchema: #"{"type":"object"}"#,
            outputSchema: #"{"type":"object"}"#
        ))
        let draftID = try #require(model.createWorkflowStudioDraft(name: "Composed", summary: "Fixture"))
        let draftSteps = [
            DesktopWorkflowStepDefinition(
                id: "local", name: "Local", kind: .classifyEvent,
                transitions: [.init(outcome: .always, targetStepID: "complete")]
            ),
            DesktopWorkflowStepDefinition(id: "complete", name: "Complete", kind: .complete),
        ]
        #expect(model.updateWorkflowStudioDraft(
            id: draftID, triggerKinds: [.manual], steps: draftSteps, permissions: .init(),
            subflows: [.init(
                subflowID: subflow.id, version: subflow.version,
                inputSchema: #"{"type":"object"}"#, outputSchema: #"{"type":"object"}"#
            )]
        ))
        let workflowID = try #require(model.publishWorkflowStudioDraft(id: draftID))
        let definition = try #require(model.workflowDefinitions.first { $0.id == workflowID })
        let revision = try #require(model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID })
        #expect(!definition.enabled)
        #expect(revision.steps.map(\.id) == ["subflow0-prepare", "local", "complete"])
        #expect(revision.steps.first?.transitions?.first?.targetStepID == "local")
    }

    @Test
    func schedulesAdvanceBeforeDispatchAndMigrationCannotSkipEvidence() throws {
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: OperationsMemoryStore(), now: { clock })
        try installFixtureWorkflow(model, triggers: [.schedule])
        let scheduleID = try #require(model.upsertWorkflowSchedule(
            workflowID: "org.example.operations",
            spec: .anchored(frequency: .once, hour: 0, minute: 0, onceAtUnixMillis: 2_000),
            timeZoneIdentifier: "UTC", missedRunPolicy: .skip, enabled: true
        ))
        clock = 2_000
        let due = model.claimDueWorkflowSchedules()
        #expect(due.map(\.id) == [scheduleID])
        #expect(model.snapshot.operations.workflows.scheduleBindings.first?.nextRunAtUnixMillis == nil)

        let assessmentID = try #require(model.createWorkflowMigrationAssessment(
            workflowID: "org.example.operations", requiredScenarioIDs: ["fixture", "restart"]
        ))
        #expect(throws: DesktopWorkflowOperationalError.self) {
            try model.advanceWorkflowMigration(id: assessmentID, to: .shadow)
        }
        #expect(model.updateWorkflowMigrationEvidence(
            id: assessmentID, passedScenarioIDs: ["fixture", "restart"], blockingFindings: []
        ))
        try model.advanceWorkflowMigration(id: assessmentID, to: .shadow)
        #expect(model.snapshot.operations.workflows.migrationAssessments.first?.stage == .shadow)
    }

    @Test
    func artifactQualificationRunsPositiveAndNegativeFixtures() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-qualification")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Package", isDirectory: true)
        let suite = root.appendingPathComponent("Suite", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        let executable = package.appendingPathComponent("run")
        let script = Data("""
        #!/bin/sh
        set -eu
        [ -r "$(dirname "$KANAME_ARTIFACT_MANIFEST")/Artifacts/source.txt" ]
        printf '%s' '{"value":"hello"}' > "$4"
        printf '%s' 'preview' > "$(dirname "$4")/Artifacts/preview.txt"
        """.utf8)
        try script.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let schema = #"{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}"#
        let manifest = DesktopWorkflowCapabilityManifest(
            schemaVersion: 1, id: "org.example.qualifier", name: "Qualifier", summary: "Fixture",
            version: "1.0.0", source: "Synthetic", license: "MIT", runtime: .isolatedProcess,
            trust: .localDigest, entrypoint: "run",
            executableSHA256: DesktopWorkflowCapabilityPackageCodec.digest(script), designatedRequirement: nil,
            inputSchema: schema, outputSchema: schema, reviewSchema: nil,
            permissions: .init(capabilityIDs: ["org.example.qualifier"]),
            limits: .init(timeoutSeconds: 5, maximumInputBytes: 1_024, maximumOutputBytes: 1_024, maximumArtifactBytes: 1_024),
            deterministic: true, idempotent: true
        )
        try DesktopWorkflowCapabilityPackageCodec.canonicalData(manifest).write(
            to: package.appendingPathComponent("capability.json")
        )
        let input = Data(#"{"value":"hello"}"#.utf8)
        let artifact = Data("preview".utf8)
        try input.write(to: suite.appendingPathComponent("input.json"))
        try artifact.write(to: suite.appendingPathComponent("source.txt"))
        let digest = DesktopWorkflowStructuredValue.digest(artifact)
        let qualification = DesktopWorkflowQualificationSuite(
            schemaVersion: 1, componentID: manifest.id, componentVersion: manifest.version,
            cases: [
                .init(
                    id: "positive", name: "Positive", inputPath: "input.json",
                    artifacts: [.init(role: "source", path: "source.txt", filename: "source.txt", mediaType: "text/plain")],
                    statePath: nil, contextPath: nil,
                    expectation: .init(
                        outputPath: "input.json", outputSHA256: DesktopWorkflowStructuredValue.digest(input),
                        artifactSHA256: ["preview.txt": digest], expectFailure: false
                    )
                ),
                .init(
                    id: "negative", name: "Negative", inputPath: "source.txt", artifacts: [],
                    statePath: nil, contextPath: nil,
                    expectation: .init(outputPath: nil, outputSHA256: nil, artifactSHA256: [:], expectFailure: true)
                ),
            ]
        )
        try DesktopWorkflowCanonicalJSON.encode(qualification).write(to: suite.appendingPathComponent("qualification.json"))
        let store = DesktopWorkflowCapabilityStore(rootDirectory: root.appendingPathComponent("Installed"))
        let receipt = try store.installPackage(at: package, installedAtUnixMillis: 1_000)
        let results = try DesktopWorkflowCapabilityQualifier().run(
            suiteURL: suite, installation: receipt, capabilityStore: store,
            scratchRoot: root.appendingPathComponent("Scratch"), now: { 2_000 }
        )
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.outcome == .passed })
        #expect(results.first?.artifactDigests == [digest])
        #expect(results.first?.outputArtifactDigests == [digest])
    }

    private func installFixtureWorkflow(
        _ model: DesktopAppModel,
        id: String = "org.example.operations",
        triggers: [DesktopWorkflowTriggerKind] = [.manual]
    ) throws {
        let manifest = fixtureManifest(id: id, triggers: triggers)
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers,
            enable: true
        )
    }

    private func fixtureManifest(
        id: String,
        triggers: [DesktopWorkflowTriggerKind]
    ) -> DesktopWorkflowPackageManifest {
        DesktopWorkflowPackageManifest(
            schemaVersion: 2, id: id, name: id, summary: "Operations fixture", icon: "gearshape",
            version: "1.0.0", source: "Synthetic", license: "MIT", triggers: triggers,
            steps: [
                .init(
                    id: "prepare", name: "Prepare", kind: .classifyEvent,
                    transitions: [.init(outcome: .always, targetStepID: "complete")]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ], permissions: .init(), correlationSummary: "Exact",
            contextSummary: "Exact", completionSummary: "Complete"
        )
    }
}

private final class OperationsMemoryStore: DesktopStateStoring {
    private var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
