import CryptoKit
import Foundation
import KanameDomain

public enum KanameUpdateStatus: String, Codable, Equatable, Sendable {
    case idle
    case staged
    case switching
    case healthy
    case rolledBack
    case failed
}

public struct KanameUpdateReceipt: Codable, Equatable, Sendable {
    public var status: KanameUpdateStatus
    public var version: String?
    public var build: String?
    public var bundleDigest: String?
    public var signerDigest: String?
    public var rollbackBundleDigest: String?
    public var rollbackSignerDigest: String?
    public var rollbackVersion: String?
    public var rollbackBuild: String?
    public var releaseNotes: String?
    public var detail: String
    public var updatedAtUnixMillis: Int64

    public init(
        status: KanameUpdateStatus,
        version: String? = nil,
        build: String? = nil,
        bundleDigest: String? = nil,
        signerDigest: String? = nil,
        rollbackBundleDigest: String? = nil,
        rollbackSignerDigest: String? = nil,
        rollbackVersion: String? = nil,
        rollbackBuild: String? = nil,
        releaseNotes: String? = nil,
        detail: String,
        updatedAtUnixMillis: Int64
    ) {
        (self.status, self.version, self.build) = (status, version, build)
        (self.bundleDigest, self.signerDigest) = (bundleDigest, signerDigest)
        (self.rollbackBundleDigest, self.rollbackSignerDigest) = (rollbackBundleDigest, rollbackSignerDigest)
        (self.rollbackVersion, self.rollbackBuild) = (rollbackVersion, rollbackBuild)
        self.releaseNotes = releaseNotes
        (self.detail, self.updatedAtUnixMillis) = (detail, updatedAtUnixMillis)
    }
}

public struct KanameUpdateManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var channel: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var minimumWorkspaceSchema: Int
    public var maximumWorkspaceSchema: Int
    public var releaseNotes: String
}

public struct KanameUpdateLaunchRequest: Equatable, Sendable {
    public let helperURL: URL
    public let arguments: [String]
}

public enum KanameUpdateError: Error, Equatable, LocalizedError, Sendable {
    case stableChannelRequired
    case invalidBundle
    case invalidSignature
    case signerMismatch
    case identifierMismatch
    case invalidVersionMetadata
    case downgradeRejected
    case stagedBundleChanged
    case invalidManifest
    case notarizationRequired
    case noStagedUpdate
    case activeApproval
    case unsavedComposer
    case helperUnavailable

    public var errorDescription: String? {
        switch self {
        case .stableChannelRequired: "Updates can be staged only from stable Kaname."
        case .invalidBundle: "Choose a complete Kaname application bundle."
        case .invalidSignature: "The selected Kaname bundle did not pass strict signature verification."
        case .signerMismatch: "The selected bundle was not signed by the same identity as this installed Kaname."
        case .identifierMismatch: "The selected bundle is not a stable Kaname update. Development candidates stay separate."
        case .invalidVersionMetadata: "The selected bundle has invalid version or build metadata."
        case .downgradeRejected: "Kaname will not replace this installation with the same or an older build."
        case .stagedBundleChanged: "The staged update changed after verification. Choose and verify it again."
        case .invalidManifest: "The selected update does not contain a valid signed stable-channel manifest."
        case .notarizationRequired: "The selected update did not pass the required Apple notarization and Gatekeeper checks."
        case .noStagedUpdate: "No verified update is ready to switch to."
        case .activeApproval: "Resolve or dismiss the active approval before switching Kaname."
        case .unsavedComposer: "Wait for the current composer draft to finish saving before switching Kaname."
        case .helperUnavailable: "The signed update helper is unavailable in this build."
        }
    }
}

public actor KanameUpdateCoordinator {
    public let environment: KanameDesktopEnvironment
    private let fileManager: FileManager
    private let now: @Sendable () -> Int64
    private let currentBundleURL: URL

    public init(
        environment: KanameDesktopEnvironment = .current,
        fileManager: FileManager = .default,
        currentBundleURL: URL = Bundle.main.bundleURL,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.currentBundleURL = currentBundleURL.standardizedFileURL
        self.now = now
    }

    public var receiptURL: URL { environment.updateDirectory.appending(path: "receipt.json") }
    public var stagedBundleURL: URL { environment.updateDirectory.appending(path: "Staged/Kaname.app", directoryHint: .isDirectory) }
    public var backupBundleURL: URL { environment.updateDirectory.appending(path: "Previous/Kaname.app", directoryHint: .isDirectory) }

    public func receipt() -> KanameUpdateReceipt {
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(KanameUpdateReceipt.self, from: data) else {
            return KanameUpdateReceipt(status: .idle, detail: "No update is staged.", updatedAtUnixMillis: now())
        }
        return receipt
    }

    public func stage(bundleURL: URL) async throws -> KanameUpdateReceipt {
        guard environment.channel == .stable else { throw KanameUpdateError.stableChannelRequired }
        let source = bundleURL.standardizedFileURL
        try Self.validateDistinctBundlePaths(
            [source, currentBundleURL, stagedBundleURL, backupBundleURL],
            fileManager: fileManager
        )
        guard source.pathExtension == "app",
              fileManager.fileExists(atPath: source.appending(path: "Contents/Info.plist").path) else {
            throw KanameUpdateError.invalidBundle
        }
        guard Self.bundleValue("CFBundleIdentifier", at: source) == environment.bundleIdentifier else {
            throw KanameUpdateError.identifierMismatch
        }
        let manifest = try Self.updateManifest(at: source)
        guard manifest.schemaVersion == 1,
              manifest.channel == KanameDesktopEnvironment.Channel.stable.rawValue,
              manifest.bundleIdentifier == environment.bundleIdentifier,
              manifest.version == Self.bundleValue("CFBundleShortVersionString", at: source),
              manifest.build == Self.bundleValue("CFBundleVersion", at: source),
              manifest.minimumWorkspaceSchema > 0,
              manifest.maximumWorkspaceSchema >= manifest.minimumWorkspaceSchema,
              !manifest.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KanameUpdateError.invalidManifest
        }
        try Self.validateWorkspaceCompatibility(manifest)
        let candidateIdentity = try await verifiedIdentity(at: source)
        let installedIdentity = try await verifiedIdentity(at: currentBundleURL)
        guard candidateIdentity == installedIdentity else { throw KanameUpdateError.signerMismatch }
        if Self.notarizationRequired(at: currentBundleURL) {
            guard Self.isDeveloperIDRequirement(candidateIdentity) else { throw KanameUpdateError.signerMismatch }
            try await verifyNotarization(at: source)
        }
        try Self.validateForwardUpdate(currentBundleURL: currentBundleURL, candidateBundleURL: source)
        let sourceDigest = try Self.bundleDigest(at: source, fileManager: fileManager)

        try preparePrivateDirectory(environment.updateDirectory)
        let stagedParent = stagedBundleURL.deletingLastPathComponent()
        try preparePrivateDirectory(stagedParent)
        if fileManager.fileExists(atPath: stagedBundleURL.path) {
            try fileManager.removeItem(at: stagedBundleURL)
        }
        try fileManager.copyItem(at: source, to: stagedBundleURL)
        let stagedDigest = try Self.bundleDigest(at: stagedBundleURL, fileManager: fileManager)
        guard stagedDigest == sourceDigest else { throw KanameUpdateError.stagedBundleChanged }
        let receipt = KanameUpdateReceipt(
            status: .staged,
            version: Self.bundleValue("CFBundleShortVersionString", at: stagedBundleURL),
            build: Self.bundleValue("CFBundleVersion", at: stagedBundleURL),
            bundleDigest: stagedDigest,
            signerDigest: Self.sha256(candidateIdentity),
            releaseNotes: manifest.releaseNotes,
            detail: "Update ready. Kaname will checkpoint local UI state before switching.",
            updatedAtUnixMillis: now()
        )
        try save(receipt)
        return receipt
    }

    public func switchRequest(
        installedBundleURL: URL,
        processIdentifier: Int32,
        composerCheckpointed: Bool,
        hasActiveApproval: Bool
    ) async throws -> KanameUpdateLaunchRequest {
        guard composerCheckpointed else { throw KanameUpdateError.unsavedComposer }
        guard !hasActiveApproval else { throw KanameUpdateError.activeApproval }
        guard fileManager.fileExists(atPath: stagedBundleURL.path) else { throw KanameUpdateError.noStagedUpdate }
        guard Self.canonicalPath(installedBundleURL) == Self.canonicalPath(currentBundleURL) else {
            throw KanameUpdateError.invalidBundle
        }
        try Self.validateManagedUpdatePaths(
            installed: installedBundleURL,
            staged: stagedBundleURL,
            backup: backupBundleURL,
            updateRoot: environment.updateDirectory,
            fileManager: fileManager
        )
        let receipt = receipt()
        guard let expectedDigest = receipt.bundleDigest,
              expectedDigest == (try Self.bundleDigest(at: stagedBundleURL, fileManager: fileManager)) else {
            throw KanameUpdateError.stagedBundleChanged
        }
        let installedIdentity = try await verifiedIdentity(at: installedBundleURL)
        let stagedIdentity = try await verifiedIdentity(at: stagedBundleURL)
        guard installedIdentity == stagedIdentity,
              receipt.signerDigest == Self.sha256(stagedIdentity) else {
            throw KanameUpdateError.signerMismatch
        }
        let manifest = try Self.updateManifest(at: stagedBundleURL)
        guard manifest.version == receipt.version,
              manifest.build == receipt.build,
              manifest.releaseNotes == receipt.releaseNotes else {
            throw KanameUpdateError.invalidManifest
        }
        try Self.validateWorkspaceCompatibility(manifest)
        if Self.notarizationRequired(at: installedBundleURL) {
            guard Self.isDeveloperIDRequirement(stagedIdentity) else { throw KanameUpdateError.signerMismatch }
            try await verifyNotarization(at: stagedBundleURL)
        }
        try Self.validateForwardUpdate(currentBundleURL: installedBundleURL, candidateBundleURL: stagedBundleURL)
        let rollbackDigest = try Self.bundleDigest(at: installedBundleURL, fileManager: fileManager)
        let rollbackSignerDigest = Self.sha256(installedIdentity)
        guard let rollbackVersion = Self.bundleValue("CFBundleShortVersionString", at: installedBundleURL),
              let rollbackBuild = Self.bundleValue("CFBundleVersion", at: installedBundleURL) else {
            throw KanameUpdateError.invalidVersionMetadata
        }
        guard let helperURL = Bundle.main.url(forResource: "KanameUpdateHelper", withExtension: nil),
              fileManager.isExecutableFile(atPath: helperURL.path) else { throw KanameUpdateError.helperUnavailable }
        try save(KanameUpdateReceipt(
            status: .switching,
            version: receipt.version,
            build: receipt.build,
            bundleDigest: receipt.bundleDigest,
            signerDigest: receipt.signerDigest,
            rollbackBundleDigest: rollbackDigest,
            rollbackSignerDigest: rollbackSignerDigest,
            rollbackVersion: rollbackVersion,
            rollbackBuild: rollbackBuild,
            releaseNotes: receipt.releaseNotes,
            detail: "Switching after an explicit UI checkpoint.",
            updatedAtUnixMillis: now()
        ))
        let healthNonce = UUID().uuidString.lowercased()
        return KanameUpdateLaunchRequest(
            helperURL: helperURL,
            arguments: [
                "--switch",
                "--installed", installedBundleURL.standardizedFileURL.path,
                "--staged", stagedBundleURL.path,
                "--backup", backupBundleURL.path,
                "--health", environment.healthHandshakeURL.path,
                "--receipt", receiptURL.path,
                "--pid", String(processIdentifier),
                "--version", receipt.version ?? "",
                "--build", receipt.build ?? "",
                "--bundle-digest", receipt.bundleDigest ?? "",
                "--signer-digest", receipt.signerDigest ?? "",
                "--health-nonce", healthNonce,
                "--channel", environment.channel.rawValue,
                "--workspace-schema", String(KanameDesktopStateSchema.currentVersion),
                "--rollback-version", rollbackVersion,
                "--rollback-build", rollbackBuild,
                "--rollback-bundle-digest", rollbackDigest,
                "--rollback-signer-digest", rollbackSignerDigest,
                "--timeout", "12",
            ]
        )
    }

    public func rollbackRequest(
        installedBundleURL: URL,
        processIdentifier: Int32,
        composerCheckpointed: Bool,
        hasActiveApproval: Bool
    ) async throws -> KanameUpdateLaunchRequest {
        guard composerCheckpointed else { throw KanameUpdateError.unsavedComposer }
        guard !hasActiveApproval else { throw KanameUpdateError.activeApproval }
        guard fileManager.fileExists(atPath: backupBundleURL.path) else { throw KanameUpdateError.noStagedUpdate }
        guard Self.canonicalPath(installedBundleURL) == Self.canonicalPath(currentBundleURL) else {
            throw KanameUpdateError.invalidBundle
        }
        try Self.validateManagedUpdatePaths(
            installed: installedBundleURL,
            staged: nil,
            backup: backupBundleURL,
            updateRoot: environment.updateDirectory,
            fileManager: fileManager
        )
        let receipt = receipt()
        guard let currentDigest = receipt.bundleDigest,
              let currentSignerDigest = receipt.signerDigest,
              let currentVersion = receipt.version,
              let currentBuild = receipt.build,
              currentDigest == (try Self.bundleDigest(at: installedBundleURL, fileManager: fileManager)),
              currentSignerDigest == Self.sha256(try await verifiedIdentity(at: installedBundleURL)),
              let rollbackDigest = receipt.rollbackBundleDigest,
              let rollbackSignerDigest = receipt.rollbackSignerDigest,
              let rollbackVersion = receipt.rollbackVersion,
              let rollbackBuild = receipt.rollbackBuild,
              rollbackDigest == (try Self.bundleDigest(at: backupBundleURL, fileManager: fileManager)),
              rollbackSignerDigest == Self.sha256(try await verifiedIdentity(at: backupBundleURL)) else {
            throw KanameUpdateError.stagedBundleChanged
        }
        guard let helperURL = Bundle.main.url(forResource: "KanameUpdateHelper", withExtension: nil),
              fileManager.isExecutableFile(atPath: helperURL.path) else { throw KanameUpdateError.helperUnavailable }
        return KanameUpdateLaunchRequest(
            helperURL: helperURL,
            arguments: [
                "--rollback",
                "--installed", installedBundleURL.standardizedFileURL.path,
                "--backup", backupBundleURL.path,
                "--health", environment.healthHandshakeURL.path,
                "--receipt", receiptURL.path,
                "--pid", String(processIdentifier),
                "--version", currentVersion,
                "--build", currentBuild,
                "--bundle-digest", currentDigest,
                "--signer-digest", currentSignerDigest,
                "--rollback-version", rollbackVersion,
                "--rollback-build", rollbackBuild,
                "--rollback-bundle-digest", rollbackDigest,
                "--rollback-signer-digest", rollbackSignerDigest,
                "--channel", environment.channel.rawValue,
                "--workspace-schema", String(KanameDesktopStateSchema.currentVersion),
                "--timeout", "12",
            ]
        )
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func save(_ receipt: KanameUpdateReceipt) throws {
        try preparePrivateDirectory(environment.updateDirectory)
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }

    private static func bundleValue(_ key: String, at bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: key) as? String
    }

    private func verifiedIdentity(at bundleURL: URL) async throws -> String {
        let verification = try await LocalProcess.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundleURL.path],
            workingDirectory: bundleURL.deletingLastPathComponent(),
            timeout: .seconds(20)
        )
        guard verification.exitStatus == 0 else { throw KanameUpdateError.invalidSignature }
        let requirement = try await LocalProcess.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--display", "--requirements", "-", bundleURL.path],
            workingDirectory: bundleURL.deletingLastPathComponent(),
            timeout: .seconds(20)
        )
        guard requirement.exitStatus == 0,
              let identity = (requirement.standardOutput + requirement.standardError)
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.hasPrefix("designated =>") }) else {
            throw KanameUpdateError.invalidSignature
        }
        return identity
    }

    private func verifyNotarization(at bundleURL: URL) async throws {
        let assessment = try await LocalProcess.capture(
            executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=4", bundleURL.path],
            workingDirectory: bundleURL.deletingLastPathComponent(),
            timeout: .seconds(30)
        )
        guard assessment.exitStatus == 0 else { throw KanameUpdateError.notarizationRequired }
    }

    static func validateForwardUpdate(currentBundleURL: URL, candidateBundleURL: URL) throws {
        guard let current = KanameBundleVersion(
            version: bundleValue("CFBundleShortVersionString", at: currentBundleURL),
            build: bundleValue("CFBundleVersion", at: currentBundleURL)
        ), let candidate = KanameBundleVersion(
            version: bundleValue("CFBundleShortVersionString", at: candidateBundleURL),
            build: bundleValue("CFBundleVersion", at: candidateBundleURL)
        ) else {
            throw KanameUpdateError.invalidVersionMetadata
        }
        guard candidate > current else { throw KanameUpdateError.downgradeRejected }
    }

    static func bundleDigest(at bundleURL: URL, fileManager: FileManager = .default) throws -> String {
        let root = bundleURL.standardizedFileURL
        guard let enumerator = fileManager.enumerator(atPath: root.path) else {
            throw KanameUpdateError.invalidBundle
        }
        let entries = enumerator.compactMap { $0 as? String }
            .filter { !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }
            .sorted()
        var hash = SHA256()
        for relative in entries {
            let url = root.appending(path: relative)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                guard !destination.hasPrefix("/"), !destination.split(separator: "/").contains("..") else {
                    throw KanameUpdateError.invalidBundle
                }
                hash.update(data: Data("link\u{0}\(relative)\u{0}\(destination)\u{0}".utf8))
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                hash.update(data: Data("file\u{0}\(relative)\u{0}".utf8))
                hash.update(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func updateManifest(at bundleURL: URL) throws -> KanameUpdateManifest {
        let url = bundleURL.appending(path: "Contents/Resources/KanameUpdateManifest.json")
        guard let manifest = try? JSONDecoder().decode(KanameUpdateManifest.self, from: Data(contentsOf: url)) else {
            throw KanameUpdateError.invalidManifest
        }
        return manifest
    }

    static func validateWorkspaceCompatibility(_ manifest: KanameUpdateManifest) throws {
        guard manifest.minimumWorkspaceSchema > 0,
              manifest.maximumWorkspaceSchema >= manifest.minimumWorkspaceSchema,
              (manifest.minimumWorkspaceSchema...manifest.maximumWorkspaceSchema)
                .contains(KanameDesktopStateSchema.currentVersion) else {
            throw KanameUpdateError.invalidManifest
        }
    }

    static func validateDistinctBundlePaths(_ urls: [URL], fileManager: FileManager = .default) throws {
        let paths = urls.map(canonicalPath)
        guard Set(paths).count == paths.count else { throw KanameUpdateError.invalidBundle }
        for (index, path) in paths.enumerated() {
            for other in paths.dropFirst(index + 1) {
                guard !path.hasPrefix(other + "/"), !other.hasPrefix(path + "/") else {
                    throw KanameUpdateError.invalidBundle
                }
            }
        }
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw KanameUpdateError.invalidBundle }
        }
    }

    private static func validateManagedUpdatePaths(
        installed: URL,
        staged: URL?,
        backup: URL,
        updateRoot: URL,
        fileManager: FileManager
    ) throws {
        let managedRoot = canonicalPath(updateRoot)
        let managed = [staged, backup].compactMap { $0 }
        guard managed.allSatisfy({ canonicalPath($0).hasPrefix(managedRoot + "/") }),
              !canonicalPath(installed).hasPrefix(managedRoot + "/") else {
            throw KanameUpdateError.invalidBundle
        }
        try validateDistinctBundlePaths([installed] + managed, fileManager: fileManager)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func notarizationRequired(at bundleURL: URL) -> Bool {
        guard let bundle = Bundle(url: bundleURL),
              let required = bundle.object(forInfoDictionaryKey: "KanameReleaseNotarizationRequired") as? Bool else {
            return false
        }
        return required
    }

    private static func isDeveloperIDRequirement(_ requirement: String) -> Bool {
        requirement.contains("anchor apple generic") && requirement.contains("1.2.840.113635.100.6.1.13")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct KanameBundleVersion: Comparable, Sendable {
    let components: [Int]
    let build: Int

    init?(version: String?, build: String?) {
        guard let version, let build, let parsedBuild = Int(build), parsedBuild >= 0 else { return nil }
        let parsed = version.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !parsed.isEmpty,
              parsed.count == version.split(separator: ".", omittingEmptySubsequences: false).count,
              parsed.allSatisfy({ $0 >= 0 }) else { return nil }
        components = parsed
        self.build = parsedBuild
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }
}
