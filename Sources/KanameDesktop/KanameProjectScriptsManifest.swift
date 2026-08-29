import Foundation

public enum KanameProjectScriptIcon: String, Codable, CaseIterable, Equatable, Sendable {
    case play
    case test
    case lint
    case build
    case debug
    case configure
}

public struct KanameProjectScript: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var command: String
    public var icon: KanameProjectScriptIcon?
    public var kind: DesktopQualityGateKind
    public var keybind: String?
    public var runOnWorktreeReady: Bool
    public var previewUrl: String?
    public var autoOpenPreview: Bool
    public var maximumDurationSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case id, title, command, icon, kind, keybind
        case runOnWorktreeReady, previewUrl, autoOpenPreview, maximumDurationSeconds
    }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        func requiredString(_ key: CodingKeys) throws -> String {
            try keyed.decode(String.self, forKey: key)
        }
        func optionalString(_ key: CodingKeys) throws -> String? {
            try keyed.decodeIfPresent(String.self, forKey: key)
        }
        id = try requiredString(.id)
        title = try requiredString(.title)
        command = try requiredString(.command)
        icon = try keyed.decodeIfPresent(KanameProjectScriptIcon.self, forKey: .icon)
        kind = try keyed.decode(DesktopQualityGateKind.self, forKey: .kind)
        keybind = try optionalString(.keybind)
        runOnWorktreeReady = try keyed.decodeIfPresent(Bool.self, forKey: .runOnWorktreeReady) ?? false
        previewUrl = try optionalString(.previewUrl)
        autoOpenPreview = try keyed.decodeIfPresent(Bool.self, forKey: .autoOpenPreview) ?? false
        maximumDurationSeconds = try keyed.decodeIfPresent(Int.self, forKey: .maximumDurationSeconds) ?? 600
    }

    public static func make(
        id: String,
        title: String,
        command: String,
        icon: KanameProjectScriptIcon? = nil,
        kind: DesktopQualityGateKind,
        keybind: String? = nil,
        runOnWorktreeReady: Bool = false,
        previewUrl: String? = nil,
        autoOpenPreview: Bool = false,
        maximumDurationSeconds: Int = 600
    ) throws -> KanameProjectScript {
        var payload: [String: Any] = [
            "id": id.trimmingCharacters(in: .whitespacesAndNewlines),
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "command": command.trimmingCharacters(in: .whitespacesAndNewlines),
            "kind": kind.rawValue,
            "runOnWorktreeReady": runOnWorktreeReady,
            "autoOpenPreview": autoOpenPreview,
            "maximumDurationSeconds": min(max(maximumDurationSeconds, 1), 3_600),
        ]
        if let icon { payload["icon"] = icon.rawValue }
        if let keybind { payload["keybind"] = keybind }
        if let previewUrl { payload["previewUrl"] = previewUrl }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(KanameProjectScript.self, from: data)
    }
}

public struct KanameProjectScriptsManifest: Codable, Equatable, Sendable {
    public static let fileName = "kaname.json"
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var scripts: [KanameProjectScript]
}

public enum KanameProjectScriptsManifestError: Error, Equatable, LocalizedError, Sendable {
    case missingFile
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case invalidScript(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile: "No kaname.json was found at the project root."
        case let .invalidJSON(detail): detail
        case let .unsupportedSchemaVersion(version):
            "kaname.json schemaVersion \(version) is unsupported; expected \(KanameProjectScriptsManifest.supportedSchemaVersion)."
        case let .invalidScript(detail): detail
        }
    }
}

public enum KanameProjectScriptsManifestLoader {
    public static func load(fromProjectRoot root: URL) throws -> KanameProjectScriptsManifest {
        let url = root.appending(path: KanameProjectScriptsManifest.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KanameProjectScriptsManifestError.missingFile
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> KanameProjectScriptsManifest {
        let decoder = JSONDecoder()
        let manifest: KanameProjectScriptsManifest
        do {
            manifest = try decoder.decode(KanameProjectScriptsManifest.self, from: data)
        } catch {
            throw KanameProjectScriptsManifestError.invalidJSON(error.localizedDescription)
        }
        guard manifest.schemaVersion == KanameProjectScriptsManifest.supportedSchemaVersion else {
            throw KanameProjectScriptsManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        for script in manifest.scripts {
            try validate(script)
        }
        return manifest
    }

    public static func detect(at directory: URL) -> String? {
        let url = directory.appending(path: KanameProjectScriptsManifest.fileName).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) != .typeSymbolicLink else {
            return nil
        }
        return KanameProjectScriptsManifest.fileName
    }

    public static func qualityGate(
        from script: KanameProjectScript,
        threadID: String,
        worktreeID: String?,
        summary: String,
        state: DesktopActionState,
        artifactIDs: [String] = [],
        recordedAtUnixMillis: Int64
    ) -> DesktopQualityGateRecord {
        DesktopQualityGateRecord(
            id: "script:\(script.id):\(recordedAtUnixMillis)",
            threadID: threadID,
            worktreeID: worktreeID,
            kind: script.kind,
            command: script.command,
            summary: String(summary.suffix(32_000)),
            state: state,
            artifactIDs: artifactIDs,
            recordedAtUnixMillis: recordedAtUnixMillis
        )
    }

    private static func validate(_ script: KanameProjectScript) throws {
        let id = script.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 128 else {
            throw KanameProjectScriptsManifestError.invalidScript("Each script requires a stable id.")
        }
        guard !title.isEmpty, title.utf8.count <= 200 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) requires a display title.")
        }
        guard !command.isEmpty, command.utf8.count <= 4_096 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) requires a bounded command.")
        }
        guard script.maximumDurationSeconds > 0, script.maximumDurationSeconds <= 3_600 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) maximumDurationSeconds must be 1...3600.")
        }
        if script.autoOpenPreview, (script.previewUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) sets autoOpenPreview without previewUrl.")
        }
    }
}
