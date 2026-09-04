import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

private struct DesktopRecoveryWorkerState: Decodable {
    let processIdentifier: Int32
}

public final class FileDesktopStateStore: DesktopRecoveryStateStoring {
    public let fileURL: URL
    private let runtimeMoveItem: (URL, URL) throws -> Void

    public var recoveryFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("workspace.previous.json")
    }

    public var managedRecoveryDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
    }

    public var backupHistoryDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Backups", isDirectory: true)
    }

    public var quarantineDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Quarantine", isDirectory: true)
    }

    public var receiptDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("Receipts", isDirectory: true)
    }

    public var recoveryLockMarkerURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("runtime-recovery-lock.json")
    }

    public var applicationSupportRootURL: URL {
        fileURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    public var localCoreDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("LocalCore", isDirectory: true)
    }

    public var conversationServiceDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("ConversationService", isDirectory: true)
    }

    public var workflowInstallationsDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("WorkflowInstallations", isDirectory: true)
    }

    public var workflowCapabilitiesDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("WorkflowCapabilities", isDirectory: true)
    }

    public var workflowLibraryDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("Workflows", isDirectory: true)
    }

    public var workflowObjectsDirectoryURL: URL {
        applicationSupportRootURL.appendingPathComponent("Objects", isDirectory: true)
    }

    public var resetArchiveDirectoryURL: URL {
        managedRecoveryDirectoryURL.appendingPathComponent("ResetArchives", isDirectory: true)
    }

    public convenience init(fileURL: URL) {
        self.init(fileURL: fileURL) { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    init(
        fileURL: URL,
        runtimeMoveItem: @escaping (URL, URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.runtimeMoveItem = runtimeMoveItem
    }

    public static func applicationSupport(rootDirectoryName: String = "Kaname") -> FileDesktopStateStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return FileDesktopStateStore(
            fileURL: base
                .appendingPathComponent(rootDirectoryName, isDirectory: true)
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("workspace.json")
        )
    }

    public func load() throws -> Data? {
        try readPrivateIfPresent(at: fileURL)
    }

    public func save(_ data: Data) throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
            let previous = try Data(contentsOf: fileURL)
            try writePrivate(previous, to: recoveryFileURL)
        }
        try writePrivate(data, to: fileURL)
    }

    public func loadRecovery() throws -> Data? {
        try readPrivateIfPresent(at: recoveryFileURL)
    }

    public func saveRecovered(_ data: Data) throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
        }
        try writePrivate(data, to: fileURL)
    }

    @discardableResult
    public func quarantinePrimary(
        reasonCode: String,
        detectedAtUnixMillis: Int64
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
        let primary = try Data(contentsOf: fileURL)
        try preparePrivateDirectory(quarantineDirectoryURL)
        let digest = DesktopRecoveryService.sha256(primary)
        let incidentURL = quarantineDirectoryURL.appendingPathComponent(
            "incident-\(digest.prefix(24))",
            isDirectory: true
        )
        let quarantinedStateURL = incidentURL.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: quarantinedStateURL.path) {
            guard DesktopRecoveryService.sha256(try Data(contentsOf: quarantinedStateURL)) == digest else {
                throw DesktopRecoveryError.destinationExists
            }
            return quarantinedStateURL
        }
        try preparePrivateDirectory(incidentURL)
        try writePrivate(primary, to: quarantinedStateURL)
        guard try Data(contentsOf: quarantinedStateURL) == primary else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        let event = DesktopRedactedDiagnosticEvent(
            category: "persistence",
            code: reasonCode,
            occurredAtUnixMillis: detectedAtUnixMillis
        )
        try writePrivate(try recoveryEncoder.encode(event), to: incidentURL.appendingPathComponent("receipt.json"))
        return quarantinedStateURL
    }

    @discardableResult
    public func createPrivateBackupHistory(
        stateSchemaVersion: Int,
        createdAtUnixMillis: Int64,
        includesRuntimeState: Bool = false
    ) throws -> DesktopBackupManifest? {
        let sources = try recoverySources(includesRuntimeState: includesRuntimeState)
        guard !sources.isEmpty else { return nil }
        try preparePrivateDirectory(backupHistoryDirectoryURL)
        var sourceFingerprint = SHA256()
        for source in sources.sorted(by: { $0.archiveName < $1.archiveName }) {
            sourceFingerprint.update(data: Data(source.archiveName.utf8))
            sourceFingerprint.update(data: Data([0]))
            sourceFingerprint.update(data: try Data(contentsOf: source.fileURL, options: [.mappedIfSafe]))
        }
        let digest = sourceFingerprint.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = backupHistoryDirectoryURL.appendingPathComponent(
            "backup-v\(stateSchemaVersion)-\(digest.prefix(24)).kanamebackup",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return try DesktopRecoveryService().validateBackup(at: destination)
        }
        let service = DesktopRecoveryService()
        _ = try service.createBackup(
            at: destination,
            sources: sources,
            stateSchemaVersion: stateSchemaVersion,
            createdAtUnixMillis: createdAtUnixMillis,
            runtimeStateIncluded: includesRuntimeState
        )
        return try service.validateBackup(at: destination)
    }

    @discardableResult
    public func exportRecoveryBackup(
        to destination: URL,
        stateSchemaVersion: Int,
        createdAtUnixMillis: Int64
    ) throws -> DesktopBackupManifest {
        let runtimeLock = try acquireExclusiveRuntimeRecoveryLock()
        defer { _ = runtimeLock }
        try requireRuntimeQuiescent()
        let sources = try recoverySources(includesRuntimeState: true)
        let service = DesktopRecoveryService()
        _ = try service.createBackup(
            at: destination,
            sources: sources,
            stateSchemaVersion: stateSchemaVersion,
            createdAtUnixMillis: createdAtUnixMillis,
            runtimeStateIncluded: true
        )
        return try service.validateBackup(at: destination)
    }

    public func requireRuntimeQuiescent() throws {
        guard FileManager.default.fileExists(atPath: conversationServiceDirectoryURL.path) else { return }
        for url in try regularFiles(below: conversationServiceDirectoryURL)
        where url.lastPathComponent == "worker.json" {
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(DesktopRecoveryWorkerState.self, from: data),
                  state.processIdentifier > 1 else { continue }
#if os(macOS)
            if Darwin.kill(state.processIdentifier, 0) == 0 {
                throw DesktopModelRecoveryError.activeRuntimeWork
            }
#endif
        }
    }

    public func acquireExclusiveRuntimeRecoveryLock() throws -> KanameRuntimeRecoveryFileLock {
        do {
            return try KanameRuntimeRecoveryFileLock.acquireExclusiveNonblocking(
                applicationSupportRoot: applicationSupportRootURL
            )
        } catch {
            throw DesktopModelRecoveryError.activeRuntimeWork
        }
    }

    @discardableResult
    public func archiveRuntimeState(resetID: UUID) throws -> [DesktopRuntimeArchiveMove] {
        try requireRuntimeQuiescent()
        let destinationRoot = resetArchiveDirectoryURL
            .appendingPathComponent(resetID.uuidString.lowercased(), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationRoot.path) else {
            throw DesktopRecoveryError.destinationExists
        }
        try preparePrivateDirectory(destinationRoot)
        var moves: [DesktopRuntimeArchiveMove] = []
        do {
            for source in [
                localCoreDirectoryURL,
                conversationServiceDirectoryURL,
                workflowInstallationsDirectoryURL,
                workflowCapabilitiesDirectoryURL,
                workflowLibraryDirectoryURL,
                workflowObjectsDirectoryURL,
            ]
            where FileManager.default.fileExists(atPath: source.path) {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw DesktopRecoveryError.unsafeSource
                }
                let destination = destinationRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                try runtimeMoveItem(source, destination)
                moves.append(.init(source: source, archive: destination))
            }
            return moves
        } catch {
            do {
                try restoreArchivedRuntimeState(moves)
            } catch {
                try? persistRecoveryFailureEvent(DesktopRedactedDiagnosticEvent(
                    category: "recovery",
                    code: "runtime-archive-rollback-unverified",
                    occurredAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                ))
                throw DesktopModelRecoveryError.recoveryRollbackFailed
            }
            throw error
        }
    }

    public func restoreArchivedRuntimeState(_ moves: [DesktopRuntimeArchiveMove]) throws {
        for move in moves.reversed() where FileManager.default.fileExists(atPath: move.archive.path) {
            guard !FileManager.default.fileExists(atPath: move.source.path) else {
                throw DesktopRecoveryError.destinationExists
            }
            try FileManager.default.createDirectory(
                at: move.source.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try runtimeMoveItem(move.archive, move.source)
        }
        guard moves.allSatisfy({
            FileManager.default.fileExists(atPath: $0.source.path)
                && !FileManager.default.fileExists(atPath: $0.archive.path)
        }) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    public func hasRuntimeState() throws -> Bool {
        try !regularFiles(below: localCoreDirectoryURL).isEmpty
            || !regularFiles(below: conversationServiceDirectoryURL).isEmpty
            || !regularFiles(below: workflowInstallationsDirectoryURL).isEmpty
            || !regularFiles(below: workflowCapabilitiesDirectoryURL).isEmpty
            || !regularFiles(below: workflowLibraryDirectoryURL).isEmpty
            || !regularFiles(below: workflowObjectsDirectoryURL).isEmpty
    }

    public func activateVerifiedRuntimeRestore(
        from bundleURL: URL,
        restoreID: UUID
    ) throws -> DesktopRuntimeRestoreTransaction {
        let service = DesktopRecoveryService()
        let manifest = try service.validateBackup(at: bundleURL)
        let runtimeKinds: Set<DesktopRecoveryArtifactKind> = [
            .localCoreJournal,
            .localCoreSnapshot,
            .conversationServiceState,
            .workflowInstallationState,
            .workflowCapabilityPackage,
            .workflowLibraryState,
            .workflowObjectState,
        ]
        let runtimeArtifacts = try service.verifiedArtifacts(kinds: runtimeKinds, from: bundleURL)
        guard manifest.runtimeStateIncluded == true else {
            guard runtimeArtifacts.isEmpty else { throw DesktopModelRecoveryError.restoreArtifactInvalid }
            if try hasRuntimeState() { throw DesktopModelRecoveryError.restoreArtifactInvalid }
            return DesktopRuntimeRestoreTransaction(
                originalMoves: [],
                activatedRoots: [],
                failedRestoreDirectory: managedRecoveryDirectoryURL
            )
        }
        let stagingRoot = managedRecoveryDirectoryURL
            .appendingPathComponent("RuntimeRestoreStaging", isDirectory: true)
            .appendingPathComponent(restoreID.uuidString.lowercased(), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: stagingRoot.path) else {
            throw DesktopRecoveryError.destinationExists
        }
        try preparePrivateDirectory(stagingRoot)
        do {
            for artifact in runtimeArtifacts {
                guard let relativePath = artifact.manifest.restoreRelativePath,
                      Self.runtimeRestorePathIsAllowed(relativePath, kind: artifact.manifest.kind) else {
                    throw DesktopModelRecoveryError.restoreArtifactInvalid
                }
                let destination = stagingRoot.appendingPathComponent(relativePath)
                try preparePrivateDirectory(destination.deletingLastPathComponent())
                try writePrivate(artifact.data, to: destination)
            }
            let originalMoves = try archiveRuntimeState(resetID: restoreID)
            var activatedRoots: [URL] = []
            let failedRestoreDirectory = managedRecoveryDirectoryURL
                .appendingPathComponent("FailedRuntimeRestores", isDirectory: true)
                .appendingPathComponent(restoreID.uuidString.lowercased(), isDirectory: true)
            do {
                for name in [
                    "LocalCore", "ConversationService", "WorkflowInstallations",
                    "WorkflowCapabilities", "Workflows", "Objects",
                ] {
                    let staged = stagingRoot.appendingPathComponent(name, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                    let active = applicationSupportRootURL.appendingPathComponent(name, isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: active.path) else {
                        throw DesktopRecoveryError.destinationExists
                    }
                    try runtimeMoveItem(staged, active)
                    activatedRoots.append(active)
                }
                return DesktopRuntimeRestoreTransaction(
                    originalMoves: originalMoves,
                    activatedRoots: activatedRoots,
                    failedRestoreDirectory: failedRestoreDirectory
                )
            } catch {
                let transaction = DesktopRuntimeRestoreTransaction(
                    originalMoves: originalMoves,
                    activatedRoots: activatedRoots,
                    failedRestoreDirectory: failedRestoreDirectory
                )
                do {
                    try rollbackRuntimeRestore(transaction)
                } catch {
                    try? persistRecoveryFailureEvent(DesktopRedactedDiagnosticEvent(
                        category: "recovery",
                        code: "runtime-activation-rollback-unverified",
                        occurredAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
                    ))
                    throw DesktopModelRecoveryError.recoveryRollbackFailed
                }
                throw error
            }
        } catch {
            throw error
        }
    }

    public func rollbackRuntimeRestore(_ transaction: DesktopRuntimeRestoreTransaction) throws {
        if !transaction.activatedRoots.isEmpty {
            try preparePrivateDirectory(transaction.failedRestoreDirectory)
        }
        for active in transaction.activatedRoots.reversed()
        where FileManager.default.fileExists(atPath: active.path) {
            let failed = transaction.failedRestoreDirectory.appendingPathComponent(active.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: failed.path) else {
                throw DesktopRecoveryError.destinationExists
            }
            try runtimeMoveItem(active, failed)
        }
        try restoreArchivedRuntimeState(transaction.originalMoves)
        guard transaction.activatedRoots.allSatisfy({ active in
            FileManager.default.fileExists(
                atPath: transaction.failedRestoreDirectory.appendingPathComponent(active.lastPathComponent).path
            )
        }) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    private static func runtimeRestorePathIsAllowed(
        _ path: String,
        kind: DesktopRecoveryArtifactKind
    ) -> Bool {
        switch kind {
        case .localCoreJournal, .localCoreSnapshot:
            path.hasPrefix("LocalCore/")
        case .conversationServiceState:
            path.hasPrefix("ConversationService/")
        case .workflowInstallationState:
            path.hasPrefix("WorkflowInstallations/")
        case .workflowCapabilityPackage:
            path.hasPrefix("WorkflowCapabilities/")
        case .workflowLibraryState:
            path.hasPrefix("Workflows/")
        case .workflowObjectState:
            path.hasPrefix("Objects/")
        case .workspaceState, .previousWorkspaceState:
            false
        }
    }

    private func recoverySources(includesRuntimeState: Bool) throws -> [DesktopRecoverySource] {
        var sources: [DesktopRecoverySource] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(fileURL) else { throw DesktopRecoveryError.unsafeSource }
            sources.append(.init(kind: .workspaceState, fileURL: fileURL, archiveName: "workspace.json"))
        }
        if FileManager.default.fileExists(atPath: recoveryFileURL.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(recoveryFileURL) else { throw DesktopRecoveryError.unsafeSource }
            sources.append(.init(kind: .previousWorkspaceState, fileURL: recoveryFileURL, archiveName: "workspace.previous.json"))
        }
        guard includesRuntimeState else { return sources }
        sources += try runtimeRecoverySources(
            below: localCoreDirectoryURL,
            kind: .localCoreJournal,
            restorePrefix: "LocalCore",
            archivePrefix: "local-core"
        )
        sources += try runtimeRecoverySources(
            below: conversationServiceDirectoryURL,
            kind: .conversationServiceState,
            restorePrefix: "ConversationService",
            archivePrefix: "conversation"
        )
        sources += try runtimeRecoverySources(
            below: workflowInstallationsDirectoryURL,
            kind: .workflowInstallationState,
            restorePrefix: "WorkflowInstallations",
            archivePrefix: "workflow-installation"
        )
        sources += try runtimeRecoverySources(
            below: workflowCapabilitiesDirectoryURL,
            kind: .workflowCapabilityPackage,
            restorePrefix: "WorkflowCapabilities",
            archivePrefix: "workflow-capability"
        )
        sources += try runtimeRecoverySources(
            below: workflowLibraryDirectoryURL,
            kind: .workflowLibraryState,
            restorePrefix: "Workflows",
            archivePrefix: "workflow-library"
        )
        sources += try runtimeRecoverySources(
            below: workflowObjectsDirectoryURL,
            kind: .workflowObjectState,
            restorePrefix: "Objects",
            archivePrefix: "workflow-object"
        )
        guard sources.count <= 4_098 else { throw DesktopRecoveryError.unsafeSource }
        return sources
    }

    private func runtimeRecoverySources(
        below root: URL,
        kind: DesktopRecoveryArtifactKind,
        restorePrefix: String,
        archivePrefix: String
    ) throws -> [DesktopRecoverySource] {
        try regularFiles(below: root).map { url in
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let restorePath = "\(restorePrefix)/\(relative)"
            let opaqueName = "\(archivePrefix)-\(DesktopRecoveryService.sha256(Data(restorePath.utf8)).prefix(32)).bin"
            return DesktopRecoverySource(
                kind: kind,
                fileURL: url,
                archiveName: opaqueName,
                restoreRelativePath: restorePath
            )
        }
    }

    private func regularFiles(below root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw DesktopRecoveryError.unsafeSource
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw DesktopRecoveryError.missingSource }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DesktopRecoveryError.unsafeSource }
            guard values.isRegularFile == true else { continue }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(canonicalRoot + "/") else { throw DesktopRecoveryError.unsafeSource }
            files.append(url)
            guard files.count <= 4_096 else { throw DesktopRecoveryError.unsafeSource }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func persistMigrationReceipt(_ receipt: DesktopMigrationReceipt) throws {
        try persistRecoveryDocument(receipt, name: "migration-\(receipt.migrationID.uuidString.lowercased()).json")
    }

    public func persistRestoreReceipt(_ receipt: DesktopRestoreReceipt) throws {
        try persistRecoveryDocument(receipt, name: "restore-\(receipt.restoreID.uuidString.lowercased()).json")
    }

    public func persistResetManifest(_ manifest: DesktopResetManifest) throws {
        try persistRecoveryDocument(manifest, name: "reset-\(manifest.resetID.uuidString.lowercased()).json")
    }

    public func persistRecoveryFailureEvent(_ event: DesktopRedactedDiagnosticEvent) throws {
        try persistRecoveryDocument(event, name: "failure-\(UUID().uuidString.lowercased()).json")
    }

    public func persistRecoveryLockMarker(_ event: DesktopRedactedDiagnosticEvent) throws {
        guard event.category == "recovery",
              event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount == 0,
              event.privateDetailSHA256 == nil else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        try preparePrivateDirectory(managedRecoveryDirectoryURL)
        let data = try recoveryEncoder.encode(event)
        try writePrivate(data, to: recoveryLockMarkerURL)
        guard try readPrivateIfPresent(at: recoveryLockMarkerURL) == data else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    public func loadRecoveryLockMarker() throws -> DesktopRedactedDiagnosticEvent? {
        guard let data = try readPrivateIfPresent(at: recoveryLockMarkerURL) else { return nil }
        let event = try JSONDecoder().decode(DesktopRedactedDiagnosticEvent.self, from: data)
        guard event.category == "recovery",
              event.occurredAtUnixMillis >= 0,
              event.privateDetailByteCount == 0,
              event.privateDetailSHA256 == nil else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
        return DesktopRedactedDiagnosticEvent(
            category: event.category,
            code: event.code,
            occurredAtUnixMillis: event.occurredAtUnixMillis
        )
    }

    public func clearRecoveryLockMarker() throws {
        guard FileManager.default.fileExists(atPath: recoveryLockMarkerURL.path) else { return }
        guard try DesktopRecoveryService.isRegularNonSymlink(recoveryLockMarkerURL) else {
            throw DesktopRecoveryError.unsafeSource
        }
        try FileManager.default.removeItem(at: recoveryLockMarkerURL)
        guard !FileManager.default.fileExists(atPath: recoveryLockMarkerURL.path) else {
            throw DesktopModelRecoveryError.persistenceVerificationFailed
        }
    }

    private func persistRecoveryDocument<Value: Encodable>(_ value: Value, name: String) throws {
        try preparePrivateDirectory(receiptDirectoryURL)
        try writePrivate(try recoveryEncoder.encode(value), to: receiptDirectoryURL.appendingPathComponent(name))
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try preparePrivateDirectory(directory)
    }

    private func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try DesktopRecoveryService.isRegularNonSymlink(url) else { throw DesktopRecoveryError.unsafeSource }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func readPrivateIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try DesktopRecoveryService.isRegularNonSymlink(url) else { throw DesktopRecoveryError.unsafeSource }
        return try Data(contentsOf: url)
    }

    private var recoveryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
