import Foundation
import KanameProtocol
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopFrozenWorkflowImporterTests {
    @Test
    func copiedWorkspaceImportsWithoutMutationAndRepeatsAsANoOp() async throws {
        let directory = try temporaryDirectory()
        let workspace = directory.appendingPathComponent("workspace.json")
        let snapshot = try legacySnapshot(blocked: true)
        let original = try JSONEncoder().encode(snapshot)
        try original.write(to: workspace)
        let transport = FrozenImportFixtureTransport()
        let importer = DesktopFrozenWorkflowImporter(transport: transport)

        let first = try await importer.importWorkspace(
            at: workspace,
            importedAtUnixMillis: 1_000,
            requestID: "import:frozen-001"
        )
        let second = try await importer.importWorkspace(
            at: workspace,
            importedAtUnixMillis: 1_001,
            requestID: "import:frozen-002"
        )

        #expect(first.outcome == .blocked)
        #expect(!first.duplicate)
        #expect(first.workflows.count == 1)
        #expect(first.workflows[0].blocked)
        #expect(second.duplicate)
        #expect(second.sourceDigest == first.sourceDigest)
        #expect(second.comparisonDigest == first.comparisonDigest)
        #expect(try Data(contentsOf: workspace) == original)

        let requests = await transport.recordedImports()
        #expect(requests.count == 2)
        #expect(requests[0].receiptID == requests[1].receiptID)
        #expect(requests[0].sourceDigest == requests[1].sourceDigest)
        #expect(requests[0].drafts == requests[1].drafts)
        #expect(requests[0].drafts[0].blocked)
        #expect(!requests[0].drafts[0].workflowJson.isEmpty)
        #expect(!requests[0].drafts[0].layoutJson.isEmpty)
        let comparison = try #require(
            JSONSerialization.jsonObject(with: requests[0].drafts[0].comparisonJson)
                as? [String: Any]
        )
        #expect(comparison["workspaceSourceDigest"] as? String == first.sourceDigest)
        #expect(comparison["blocking"] as? Bool == true)
        let serializedRequest = try requests[0].serializedData()
        #expect(serializedRequest.count <= 2 * 1024 * 1024)
        #expect(!String(decoding: serializedRequest, as: UTF8.self).contains("private-account-token"))
    }

    @Test
    func linksNewerSnapshotsAndMissingRevisionsFailBeforeTransport() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(try legacySnapshot(blocked: false)).write(to: source)
        let link = directory.appendingPathComponent("linked-workspace.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let transport = FrozenImportFixtureTransport()
        let importer = DesktopFrozenWorkflowImporter(transport: transport)

        await #expect(throws: DesktopFrozenWorkspaceImportError.unsafeSource) {
            _ = try await importer.importWorkspace(
                at: link,
                importedAtUnixMillis: 2_000,
                requestID: "import:link"
            )
        }

        var newer = try legacySnapshot(blocked: false)
        newer.version = DesktopAppSnapshot.currentVersion + 1
        try JSONEncoder().encode(newer).write(to: source, options: .atomic)
        await #expect(throws: DesktopFrozenWorkspaceImportError.unsupportedSnapshotVersion) {
            _ = try await importer.importWorkspace(
                at: source,
                importedAtUnixMillis: 2_001,
                requestID: "import:newer"
            )
        }

        var missing = try legacySnapshot(blocked: false)
        missing.operations.workflows.revisions.removeAll()
        try JSONEncoder().encode(missing).write(to: source, options: .atomic)
        await #expect(throws: (any Error).self) {
            _ = try await importer.importWorkspace(
                at: source,
                importedAtUnixMillis: 2_002,
                requestID: "import:missing"
            )
        }
        #expect(await transport.recordedImports().isEmpty)
    }

    @Test
    func contradictoryBlockedStateInReceiptFailsClosed() async throws {
        let directory = try temporaryDirectory()
        let workspace = directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(try legacySnapshot(blocked: true)).write(to: workspace)
        let importer = DesktopFrozenWorkflowImporter(
            transport: FrozenImportFixtureTransport(tamperBlocked: true)
        )

        await #expect(throws: DesktopFrozenWorkspaceImportError.malformedReceipt) {
            _ = try await importer.importWorkspace(
                at: workspace,
                importedAtUnixMillis: 3_000,
                requestID: "import:contradictory-receipt"
            )
        }
    }

    private func legacySnapshot(blocked: Bool) throws -> DesktopAppSnapshot {
        let model = DesktopAppModel(store: FrozenImportMemoryStore(), now: { 10_000 })
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2,
            id: "org.example.frozen-workflow",
            name: "Frozen workflow",
            summary: "Synthetic frozen import.",
            icon: "point.3.connected.trianglepath.dotted",
            version: "1.0.0",
            source: "Synthetic",
            license: "MIT",
            triggers: [.manual],
            steps: [.init(id: "complete", name: "Complete", kind: .complete)],
            permissions: .init(),
            correlationSummary: "Synthetic correlation",
            contextSummary: "Synthetic context",
            completionSummary: "Synthetic completion"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers
        )
        var snapshot = model.snapshot
        if blocked {
            snapshot.operations.workflows.revisions[0].permissions = .init(
                permissions: [.emailRead],
                accountIDs: ["private-account-token"]
            )
        }
        return snapshot
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-frozen-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FrozenImportFixtureTransport: DesktopWorkflowLibraryTransport {
    private var imports: [Kaname_V1_ImportFrozenWorkspaceRequest] = []
    private let tamperBlocked: Bool

    init(tamperBlocked: Bool = false) {
        self.tamperBlocked = tamperBlocked
    }

    func queryWorkflowLibrary(
        _: Kaname_V1_WorkflowLibraryQueryRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_WorkflowLibraryQueryResponse {
        Kaname_V1_WorkflowLibraryQueryResponse()
    }

    func setWorkflowActivation(
        _: Kaname_V1_SetWorkflowActivationRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_SetWorkflowActivationResponse {
        Kaname_V1_SetWorkflowActivationResponse()
    }

    func importFrozenWorkspace(
        _ request: Kaname_V1_ImportFrozenWorkspaceRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_ImportFrozenWorkspaceResponse {
        let duplicate = !imports.isEmpty
        imports.append(request)
        var response = Kaname_V1_ImportFrozenWorkspaceResponse()
        response.schemaVersion = schemaVersion
        response.requestID = request.requestID
        response.sourceDigest = request.sourceDigest
        response.outcome = request.drafts.contains(where: \.blocked) ? .blocked : .created
        response.comparisonDigest = String(repeating: "a", count: 64)
        response.duplicate = duplicate
        response.workflows = request.drafts
            .sorted { $0.workflowID < $1.workflowID }
            .map { draft in
                var imported = Kaname_V1_ImportedFrozenWorkflow()
                imported.workflowID = draft.workflowID
                imported.generation = 1
                imported.blocked = tamperBlocked ? !draft.blocked : draft.blocked
                imported.comparisonDigest = String(repeating: "b", count: 64)
                return imported
            }
        return response
    }

    func recordedImports() -> [Kaname_V1_ImportFrozenWorkspaceRequest] { imports }

    private var schemaVersion: Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }
}

private final class FrozenImportMemoryStore: DesktopStateStoring {
    private var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
