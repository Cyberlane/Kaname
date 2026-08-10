import CryptoKit
import Foundation

public enum DesktopPortableDocumentKind: String, Codable, Sendable {
    case conversationMarkdown
    case projectJSON
}

public struct DesktopPortableDocument: Equatable, Sendable {
    public let kind: DesktopPortableDocumentKind
    public let suggestedFilename: String
    public let data: Data

    public init(kind: DesktopPortableDocumentKind, suggestedFilename: String, data: Data) {
        self.kind = kind
        self.suggestedFilename = suggestedFilename
        self.data = data
    }
}

public struct DesktopImportedFile: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let fileExtension: String
    public let byteCount: Int
    public let sha256: String
    public let text: String

    public init(id: String, displayName: String, fileExtension: String, byteCount: Int, sha256: String, text: String) {
        self.id = id
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.sha256 = sha256
        self.text = text
    }
}

public struct DesktopImportPreview: Equatable, Sendable {
    public let files: [DesktopImportedFile]
    public let totalByteCount: Int
    public let composerDraft: String
}

public enum DesktopImportExportError: Error, Equatable, LocalizedError, Sendable {
    case noFiles
    case tooManyFiles
    case unsupportedFile(String)
    case symbolicLink(String)
    case fileTooLarge(String)
    case importTooLarge
    case invalidText(String)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .noFiles: "Choose at least one local text or source file."
        case .tooManyFiles: "Import at most 20 files at once."
        case let .unsupportedFile(name): "\(name) is not a supported local text or source file."
        case let .symbolicLink(name): "\(name) is a symbolic link. Choose the exact file instead."
        case let .fileTooLarge(name): "\(name) is larger than the 1 MB per-file limit."
        case .importTooLarge: "The selected files exceed the 4 MB import limit."
        case let .invalidText(name): "\(name) is not valid UTF-8 text."
        case .emptyDocument: "There is no current conversation or project to export."
        }
    }
}

public enum DesktopImportExportService {
    public static let maximumFileCount = 20
    public static let maximumFileBytes = 1_048_576
    public static let maximumImportBytes = 4_194_304
    public static let supportedExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "diff", "go", "h", "hpp", "html", "java", "js", "json",
        "jsx", "kt", "log", "md", "patch", "py", "rb", "rs", "sh", "sql", "swift", "toml",
        "ts", "tsx", "txt", "xml", "yaml", "yml",
    ]

    public static func previewImport(urls: [URL], fileManager: FileManager = .default) throws -> DesktopImportPreview {
        let unique = urls.reduce(into: [URL]()) { result, url in
            let standardized = url.standardizedFileURL
            if !result.contains(standardized) { result.append(standardized) }
        }
        guard !unique.isEmpty else { throw DesktopImportExportError.noFiles }
        guard unique.count <= maximumFileCount else { throw DesktopImportExportError.tooManyFiles }

        var files: [DesktopImportedFile] = []
        var total = 0
        for (selectionIndex, url) in unique.enumerated() {
            let name = safeFilename(url.lastPathComponent)
            let fileExtension = url.pathExtension.lowercased()
            guard supportedExtensions.contains(fileExtension) else {
                throw DesktopImportExportError.unsupportedFile(name)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw DesktopImportExportError.symbolicLink(name)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw DesktopImportExportError.unsupportedFile(name)
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maximumFileBytes else { throw DesktopImportExportError.fileTooLarge(name) }
            total += size
            guard total <= maximumImportBytes else { throw DesktopImportExportError.importTooLarge }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw DesktopImportExportError.invalidText(name)
            }
            let digest = sha256(data)
            files.append(DesktopImportedFile(
                id: "selection-\(selectionIndex)-\(digest)",
                displayName: name,
                fileExtension: fileExtension,
                byteCount: data.count,
                sha256: digest,
                text: text
            ))
        }
        return DesktopImportPreview(files: files, totalByteCount: total, composerDraft: composerDraft(files: files))
    }

    public static func exportConversation(_ thread: DesktopThread, projectName: String?) throws -> DesktopPortableDocument {
        var lines = ["# \(thread.title)", ""]
        if let projectName { lines.append("Project: \(projectName)\n") }
        lines.append("Kind: \(thread.kind.label)\n")
        for message in thread.messages {
            lines.append("## \(message.role == .user ? "You" : "Assistant")")
            lines.append("")
            lines.append(message.body)
            lines.append("")
        }
        guard thread.messages.isEmpty == false else { throw DesktopImportExportError.emptyDocument }
        return DesktopPortableDocument(
            kind: .conversationMarkdown,
            suggestedFilename: "\(filenameStem(thread.title))-conversation.md",
            data: Data(lines.joined(separator: "\n").utf8)
        )
    }

    public static func exportProject(_ project: DesktopProject) throws -> DesktopPortableDocument {
        struct PortableProject: Codable {
            let schemaVersion: Int
            let name: String
            let summary: String
            let defaultKind: String
            let defaultProvider: String
            let instructionReferences: [String]
            let knowledgeSourceIDs: [String]
            let skillIDs: [String]
        }
        let portable = PortableProject(
            schemaVersion: 1,
            name: project.name,
            summary: project.summary,
            defaultKind: project.context.defaultKind.rawValue,
            defaultProvider: project.context.defaultProvider,
            instructionReferences: portableInstructionReferences(
                project.context.instructionReferences,
                projectPath: project.path
            ),
            knowledgeSourceIDs: project.context.knowledgeSourceIDs,
            skillIDs: project.context.skillIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return DesktopPortableDocument(
            kind: .projectJSON,
            suggestedFilename: "\(filenameStem(project.name))-project.json",
            data: try encoder.encode(portable)
        )
    }

    private static func composerDraft(files: [DesktopImportedFile]) -> String {
        var lines = [
            "Review these explicitly selected local files. They are attached to this draft only and have not been sent yet.",
            "",
        ]
        for file in files {
            lines.append("<file name=\"\(file.displayName)\" sha256=\"\(file.sha256)\">")
            lines.append(file.text)
            lines.append("</file>")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeFilename(_ value: String) -> String {
        let sanitized = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- ")).contains(scalar)
                ? Character(String(scalar))
                : "_"
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "local-file" : result).prefix(160))
    }

    private static func filenameStem(_ value: String) -> String {
        let lowered = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let segments = String(lowered).split(separator: "-").filter { !$0.isEmpty }
        return String((segments.isEmpty ? ["kaname"] : segments).joined(separator: "-").prefix(80))
    }

    private static func portableInstructionReferences(_ references: [String], projectPath: String?) -> [String] {
        let projectRoot = projectPath.flatMap(absoluteFilesystemPath)
        return references.compactMap { reference in
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let absolutePath = absoluteFilesystemPath(trimmed) {
                guard let projectRoot,
                      projectRoot != "/",
                      absolutePath.hasPrefix(projectRoot + "/") else { return nil }
                return safeRepositoryRelativeReference(String(absolutePath.dropFirst(projectRoot.count + 1)))
            }
            return safeRepositoryRelativeReference(trimmed)
        }
    }

    private static func absoluteFilesystemPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let expanded: String
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home + String(trimmed.dropFirst())
        } else if trimmed == "$HOME" || trimmed == "${HOME}" {
            expanded = home
        } else if trimmed.hasPrefix("$HOME/") {
            expanded = home + "/" + String(trimmed.dropFirst("$HOME/".count))
        } else if trimmed.hasPrefix("${HOME}/") {
            expanded = home + "/" + String(trimmed.dropFirst("${HOME}/".count))
        } else {
            expanded = trimmed
        }
        guard expanded.hasPrefix("/") else { return nil }
        return NSString(string: expanded).standardizingPath
    }

    private static func safeRepositoryRelativeReference(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.hasPrefix("$"),
              !value.hasPrefix("%"),
              !value.hasPrefix("\\"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }

        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("file:"),
              !lowercased.hasPrefix("users/"),
              !lowercased.hasPrefix("home/"),
              !lowercased.hasPrefix("private/var/"),
              !lowercased.hasPrefix("volumes/"),
              !lowercased.contains("/users/"),
              !lowercased.contains("/home/"),
              !lowercased.contains("/private/var/"),
              !lowercased.contains("/volumes/"),
              !lowercased.contains("$home"),
              !lowercased.contains("${home}"),
              !lowercased.contains("%userprofile%"),
              !lowercased.contains("%homepath%") else { return nil }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.first?.contains(":") == false else { return nil }
        return value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
