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

    private init(url: URL) {
        self.url = url
    }

    static func create(sourceHome: URL?) throws -> CodexEphemeralHome {
        let source = sourceHome ?? defaultSourceHome()
        let authentication = source.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: authentication.path) else {
            throw Error.fileBackedAuthenticationUnavailable
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-codex-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: "auth.json").path,
                withDestinationPath: authentication.path
            )
            return CodexEphemeralHome(url: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw Error.fileBackedAuthenticationUnavailable
        }
    }

    func cleanup() throws {
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
