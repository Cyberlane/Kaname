import Foundation
import KanameConnectivity
import KanameDesktop

public struct DesktopDevelopmentDataForkReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let forkID: UUID
    public let sourceBackupID: UUID
    public let createdAtUnixMillis: Int64
    public let sourceStateSchemaVersion: Int
    public let developmentStateSchemaVersion: Int
    public let sourceWorkspaceSHA256: String
    public let developmentWorkspaceSHA256: String
    public let copiedWorkflowArtifactCount: Int
    public let previousDevelopmentDataArchived: Bool
    public let authorityRemoved: Bool
    public let automaticExecutionEnabled: Bool
    public let externalMutationPolicy: KanameExternalMutationPolicy

    public init(
        forkID: UUID,
        sourceBackupID: UUID,
        createdAtUnixMillis: Int64,
        sourceStateSchemaVersion: Int,
        developmentStateSchemaVersion: Int,
        sourceWorkspaceSHA256: String,
        developmentWorkspaceSHA256: String,
        copiedWorkflowArtifactCount: Int,
        previousDevelopmentDataArchived: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.forkID = forkID
        self.sourceBackupID = sourceBackupID
        self.createdAtUnixMillis = createdAtUnixMillis
        self.sourceStateSchemaVersion = sourceStateSchemaVersion
        self.developmentStateSchemaVersion = developmentStateSchemaVersion
        self.sourceWorkspaceSHA256 = sourceWorkspaceSHA256
        self.developmentWorkspaceSHA256 = developmentWorkspaceSHA256
        self.copiedWorkflowArtifactCount = copiedWorkflowArtifactCount
        self.previousDevelopmentDataArchived = previousDevelopmentDataArchived
        authorityRemoved = true
        automaticExecutionEnabled = false
        externalMutationPolicy = .denied
    }
}

public enum DesktopDevelopmentDataForkOutcome: Equatable, Sendable {
    case notDevelopment
    case stableDataUnavailable
    case existing(DesktopDevelopmentDataForkReceipt?)
    case created(DesktopDevelopmentDataForkReceipt)
}

public enum DesktopDevelopmentDataForkError: Error, Equatable, LocalizedError, Sendable {
    case unsafeEnvironment
    case stableDataBusy
    case developmentDataBusy
    case sourceWorkspaceInvalid
    case sanitizationFailed
    case unsafeArtifact
    case activationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeEnvironment:
            "Kaname refused to fork data because the Stable and Development storage roots were not safely isolated."
        case .stableDataBusy:
            "Stable data is busy. Close Stable and wait for its workflow worker to stop before starting the Development build."
        case .developmentDataBusy:
            "Development data is busy. Stop its workflow worker before refreshing the Development fork."
        case .sourceWorkspaceInvalid:
            "The verified Stable backup did not contain a usable workspace. Stable was not changed."
        case .sanitizationFailed:
            "Kaname could not remove copied execution authority. The Development fork was not activated."
        case .unsafeArtifact:
            "The Stable backup contained an unsafe workflow artifact path. The Development fork was not activated."
        case .activationFailed:
            "Kaname could not atomically activate the Development data fork. Stable was not changed."
        case .rollbackFailed:
            "Kaname could not restore the archived Development data after activation failed. Stable was not changed."
        }
    }
}

@MainActor
public enum DesktopDevelopmentDataFork {
    public static let refreshArgument = "--desktop-refresh-from-stable"
    public static let receiptRelativePath = "DevelopmentFork/receipt.json"

    public static func prepareIfNeeded(
        environment: KanameDesktopEnvironment = .current,
        arguments: [String] = CommandLine.arguments
    ) throws -> DesktopDevelopmentDataForkOutcome {
        try prepare(
            environment: environment,
            refresh: arguments.contains(refreshArgument),
            forkID: UUID(),
            createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    public static func prepare(
        environment: KanameDesktopEnvironment,
        refresh: Bool,
        forkID: UUID,
        createdAtUnixMillis: Int64
    ) throws -> DesktopDevelopmentDataForkOutcome {
        guard environment.channel == .development else { return .notDevelopment }
        let manager = FileManager.default
        let base = environment.applicationSupportRoot.deletingLastPathComponent().standardizedFileURL
        let expectedDevelopmentRoot = base.appendingPathComponent("Kaname Dev", isDirectory: true).standardizedFileURL
        guard environment.applicationSupportRoot.standardizedFileURL == expectedDevelopmentRoot else {
            throw DesktopDevelopmentDataForkError.unsafeEnvironment
        }
        let stableEnvironment = KanameDesktopEnvironment(
            channel: .stable,
            applicationSupportDirectory: base
        )
        guard stableEnvironment.applicationSupportRoot.standardizedFileURL != expectedDevelopmentRoot else {
            throw DesktopDevelopmentDataForkError.unsafeEnvironment
        }

        let developmentWorkspaceExists = manager.fileExists(atPath: environment.workspaceFileURL.path)
        if developmentWorkspaceExists, !refresh {
            return .existing(try? receipt(environment: environment))
        }
        guard manager.fileExists(atPath: stableEnvironment.workspaceFileURL.path) else {
            return .stableDataUnavailable
        }
        guard try DesktopRecoveryService.isRegularNonSymlink(stableEnvironment.workspaceFileURL) else {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }

#if os(macOS)
        let stableLock: KanameDesktopInstanceLock
        do {
            stableLock = try KanameDesktopInstanceLock(lockFileURL: stableEnvironment.instanceLockURL)
        } catch KanameDesktopInstanceLockError.alreadyRunning {
            throw DesktopDevelopmentDataForkError.stableDataBusy
        } catch {
            throw DesktopDevelopmentDataForkError.stableDataBusy
        }
        defer { _ = stableLock }

        var developmentLock: KanameDesktopInstanceLock?
        if manager.fileExists(atPath: environment.applicationSupportRoot.path) {
            do {
                developmentLock = try KanameDesktopInstanceLock(lockFileURL: environment.instanceLockURL)
            } catch KanameDesktopInstanceLockError.alreadyRunning {
                throw DesktopDevelopmentDataForkError.developmentDataBusy
            } catch {
                throw DesktopDevelopmentDataForkError.developmentDataBusy
            }
        }
        defer { _ = developmentLock }
#endif

        let workingRoot = base.appendingPathComponent(
            ".kaname-dev-fork-\(forkID.uuidString.lowercased())",
            isDirectory: true
        )
        guard !manager.fileExists(atPath: workingRoot.path) else {
            throw DesktopDevelopmentDataForkError.unsafeEnvironment
        }
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            workingRoot,
            failure: DesktopDevelopmentDataForkError.unsafeEnvironment
        )
        defer { try? manager.removeItem(at: workingRoot) }

        let backupURL = workingRoot.appendingPathComponent("stable.kanamebackup", isDirectory: true)
        let stableStore = FileDesktopStateStore(fileURL: stableEnvironment.workspaceFileURL)
        guard let stableWorkspace = try stableStore.load() else {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }
        let sourceStateSchemaVersion = DesktopAppModel.declaredSchemaVersion(from: stableWorkspace)
            ?? DesktopAppSnapshot.currentVersion
        let backup: DesktopBackupManifest
        do {
            backup = try stableStore.exportRecoveryBackup(
                to: backupURL,
                stateSchemaVersion: sourceStateSchemaVersion,
                createdAtUnixMillis: createdAtUnixMillis
            )
        } catch DesktopModelRecoveryError.activeRuntimeWork {
            throw DesktopDevelopmentDataForkError.stableDataBusy
        }

        let recovery = DesktopRecoveryService()
        let sourceWorkspace: Data
        do {
            sourceWorkspace = try recovery.verifiedArtifactData(kind: .workspaceState, from: backupURL)
        } catch {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }
        guard sourceWorkspace == stableWorkspace else {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }
        let memoryStore = DevelopmentForkMemoryStore(data: sourceWorkspace)
        let developmentModel = DesktopAppModel(store: memoryStore, now: { createdAtUnixMillis })
        guard developmentModel.recoveryStatus == nil,
              developmentModel.persistenceError == nil,
              developmentModel.prepareDevelopmentDataFork(),
              let developmentWorkspace = memoryStore.data else {
            throw DesktopDevelopmentDataForkError.sanitizationFailed
        }

        let stagingRoot = workingRoot.appendingPathComponent("Kaname Dev", isDirectory: true)
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            stagingRoot,
            failure: DesktopDevelopmentDataForkError.activationFailed
        )
        let stagedWorkspace = stagingRoot.appendingPathComponent("Desktop/workspace.json")
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            stagedWorkspace.deletingLastPathComponent(),
            failure: DesktopDevelopmentDataForkError.unsafeArtifact
        )
        try DesktopWorkflowFilesystem.writePrivate(
            developmentWorkspace,
            to: stagedWorkspace,
            failure: DesktopDevelopmentDataForkError.unsafeArtifact
        )

        let copiedKinds: Set<DesktopRecoveryArtifactKind> = [
            .workflowInstallationState,
            .workflowCapabilityPackage,
            .workflowLibraryState,
            .workflowObjectState,
        ]
        let copiedArtifacts = try recovery.verifiedArtifacts(kinds: copiedKinds, from: backupURL)
        for artifact in copiedArtifacts {
            guard let relativePath = artifact.manifest.restoreRelativePath,
                  workflowRestorePathIsAllowed(relativePath, kind: artifact.manifest.kind) else {
                throw DesktopDevelopmentDataForkError.unsafeArtifact
            }
            let destination = stagingRoot.appendingPathComponent(relativePath)
            try DesktopWorkflowFilesystem.preparePrivateDirectory(
                destination.deletingLastPathComponent(),
                failure: DesktopDevelopmentDataForkError.unsafeArtifact
            )
            try DesktopWorkflowFilesystem.writePrivate(
                artifact.data,
                to: destination,
                failure: DesktopDevelopmentDataForkError.unsafeArtifact
            )
        }

        let willArchiveDevelopmentData = manager.fileExists(atPath: environment.applicationSupportRoot.path)
        if willArchiveDevelopmentData {
            try preserveDevelopmentGoogleConfiguration(
                from: environment.applicationSupportRoot,
                into: stagingRoot
            )
        }

        let receipt = DesktopDevelopmentDataForkReceipt(
            forkID: forkID,
            sourceBackupID: backup.backupID,
            createdAtUnixMillis: createdAtUnixMillis,
            sourceStateSchemaVersion: backup.stateSchemaVersion,
            developmentStateSchemaVersion: developmentModel.snapshot.version,
            sourceWorkspaceSHA256: DesktopRecoveryService.sha256(sourceWorkspace),
            developmentWorkspaceSHA256: DesktopRecoveryService.sha256(developmentWorkspace),
            copiedWorkflowArtifactCount: copiedArtifacts.count,
            previousDevelopmentDataArchived: willArchiveDevelopmentData
        )
        let receiptURL = stagingRoot.appendingPathComponent(receiptRelativePath)
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            receiptURL.deletingLastPathComponent(),
            failure: DesktopDevelopmentDataForkError.unsafeArtifact
        )
        try DesktopWorkflowFilesystem.writePrivate(
            try receiptEncoder.encode(receipt),
            to: receiptURL,
            failure: DesktopDevelopmentDataForkError.unsafeArtifact
        )
        guard try JSONDecoder().decode(
            DesktopDevelopmentDataForkReceipt.self,
            from: Data(contentsOf: receiptURL)
        ) == receipt else {
            throw DesktopDevelopmentDataForkError.activationFailed
        }

        var archivedRoot: URL?
        if willArchiveDevelopmentData {
            let archiveDirectory = base.appendingPathComponent("Kaname Dev Archives", isDirectory: true)
            try DesktopWorkflowFilesystem.preparePrivateDirectory(
                archiveDirectory,
                failure: DesktopDevelopmentDataForkError.activationFailed
            )
            let archive = archiveDirectory.appendingPathComponent(
                "fork-\(createdAtUnixMillis)-\(forkID.uuidString.lowercased())",
                isDirectory: true
            )
            guard !manager.fileExists(atPath: archive.path) else {
                throw DesktopDevelopmentDataForkError.unsafeEnvironment
            }
            try manager.moveItem(at: environment.applicationSupportRoot, to: archive)
            archivedRoot = archive
        }

        do {
            try manager.moveItem(at: stagingRoot, to: environment.applicationSupportRoot)
        } catch {
            guard let archivedRoot else { throw DesktopDevelopmentDataForkError.activationFailed }
            do {
                guard !manager.fileExists(atPath: environment.applicationSupportRoot.path) else {
                    throw DesktopDevelopmentDataForkError.rollbackFailed
                }
                try manager.moveItem(at: archivedRoot, to: environment.applicationSupportRoot)
            } catch {
                throw DesktopDevelopmentDataForkError.rollbackFailed
            }
            throw DesktopDevelopmentDataForkError.activationFailed
        }
        return .created(receipt)
    }

    public static func receipt(
        environment: KanameDesktopEnvironment = .current
    ) throws -> DesktopDevelopmentDataForkReceipt {
        let url = environment.applicationSupportRoot.appendingPathComponent(receiptRelativePath)
        guard try DesktopRecoveryService.isRegularNonSymlink(url) else {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }
        let decoded = try JSONDecoder().decode(DesktopDevelopmentDataForkReceipt.self, from: Data(contentsOf: url))
        guard decoded.schemaVersion == DesktopDevelopmentDataForkReceipt.currentSchemaVersion,
              decoded.authorityRemoved,
              !decoded.automaticExecutionEnabled,
              decoded.externalMutationPolicy == .denied else {
            throw DesktopDevelopmentDataForkError.sourceWorkspaceInvalid
        }
        return decoded
    }

    private static func workflowRestorePathIsAllowed(
        _ relativePath: String,
        kind: DesktopRecoveryArtifactKind
    ) -> Bool {
        guard DesktopRecoveryService.isSafeRestoreRelativePath(relativePath) else { return false }
        return switch kind {
        case .workflowInstallationState:
            relativePath.hasPrefix("WorkflowInstallations/")
        case .workflowCapabilityPackage:
            relativePath.hasPrefix("WorkflowCapabilities/")
        case .workflowLibraryState:
            relativePath.hasPrefix("Workflows/")
        case .workflowObjectState:
            relativePath.hasPrefix("Objects/")
        case .workspaceState, .previousWorkspaceState, .localCoreJournal, .localCoreSnapshot,
             .conversationServiceState:
            false
        }
    }

    private static func preserveDevelopmentGoogleConfiguration(from archive: URL, into stagingRoot: URL) throws {
        let source = archive.appendingPathComponent("Google", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DesktopDevelopmentDataForkError.unsafeArtifact
        }
        let allowedNames = Set(["accounts.json", "oauth-client.json"])
        let destination = stagingRoot.appendingPathComponent("Google", isDirectory: true)
        for name in allowedNames {
            let file = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard try DesktopRecoveryService.isRegularNonSymlink(file) else {
                throw DesktopDevelopmentDataForkError.unsafeArtifact
            }
            let data = try Data(contentsOf: file)
            guard data.count <= 1_048_576 else { throw DesktopDevelopmentDataForkError.unsafeArtifact }
            let destinationURL = destination.appendingPathComponent(name)
            try DesktopWorkflowFilesystem.preparePrivateDirectory(
                destinationURL.deletingLastPathComponent(),
                failure: DesktopDevelopmentDataForkError.unsafeArtifact
            )
            try DesktopWorkflowFilesystem.writePrivate(
                data,
                to: destinationURL,
                failure: DesktopDevelopmentDataForkError.unsafeArtifact
            )
        }
    }

    private static var receiptEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private final class DevelopmentForkMemoryStore: DesktopStateStoring {
    var data: Data?

    init(data: Data) {
        self.data = data
    }

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
