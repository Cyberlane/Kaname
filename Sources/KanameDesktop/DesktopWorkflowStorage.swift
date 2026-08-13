import CryptoKit
import Foundation
#if os(macOS)
import Darwin
#endif

public enum DesktopWorkflowStorageError: Error, Equatable, LocalizedError, Sendable {
    case invalidWorkflowID
    case invalidKey
    case invalidValue
    case quotaExceeded
    case unsafeStorage
    case artifactUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidWorkflowID: "The workflow storage identity is invalid."
        case .invalidKey: "The workflow storage key is invalid."
        case .invalidValue: "The workflow storage value is missing, oversized, or not valid JSON."
        case .quotaExceeded: "The workflow has reached its private storage quota."
        case .unsafeStorage: "Kaname refused an unsafe workflow storage path."
        case .artifactUnavailable: "The workflow artifact is unavailable or no longer matches its digest."
        }
    }
}

public struct DesktopWorkflowStoredArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sha256 }
    public let sha256: String
    public let filename: String
    public let mediaType: String
    public let byteCount: Int
    public let createdAtUnixMillis: Int64
}

public struct DesktopWorkflowStorage: Sendable {
    public static let maximumValueBytes = 1 * 1_024 * 1_024
    public static let maximumValuesBytes = 16 * 1_024 * 1_024
    public static let maximumArtifactBytes = 128 * 1_024 * 1_024
    public static let defaultMaximumArtifactsBytes = 256 * 1_024 * 1_024

    private struct ValuesFile: Codable {
        var values: [String: Data]
    }

    public let installationRoot: URL
    public let maximumArtifactsBytes: Int

    public init(
        installationRoot: URL,
        maximumArtifactsBytes: Int = DesktopWorkflowStorage.defaultMaximumArtifactsBytes
    ) {
        self.installationRoot = installationRoot.standardizedFileURL
        self.maximumArtifactsBytes = max(1, maximumArtifactsBytes)
    }

    public func value(forKey key: String) throws -> Data? {
        try validateKey(key)
        return try loadValues().values[key]
    }

    public func setValue(_ value: Data?, forKey key: String) throws {
        try validateKey(key)
        if let value {
            guard !value.isEmpty, value.count <= Self.maximumValueBytes,
                  (try? JSONSerialization.jsonObject(with: value)) != nil else {
                throw DesktopWorkflowStorageError.invalidValue
            }
        }
        var file = try loadValues()
        file.values[key] = value
        guard file.values.values.reduce(0, { $0 + $1.count }) <= Self.maximumValuesBytes else {
            throw DesktopWorkflowStorageError.quotaExceeded
        }
        try writePrivate(try canonicalEncoder().encode(file), to: valuesURL())
    }

    public func keys() throws -> [String] {
        try loadValues().values.keys.sorted()
    }

    @discardableResult
    public func importArtifact(
        data: Data,
        filename: String,
        mediaType: String,
        createdAtUnixMillis: Int64
    ) throws -> DesktopWorkflowStoredArtifact {
        let safeFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMediaType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty, data.count <= Self.maximumArtifactBytes,
              !safeFilename.isEmpty, safeFilename.utf8.count <= 512,
              !safeFilename.contains("/"), !safeFilename.contains("\\"),
              !safeFilename.contains("\r"), !safeFilename.contains("\n"),
              safeMediaType.range(
                of: #"^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { throw DesktopWorkflowStorageError.artifactUnavailable }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let record = DesktopWorkflowStoredArtifact(
            sha256: digest,
            filename: safeFilename,
            mediaType: safeMediaType,
            byteCount: data.count,
            createdAtUnixMillis: createdAtUnixMillis
        )
        let existingRecords = try artifactRecords()
        if !existingRecords.contains(where: { $0.sha256 == digest }),
           existingRecords.reduce(0, { $0 + $1.byteCount }) + data.count > maximumArtifactsBytes {
            throw DesktopWorkflowStorageError.quotaExceeded
        }
        let artifacts = try privateDirectory(artifactsDirectory())
        let destination = artifacts.appendingPathComponent(digest).standardizedFileURL
        guard destination.deletingLastPathComponent() == artifacts else { throw DesktopWorkflowStorageError.unsafeStorage }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try requiredData(at: destination, maximumBytes: Self.maximumArtifactBytes) == data else {
                throw DesktopWorkflowStorageError.artifactUnavailable
            }
        } else {
            try writePrivate(data, to: destination)
        }
        var records = existingRecords
        if !records.contains(where: { $0.sha256 == digest }) {
            records.append(record)
            try writePrivate(try canonicalEncoder().encode(records.sorted { $0.sha256 < $1.sha256 }), to: artifactManifestURL())
        }
        return record
    }

    public func artifactRecords() throws -> [DesktopWorkflowStoredArtifact] {
        let url = artifactManifestURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try requiredData(at: url, maximumBytes: 4 * 1_024 * 1_024)
        let records = try JSONDecoder().decode([DesktopWorkflowStoredArtifact].self, from: data)
        guard Set(records.map(\.sha256)).count == records.count,
              records.allSatisfy({
                  $0.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
                      && $0.byteCount > 0 && $0.byteCount <= Self.maximumArtifactBytes
              }) else { throw DesktopWorkflowStorageError.artifactUnavailable }
        return records.sorted { ($0.createdAtUnixMillis, $0.sha256) < ($1.createdAtUnixMillis, $1.sha256) }
    }

    public func artifactUsageBytes() throws -> Int {
        try artifactRecords().reduce(0) { $0 + $1.byteCount }
    }

    /// Removes an exact digest set through a private staging directory. The
    /// manifest changes only after every source file has been verified and
    /// moved, and a failed manifest write restores the canonical files.
    @discardableResult
    public func removeArtifacts(sha256s: Set<String>) throws -> [DesktopWorkflowStoredArtifact] {
        guard !sha256s.isEmpty,
              sha256s.allSatisfy({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
            return []
        }
        let records = try artifactRecords()
        let removing = records.filter { sha256s.contains($0.sha256) }
        guard Set(removing.map(\.sha256)) == sha256s else { throw DesktopWorkflowStorageError.artifactUnavailable }
        for record in removing { _ = try artifactData(sha256: record.sha256) }
        let artifacts = try privateDirectory(artifactsDirectory())
        let staging = try privateDirectory(
            installationRoot.appendingPathComponent("PurgeStaging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        )
        var moved: [(source: URL, staged: URL)] = []
        do {
            for record in removing {
                let source = artifacts.appendingPathComponent(record.sha256).standardizedFileURL
                let staged = staging.appendingPathComponent(record.sha256).standardizedFileURL
                guard source.deletingLastPathComponent() == artifacts,
                      staged.deletingLastPathComponent() == staging else {
                    throw DesktopWorkflowStorageError.unsafeStorage
                }
                try FileManager.default.moveItem(at: source, to: staged)
                moved.append((source, staged))
            }
            let retained = records.filter { !sha256s.contains($0.sha256) }
            try writePrivate(
                try canonicalEncoder().encode(retained.sorted { $0.sha256 < $1.sha256 }),
                to: artifactManifestURL()
            )
        } catch {
            for pair in moved.reversed() where FileManager.default.fileExists(atPath: pair.staged.path) {
                try? FileManager.default.moveItem(at: pair.staged, to: pair.source)
            }
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        let presentation = installationRoot.appendingPathComponent("Presentation", isDirectory: true).standardizedFileURL
        for record in removing {
            let copyDirectory = presentation.appendingPathComponent(record.sha256, isDirectory: true).standardizedFileURL
            if copyDirectory.deletingLastPathComponent() == presentation {
                try? FileManager.default.removeItem(at: copyDirectory)
            }
        }
        // The manifest is already committed and the canonical files are gone.
        // A leftover private staging directory is harmless and can be cleaned by
        // maintenance; it must not turn a completed purge into an unknown result.
        try? FileManager.default.removeItem(at: staging)
        return removing.sorted { $0.sha256 < $1.sha256 }
    }

    public func artifactData(sha256: String) throws -> Data {
        guard sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let record = try artifactRecords().first(where: { $0.sha256 == sha256 }) else {
            throw DesktopWorkflowStorageError.artifactUnavailable
        }
        let url = artifactsDirectory().appendingPathComponent(sha256).standardizedFileURL
        guard url.deletingLastPathComponent() == artifactsDirectory().standardizedFileURL else {
            throw DesktopWorkflowStorageError.unsafeStorage
        }
        let data = try requiredData(at: url, maximumBytes: Self.maximumArtifactBytes)
        guard data.count == record.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw DesktopWorkflowStorageError.artifactUnavailable
        }
        return data
    }

    public func artifactURL(sha256: String) throws -> URL {
        _ = try artifactData(sha256: sha256)
        let url = artifactsDirectory().appendingPathComponent(sha256).standardizedFileURL
        guard url.deletingLastPathComponent() == artifactsDirectory().standardizedFileURL else {
            throw DesktopWorkflowStorageError.unsafeStorage
        }
        return url
    }

    /// Returns a private, filename-preserving copy for system presentation.
    /// The canonical content-addressed artifact remains immutable.
    public func artifactPresentationURL(sha256: String, filename: String) throws -> URL {
        let data = try artifactData(sha256: sha256)
        let safeFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeFilename.isEmpty, safeFilename.utf8.count <= 512,
              !safeFilename.contains("/"), !safeFilename.contains("\\"),
              !safeFilename.contains("\r"), !safeFilename.contains("\n") else {
            throw DesktopWorkflowStorageError.artifactUnavailable
        }
        let directory = try privateDirectory(
            installationRoot.appendingPathComponent("Presentation", isDirectory: true)
                .appendingPathComponent(sha256, isDirectory: true)
        )
        let url = directory.appendingPathComponent(safeFilename).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else { throw DesktopWorkflowStorageError.unsafeStorage }
        if FileManager.default.fileExists(atPath: url.path) {
            guard try requiredData(at: url, maximumBytes: Self.maximumArtifactBytes) == data else {
                throw DesktopWorkflowStorageError.artifactUnavailable
            }
        } else {
            try writePrivate(data, to: url)
        }
        return url
    }

    private func validateKey(_ key: String) throws {
        guard key.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw DesktopWorkflowStorageError.invalidKey
        }
    }

    private func loadValues() throws -> ValuesFile {
        let url = valuesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return ValuesFile(values: [:]) }
        let data = try requiredData(at: url, maximumBytes: Self.maximumValuesBytes * 2)
        let file = try JSONDecoder().decode(ValuesFile.self, from: data)
        guard file.values.keys.allSatisfy({
            $0.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
        }), file.values.values.allSatisfy({
            !$0.isEmpty && $0.count <= Self.maximumValueBytes && (try? JSONSerialization.jsonObject(with: $0)) != nil
        }), file.values.values.reduce(0, { $0 + $1.count }) <= Self.maximumValuesBytes else {
            throw DesktopWorkflowStorageError.invalidValue
        }
        return file
    }

    private func stateDirectory() -> URL {
        installationRoot.appendingPathComponent("State", isDirectory: true).standardizedFileURL
    }

    private func artifactsDirectory() -> URL {
        installationRoot.appendingPathComponent("Artifacts", isDirectory: true).standardizedFileURL
    }

    private func valuesURL() -> URL {
        stateDirectory().appendingPathComponent("values.json").standardizedFileURL
    }

    private func artifactManifestURL() -> URL {
        stateDirectory().appendingPathComponent("artifacts.json").standardizedFileURL
    }

    private func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    @discardableResult
    private func privateDirectory(_ url: URL) throws -> URL {
        let rootPath = installationRoot.path + "/"
        guard url.path == installationRoot.path || url.path.hasPrefix(rootPath) else {
            throw DesktopWorkflowStorageError.unsafeStorage
        }
        try DesktopWorkflowFilesystem.preparePrivateDirectory(url, failure: DesktopWorkflowStorageError.unsafeStorage)
        return url
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        _ = try privateDirectory(url.deletingLastPathComponent())
        try DesktopWorkflowFilesystem.writePrivate(data, to: url, failure: DesktopWorkflowStorageError.unsafeStorage)
    }

    private func requiredData(at url: URL, maximumBytes: Int) throws -> Data {
        try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: url,
            maximumBytes: maximumBytes,
            mapped: true,
            failure: DesktopWorkflowStorageError.unsafeStorage
        )
    }
}

public extension DesktopAppModel {
    func workflowStorage(workflowID: String) -> DesktopWorkflowStorage? {
        let quotas = workflowInstallations(workflowID: workflowID).compactMap { installation in
            snapshot.operations.workflows.retentionPolicyRevisions.first {
                $0.id == installation.currentRetentionPolicyRevisionID
            }?.policy.localByteQuota
        }
        // Storage is namespaced by reusable workflow identity, so multiple local
        // installations share the same artifact pool. Honor the narrowest
        // reviewed quota rather than allowing one installation to widen another.
        let quota = quotas.min() ?? DesktopWorkflowStorage.defaultMaximumArtifactsBytes
        return workflowInstallationStorageURL(workflowID: workflowID).map {
            DesktopWorkflowStorage(installationRoot: $0, maximumArtifactsBytes: quota)
        }
    }
}
