import CryptoKit
import Darwin
import Foundation
import KanameLocalCore
import KanameProtocol

public enum DesktopFrozenWorkspaceImportOutcome: String, Equatable, Sendable {
    case created
    case blocked
}

public struct DesktopFrozenImportedWorkflow: Identifiable, Equatable, Sendable {
    public var id: String { workflowID }
    public let workflowID: String
    public let generation: Int64
    public let blocked: Bool
    public let comparisonDigest: String
}

public struct DesktopFrozenWorkspaceImportReceipt: Equatable, Sendable {
    public let sourceDigest: String
    public let outcome: DesktopFrozenWorkspaceImportOutcome
    public let comparisonDigest: String
    public let duplicate: Bool
    public let workflows: [DesktopFrozenImportedWorkflow]
}

public enum DesktopFrozenWorkspaceImportError: Error, Equatable, LocalizedError {
    case unsafeSource
    case sourceOutOfBounds
    case unsupportedSnapshotVersion
    case malformedSnapshot
    case missingWorkflowRevision(String)
    case noWorkflows
    case requestOutOfBounds
    case malformedReceipt

    public var errorDescription: String? {
        switch self {
        case .unsafeSource: "Choose a regular copied workspace.json file without links."
        case .sourceOutOfBounds: "The copied workspace is empty or too large to import safely."
        case .unsupportedSnapshotVersion: "This workspace version is newer than this Kaname build."
        case .malformedSnapshot: "The copied workspace could not be decoded without changing it."
        case let .missingWorkflowRevision(identifier):
            "Workflow \(identifier) does not contain its declared current revision."
        case .noWorkflows: "The copied workspace contains no legacy workflows."
        case .requestOutOfBounds: "The sanitized workflow import is too large for one local request."
        case .malformedReceipt: "The local workflow library returned an invalid import receipt."
        }
    }
}

public struct DesktopFrozenWorkflowImporter: Sendable {
    public static let maximumWorkspaceBytes = 64 * 1024 * 1024

    private let transport: any DesktopWorkflowLibraryTransport
    private let timeout: TimeInterval

    public init(
        transport: any DesktopWorkflowLibraryTransport,
        timeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func importWorkspace(
        at sourceURL: URL,
        importedAtUnixMillis: Int64,
        requestID: String
    ) async throws -> DesktopFrozenWorkspaceImportReceipt {
        let source = try Self.readFrozenSource(sourceURL)
        let sourceDigest = Self.sha256(source)
        let snapshot = try Self.decodeSnapshot(source, now: importedAtUnixMillis)
        let imports = try Self.prepareImports(from: snapshot, workspaceDigest: sourceDigest)
        var request = Kaname_V1_ImportFrozenWorkspaceRequest()
        request.schemaVersion = Self.schemaVersion
        request.requestID = requestID
        request.receiptID = "workspace-\(sourceDigest.prefix(24))"
        request.sourceDigest = sourceDigest
        request.importedAtUnixMillis = importedAtUnixMillis
        request.drafts = imports
        guard try request.serializedData().count <= LocalCoreRunner.maximumWorkflowLibraryRequestBytes else {
            throw DesktopFrozenWorkspaceImportError.requestOutOfBounds
        }
        let response = try await transport.importFrozenWorkspace(request, timeout: timeout)
        return try Self.receipt(response, request: request)
    }

    private static func readFrozenSource(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw DesktopFrozenWorkspaceImportError.unsafeSource }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DesktopFrozenWorkspaceImportError.unsafeSource }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= off_t(maximumWorkspaceBytes) else {
            throw before.st_size > off_t(maximumWorkspaceBytes)
                ? DesktopFrozenWorkspaceImportError.sourceOutOfBounds
                : DesktopFrozenWorkspaceImportError.unsafeSource
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw DesktopFrozenWorkspaceImportError.unsafeSource
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              data.count == Int(before.st_size),
              !data.isEmpty,
              data.count <= maximumWorkspaceBytes else {
            throw DesktopFrozenWorkspaceImportError.sourceOutOfBounds
        }
        return data
    }

    private static func decodeSnapshot(_ data: Data, now: Int64) throws -> DesktopAppSnapshot {
        let decoded: DesktopAppSnapshot
        do {
            decoded = try JSONDecoder().decode(DesktopAppSnapshot.self, from: data)
        } catch {
            throw DesktopFrozenWorkspaceImportError.malformedSnapshot
        }
        if decoded.version > DesktopAppSnapshot.currentVersion {
            throw DesktopFrozenWorkspaceImportError.unsupportedSnapshotVersion
        }
        if decoded.version == DesktopAppSnapshot.currentVersion { return decoded }
        do {
            return try decoded.migratedToCurrent(now: now)
        } catch {
            throw DesktopFrozenWorkspaceImportError.unsupportedSnapshotVersion
        }
    }

    private static func prepareImports(
        from snapshot: DesktopAppSnapshot,
        workspaceDigest: String
    ) throws -> [Kaname_V1_FrozenWorkflowDraftImport] {
        let definitions = snapshot.operations.workflows.definitions.sorted { $0.id < $1.id }
        guard !definitions.isEmpty else { throw DesktopFrozenWorkspaceImportError.noWorkflows }
        return try definitions.map { definition in
            guard let revision = snapshot.operations.workflows.revisions.first(where: {
                $0.id == definition.currentRevisionID
            }) else {
                throw DesktopFrozenWorkspaceImportError.missingWorkflowRevision(definition.id)
            }
            let imported = try DesktopWorkflowLegacyImporter.importSource(.init(
                definition: definition,
                revision: revision
            ))
            let comparison = FrozenComparisonDocument(
                formatVersion: 1,
                workspaceSourceDigest: workspaceDigest,
                legacySourceDigest: imported.sourceDigest,
                legacyDefinitionID: definition.id,
                legacyRevisionID: revision.id,
                workflowID: imported.workflow.workflowId,
                blocking: !imported.isLossless,
                losses: imported.losses
            )
            var draft = Kaname_V1_FrozenWorkflowDraftImport()
            draft.workflowID = imported.workflow.workflowId
            draft.packageID = imported.workflow.packageId
            draft.name = imported.workflow.name
            draft.summary = imported.workflow.summary
            draft.workflowJson = Data(imported.canonicalSource.utf8)
            draft.layoutJson = Data(imported.canonicalLayoutSource.utf8)
            draft.comparisonJson = try DesktopWorkflowCanonicalJSON.encode(comparison)
            draft.blocked = !imported.isLossless
            return draft
        }
    }

    private static func receipt(
        _ response: Kaname_V1_ImportFrozenWorkspaceResponse,
        request: Kaname_V1_ImportFrozenWorkspaceRequest
    ) throws -> DesktopFrozenWorkspaceImportReceipt {
        let outcome: DesktopFrozenWorkspaceImportOutcome
        switch response.outcome {
        case .created: outcome = .created
        case .blocked: outcome = .blocked
        case .unspecified, .UNRECOGNIZED:
            throw DesktopFrozenWorkspaceImportError.malformedReceipt
        }
        let expectedIDs = request.drafts.map(\.workflowID).sorted()
        let expectedBlocked = Dictionary(
            uniqueKeysWithValues: request.drafts.map { ($0.workflowID, $0.blocked) }
        )
        let expectedOutcome: DesktopFrozenWorkspaceImportOutcome = request.drafts.contains(where: \.blocked)
            ? .blocked
            : .created
        let imported = response.workflows.map {
            DesktopFrozenImportedWorkflow(
                workflowID: $0.workflowID,
                generation: $0.generation,
                blocked: $0.blocked,
                comparisonDigest: $0.comparisonDigest
            )
        }
        guard response.schemaVersion.major == 1,
              response.requestID == request.requestID,
              response.sourceDigest == request.sourceDigest,
              outcome == expectedOutcome,
              Self.isDigest(response.comparisonDigest),
              imported.map(\.workflowID) == expectedIDs,
              imported.allSatisfy({
                  $0.generation == 1
                      && $0.blocked == expectedBlocked[$0.workflowID]
                      && Self.isDigest($0.comparisonDigest)
              }) else {
            throw DesktopFrozenWorkspaceImportError.malformedReceipt
        }
        return DesktopFrozenWorkspaceImportReceipt(
            sourceDigest: response.sourceDigest,
            outcome: outcome,
            comparisonDigest: response.comparisonDigest,
            duplicate: response.duplicate,
            workflows: imported
        )
    }

    private static var schemaVersion: Kaname_V1_SchemaVersion {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        return version
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

private struct FrozenComparisonDocument: Codable {
    let formatVersion: Int
    let workspaceSourceDigest: String
    let legacySourceDigest: String
    let legacyDefinitionID: String
    let legacyRevisionID: String
    let workflowID: String
    let blocking: Bool
    let losses: [DesktopWorkflowLegacyImportLoss]
}
