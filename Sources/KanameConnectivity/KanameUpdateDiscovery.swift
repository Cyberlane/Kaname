import Foundation
import KanameDomain

public enum KanameUpdateDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case invalidCatalog
    case catalogTooLarge
    case incompatibleWorkspace
    case unsafeArtifactPath
    case artifactUnavailable
    case artifactDigestMismatch
    case notNewerThanPublished

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The local dogfood update catalog is invalid."
        case .catalogTooLarge: "The local dogfood update catalog exceeds its safety limit."
        case .incompatibleWorkspace: "The available update does not support this workspace schema."
        case .unsafeArtifactPath: "The local dogfood update points outside its private artifact directory."
        case .artifactUnavailable: "The local dogfood update artifact is unavailable."
        case .artifactDigestMismatch: "The local dogfood update changed after publication."
        case .notNewerThanPublished: "The local dogfood update is not newer than the published build."
        }
    }
}

public enum KanameUpdateDiscoveryStatus: String, Equatable, Sendable {
    case notChecked
    case checking
    case upToDate
    case available
    case deferred
    case skipped
    case verifying
    case staged
    case failed
    case rolledBack
}

public struct KanameAvailableUpdate: Equatable, Sendable {
    public let sourceIdentifier: String
    public let sourceLabel: String
    public let channel: KanameDesktopEnvironment.Channel
    public let version: String
    public let build: String
    public let bundleIdentifier: String
    public let publishedAtUnixMillis: Int64
    public let releaseNotes: String
    public let minimumWorkspaceSchema: Int
    public let maximumWorkspaceSchema: Int
    public let artifactURL: URL
    public let bundleDigest: String

    public var identity: String { "\(channel.rawValue):\(version):\(build):\(bundleDigest)" }
}

public protocol KanameUpdateCatalog: Sendable {
    func latestUpdate() async throws -> KanameAvailableUpdate?
    func verifiedArtifactURL(for update: KanameAvailableUpdate) async throws -> URL
}

struct KanameLocalDogfoodCatalogDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var channel: String
    var generatedAtUnixMillis: Int64
    var releases: [Release]

    struct Release: Codable, Equatable, Sendable {
        var version: String
        var build: String
        var bundleIdentifier: String
        var publishedAtUnixMillis: Int64
        var releaseNotes: String
        var minimumWorkspaceSchema: Int
        var maximumWorkspaceSchema: Int
        var artifactRelativePath: String
        var bundleDigest: String
    }
}

public actor KanameLocalDogfoodUpdateCatalog: KanameUpdateCatalog {
    public static let sourceIdentifier = "local-dogfood"
    public static let sourceLabel = "Local dogfood"
    static let maximumCatalogBytes = 256 * 1_024
    static let maximumReleaseNotesBytes = 20 * 1_024
    static let maximumReleases = 20

    private let environment: KanameDesktopEnvironment
    private let currentBundleURL: URL
    private let fileManager: FileManager

    public init(
        environment: KanameDesktopEnvironment = .current,
        currentBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.currentBundleURL = currentBundleURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func latestUpdate() throws -> KanameAvailableUpdate? {
        guard environment.channel == .stable else { return nil }
        guard fileManager.fileExists(atPath: environment.dogfoodUpdateCatalogURL.path) else { return nil }
        let document = try Self.readDocument(
            at: environment.dogfoodUpdateCatalogURL,
            dogfoodRoot: environment.dogfoodUpdateDirectory,
            fileManager: fileManager
        )
        guard let current = KanameBundleVersion(
            version: KanameUpdateCoordinator.bundleValue("CFBundleShortVersionString", at: currentBundleURL),
            build: KanameUpdateCoordinator.bundleValue("CFBundleVersion", at: currentBundleURL)
        ) else { throw KanameUpdateError.invalidVersionMetadata }

        let newer = try document.releases.compactMap { release -> (KanameBundleVersion, KanameLocalDogfoodCatalogDocument.Release)? in
            guard let version = KanameBundleVersion(version: release.version, build: release.build) else {
                throw KanameUpdateDiscoveryError.invalidCatalog
            }
            return version > current ? (version, release) : nil
        }.max { $0.0 < $1.0 }
        guard let release = newer?.1 else { return nil }
        guard (release.minimumWorkspaceSchema...release.maximumWorkspaceSchema)
            .contains(KanameDesktopStateSchema.currentVersion) else {
            throw KanameUpdateDiscoveryError.incompatibleWorkspace
        }
        let artifactURL = try Self.resolveArtifact(
            release.artifactRelativePath,
            dogfoodRoot: environment.dogfoodUpdateDirectory,
            requireExisting: true,
            fileManager: fileManager
        )
        return KanameAvailableUpdate(
            sourceIdentifier: Self.sourceIdentifier,
            sourceLabel: Self.sourceLabel,
            channel: .stable,
            version: release.version,
            build: release.build,
            bundleIdentifier: release.bundleIdentifier,
            publishedAtUnixMillis: release.publishedAtUnixMillis,
            releaseNotes: release.releaseNotes,
            minimumWorkspaceSchema: release.minimumWorkspaceSchema,
            maximumWorkspaceSchema: release.maximumWorkspaceSchema,
            artifactURL: artifactURL,
            bundleDigest: release.bundleDigest
        )
    }

    public func verifiedArtifactURL(for update: KanameAvailableUpdate) throws -> URL {
        guard update.sourceIdentifier == Self.sourceIdentifier,
              update.channel == .stable,
              update.bundleIdentifier == environment.bundleIdentifier else {
            throw KanameUpdateDiscoveryError.invalidCatalog
        }
        let resolved = try Self.resolveArtifact(
            String(update.artifactURL.path.dropFirst(environment.dogfoodUpdateDirectory.path.count + 1)),
            dogfoodRoot: environment.dogfoodUpdateDirectory,
            requireExisting: true,
            fileManager: fileManager
        )
        guard try KanameUpdateCoordinator.bundleDigest(at: resolved, fileManager: fileManager) == update.bundleDigest else {
            throw KanameUpdateDiscoveryError.artifactDigestMismatch
        }
        return resolved
    }

    static func readDocument(at url: URL, dogfoodRoot: URL, fileManager: FileManager) throws -> KanameLocalDogfoodCatalogDocument {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw KanameUpdateDiscoveryError.invalidCatalog
        }
        guard (values.fileSize ?? maximumCatalogBytes + 1) <= maximumCatalogBytes else {
            throw KanameUpdateDiscoveryError.catalogTooLarge
        }
        let document: KanameLocalDogfoodCatalogDocument
        do {
            document = try JSONDecoder().decode(KanameLocalDogfoodCatalogDocument.self, from: Data(contentsOf: url))
        } catch {
            throw KanameUpdateDiscoveryError.invalidCatalog
        }
        guard document.schemaVersion == 1,
              document.channel == KanameDesktopEnvironment.Channel.stable.rawValue,
              document.generatedAtUnixMillis >= 0,
              document.releases.count <= maximumReleases else {
            throw KanameUpdateDiscoveryError.invalidCatalog
        }
        var tuples = Set<String>()
        var identities = Set<String>()
        for release in document.releases {
            let tuple = "\(release.version):\(release.build)"
            let identity = "\(tuple):\(release.bundleDigest)"
            guard tuples.insert(tuple).inserted,
                  identities.insert(identity).inserted,
                  KanameBundleVersion(version: release.version, build: release.build) != nil,
                  release.bundleIdentifier == "com.cyberlane.kaname.desktop",
                  release.publishedAtUnixMillis >= 0,
                  !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  release.releaseNotes.lengthOfBytes(using: .utf8) <= maximumReleaseNotesBytes,
                  release.minimumWorkspaceSchema > 0,
                  release.maximumWorkspaceSchema >= release.minimumWorkspaceSchema,
                  Self.isDigest(release.bundleDigest) else {
                throw KanameUpdateDiscoveryError.invalidCatalog
            }
            _ = try resolveArtifact(
                release.artifactRelativePath,
                dogfoodRoot: dogfoodRoot,
                requireExisting: false,
                fileManager: fileManager
            )
        }
        return document
    }

    static func resolveArtifact(
        _ relativePath: String,
        dogfoodRoot: URL,
        requireExisting: Bool,
        fileManager: FileManager
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2,
              components.first == "Artifacts",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.hasPrefix("/"),
              relativePath.hasSuffix(".app") else {
            throw KanameUpdateDiscoveryError.unsafeArtifactPath
        }
        let root = dogfoodRoot.standardizedFileURL.resolvingSymlinksInPath()
        let artifact = dogfoodRoot.appending(path: relativePath, directoryHint: .isDirectory).standardizedFileURL
        let canonical = artifact.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(root.path + "/") else {
            throw KanameUpdateDiscoveryError.unsafeArtifactPath
        }
        if requireExisting {
            guard fileManager.fileExists(atPath: artifact.path) else {
                throw KanameUpdateDiscoveryError.artifactUnavailable
            }
            let values = try artifact.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, canonical == artifact.standardizedFileURL else {
                throw KanameUpdateDiscoveryError.unsafeArtifactPath
            }
        }
        return artifact
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || "abcdef".contains($0) }
    }
}

public struct KanameUpdateDiscoveryPreferences: Codable, Equatable, Sendable {
    public var automaticChecksEnabled: Bool
    public var lastAttemptAtUnixMillis: Int64?
    public var lastSuccessAtUnixMillis: Int64?
    public var deferredIdentity: String?
    public var deferredUntilUnixMillis: Int64?
    public var skippedIdentity: String?
    public var lastSourceIdentifier: String?

    public init(
        automaticChecksEnabled: Bool = true,
        lastAttemptAtUnixMillis: Int64? = nil,
        lastSuccessAtUnixMillis: Int64? = nil,
        deferredIdentity: String? = nil,
        deferredUntilUnixMillis: Int64? = nil,
        skippedIdentity: String? = nil,
        lastSourceIdentifier: String? = nil
    ) {
        self.automaticChecksEnabled = automaticChecksEnabled
        self.lastAttemptAtUnixMillis = lastAttemptAtUnixMillis
        self.lastSuccessAtUnixMillis = lastSuccessAtUnixMillis
        self.deferredIdentity = deferredIdentity
        self.deferredUntilUnixMillis = deferredUntilUnixMillis
        self.skippedIdentity = skippedIdentity
        self.lastSourceIdentifier = lastSourceIdentifier
    }
}

public actor KanameUpdateDiscoveryPreferencesStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(environment: KanameDesktopEnvironment = .current, fileManager: FileManager = .default) {
        fileURL = environment.dogfoodUpdatePreferencesURL
        self.fileManager = fileManager
    }

    public func load() -> KanameUpdateDiscoveryPreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(KanameUpdateDiscoveryPreferences.self, from: data) else {
            return KanameUpdateDiscoveryPreferences()
        }
        return value
    }

    public func save(_ value: KanameUpdateDiscoveryPreferences) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct KanameLocalDogfoodPublicationReceipt: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let bundleDigest: String
    public let catalogPath: String
}

public actor KanameLocalDogfoodUpdatePublisher {
    private let environment: KanameDesktopEnvironment
    private let installedBundleURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Int64

    public init(
        environment: KanameDesktopEnvironment = KanameDesktopEnvironment(channel: .stable),
        installedBundleURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.environment = environment
        self.installedBundleURL = installedBundleURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    public func publish(bundleURL: URL) async throws -> KanameLocalDogfoodPublicationReceipt {
        guard environment.channel == .stable else { throw KanameUpdateError.stableChannelRequired }
        let coordinator = KanameUpdateCoordinator(
            environment: environment,
            fileManager: .default,
            currentBundleURL: installedBundleURL,
            now: now
        )
        let validated = try await coordinator.validate(bundleURL: bundleURL)
        let root = environment.dogfoodUpdateDirectory
        let artifacts = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        let publishing = root.appending(path: "Publishing", directoryHint: .isDirectory)
        for directory in [root, artifacts, publishing] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        var releases: [KanameLocalDogfoodCatalogDocument.Release] = []
        if fileManager.fileExists(atPath: environment.dogfoodUpdateCatalogURL.path) {
            releases = try KanameLocalDogfoodUpdateCatalog.readDocument(
                at: environment.dogfoodUpdateCatalogURL,
                dogfoodRoot: root,
                fileManager: fileManager
            ).releases
        }
        let publishedVersions = releases.compactMap { KanameBundleVersion(version: $0.version, build: $0.build) }
        guard let candidateVersion = KanameBundleVersion(
            version: validated.manifest.version,
            build: validated.manifest.build
        ), publishedVersions.max().map({ candidateVersion > $0 }) ?? true else {
            throw KanameUpdateDiscoveryError.notNewerThanPublished
        }

        let artifactName = "Kaname-\(validated.manifest.version)-\(validated.manifest.build)-\(validated.bundleDigest.prefix(12)).app"
        let relativePath = "Artifacts/\(artifactName)"
        let finalURL = artifacts.appending(path: artifactName, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw KanameUpdateDiscoveryError.notNewerThanPublished
        }
        let transaction = publishing.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        let copied = transaction.appending(path: "Kaname.app", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: transaction,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        defer { try? fileManager.removeItem(at: transaction) }
        try fileManager.copyItem(at: validated.bundleURL, to: copied)
        guard try KanameUpdateCoordinator.bundleDigest(at: copied, fileManager: fileManager) == validated.bundleDigest else {
            throw KanameUpdateDiscoveryError.artifactDigestMismatch
        }
        try fileManager.moveItem(at: copied, to: finalURL)

        releases.append(KanameLocalDogfoodCatalogDocument.Release(
            version: validated.manifest.version,
            build: validated.manifest.build,
            bundleIdentifier: validated.manifest.bundleIdentifier,
            publishedAtUnixMillis: now(),
            releaseNotes: validated.manifest.releaseNotes,
            minimumWorkspaceSchema: validated.manifest.minimumWorkspaceSchema,
            maximumWorkspaceSchema: validated.manifest.maximumWorkspaceSchema,
            artifactRelativePath: relativePath,
            bundleDigest: validated.bundleDigest
        ))
        releases.sort {
            KanameBundleVersion(version: $0.version, build: $0.build)! > KanameBundleVersion(version: $1.version, build: $1.build)!
        }
        if releases.count > KanameLocalDogfoodUpdateCatalog.maximumReleases {
            releases.removeLast(releases.count - KanameLocalDogfoodUpdateCatalog.maximumReleases)
        }
        let document = KanameLocalDogfoodCatalogDocument(
            schemaVersion: 1,
            channel: KanameDesktopEnvironment.Channel.stable.rawValue,
            generatedAtUnixMillis: now(),
            releases: releases
        )
        let temporaryCatalog = root.appending(path: "catalog.\(UUID().uuidString.lowercased()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: temporaryCatalog, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryCatalog.path)
        _ = try KanameLocalDogfoodUpdateCatalog.readDocument(at: temporaryCatalog, dogfoodRoot: root, fileManager: fileManager)
        if fileManager.fileExists(atPath: environment.dogfoodUpdateCatalogURL.path) {
            _ = try fileManager.replaceItemAt(
                environment.dogfoodUpdateCatalogURL,
                withItemAt: temporaryCatalog,
                backupItemName: "catalog.previous.json",
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryCatalog, to: environment.dogfoodUpdateCatalogURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environment.dogfoodUpdateCatalogURL.path)
        return KanameLocalDogfoodPublicationReceipt(
            version: validated.manifest.version,
            build: validated.manifest.build,
            bundleDigest: validated.bundleDigest,
            catalogPath: "Dogfood/catalog.json"
        )
    }
}
