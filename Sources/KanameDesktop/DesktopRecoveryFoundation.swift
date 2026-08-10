import CryptoKit
import Foundation

public enum DesktopRecoveryArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceState
    case previousWorkspaceState
    case localCoreJournal
    case localCoreSnapshot
    case conversationServiceState
}

public enum DesktopRecoveryExcludedScope: String, Codable, CaseIterable, Sendable {
    case credentials
    case providerOwnedData
    case repositories
    case vaults
}

public struct DesktopRecoverySource: Equatable, Sendable {
    public let kind: DesktopRecoveryArtifactKind
    public let fileURL: URL
    public let archiveName: String
    public let restoreRelativePath: String?

    public init(
        kind: DesktopRecoveryArtifactKind,
        fileURL: URL,
        archiveName: String,
        restoreRelativePath: String? = nil
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.archiveName = archiveName
        self.restoreRelativePath = restoreRelativePath
    }
}

public struct DesktopRecoveryArtifactManifest: Codable, Equatable, Sendable {
    public let kind: DesktopRecoveryArtifactKind
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
    public let restoreRelativePath: String?

    public init(
        kind: DesktopRecoveryArtifactKind,
        relativePath: String,
        byteCount: Int64,
        sha256: String,
        restoreRelativePath: String? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.restoreRelativePath = restoreRelativePath
    }
}

public struct DesktopVerifiedRecoveryArtifact: Equatable, Sendable {
    public let manifest: DesktopRecoveryArtifactManifest
    public let data: Data

    public init(manifest: DesktopRecoveryArtifactManifest, data: Data) {
        self.manifest = manifest
        self.data = data
    }
}

public struct DesktopBackupManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let backupID: UUID
    public let createdAtUnixMillis: Int64
    public let stateSchemaVersion: Int
    public let artifacts: [DesktopRecoveryArtifactManifest]
    public let excludedScopes: [DesktopRecoveryExcludedScope]
    public let runtimeStateIncluded: Bool?

    public init(
        backupID: UUID,
        createdAtUnixMillis: Int64,
        stateSchemaVersion: Int,
        artifacts: [DesktopRecoveryArtifactManifest],
        excludedScopes: [DesktopRecoveryExcludedScope] = DesktopRecoveryExcludedScope.allCases,
        runtimeStateIncluded: Bool? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.backupID = backupID
        self.createdAtUnixMillis = createdAtUnixMillis
        self.stateSchemaVersion = stateSchemaVersion
        self.artifacts = artifacts
        self.excludedScopes = excludedScopes
        self.runtimeStateIncluded = runtimeStateIncluded
    }
}

public struct DesktopRestoreReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let restoreID: UUID
    public let backupID: UUID
    public let stagedAtUnixMillis: Int64
    public let verifiedArtifactCount: Int
    public let verifiedByteCount: Int64

    public init(
        restoreID: UUID,
        backupID: UUID,
        stagedAtUnixMillis: Int64,
        verifiedArtifactCount: Int,
        verifiedByteCount: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.restoreID = restoreID
        self.backupID = backupID
        self.stagedAtUnixMillis = stagedAtUnixMillis
        self.verifiedArtifactCount = verifiedArtifactCount
        self.verifiedByteCount = verifiedByteCount
    }
}

public struct DesktopRestoreManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let restoreID: UUID
    public let backupID: UUID
    public let preparedAtUnixMillis: Int64
    public let stateSchemaVersion: Int
    public let artifacts: [DesktopRecoveryArtifactManifest]
    public let preservedScopes: [DesktopRecoveryExcludedScope]

    public init(
        restoreID: UUID,
        backupID: UUID,
        preparedAtUnixMillis: Int64,
        stateSchemaVersion: Int,
        artifacts: [DesktopRecoveryArtifactManifest],
        preservedScopes: [DesktopRecoveryExcludedScope]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.restoreID = restoreID
        self.backupID = backupID
        self.preparedAtUnixMillis = preparedAtUnixMillis
        self.stateSchemaVersion = stateSchemaVersion
        self.artifacts = artifacts
        self.preservedScopes = preservedScopes
    }
}

public struct DesktopResetManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let resetID: UUID
    public let preparedAtUnixMillis: Int64
    public let verifiedBackupID: UUID
    public let localArtifacts: [DesktopRecoveryArtifactManifest]
    public let preservedScopes: [DesktopRecoveryExcludedScope]

    public init(
        resetID: UUID,
        preparedAtUnixMillis: Int64,
        verifiedBackupID: UUID,
        localArtifacts: [DesktopRecoveryArtifactManifest],
        preservedScopes: [DesktopRecoveryExcludedScope] = DesktopRecoveryExcludedScope.allCases
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.resetID = resetID
        self.preparedAtUnixMillis = preparedAtUnixMillis
        self.verifiedBackupID = verifiedBackupID
        self.localArtifacts = localArtifacts
        self.preservedScopes = preservedScopes
    }
}

public enum DesktopMigrationOutcome: String, Codable, Sendable {
    case applied
    case noChange
    case failed
}

public struct DesktopMigrationReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let migrationID: UUID
    public let fromStateSchemaVersion: Int
    public let toStateSchemaVersion: Int
    public let startedAtUnixMillis: Int64
    public let completedAtUnixMillis: Int64
    public let outcome: DesktopMigrationOutcome
    public let backupID: UUID?
    public let reasonCode: String?

    public init(
        migrationID: UUID,
        fromStateSchemaVersion: Int,
        toStateSchemaVersion: Int,
        startedAtUnixMillis: Int64,
        completedAtUnixMillis: Int64,
        outcome: DesktopMigrationOutcome,
        backupID: UUID?,
        reasonCode: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.migrationID = migrationID
        self.fromStateSchemaVersion = fromStateSchemaVersion
        self.toStateSchemaVersion = toStateSchemaVersion
        self.startedAtUnixMillis = startedAtUnixMillis
        self.completedAtUnixMillis = completedAtUnixMillis
        self.outcome = outcome
        self.backupID = backupID
        self.reasonCode = DesktopDiagnosticsRedactor.safeCode(reasonCode)
    }
}

public struct DesktopRedactedDiagnosticEvent: Codable, Equatable, Sendable {
    public let category: String
    public let code: String
    public let occurredAtUnixMillis: Int64
    public let privateDetailByteCount: Int
    public let privateDetailSHA256: String?

    public init(category: String, code: String, occurredAtUnixMillis: Int64, privateDetail: String? = nil) {
        self.category = DesktopDiagnosticsRedactor.safeCode(category) ?? "unknown"
        self.code = DesktopDiagnosticsRedactor.safeCode(code) ?? "unknown"
        self.occurredAtUnixMillis = occurredAtUnixMillis
        privateDetailByteCount = privateDetail?.utf8.count ?? 0
        privateDetailSHA256 = privateDetail.map { DesktopRecoveryService.sha256(Data($0.utf8)) }
    }
}

public struct DesktopRedactedRestoreReceipt: Codable, Equatable, Sendable {
    public let restoreID: UUID
    public let backupID: UUID
    public let stagedAtUnixMillis: Int64
    public let verifiedArtifactCount: Int
    public let verifiedByteCount: Int64

    public init?(_ receipt: DesktopRestoreReceipt) {
        guard receipt.schemaVersion == DesktopRestoreReceipt.currentSchemaVersion,
              receipt.stagedAtUnixMillis >= 0,
              (0...4_098).contains(receipt.verifiedArtifactCount),
              receipt.verifiedByteCount >= 0 else { return nil }
        restoreID = receipt.restoreID
        backupID = receipt.backupID
        stagedAtUnixMillis = receipt.stagedAtUnixMillis
        verifiedArtifactCount = receipt.verifiedArtifactCount
        verifiedByteCount = receipt.verifiedByteCount
    }
}

public struct DesktopRedactedResetReceipt: Codable, Equatable, Sendable {
    public let resetID: UUID
    public let preparedAtUnixMillis: Int64
    public let verifiedBackupID: UUID
    public let localArtifactCount: Int
    public let localArtifactByteCount: Int64
    public let preservedScopes: [DesktopRecoveryExcludedScope]

    public init?(_ manifest: DesktopResetManifest) {
        guard manifest.schemaVersion == DesktopResetManifest.currentSchemaVersion,
              manifest.preparedAtUnixMillis >= 0,
              manifest.localArtifacts.count <= 4_098,
              Set(manifest.preservedScopes) == Set(DesktopRecoveryExcludedScope.allCases) else { return nil }
        var byteCount: Int64 = 0
        for artifact in manifest.localArtifacts {
            guard artifact.byteCount >= 0 else { return nil }
            let addition = byteCount.addingReportingOverflow(artifact.byteCount)
            guard !addition.overflow else { return nil }
            byteCount = addition.partialValue
        }
        resetID = manifest.resetID
        preparedAtUnixMillis = manifest.preparedAtUnixMillis
        verifiedBackupID = manifest.verifiedBackupID
        localArtifactCount = manifest.localArtifacts.count
        localArtifactByteCount = byteCount
        preservedScopes = DesktopRecoveryExcludedScope.allCases
    }
}

public struct DesktopRedactedDiagnosticsBundle: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAtUnixMillis: Int64
    public let report: DesktopDiagnosticsReport
    public let migrationReceipts: [DesktopMigrationReceipt]
    public let restoreReceipts: [DesktopRedactedRestoreReceipt]
    public let resetReceipts: [DesktopRedactedResetReceipt]
    public let events: [DesktopRedactedDiagnosticEvent]
    public let malformedReceiptCount: Int
    public let rejectedUnsafeReceiptCount: Int
    public let receiptScanTruncated: Bool

    public init(
        generatedAtUnixMillis: Int64,
        report: DesktopDiagnosticsReport,
        migrationReceipts: [DesktopMigrationReceipt],
        restoreReceipts: [DesktopRedactedRestoreReceipt] = [],
        resetReceipts: [DesktopRedactedResetReceipt] = [],
        events: [DesktopRedactedDiagnosticEvent],
        malformedReceiptCount: Int = 0,
        rejectedUnsafeReceiptCount: Int = 0,
        receiptScanTruncated: Bool = false
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAtUnixMillis = generatedAtUnixMillis
        self.report = DesktopDiagnosticsReport(
            schemaVersion: report.schemaVersion,
            generatedAtUnixMillis: report.generatedAtUnixMillis,
            projectCount: report.projectCount,
            activeThreadCount: report.activeThreadCount,
            archivedThreadCount: report.archivedThreadCount,
            unreadThreadCount: report.unreadThreadCount,
            pendingApprovalCount: report.pendingApprovalCount,
            researchCount: report.researchCount,
            emailDraftCount: report.emailDraftCount,
            calendarProposalCount: report.calendarProposalCount,
            automationCount: report.automationCount,
            artifactCount: report.artifactCount,
            auditRecordCount: report.auditRecordCount,
            safeMode: report.safeMode,
            persistenceHealthy: report.persistenceHealthy,
            relayState: DesktopDiagnosticsRedactor.safeCode(report.relayState) ?? "unknown",
            queueState: DesktopDiagnosticsRedactor.safeCode(report.queueState) ?? "unknown"
        )
        self.migrationReceipts = migrationReceipts
        self.restoreReceipts = restoreReceipts
        self.resetReceipts = resetReceipts
        self.events = events
        self.malformedReceiptCount = max(0, malformedReceiptCount)
        self.rejectedUnsafeReceiptCount = max(0, rejectedUnsafeReceiptCount)
        self.receiptScanTruncated = receiptScanTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAtUnixMillis
        case report
        case migrationReceipts
        case restoreReceipts
        case resetReceipts
        case events
        case malformedReceiptCount
        case rejectedUnsafeReceiptCount
        case receiptScanTruncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAtUnixMillis = try container.decode(Int64.self, forKey: .generatedAtUnixMillis)
        report = try container.decode(DesktopDiagnosticsReport.self, forKey: .report)
        migrationReceipts = try container.decodeIfPresent([DesktopMigrationReceipt].self, forKey: .migrationReceipts) ?? []
        restoreReceipts = try container.decodeIfPresent([DesktopRedactedRestoreReceipt].self, forKey: .restoreReceipts) ?? []
        resetReceipts = try container.decodeIfPresent([DesktopRedactedResetReceipt].self, forKey: .resetReceipts) ?? []
        events = try container.decodeIfPresent([DesktopRedactedDiagnosticEvent].self, forKey: .events) ?? []
        malformedReceiptCount = max(0, try container.decodeIfPresent(Int.self, forKey: .malformedReceiptCount) ?? 0)
        rejectedUnsafeReceiptCount = max(0, try container.decodeIfPresent(Int.self, forKey: .rejectedUnsafeReceiptCount) ?? 0)
        receiptScanTruncated = try container.decodeIfPresent(Bool.self, forKey: .receiptScanTruncated) ?? false
    }
}

public enum DesktopRecoveryError: Error, Equatable, LocalizedError {
    case destinationExists
    case emptyBackup
    case missingSource
    case unsafeSource
    case duplicateArchiveName
    case unsupportedManifestSchema
    case missingRequiredExclusions
    case unsafeManifestPath
    case missingArtifact
    case unexpectedArtifact
    case integrityMismatch
    case missingRequestedArtifact
    case ambiguousRequestedArtifact

    public var errorDescription: String? {
        switch self {
        case .destinationExists: "The recovery destination already exists."
        case .emptyBackup: "A recovery bundle must contain at least one local artifact."
        case .missingSource: "A requested local recovery source does not exist."
        case .unsafeSource: "Only explicit regular, non-symbolic-link files can be included."
        case .duplicateArchiveName: "Every recovery artifact needs a unique archive name."
        case .unsupportedManifestSchema: "The recovery manifest schema is not supported."
        case .missingRequiredExclusions: "The recovery manifest does not preserve every excluded privacy scope."
        case .unsafeManifestPath: "The recovery manifest contains an unsafe path."
        case .missingArtifact: "A declared recovery artifact is missing."
        case .unexpectedArtifact: "The recovery bundle contains an undeclared artifact."
        case .integrityMismatch: "A recovery artifact does not match its recorded size and digest."
        case .missingRequestedArtifact: "The recovery bundle does not contain the requested local artifact."
        case .ambiguousRequestedArtifact: "The recovery bundle contains more than one requested local artifact."
        }
    }
}

public enum DesktopDiagnosticsRedactor {
    public static func safeCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty else { return nil }
        guard value.count <= 80, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            let digest = DesktopRecoveryService.sha256(Data(value.utf8))
            return "redacted-\(digest.prefix(16))"
        }
        return value
    }
}

public struct DesktopRecoveryService: Sendable {
    public static let manifestFileName = "manifest.json"
    public static let restoreManifestFileName = "restore-manifest.json"
    public static let restoreReceiptFileName = "restore-receipt.json"

    public init() {}

    @discardableResult
    public func createBackup(
        at bundleURL: URL,
        sources: [DesktopRecoverySource],
        stateSchemaVersion: Int,
        backupID: UUID = UUID(),
        createdAtUnixMillis: Int64,
        runtimeStateIncluded: Bool = false
    ) throws -> DesktopBackupManifest {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: bundleURL.path) else { throw DesktopRecoveryError.destinationExists }
        guard !sources.isEmpty else { throw DesktopRecoveryError.emptyBackup }
        try validateSources(sources)

        let parent = bundleURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partialURL = parent.appendingPathComponent(".\(bundleURL.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        defer { try? manager.removeItem(at: partialURL) }

        try manager.createDirectory(at: partialURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let artifactsURL = partialURL.appendingPathComponent("artifacts", isDirectory: true)
        try manager.createDirectory(at: artifactsURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        var artifactManifests: [DesktopRecoveryArtifactManifest] = []
        for source in sources.sorted(by: { $0.archiveName < $1.archiveName }) {
            let data = try Data(contentsOf: source.fileURL, options: [.mappedIfSafe])
            let relativePath = "artifacts/\(source.archiveName)"
            let destination = partialURL.appendingPathComponent(relativePath)
            try writePrivate(data, to: destination)
            artifactManifests.append(DesktopRecoveryArtifactManifest(
                kind: source.kind,
                relativePath: relativePath,
                byteCount: Int64(data.count),
                sha256: Self.sha256(data),
                restoreRelativePath: source.restoreRelativePath
            ))
        }

        let manifest = DesktopBackupManifest(
            backupID: backupID,
            createdAtUnixMillis: createdAtUnixMillis,
            stateSchemaVersion: stateSchemaVersion,
            artifacts: artifactManifests,
            runtimeStateIncluded: runtimeStateIncluded ? true : nil
        )
        try writePrivate(try Self.encoder.encode(manifest), to: partialURL.appendingPathComponent(Self.manifestFileName))
        try manager.moveItem(at: partialURL, to: bundleURL)
        return manifest
    }

    public func validateBackup(at bundleURL: URL) throws -> DesktopBackupManifest {
        let manager = FileManager.default
        let manifestURL = bundleURL.appendingPathComponent(Self.manifestFileName)
        guard try Self.isRegularNonSymlink(manifestURL) else { throw DesktopRecoveryError.missingArtifact }

        let manifest = try JSONDecoder().decode(DesktopBackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == DesktopBackupManifest.currentSchemaVersion else {
            throw DesktopRecoveryError.unsupportedManifestSchema
        }
        guard Set(manifest.excludedScopes) == Set(DesktopRecoveryExcludedScope.allCases) else {
            throw DesktopRecoveryError.missingRequiredExclusions
        }
        guard !manifest.artifacts.isEmpty else { throw DesktopRecoveryError.emptyBackup }

        var declaredPaths = Set([Self.manifestFileName])
        var restorePaths = Set<String>()
        for artifact in manifest.artifacts {
            guard isSafeRelativeArtifactPath(artifact.relativePath), declaredPaths.insert(artifact.relativePath).inserted else {
                throw DesktopRecoveryError.unsafeManifestPath
            }
            if let restoreRelativePath = artifact.restoreRelativePath {
                guard isSafeRestoreRelativePath(restoreRelativePath), restorePaths.insert(restoreRelativePath).inserted else {
                    throw DesktopRecoveryError.unsafeManifestPath
                }
            }
            let artifactURL = bundleURL.appendingPathComponent(artifact.relativePath)
            guard try Self.isRegularNonSymlink(artifactURL) else { throw DesktopRecoveryError.missingArtifact }
            _ = try readVerifiedArtifact(artifact, at: artifactURL)
        }

        let canonicalBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalBundlePath = canonicalBundleURL.path
        guard let enumerator = manager.enumerator(at: canonicalBundleURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw DesktopRecoveryError.missingArtifact
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw DesktopRecoveryError.unexpectedArtifact }
            guard values.isRegularFile == true else { continue }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(canonicalBundlePath + "/") else { throw DesktopRecoveryError.unexpectedArtifact }
            let relativePath = String(canonicalPath.dropFirst(canonicalBundlePath.count + 1))
            guard declaredPaths.contains(relativePath) else { throw DesktopRecoveryError.unexpectedArtifact }
        }
        return manifest
    }

    @discardableResult
    public func stageRestore(
        from bundleURL: URL,
        at stagingURL: URL,
        restoreID: UUID = UUID(),
        stagedAtUnixMillis: Int64
    ) throws -> DesktopRestoreReceipt {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: stagingURL.path) else { throw DesktopRecoveryError.destinationExists }
        let manifest = try validateBackup(at: bundleURL)
        let parent = stagingURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partialURL = parent.appendingPathComponent(".\(stagingURL.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        defer { try? manager.removeItem(at: partialURL) }
        try manager.createDirectory(at: partialURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        for artifact in manifest.artifacts {
            let destination = partialURL.appendingPathComponent(artifact.relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try readVerifiedArtifact(artifact, at: bundleURL.appendingPathComponent(artifact.relativePath))
            try writePrivate(data, to: destination)
        }
        let receipt = DesktopRestoreReceipt(
            restoreID: restoreID,
            backupID: manifest.backupID,
            stagedAtUnixMillis: stagedAtUnixMillis,
            verifiedArtifactCount: manifest.artifacts.count,
            verifiedByteCount: manifest.artifacts.reduce(0) { $0 + $1.byteCount }
        )
        let restoreManifest = DesktopRestoreManifest(
            restoreID: restoreID,
            backupID: manifest.backupID,
            preparedAtUnixMillis: stagedAtUnixMillis,
            stateSchemaVersion: manifest.stateSchemaVersion,
            artifacts: manifest.artifacts,
            preservedScopes: manifest.excludedScopes
        )
        try writePrivate(
            try Self.encoder.encode(restoreManifest),
            to: partialURL.appendingPathComponent(Self.restoreManifestFileName)
        )
        try writePrivate(try Self.encoder.encode(receipt), to: partialURL.appendingPathComponent(Self.restoreReceiptFileName))
        try manager.moveItem(at: partialURL, to: stagingURL)
        return receipt
    }

    public func prepareResetManifest(
        verifiedBackupAt bundleURL: URL,
        resetID: UUID = UUID(),
        preparedAtUnixMillis: Int64
    ) throws -> DesktopResetManifest {
        let backup = try validateBackup(at: bundleURL)
        return DesktopResetManifest(
            resetID: resetID,
            preparedAtUnixMillis: preparedAtUnixMillis,
            verifiedBackupID: backup.backupID,
            localArtifacts: backup.artifacts
        )
    }

    public func verifiedArtifactData(
        kind: DesktopRecoveryArtifactKind,
        from bundleURL: URL
    ) throws -> Data {
        let manifest = try validateBackup(at: bundleURL)
        let matches = manifest.artifacts.filter { $0.kind == kind }
        guard !matches.isEmpty else { throw DesktopRecoveryError.missingRequestedArtifact }
        guard matches.count == 1, let artifact = matches.first else {
            throw DesktopRecoveryError.ambiguousRequestedArtifact
        }
        return try readVerifiedArtifact(artifact, at: bundleURL.appendingPathComponent(artifact.relativePath))
    }

    public func verifiedArtifacts(
        kinds: Set<DesktopRecoveryArtifactKind>,
        from bundleURL: URL
    ) throws -> [DesktopVerifiedRecoveryArtifact] {
        let manifest = try validateBackup(at: bundleURL)
        return try manifest.artifacts
            .filter { kinds.contains($0.kind) }
            .map { artifact in
                DesktopVerifiedRecoveryArtifact(
                    manifest: artifact,
                    data: try readVerifiedArtifact(
                        artifact,
                        at: bundleURL.appendingPathComponent(artifact.relativePath)
                    )
                )
            }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateSources(_ sources: [DesktopRecoverySource]) throws {
        var archiveNames = Set<String>()
        for source in sources {
            guard isSafeArchiveName(source.archiveName) else { throw DesktopRecoveryError.unsafeSource }
            if let restoreRelativePath = source.restoreRelativePath {
                guard isSafeRestoreRelativePath(restoreRelativePath) else { throw DesktopRecoveryError.unsafeSource }
            }
            guard archiveNames.insert(source.archiveName).inserted else { throw DesktopRecoveryError.duplicateArchiveName }
            guard FileManager.default.fileExists(atPath: source.fileURL.path) else { throw DesktopRecoveryError.missingSource }
            guard try Self.isRegularNonSymlink(source.fileURL) else { throw DesktopRecoveryError.unsafeSource }
        }
    }

    private func isSafeArchiveName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private func isSafeRelativeArtifactPath(_ path: String) -> Bool {
        guard path.hasPrefix("artifacts/"), !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func isSafeRestoreRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isRegularNonSymlink(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        } catch {
            return false
        }
    }

    private func readVerifiedArtifact(_ artifact: DesktopRecoveryArtifactManifest, at url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) == artifact.byteCount, Self.sha256(data) == artifact.sha256 else {
            throw DesktopRecoveryError.integrityMismatch
        }
        return data
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
