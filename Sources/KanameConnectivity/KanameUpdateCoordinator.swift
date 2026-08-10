import Foundation

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
    public var detail: String
    public var updatedAtUnixMillis: Int64

    public init(
        status: KanameUpdateStatus,
        version: String? = nil,
        build: String? = nil,
        detail: String,
        updatedAtUnixMillis: Int64
    ) {
        (self.status, self.version, self.build) = (status, version, build)
        (self.detail, self.updatedAtUnixMillis) = (detail, updatedAtUnixMillis)
    }
}

public struct KanameUpdateLaunchRequest: Equatable, Sendable {
    public let helperURL: URL
    public let arguments: [String]
}

public enum KanameUpdateError: Error, Equatable, LocalizedError, Sendable {
    case stableChannelRequired
    case invalidBundle
    case invalidSignature
    case identifierMismatch
    case noStagedUpdate
    case activeApproval
    case unsavedComposer
    case helperUnavailable

    public var errorDescription: String? {
        switch self {
        case .stableChannelRequired: "Updates can be staged only from stable Kaname."
        case .invalidBundle: "Choose a complete Kaname application bundle."
        case .invalidSignature: "The selected Kaname bundle did not pass strict signature verification."
        case .identifierMismatch: "The selected bundle is not a stable Kaname update. Development candidates stay separate."
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

    public init(
        environment: KanameDesktopEnvironment = .current,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.environment = environment
        self.fileManager = fileManager
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
        guard source.pathExtension == "app",
              fileManager.fileExists(atPath: source.appending(path: "Contents/Info.plist").path) else {
            throw KanameUpdateError.invalidBundle
        }
        guard Self.bundleValue("CFBundleIdentifier", at: source) == environment.bundleIdentifier else {
            throw KanameUpdateError.identifierMismatch
        }
        let signature = try await LocalProcess.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", source.path],
            workingDirectory: source.deletingLastPathComponent(),
            timeout: .seconds(20)
        )
        guard signature.exitStatus == 0 else { throw KanameUpdateError.invalidSignature }

        try preparePrivateDirectory(environment.updateDirectory)
        let stagedParent = stagedBundleURL.deletingLastPathComponent()
        try preparePrivateDirectory(stagedParent)
        if fileManager.fileExists(atPath: stagedBundleURL.path) {
            try fileManager.removeItem(at: stagedBundleURL)
        }
        try fileManager.copyItem(at: source, to: stagedBundleURL)
        let receipt = KanameUpdateReceipt(
            status: .staged,
            version: Self.bundleValue("CFBundleShortVersionString", at: stagedBundleURL),
            build: Self.bundleValue("CFBundleVersion", at: stagedBundleURL),
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
    ) throws -> KanameUpdateLaunchRequest {
        guard composerCheckpointed else { throw KanameUpdateError.unsavedComposer }
        guard !hasActiveApproval else { throw KanameUpdateError.activeApproval }
        guard fileManager.fileExists(atPath: stagedBundleURL.path) else { throw KanameUpdateError.noStagedUpdate }
        guard let helperURL = Bundle.main.url(forResource: "KanameUpdateHelper", withExtension: nil),
              fileManager.isExecutableFile(atPath: helperURL.path) else { throw KanameUpdateError.helperUnavailable }
        let receipt = receipt()
        try save(KanameUpdateReceipt(
            status: .switching,
            version: receipt.version,
            build: receipt.build,
            detail: "Switching after an explicit UI checkpoint.",
            updatedAtUnixMillis: now()
        ))
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
                "--timeout", "12",
            ]
        )
    }

    public func rollbackRequest(installedBundleURL: URL, processIdentifier: Int32) throws -> KanameUpdateLaunchRequest {
        guard fileManager.fileExists(atPath: backupBundleURL.path) else { throw KanameUpdateError.noStagedUpdate }
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
}
