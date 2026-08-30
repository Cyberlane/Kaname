import Darwin
import Foundation
import KanameConnectivity

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
            "command": command,
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
    case unreadableFile
    case symbolicLink
    case manifestTooLarge(maximumBytes: Int)
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case tooManyScripts(maximumCount: Int)
    case duplicateScriptID(String)
    case invalidPreviewURL(String)
    case controlCharacters(scriptID: String, field: String)
    case invalidScript(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile: "No kaname.json was found at the project root."
        case .unreadableFile: "kaname.json must be a readable regular file."
        case .symbolicLink: "kaname.json must not be a symbolic link."
        case let .manifestTooLarge(maximumBytes):
            "kaname.json exceeds the \(maximumBytes)-byte limit."
        case let .invalidJSON(detail): detail
        case let .unsupportedSchemaVersion(version):
            "kaname.json schemaVersion \(version) is unsupported; expected \(KanameProjectScriptsManifest.supportedSchemaVersion)."
        case let .tooManyScripts(maximumCount):
            "kaname.json contains more than \(maximumCount) scripts."
        case let .duplicateScriptID(id): "kaname.json contains duplicate script id \(id)."
        case let .invalidPreviewURL(id):
            "Script \(id) previewUrl must use http or https on localhost, 127.0.0.1, or ::1."
        case let .controlCharacters(id, field):
            "Script \(id) \(field) must not contain control characters."
        case let .invalidScript(detail): detail
        }
    }
}

public enum KanameProjectScriptsManifestLoader {
    public static let maximumManifestBytes = 256 * 1_024
    public static let maximumScriptCount = 64

    public static func load(fromProjectRoot root: URL) throws -> KanameProjectScriptsManifest {
        try load(fromProjectRoot: root, afterRead: { _ in })
    }

    static func load(
        fromProjectRoot root: URL,
        afterRead: (URL) throws -> Void
    ) throws -> KanameProjectScriptsManifest {
        guard root.isFileURL else {
            throw KanameProjectScriptsManifestError.unreadableFile
        }
        let url = root.appending(path: KanameProjectScriptsManifest.fileName)
        let data = try readManifest(at: url, afterRead: afterRead)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> KanameProjectScriptsManifest {
        guard data.count <= maximumManifestBytes else {
            throw KanameProjectScriptsManifestError.manifestTooLarge(maximumBytes: maximumManifestBytes)
        }
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
        guard manifest.scripts.count <= maximumScriptCount else {
            throw KanameProjectScriptsManifestError.tooManyScripts(maximumCount: maximumScriptCount)
        }
        var scriptIDs = Set<String>()
        for script in manifest.scripts {
            try validate(script)
            let id = script.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard scriptIDs.insert(id).inserted else {
                throw KanameProjectScriptsManifestError.duplicateScriptID(id)
            }
        }
        return manifest
    }

    public static func detect(at directory: URL) -> String? {
        guard directory.isFileURL else { return nil }
        let url = directory.appending(path: KanameProjectScriptsManifest.fileName).standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
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

    private static func readManifest(
        at url: URL,
        afterRead: (URL) throws -> Void
    ) throws -> Data {
        guard url.isFileURL else {
            throw KanameProjectScriptsManifestError.unreadableFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw KanameProjectScriptsManifestError.missingFile
            case ELOOP:
                throw KanameProjectScriptsManifestError.symbolicLink
            default:
                throw KanameProjectScriptsManifestError.unreadableFile
            }
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw KanameProjectScriptsManifestError.unreadableFile
        }
        guard before.st_size <= off_t(maximumManifestBytes) else {
            throw KanameProjectScriptsManifestError.manifestTooLarge(maximumBytes: maximumManifestBytes)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumManifestBytes {
                let remaining = maximumManifestBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            throw KanameProjectScriptsManifestError.unreadableFile
        }
        guard data.count <= maximumManifestBytes else {
            throw KanameProjectScriptsManifestError.manifestTooLarge(maximumBytes: maximumManifestBytes)
        }
        try afterRead(url)

        var after = stat()
        var currentPath = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &currentPath) == 0,
              stableFileMetadata(before, matches: after),
              stableFileMetadata(after, matches: currentPath),
              data.count == Int(before.st_size) else {
            throw KanameProjectScriptsManifestError.unreadableFile
        }
        return data
    }

    private static func stableFileMetadata(_ expected: stat, matches actual: stat) -> Bool {
        expected.st_dev == actual.st_dev
            && expected.st_ino == actual.st_ino
            && expected.st_mode == actual.st_mode
            && expected.st_nlink == actual.st_nlink
            && expected.st_uid == actual.st_uid
            && expected.st_gid == actual.st_gid
            && expected.st_size == actual.st_size
            && expected.st_mtimespec.tv_sec == actual.st_mtimespec.tv_sec
            && expected.st_mtimespec.tv_nsec == actual.st_mtimespec.tv_nsec
            && expected.st_ctimespec.tv_sec == actual.st_ctimespec.tv_sec
            && expected.st_ctimespec.tv_nsec == actual.st_ctimespec.tv_nsec
    }

    private static func validate(_ script: KanameProjectScript) throws {
        let id = script.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, script.id.utf8.count <= 128 else {
            throw KanameProjectScriptsManifestError.invalidScript("Each script requires a stable id.")
        }
        guard !title.isEmpty, script.title.utf8.count <= 200 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) requires a display title.")
        }
        guard !command.isEmpty, script.command.utf8.count <= 4_096 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) requires a bounded command.")
        }
        guard !containsControlCharacters(script.title) else {
            throw KanameProjectScriptsManifestError.controlCharacters(scriptID: id, field: "title")
        }
        guard !containsControlCharacters(script.command) else {
            throw KanameProjectScriptsManifestError.controlCharacters(scriptID: id, field: "command")
        }
        guard script.maximumDurationSeconds > 0, script.maximumDurationSeconds <= 3_600 else {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) maximumDurationSeconds must be 1...3600.")
        }
        if let previewURL = script.previewUrl {
            guard let url = URL(string: previewURL), CodingPreviewMCPGrant.isLocalPreviewURL(url) else {
                throw KanameProjectScriptsManifestError.invalidPreviewURL(id)
            }
        }
        if script.autoOpenPreview, (script.previewUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KanameProjectScriptsManifestError.invalidScript("Script \(id) sets autoOpenPreview without previewUrl.")
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
