import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum DesktopBackupDestination: String, Codable, CaseIterable, Equatable, Sendable {
    case localFolder
    case cloudflareR2
    case s3Compatible

    public var label: String {
        switch self {
        case .localFolder: "Local folder"
        case .cloudflareR2: "Cloudflare R2"
        case .s3Compatible: "S3-compatible storage"
        }
    }
}

public struct DesktopAutomaticBackupConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Self.currentSchemaVersion
    public var enabled = false
    public var destination = DesktopBackupDestination.localFolder
    public var localFolderPath = ""
    public var endpoint = ""
    public var bucket = ""
    public var region = "auto"
    public var prefix = "kaname-backups"
    public var frequencyHours = 24
    public var retentionDays = 30
    public var lastAttemptAtUnixMillis: Int64?
    public var lastSuccessAtUnixMillis: Int64?
    public var lastVerifiedAtUnixMillis: Int64?
    public var lastObjectKey: String?
    public var lastObjectByteCount: Int64?
    public var lastFailureSummary: String?
    public var verifiedDestinationDigest: String?

    public init() {}

    public func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
              (1...168).contains(frequencyHours),
              (7...365).contains(retentionDays),
              Self.validPrefix(prefix) else { throw DesktopAutomaticBackupError.invalidConfiguration }
        switch destination {
        case .localFolder:
            guard !localFolderPath.isEmpty, URL(fileURLWithPath: localFolderPath).path == localFolderPath else {
                throw DesktopAutomaticBackupError.invalidConfiguration
            }
        case .cloudflareR2, .s3Compatible:
            guard let endpointURL = URL(string: endpoint),
                  endpointURL.scheme == "https",
                  endpointURL.host != nil,
                  endpointURL.user == nil,
                  endpointURL.password == nil,
                  endpointURL.query == nil,
                  endpointURL.fragment == nil,
                  Self.validBucket(bucket),
                  Self.validRegion(region) else {
                throw DesktopAutomaticBackupError.invalidConfiguration
            }
        }
        return self
    }

    public var nextBackupAtUnixMillis: Int64? {
        guard enabled else { return nil }
        return (lastSuccessAtUnixMillis ?? 0) + Int64(frequencyHours) * 3_600_000
    }

    public var destinationDigest: String {
        let value = [
            destination.rawValue,
            localFolderPath,
            endpoint,
            bucket,
            region,
            prefix,
        ].joined(separator: "\u{0}")
        return DesktopRecoveryService.sha256(Data(value.utf8))
    }

    private static func validPrefix(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 240
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
            && !value.contains("..") && !value.hasPrefix("/") && !value.hasSuffix("/")
    }

    private static func validBucket(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }

    private static func validRegion(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }
}

public struct DesktopAutomaticBackupSecrets: Codable, Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var encryptionPassphrase: String

    public init(accessKeyID: String = "", secretAccessKey: String = "", encryptionPassphrase: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.encryptionPassphrase = encryptionPassphrase
    }
}

public enum DesktopAutomaticBackupError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case credentialsUnavailable
    case activeRuntimeWork
    case unsafeBundle
    case transportFailure(Int)
    case integrityMismatch
    case noRemoteBackup
    case destinationExists
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Complete and verify the selected backup destination before enabling automatic backups."
        case .credentialsUnavailable: "Backup credentials or the encryption passphrase are unavailable. Save them again."
        case .activeRuntimeWork: "Kaname waited because active workflow or provider work must finish before a coherent backup can be sealed."
        case .unsafeBundle: "The backup bundle contains an unsafe, oversized, or unexpected entry."
        case .transportFailure(let status): "The backup destination returned HTTP \(status)."
        case .integrityMismatch: "The uploaded or downloaded backup did not match its expected SHA-256 digest."
        case .noRemoteBackup: "No encrypted Kaname backup exists at this destination."
        case .destinationExists: "The selected restore destination already exists."
        case .keychainFailure(let status): "The backup credential could not be accessed securely (Keychain status \(status))."
        }
    }
}

public protocol DesktopAutomaticBackupSecretStoring: Sendable {
    func save(_ secrets: DesktopAutomaticBackupSecrets) throws
    func load() throws -> DesktopAutomaticBackupSecrets?
    func delete() throws
}

public struct KeychainDesktopAutomaticBackupSecretStore: DesktopAutomaticBackupSecretStoring, Sendable {
    private let service: String
    private let account = "automatic-backup"

    public init(service: String) {
        self.service = service
    }

    public func save(_ secrets: DesktopAutomaticBackupSecrets) throws {
        let data = try JSONEncoder().encode(secrets)
        let primary = try upsert(data, dataProtection: true)
        if primary == errSecMissingEntitlement {
            let fallback = try upsert(data, dataProtection: false)
            guard fallback == errSecSuccess else { throw DesktopAutomaticBackupError.keychainFailure(fallback) }
            return
        }
        guard primary == errSecSuccess else { throw DesktopAutomaticBackupError.keychainFailure(primary) }
    }

    public func load() throws -> DesktopAutomaticBackupSecrets? {
        let primary = read(dataProtection: true)
        let result: (OSStatus, Data?)
        if primary.0 == errSecMissingEntitlement || primary.0 == errSecItemNotFound {
            result = read(dataProtection: false)
        } else {
            result = primary
        }
        if result.0 == errSecItemNotFound { return nil }
        guard result.0 == errSecSuccess, let data = result.1 else {
            throw DesktopAutomaticBackupError.keychainFailure(result.0)
        }
        return try JSONDecoder().decode(DesktopAutomaticBackupSecrets.self, from: data)
    }

    public func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw DesktopAutomaticBackupError.keychainFailure(status)
            }
        }
    }

    private func upsert(_ data: Data, dataProtection: Bool) throws -> OSStatus {
        let lookup = query(dataProtection: dataProtection)
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return update }
        guard update == errSecItemNotFound else { return update }
        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    private func read(dataProtection: Bool) -> (OSStatus, Data?) {
        var lookup = query(dataProtection: dataProtection)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        return (status, result as? Data)
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        value[kSecUseAuthenticationContext as String] = context
        if dataProtection { value[kSecUseDataProtectionKeychain as String] = true }
        return value
    }
}

public struct FileDesktopAutomaticBackupConfigurationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> DesktopAutomaticBackupConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
        return try JSONDecoder().decode(DesktopAutomaticBackupConfiguration.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ configuration: DesktopAutomaticBackupConfiguration) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct DesktopBackupBundleFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let data: Data
}

public struct DesktopBackupBundlePayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = Self.currentSchemaVersion
    public let backupID: UUID
    public let createdAtUnixMillis: Int64
    public let files: [DesktopBackupBundleFile]

}

public struct DesktopEncryptedBackupArtifact: Equatable, Sendable {
    public let backupID: UUID
    public let createdAtUnixMillis: Int64
    public let data: Data
    public let sha256: String
}

public enum DesktopEncryptedBackupBundleCodec {
    public static func seal(bundleURL: URL, passphrase: String) throws -> DesktopEncryptedBackupArtifact {
        let manifest = try DesktopRecoveryService().validateBackup(at: bundleURL)
        let files = try regularFiles(below: bundleURL)
        guard files.count <= 4_100 else { throw DesktopAutomaticBackupError.unsafeBundle }
        var total = 0
        let entries = try files.map { url -> DesktopBackupBundleFile in
            let relative = String(url.standardizedFileURL.path.dropFirst(bundleURL.standardizedFileURL.path.count + 1))
            guard safeRelativePath(relative) else { throw DesktopAutomaticBackupError.unsafeBundle }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            total += data.count
            guard total <= DesktopEncryptedTransferCodec.maximumPlaintextBytes else {
                throw DesktopAutomaticBackupError.unsafeBundle
            }
            return DesktopBackupBundleFile(
                relativePath: relative,
                sha256: DesktopRecoveryService.sha256(data),
                data: data
            )
        }
        let payload = DesktopBackupBundlePayload(
            backupID: manifest.backupID,
            createdAtUnixMillis: manifest.createdAtUnixMillis,
            files: entries.sorted { $0.relativePath < $1.relativePath }
        )
        let data = try DesktopEncryptedTransferCodec.seal(payload, kind: "kaname-full-backup", passphrase: passphrase)
        return DesktopEncryptedBackupArtifact(
            backupID: manifest.backupID,
            createdAtUnixMillis: manifest.createdAtUnixMillis,
            data: data,
            sha256: DesktopRecoveryService.sha256(data)
        )
    }

    @discardableResult
    public static func open(_ data: Data, passphrase: String, destination: URL) throws -> DesktopBackupManifest {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DesktopAutomaticBackupError.destinationExists
        }
        let payload = try DesktopEncryptedTransferCodec.open(
            data,
            kind: "kaname-full-backup",
            passphrase: passphrase,
            as: DesktopBackupBundlePayload.self
        )
        guard payload.schemaVersion == DesktopBackupBundlePayload.currentSchemaVersion,
              !payload.files.isEmpty,
              payload.files.count <= 4_100 else { throw DesktopAutomaticBackupError.unsafeBundle }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var seen = Set<String>()
        for file in payload.files {
            guard safeRelativePath(file.relativePath), seen.insert(file.relativePath).inserted,
                  DesktopRecoveryService.sha256(file.data) == file.sha256 else {
                throw DesktopAutomaticBackupError.integrityMismatch
            }
            let target = partial.appendingPathComponent(file.relativePath)
            guard target.standardizedFileURL.path.hasPrefix(partial.standardizedFileURL.path + "/") else {
                throw DesktopAutomaticBackupError.unsafeBundle
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try file.data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        let decodedManifest = try DesktopRecoveryService().validateBackup(at: partial)
        guard decodedManifest.backupID == payload.backupID,
              decodedManifest.createdAtUnixMillis == payload.createdAtUnixMillis else {
            throw DesktopAutomaticBackupError.integrityMismatch
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return try DesktopRecoveryService().validateBackup(at: destination)
    }

    private static func regularFiles(below root: URL) throws -> [URL] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw DesktopAutomaticBackupError.unsafeBundle
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { throw DesktopAutomaticBackupError.unsafeBundle }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw DesktopAutomaticBackupError.unsafeBundle }
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.hasPrefix("/")
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

public struct DesktopBackupObject: Equatable, Sendable {
    public let key: String
    public let byteCount: Int64
    public let lastModified: Date?
    public let sha256: String?
}

public protocol DesktopBackupObjectTransport: Sendable {
    func testConnection(prefix: String) async throws
    func put(key: String, data: Data, sha256: String) async throws
    func get(key: String) async throws -> Data
    func list(prefix: String) async throws -> [DesktopBackupObject]
    func delete(key: String) async throws
}

public actor LocalFolderDesktopBackupTransport: DesktopBackupObjectTransport {
    private let root: URL

    public init(root: URL) { self.root = root }

    public func testConnection(prefix: String) async throws {
        try prepareRoot()
    }

    public func put(key: String, data: Data, sha256: String) async throws {
        try prepareRoot()
        let target = try safeURL(key: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireSafePathComponents(to: target.deletingLastPathComponent())
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        guard DesktopRecoveryService.sha256(try Data(contentsOf: target)) == sha256 else {
            throw DesktopAutomaticBackupError.integrityMismatch
        }
    }

    public func get(key: String) async throws -> Data {
        let target = try safeURL(key: key)
        try requireSafePathComponents(to: target.deletingLastPathComponent())
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DesktopAutomaticBackupError.unsafeBundle
        }
        return try Data(contentsOf: target)
    }

    public func list(prefix: String) async throws -> [DesktopBackupObject] {
        try prepareRoot()
        let prefixRoot = try safeURL(key: prefix)
        guard FileManager.default.fileExists(atPath: prefixRoot.path) else { return [] }
        try requireSafePathComponents(to: prefixRoot)
        return try enumerateObjects(below: prefixRoot)
    }

    private func enumerateObjects(below prefixRoot: URL) throws -> [DesktopBackupObject] {
        guard let enumerator = FileManager.default.enumerator(
            at: prefixRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        ) else { return [] }
        var objects: [DesktopBackupObject] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { throw DesktopAutomaticBackupError.unsafeBundle }
            guard values.isRegularFile == true else { continue }
            let key = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            objects.append(.init(key: key, byteCount: Int64(values.fileSize ?? 0), lastModified: values.contentModificationDate, sha256: nil))
        }
        return objects.sorted { $0.key < $1.key }
    }

    public func delete(key: String) async throws {
        let target = try safeURL(key: key)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try requireSafePathComponents(to: target.deletingLastPathComponent())
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DesktopAutomaticBackupError.unsafeBundle
        }
        try FileManager.default.removeItem(at: target)
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
    }

    private func safeURL(key: String) throws -> URL {
        guard !key.isEmpty, !key.hasPrefix("/"), !key.contains("..") else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
        let value = root.appendingPathComponent(key).standardizedFileURL
        guard value.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
        return value
    }

    private func requireSafePathComponents(to destination: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
        var cursor = root.standardizedFileURL
        let suffix = destinationPath.dropFirst(rootPath.count).split(separator: "/")
        for component in suffix {
            cursor.appendPathComponent(String(component), isDirectory: true)
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DesktopAutomaticBackupError.unsafeBundle
            }
        }
    }
}

private struct S3DesktopBackupConnection: Sendable {
    let endpoint: URL
    let bucket: String
    let region: String
    let accessKeyID: String
    let secretAccessKey: String
}

public struct S3DesktopBackupTransport: DesktopBackupObjectTransport, Sendable {
    private let connection: S3DesktopBackupConnection
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL,
        bucket: String,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        connection = S3DesktopBackupConnection(
            endpoint: endpoint,
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
        self.session = session
        self.now = now
    }

    public func testConnection(prefix: String) async throws {
        _ = try await list(prefix: prefix)
    }

    public func put(key: String, data: Data, sha256: String) async throws {
        var request = try signedRequest(method: "PUT", key: key, queryItems: [], body: data, metadataSHA256: sha256)
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        try requireSuccess(response)
        var head = try signedRequest(method: "HEAD", key: key, queryItems: [], body: Data(), metadataSHA256: nil)
        head.httpBody = nil
        let (_, headResponse) = try await session.data(for: head)
        try requireSuccess(headResponse)
        guard let http = headResponse as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "x-amz-meta-kaname-sha256") == sha256 else {
            throw DesktopAutomaticBackupError.integrityMismatch
        }
    }

    public func get(key: String) async throws -> Data {
        let request = try signedRequest(method: "GET", key: key, queryItems: [], body: Data(), metadataSHA256: nil)
        let (data, response) = try await session.data(for: request)
        try requireSuccess(response)
        guard let expected = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-amz-meta-kaname-sha256"),
              DesktopRecoveryService.sha256(data) == expected else {
            throw DesktopAutomaticBackupError.integrityMismatch
        }
        return data
    }

    public func list(prefix: String) async throws -> [DesktopBackupObject] {
        var objects: [DesktopBackupObject] = []
        var continuationToken: String?
        for _ in 0..<10_000 {
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix + "/"),
            ]
            if let continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }
            let request = try signedRequest(
                method: "GET",
                key: nil,
                queryItems: queryItems,
                body: Data(),
                metadataSHA256: nil
            )
            let (data, response) = try await session.data(for: request)
            try requireSuccess(response)
            let parser = S3ListObjectsParser(data: data)
            guard parser.parse() else { throw DesktopAutomaticBackupError.transportFailure(502) }
            objects.append(contentsOf: parser.objects)
            guard parser.isTruncated else { return objects }
            guard let next = parser.nextContinuationToken, next != continuationToken else {
                throw DesktopAutomaticBackupError.transportFailure(502)
            }
            continuationToken = next
        }
        throw DesktopAutomaticBackupError.transportFailure(502)
    }

    public func delete(key: String) async throws {
        let request = try signedRequest(method: "DELETE", key: key, queryItems: [], body: Data(), metadataSHA256: nil)
        let (_, response) = try await session.data(for: request)
        try requireSuccess(response)
    }

    func signedRequest(
        method: String,
        key: String?,
        queryItems: [URLQueryItem],
        body: Data,
        metadataSHA256: String?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: connection.endpoint, resolvingAgainstBaseURL: false) else {
            throw DesktopAutomaticBackupError.invalidConfiguration
        }
        let keyPath = key.map { "/" + $0.split(separator: "/").map(String.init).map(Self.encodePathComponent).joined(separator: "/") } ?? ""
        components.percentEncodedPath = connection.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).map(Self.encodePathComponent).joined(separator: "/")
        components.percentEncodedPath = "/" + [components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")), Self.encodePathComponent(connection.bucket)]
            .filter { !$0.isEmpty }.joined(separator: "/") + keyPath
        components.queryItems = queryItems.isEmpty
            ? nil
            : queryItems.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        guard let url = components.url else { throw DesktopAutomaticBackupError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let date = now()
        let payloadHash = DesktopRecoveryService.sha256(body)
        let timestamps = S3SignatureV4.timestamps(date)
        request.setValue(url.hostWithPort, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(timestamps.full, forHTTPHeaderField: "x-amz-date")
        if let metadataSHA256 { request.setValue(metadataSHA256, forHTTPHeaderField: "x-amz-meta-kaname-sha256") }
        let authorization = try S3SignatureV4.authorization(
            request: request,
            payloadHash: payloadHash,
            accessKeyID: connection.accessKeyID,
            secretAccessKey: connection.secretAccessKey,
            region: connection.region,
            timestamps: timestamps
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DesktopAutomaticBackupError.transportFailure(0) }
        guard (200..<300).contains(http.statusCode) else { throw DesktopAutomaticBackupError.transportFailure(http.statusCode) }
    }

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}

enum S3SignatureV4 {
    struct Timestamps: Sendable {
        let full: String
        let day: String
    }

    static func timestamps(_ date: Date) -> Timestamps {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        let day = String(format: "%04d%02d%02d", components.year!, components.month!, components.day!)
        let full = String(format: "%@T%02d%02d%02dZ", day, components.hour!, components.minute!, components.second!)
        return Timestamps(full: full, day: day)
    }

    static func authorization(
        request: URLRequest,
        payloadHash: String,
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        timestamps: Timestamps
    ) throws -> String {
        guard let url = request.url, !accessKeyID.isEmpty, !secretAccessKey.isEmpty else {
            throw DesktopAutomaticBackupError.credentialsUnavailable
        }
        let headerPairs = request.allHTTPHeaderFields?.compactMap { key, value -> (String, String)? in
            let name = key.lowercased()
            guard name == "host" || name.hasPrefix("x-amz-") else { return nil }
            return (name, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.0 < $1.0 } ?? []
        let canonicalHeaders = headerPairs.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headerPairs.map(\.0).joined(separator: ";")
        let canonicalQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/",
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(timestamps.day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamps.full,
            scope,
            DesktopRecoveryService.sha256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let dateKey = hmac(Data(timestamps.day.utf8), key: Data(("AWS4" + secretAccessKey).utf8))
        let regionKey = hmac(Data(region.utf8), key: dateKey)
        let serviceKey = hmac(Data("s3".utf8), key: regionKey)
        let signingKey = hmac(Data("aws4_request".utf8), key: serviceKey)
        let signature = hmac(Data(stringToSign.utf8), key: signingKey).map { String(format: "%02x", $0) }.joined()
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

final class S3ListObjectsParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private(set) var objects: [DesktopBackupObject] = []
    private(set) var isTruncated = false
    private(set) var nextContinuationToken: String?
    private var text = ""
    private var key: String?
    private var size: Int64?
    private var modified: Date?

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool { parser.parse() }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" { key = nil; size = nil; modified = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key": key = value
        case "Size": size = Int64(value)
        case "LastModified": modified = ISO8601DateFormatter().date(from: value)
        case "IsTruncated": isTruncated = value.lowercased() == "true"
        case "NextContinuationToken": nextContinuationToken = value.isEmpty ? nil : value
        case "Contents":
            if let key, let size { objects.append(.init(key: key, byteCount: size, lastModified: modified, sha256: nil)) }
        default: break
        }
        text = ""
    }
}

private extension URL {
    var hostWithPort: String {
        guard let port else { return host ?? "" }
        return "\(host ?? ""):\(port)"
    }
}

public struct DesktopAutomaticBackupService: Sendable {
    public init() {}

    public func transport(
        configuration: DesktopAutomaticBackupConfiguration,
        secrets: DesktopAutomaticBackupSecrets
    ) throws -> any DesktopBackupObjectTransport {
        let configuration = try configuration.validated()
        switch configuration.destination {
        case .localFolder:
            return LocalFolderDesktopBackupTransport(root: URL(fileURLWithPath: configuration.localFolderPath, isDirectory: true))
        case .cloudflareR2, .s3Compatible:
            guard !secrets.accessKeyID.isEmpty, !secrets.secretAccessKey.isEmpty,
                  let endpoint = URL(string: configuration.endpoint) else {
                throw DesktopAutomaticBackupError.credentialsUnavailable
            }
            return S3DesktopBackupTransport(
                endpoint: endpoint,
                bucket: configuration.bucket,
                region: configuration.region,
                accessKeyID: secrets.accessKeyID,
                secretAccessKey: secrets.secretAccessKey
            )
        }
    }

    public func objectKey(configuration: DesktopAutomaticBackupConfiguration, artifact: DesktopEncryptedBackupArtifact) -> String {
        let timestamp = artifact.createdAtUnixMillis
        return "\(configuration.prefix)/generations/\(timestamp)-\(artifact.backupID.uuidString.lowercased()).kanamebackup.encrypted"
    }

    public func enforceRetention(
        transport: any DesktopBackupObjectTransport,
        configuration: DesktopAutomaticBackupConfiguration,
        now: Date
    ) async throws {
        let objects = try await transport.list(prefix: configuration.prefix)
            .filter { $0.key.hasSuffix(".kanamebackup.encrypted") }
        let cutoff = now.addingTimeInterval(-Double(configuration.retentionDays) * 86_400)
        let ordered = objects.sorted { ($0.lastModified ?? .distantPast, $0.key) > ($1.lastModified ?? .distantPast, $1.key) }
        for object in ordered.dropFirst(3) where (object.lastModified ?? .distantPast) < cutoff {
            try await transport.delete(key: object.key)
        }
    }

    public func latestObject(
        transport: any DesktopBackupObjectTransport,
        configuration: DesktopAutomaticBackupConfiguration
    ) async throws -> DesktopBackupObject {
        guard let latest = try await transport.list(prefix: configuration.prefix)
            .filter({ $0.key.hasSuffix(".kanamebackup.encrypted") })
            .sorted(by: { ($0.lastModified ?? .distantPast, $0.key) > ($1.lastModified ?? .distantPast, $1.key) })
            .first else {
            throw DesktopAutomaticBackupError.noRemoteBackup
        }
        return latest
    }
}
