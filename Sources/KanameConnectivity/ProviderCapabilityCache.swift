import Foundation
import KanameDomain

public struct ProviderCapabilityCacheSnapshot: Codable, Equatable, Sendable {
    public let capabilities: [ProviderCapabilitySnapshot]
    public let checkedAt: Date

    public init(capabilities: [ProviderCapabilitySnapshot], checkedAt: Date) {
        self.capabilities = capabilities
        self.checkedAt = checkedAt
    }
}

public actor ProviderCapabilityCacheStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory
            ?? applicationSupport.appending(path: "Kaname/Connectivity", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    public func load() throws -> ProviderCapabilityCacheSnapshot? {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        return try JSONDecoder().decode(
            ProviderCapabilityCacheSnapshot.self,
            from: Data(contentsOf: cacheURL)
        )
    }

    public func save(_ snapshot: ProviderCapabilityCacheSnapshot) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    private var cacheURL: URL {
        directory.appending(path: "provider-capabilities.json")
    }
}
