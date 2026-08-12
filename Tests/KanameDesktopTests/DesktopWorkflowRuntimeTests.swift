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
        let script = Data("#!/bin/sh\nprintf '%s' '{\"value\":\"hello\"}' > \"$4\"\n".utf8)
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
        let result = try DesktopWorkflowCapabilityProcessRunner().execute(
            manifest: try store.manifest(for: receipt),
            installationDirectory: store.installationDirectory(capabilityID: receipt.capabilityID, version: receipt.version),
            input: Data(#"{"value":"hello"}"#.utf8),
            scratchRoot: root.appendingPathComponent("Scratch")
        )
        #expect(result.output == Data(#"{"value":"hello"}"#.utf8))
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
        #expect(model.snapshot.version == 18)
        #expect(Set(model.workflowCapabilityInstallations.map(\.capabilityID)) == DesktopWorkflowBuiltinCapabilities.identifiers)

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
