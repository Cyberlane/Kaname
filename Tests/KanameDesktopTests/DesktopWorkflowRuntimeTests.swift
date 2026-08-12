import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowRuntimeTests {
    @Test
    func isolatedCapabilityIsPinnedSchemaCheckedNetworkDeniedAndExecutable() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-capability")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("fixture.kanamecapability", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let executable = package.appendingPathComponent("run")
        let script = Data("""
        #!/bin/sh
        set -eu
        [ -s "$KANAME_ARTIFACT_MANIFEST" ]
        [ -s "$KANAME_STATE_MANIFEST" ]
        [ -s "$KANAME_CONTEXT_SNAPSHOT" ]
        [ -r "$(dirname "$KANAME_ARTIFACT_MANIFEST")/Artifacts/source.txt" ]
        printf '%s' '{"stateMutations":[],"knowledgeProposals":[],"artifactRoles":[]}' > "$KANAME_COMMIT_PROPOSAL"
        printf '%s' '{"value":"hello"}' > "$4"
        """.utf8)
        try script.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("reviewed fixture data".utf8).write(to: package.appendingPathComponent("rules.txt"))
        let schema = #"{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}"#
        let manifest = DesktopWorkflowCapabilityManifest(
            schemaVersion: 1,
            id: "org.example.echo",
            name: "Synthetic echo",
            summary: "Copies schema-constrained test input to output.",
            version: "1.0.0",
            source: "Synthetic fixture",
            license: "MIT",
            runtime: .isolatedProcess,
            trust: .localDigest,
            entrypoint: "run",
            executableSHA256: DesktopWorkflowCapabilityPackageCodec.digest(script),
            designatedRequirement: nil,
            inputSchema: schema,
            outputSchema: schema,
            reviewSchema: nil,
            permissions: .init(permissions: [], capabilityIDs: ["org.example.echo"]),
            limits: .init(timeoutSeconds: 5, maximumInputBytes: 1_024, maximumOutputBytes: 1_024, maximumArtifactBytes: 1_024),
            deterministic: true,
            idempotent: true
        )
        try DesktopWorkflowCapabilityPackageCodec.canonicalData(manifest).write(
            to: package.appendingPathComponent(DesktopWorkflowCapabilityStore.manifestFilename)
        )
        let store = DesktopWorkflowCapabilityStore(rootDirectory: root.appendingPathComponent("Installed"))
        let receipt = try store.installPackage(at: package, installedAtUnixMillis: 100)
        #expect(receipt.enabled == false)
        let stateInput = try JSONDecoder().decode(
            DesktopWorkflowCapabilityStateInput.self,
            from: Data(#"{"namespace":"fixture","key":"cursor","schemaVersion":1,"revision":2,"value":{"cursor":"42"}}"#.utf8)
        )
        let result = try DesktopWorkflowCapabilityProcessRunner().execute(
            manifest: try store.manifest(for: receipt),
            installationDirectory: store.installationDirectory(capabilityID: receipt.capabilityID, version: receipt.version),
            input: Data(#"{"value":"hello"}"#.utf8),
            artifactInputs: [.init(
                role: "source", artifactDigest: DesktopWorkflowCapabilityPackageCodec.digest(Data("artifact".utf8)),
                filename: "source.txt", mediaType: "text/plain", data: Data("artifact".utf8)
            )],
            stateInputs: [stateInput],
            contextSnapshot: DesktopWorkflowContextSnapshotRecord(
                id: "context", workItemID: "work", episodeID: "episode", compilerVersion: 2,
                currentRequest: "Fixture", openQuestions: [], negativeConstraints: [], references: [],
                authoritySummary: "Read-only", dataEgressSummary: "None", estimatedTokens: 1,
                digest: "digest", createdAtUnixMillis: 1
            ),
            scratchRoot: root.appendingPathComponent("Scratch")
        )
        #expect(result.output == Data(#"{"value":"hello"}"#.utf8))
        #expect(result.commitProposal.isEmpty)
        let installedRules = store.installationDirectory(capabilityID: receipt.capabilityID, version: receipt.version)
            .appendingPathComponent("rules.txt")
        try Data("mutated after review".utf8).write(to: installedRules)
        #expect(throws: DesktopWorkflowCapabilityError.digestMismatch) {
            try store.manifest(for: receipt)
        }

        var networked = manifest
        networked = DesktopWorkflowCapabilityManifest(
            schemaVersion: networked.schemaVersion, id: networked.id, name: networked.name,
            summary: networked.summary, version: networked.version, source: networked.source,
            license: networked.license, runtime: networked.runtime, trust: networked.trust,
            entrypoint: networked.entrypoint, executableSHA256: networked.executableSHA256,
            designatedRequirement: networked.designatedRequirement, inputSchema: networked.inputSchema,
            outputSchema: networked.outputSchema, reviewSchema: networked.reviewSchema,
            permissions: .init(permissions: [], capabilityIDs: [networked.id], networkDestinations: ["example.invalid"]),
            limits: networked.limits, deterministic: networked.deterministic, idempotent: networked.idempotent
        )
        #expect(throws: DesktopWorkflowCapabilityError.unsupportedRuntime) {
            try DesktopWorkflowCapabilityPackageCodec.canonicalData(networked)
        }
    }

    @Test
    func storageIsNamespacedJsonBoundedAndContentAddressed() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-workflow-storage")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DesktopWorkflowStorage(installationRoot: root)
        try storage.setValue(Data(#"{"cursor":"42"}"#.utf8), forKey: "gmail.cursor")
        #expect(try storage.value(forKey: "gmail.cursor") == Data(#"{"cursor":"42"}"#.utf8))
        #expect(throws: DesktopWorkflowStorageError.invalidKey) {
            try storage.setValue(Data("{}".utf8), forKey: "../escape")
        }
        let artifact = try storage.importArtifact(
            data: Data("private artifact".utf8),
            filename: "result.txt",
            mediaType: "text/plain",
            createdAtUnixMillis: 10
        )
        #expect(try storage.artifactData(sha256: artifact.sha256) == Data("private artifact".utf8))
        #expect(try storage.artifactRecords() == [artifact])
        let presentation = try storage.artifactPresentationURL(
            sha256: artifact.sha256, filename: artifact.filename
        )
        #expect(presentation.lastPathComponent == "result.txt")
        #expect(try Data(contentsOf: presentation) == Data("private artifact".utf8))
        #expect(throws: DesktopWorkflowStorageError.artifactUnavailable) {
            _ = try storage.artifactPresentationURL(sha256: artifact.sha256, filename: "../escape.txt")
        }
    }

    @Test
    func runtimeChainsCapabilityOutputAndCompletesWithDurableReceipts() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-workflow-runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 1_000 }
        )
        let capabilityID = "org.example.uppercase"
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 1,
            id: "org.example.runtime",
            name: "Runtime fixture",
            summary: "Exercises durable dispatch.",
            icon: "gearshape.2",
            version: "1.0.0",
            source: "Synthetic fixture",
            license: "MIT",
            triggers: [.manual],
            steps: [
                .init(id: "transform", name: "Transform", kind: .invokeTool, capabilityID: capabilityID, retryLimit: 1, isIdempotent: true),
                .init(id: "verify", name: "Verify durable output", kind: .invokeTool, capabilityID: capabilityID, retryLimit: 1, isIdempotent: true),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(permissions: [], capabilityIDs: [capabilityID]),
            correlationSummary: "Manual fixture",
            contextSummary: "Exact synthetic input",
            completionSummary: "All stages complete"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [capabilityID],
            enable: true
        )
        #expect(model.registerWorkflowCapabilityInstallation(.init(
            capabilityID: capabilityID, version: "1.0.0", name: "Uppercase", summary: "Synthetic",
            runtime: .isolatedProcess, trust: .localDigest, packageDigest: String(repeating: "a", count: 64),
            executableDigest: String(repeating: "b", count: 64), designatedRequirement: nil,
            permissions: .init(permissions: [], capabilityIDs: [capabilityID]), deterministic: true,
            idempotent: true, enabled: true, lastTestedAtUnixMillis: 1_000, lastTestPassed: true,
            installedAtUnixMillis: 1_000
        )))
        let workID = try #require(model.createWorkflowWorkItem(workflowID: manifest.id, title: "Fixture", goal: "Run fixture"))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "input", deduplicationKey: "runtime-fixture"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Run", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "hello", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(workItemID: workID, episodeID: episodeID, contextSnapshotID: contextID))
        let installations = root.appendingPathComponent("WorkflowInstallations", isDirectory: true)
        let firstRuntime = DesktopWorkflowRuntime(
            model: model,
            invoker: UppercaseInvoker(),
            workflowInstallationsRoot: installations
        )
        #expect(await firstRuntime.executeNext(runID: runID, input: Data("hello".utf8)) == .completedStep(
            stepID: "transform",
            output: Data("HELLO".utf8)
        ))
        let restartedRuntime = DesktopWorkflowRuntime(
            model: model,
            invoker: UppercaseInvoker(),
            workflowInstallationsRoot: installations
        )
        let result = await restartedRuntime.executeUntilBlocked(runID: runID, initialInput: Data("wrong after restart".utf8))
        #expect(result == .completedRun)
        #expect(model.snapshot.operations.workflows.stepAttempts.count == 3)
        #expect(model.snapshot.operations.workflows.stepAttempts.allSatisfy { $0.state == .completed })
        #expect(model.snapshot.operations.workflows.runs.first(where: { $0.id == runID })?.state == .completed)
        #expect(model.snapshot.operations.workflows.executionReceipts.count == 2)
    }

    @Test
    func capabilityCommitAtomicallyPublishesStateArtifactRoleAndReviewableKnowledge() async throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-workflow-data-plane")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DesktopAppModel(
            store: FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json")),
            now: { 2_000 }
        )
        let capabilityID = "org.example.data-plane"
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 1, id: "org.example.data-workflow", name: "Data workflow",
            summary: "Exercises generic workflow data contracts.", icon: "shippingbox",
            version: "1.0.0", source: "Synthetic fixture", license: "MIT", triggers: [.manual],
            steps: [
                .init(id: "produce", name: "Produce", kind: .invokeTool, capabilityID: capabilityID),
                .init(
                    id: "consume", name: "Consume", kind: .invokeTool, capabilityID: capabilityID,
                    artifactInputs: [.init(role: "current-report")],
                    stateInputs: [.init(namespace: "processing", key: "mapping", required: true)]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ],
            permissions: .init(permissions: [], capabilityIDs: [capabilityID]),
            correlationSummary: "Manual", contextSummary: "Verified current knowledge",
            completionSummary: "State and artifacts are committed"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: [capabilityID], enable: true
        )
        #expect(model.registerWorkflowCapabilityInstallation(.init(
            capabilityID: capabilityID, version: "1.0.0", name: "Data plane", summary: "Synthetic",
            runtime: .isolatedProcess, trust: .localDigest, packageDigest: String(repeating: "a", count: 64),
            executableDigest: String(repeating: "b", count: 64), designatedRequirement: nil,
            permissions: .init(permissions: [], capabilityIDs: [capabilityID]), deterministic: true,
            idempotent: true, enabled: true, lastTestedAtUnixMillis: 2_000, lastTestPassed: true,
            installedAtUnixMillis: 2_000
        )))
        let workID = try #require(model.createWorkflowWorkItem(workflowID: manifest.id, title: "Data", goal: "Exercise contracts"))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "input", deduplicationKey: "data-plane"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Run", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "Process", references: []
        ))
        let runID = try #require(model.queueWorkflowRun(
            workItemID: workID, episodeID: episodeID, contextSnapshotID: contextID
        ))
        let runtime = DesktopWorkflowRuntime(
            model: model, invoker: DataPlaneInvoker(),
            workflowInstallationsRoot: root.appendingPathComponent("WorkflowInstallations")
        )
        #expect(await runtime.executeUntilBlocked(runID: runID, initialInput: Data("{}".utf8)) == .completedRun)

        let state = try #require(model.workflowStateRecords(workflowID: manifest.id).first)
        #expect(state.namespace == "processing")
        #expect(state.key == "mapping")
        #expect(state.revision == 1)
        #expect(model.workflowArtifactRoles(workItemID: workID).map(\.role) == ["current-report"])
        let proposed = try #require(model.workflowFacts(workItemID: workID).first { $0.key == "report.preference" })
        #expect(proposed.state == .proposed)
        #expect(model.snapshot.operations.audit.contains {
            $0.domain == "workflow-data" && $0.action == "capability-commit"
        })
        let encodedMutation = try JSONEncoder().encode(DesktopWorkflowStateMutationProposal(
            namespace: "processing", key: "mapping", scope: .installation,
            expectedRevision: 1, schemaVersion: 1,
            schema: #"{"type":"object"}"#, value: Data(#"{"category":"verified"}"#.utf8)
        ))
        #expect(String(decoding: encodedMutation, as: UTF8.self).contains(#""value":{"category":"verified"}"#))

        let beforeReview = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "Before review", references: []
        ))
        #expect(model.snapshot.operations.workflows.contextSnapshots.first { $0.id == beforeReview }?.knowledge?.isEmpty == true)
        #expect(model.reviewWorkflowKnowledge(id: proposed.id, accepted: true, reviewer: "Fixture reviewer"))
        let afterReview = try #require(model.compileWorkflowContext(
            workItemID: workID, episodeID: episodeID, request: "After review", references: []
        ))
        #expect(model.snapshot.operations.workflows.contextSnapshots.first { $0.id == afterReview }?.knowledge?.map(\.id) == [proposed.id])

        let conflictingRun = try #require(model.queueWorkflowRun(
            workItemID: workID, episodeID: episodeID, contextSnapshotID: afterReview
        ))
        let conflict = await runtime.executeNext(runID: conflictingRun, input: Data("{}".utf8))
        guard case .failed(stepID: "produce", reason: _) = conflict else {
            Issue.record("A stale first-write proposal should fail closed")
            return
        }
        #expect(model.workflowStateRecords(workflowID: manifest.id).first?.revision == 1)
        #expect(model.workflowArtifactRoles(workItemID: workID).count == 1)
        #expect(model.workflowFacts(workItemID: workID).count == 1)
    }

    @Test
    func schema17MigrationSeedsBuiltInsAndExpiredLeaseStopsNonIdempotentRetry() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-workflow-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        var old = DesktopAppModel(store: store, now: { 1_000 }).snapshot
        old.version = 17
        old.operations.workflows.capabilityInstallations = []
        old.operations.workflows.runtimeClaims = []
        try store.save(JSONEncoder().encode(old))
        var clock: Int64 = 10_000
        let model = DesktopAppModel(store: store, now: { clock })
        #expect(model.snapshot.version == 21)
        #expect(Set(model.workflowCapabilityInstallations.map(\.capabilityID)) == DesktopWorkflowBuiltinCapabilities.identifiers)
        #expect(model.workflowCapabilityInstallation(capabilityID: "kaname.email.read")?.deterministic == false)
        #expect(model.workflowCapabilityInstallation(capabilityID: "kaname.agent.bounded")?.deterministic == false)

        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 1, id: "org.example.lease", name: "Lease", summary: "Recovery fixture",
            icon: "timer", version: "1.0.0", source: "Synthetic", license: "MIT", triggers: [.manual],
            steps: [.init(id: "send", name: "Send", kind: .sendEmail, capabilityID: "kaname.email.send", isIdempotent: false)],
            permissions: .init(permissions: [.emailSend], capabilityIDs: ["kaname.email.send"]),
            correlationSummary: "Manual", contextSummary: "Exact", completionSummary: "Sent"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers,
            enable: true
        )
        let workID = try #require(model.createWorkflowWorkItem(workflowID: manifest.id, title: "Lease", goal: "Recover"))
        let eventID = try #require(model.observeWorkflowExternalEvent(
            source: "manual", accountID: "local", conversationID: nil, messageID: nil,
            cursor: nil, payloadDigest: "input", deduplicationKey: "lease"
        ))
        let episodeID = try #require(model.createWorkflowEpisode(
            workItemID: workID, sourceEventID: eventID, sourceMessageID: nil,
            intent: .request, summary: "Send", deltaSummary: "Initial"
        ))
        let contextID = try #require(model.compileWorkflowContext(workItemID: workID, episodeID: episodeID, request: "Send", references: []))
        let runID = try #require(model.queueWorkflowRun(workItemID: workID, episodeID: episodeID, contextSnapshotID: contextID))
        _ = try #require(model.claimWorkflowRun(runID: runID, ownerID: "worker", leaseMilliseconds: 5_000))
        _ = try #require(model.beginWorkflowStep(runID: runID, stepID: "send", inputDigest: "input"))
        clock = 20_000
        #expect(model.recoverExpiredWorkflowClaims() == 1)
        #expect(model.snapshot.operations.workflows.runs.first(where: { $0.id == runID })?.state == .failed)
        #expect(model.workflowWorkItems.first(where: { $0.id == workID })?.state == .needsAttention)
        #expect(model.nextWorkflowStep(runID: runID) == nil)
    }

    @Test
    func schema20MigrationAddsOnlyMissingBuiltInHostCapabilities() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-workflow-host-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileDesktopStateStore(fileURL: root.appendingPathComponent("Desktop/workspace.json"))
        var old = DesktopAppModel(store: store, now: { 1_000 }).snapshot
        old.version = 20
        old.operations.workflows.capabilityInstallations =
            DesktopWorkflowBuiltinCapabilities.installations(at: 1_000)
                .filter { $0.capabilityID != "kaname.email.read" && $0.capabilityID != "kaname.agent.bounded" }
        let preserved = old.operations.workflows.capabilityInstallations
            .first { $0.capabilityID == "kaname.email.send" }
        try store.save(JSONEncoder().encode(old))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == 21)
        #expect(Set(model.workflowCapabilityInstallations.map(\.capabilityID)) == DesktopWorkflowBuiltinCapabilities.identifiers)
        #expect(model.workflowCapabilityInstallations.first { $0.capabilityID == "kaname.email.send" } == preserved)
        #expect(model.workflowCapabilityInstallations.filter { $0.capabilityID == "kaname.email.read" }.count == 1)
        #expect(model.workflowCapabilityInstallations.filter { $0.capabilityID == "kaname.agent.bounded" }.count == 1)
    }
}

private struct UppercaseInvoker: DesktopWorkflowCapabilityInvoking {
    func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        if invocation.step.id == "verify" {
            guard invocation.input == Data("HELLO".utf8) else { throw DesktopWorkflowCapabilityError.outputInvalid }
            return .completed(output: Data(#"{"verified":true}"#.utf8), artifactIDs: [])
        }
        return .completed(output: Data(String(decoding: invocation.input, as: UTF8.self).uppercased().utf8), artifactIDs: [])
    }
}

private struct DataPlaneInvoker: DesktopWorkflowCapabilityInvoking {
    private let mappingSchema = #"{"type":"object","required":["category"],"properties":{"category":{"type":"string"}},"additionalProperties":false}"#

    func invoke(
        _ invocation: DesktopWorkflowCapabilityInvocation,
        installation: DesktopWorkflowCapabilityInstallationRecord
    ) async throws -> DesktopWorkflowCapabilityInvocationResult {
        if invocation.step.id == "consume" {
            guard invocation.artifactInputs.count == 1,
                  invocation.artifactInputs[0].role == "current-report",
                  invocation.artifactInputs[0].data == Data(#"{"report":"ready"}"#.utf8),
                  invocation.stateInputs.count == 1,
                  invocation.stateInputs[0].revision == 1,
                  invocation.stateInputs[0].value == Data(#"{"category":"verified"}"#.utf8) else {
                throw DesktopWorkflowCapabilityError.outputInvalid
            }
            return .completed(output: Data(#"{"consumed":true}"#.utf8), artifactIDs: [])
        }
        let output = Data(#"{"report":"ready"}"#.utf8)
        let digest = DesktopWorkflowCapabilityPackageCodec.digest(output)
        return .completed(
            output: output,
            artifactIDs: [],
            commitProposal: .init(
                stateMutations: [.init(
                    namespace: "processing", key: "mapping", scope: .installation,
                    expectedRevision: nil, schemaVersion: 1, schema: mappingSchema,
                    value: Data(#"{"category":"verified"}"#.utf8)
                )],
                knowledgeProposals: [.init(
                    key: "report.preference", value: "Use the reviewed layout", scope: .installation,
                    sourceReferenceIDs: ["synthetic-request"], supersedesFactID: nil
                )],
                artifactRoles: [.init(role: "current-report", artifactDigest: digest)]
            )
        )
    }
}
