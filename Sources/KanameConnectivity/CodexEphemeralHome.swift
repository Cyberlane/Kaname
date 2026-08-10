import Foundation

/// A run-scoped Codex home that contains only a symbolic reference to the
/// active file-backed authentication record. It deliberately does not copy
/// credentials and does not inherit config.toml, MCP definitions, history, or
/// cached provider state from the user's normal Codex home.
final class CodexEphemeralHome: @unchecked Sendable {
    enum Error: LocalizedError {
        case fileBackedAuthenticationUnavailable
        case cleanupFailed

        var errorDescription: String? {
            switch self {
            case .fileBackedAuthenticationUnavailable:
                "Kaname could not create an isolated Codex home from file-backed authentication."
            case .cleanupFailed:
                "Kaname could not remove its temporary Codex home."
            }
        }
    }

    let url: URL
    private let removesOnCleanup: Bool

    private init(url: URL, removesOnCleanup: Bool = true) {
        self.url = url
        self.removesOnCleanup = removesOnCleanup
    }

    static func create(sourceHome: URL?, persistentDirectory: URL? = nil) throws -> CodexEphemeralHome {
        let source = sourceHome ?? defaultSourceHome()
        let authentication = source.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: authentication.path) else {
            throw Error.fileBackedAuthenticationUnavailable
        }

        let root = persistentDirectory?.standardizedFileURL ?? FileManager.default.temporaryDirectory
            .appending(path: "kaname-codex-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: persistentDirectory != nil,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let authenticationReference = root.appending(path: "auth.json")
            if FileManager.default.fileExists(atPath: authenticationReference.path) {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: authenticationReference.path)
                guard URL(fileURLWithPath: destination).standardizedFileURL == authentication.standardizedFileURL else {
                    throw Error.fileBackedAuthenticationUnavailable
                }
            } else {
                try FileManager.default.createSymbolicLink(
                    atPath: authenticationReference.path,
                    withDestinationPath: authentication.path
                )
            }
            return CodexEphemeralHome(url: root, removesOnCleanup: persistentDirectory == nil)
        } catch {
            if persistentDirectory == nil { try? FileManager.default.removeItem(at: root) }
            throw Error.fileBackedAuthenticationUnavailable
        }
    }

    func cleanup() throws {
        guard removesOnCleanup else { return }
        guard url.lastPathComponent.hasPrefix("kaname-codex-isolation-") else {
            throw Error.cleanupFailed
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw Error.cleanupFailed
        }
    }

    private static func defaultSourceHome() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
    }
}
