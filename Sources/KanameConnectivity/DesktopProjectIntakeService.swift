import Foundation

public struct DesktopProjectIntakeSnapshot: Equatable, Sendable {
    public let selectedPath: String
    public let canonicalSelectedPath: String
    public let suggestedName: String
    public let repository: LocalGitInspection?
    public let repositoryInstructionReferences: [String]
    public let selectedInstructionReferences: [String]
    /// Relative path to `kaname.json` when present at the repository or
    /// selection root; nil when absent or unreadable.
    public let projectScriptsManifestReference: String?
    public let projectScriptCount: Int

    public var instructionReferences: [String] { repositoryInstructionReferences }

    public var isRepositorySubfolder: Bool {
        guard let repository else { return false }
        return repository.root != canonicalSelectedPath
    }
}

public struct DesktopRemoteProjectReference: Equatable, Sendable {
    public let cloneURL: String
    public let suggestedName: String
    public let displayName: String
}

public enum DesktopProjectIntakeError: Error, Equatable, LocalizedError, Sendable {
    case invalidRemote(String)
    case destinationExists(String)
    case cloneFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRemote(detail), let .destinationExists(detail), let .cloneFailed(detail): detail
        }
    }
}

public actor DesktopProjectIntakeService {
    private static let instructionCandidates = [
        "AGENTS.md",
        "CLAUDE.md",
        ".github/copilot-instructions.md",
        ".cursor/rules",
    ]

    public init() {}

    public func inspectLocalDirectory(path: String) async throws -> DesktopProjectIntakeSnapshot {
        let selected = try Self.validatedDirectory(path)
        let canonicalSelected = selected.resolvingSymlinksInPath().standardizedFileURL
        let repository = try? await DesktopLocalReadService().inspectGitWorkspace(path: canonicalSelected.path)
        let repositoryRoot = repository.map { URL(fileURLWithPath: $0.root, isDirectory: true) } ?? canonicalSelected
        let selectedInstructions = Self.detectedInstructions(at: canonicalSelected, relativeTo: canonicalSelected)
        var repositoryInstructions = Self.detectedInstructions(at: repositoryRoot, relativeTo: repositoryRoot)
        if repositoryRoot.path != canonicalSelected.path {
            repositoryInstructions.append(contentsOf: Self.detectedInstructions(at: canonicalSelected, relativeTo: repositoryRoot))
        }
        let scripts = Self.detectProjectScripts(at: repositoryRoot)
            ?? Self.detectProjectScripts(at: canonicalSelected)
            ?? (reference: nil as String?, count: 0)
        return DesktopProjectIntakeSnapshot(
            selectedPath: selected.path,
            canonicalSelectedPath: canonicalSelected.path,
            suggestedName: canonicalSelected.lastPathComponent,
            repository: repository,
            repositoryInstructionReferences: Self.unique(repositoryInstructions),
            selectedInstructionReferences: selectedInstructions,
            projectScriptsManifestReference: scripts.reference,
            projectScriptCount: scripts.count
        )
    }

    public func cloneRemote(
        reference: DesktopRemoteProjectReference,
        parentDirectory: String
    ) async throws -> DesktopProjectIntakeSnapshot {
        let parent = try Self.validatedDirectory(parentDirectory)
        let destination = parent.appending(path: reference.suggestedName, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DesktopProjectIntakeError.destinationExists(
                "A file or folder already exists at \(destination.path). Choose another parent folder."
            )
        }
        let staging = parent.appending(
            path: ".kaname-clone-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        do {
            let result = try await LocalProcess.capture(
                executable: "/usr/bin/git",
                arguments: ["clone", "--progress", "--", reference.cloneURL, staging.path],
                workingDirectory: parent,
                timeout: .seconds(300),
                environmentRemovals: Self.hostEnvironmentRemovals(),
                maximumOutputBytes: 262_144
            )
            guard result.exitStatus == 0 else {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DesktopProjectIntakeError.cloneFailed(
                    detail.isEmpty ? "Git could not clone this repository." : String(detail.suffix(4_096))
                )
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
        return try await inspectLocalDirectory(path: destination.path)
    }

    public static func parseRemoteReference(_ value: String) throws -> DesktopRemoteProjectReference {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else {
            throw DesktopProjectIntakeError.invalidRemote("Enter a GitHub owner/repository or a Git HTTPS or SSH URL.")
        }

        if isGitHubSlug(trimmed) {
            let name = try repositoryName(from: trimmed)
            return DesktopRemoteProjectReference(
                cloneURL: "https://github.com/\(trimmed.hasSuffix(".git") ? trimmed : "\(trimmed).git")",
                suggestedName: name,
                displayName: trimmed
            )
        }

        if trimmed.hasPrefix("git@") {
            guard let colon = trimmed.firstIndex(of: ":"), colon < trimmed.index(before: trimmed.endIndex) else {
                throw DesktopProjectIntakeError.invalidRemote("Enter a complete Git SSH URL.")
            }
            let host = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<colon]
            guard Self.isSafeHost(String(host)) else {
                throw DesktopProjectIntakeError.invalidRemote("The Git SSH host is not valid.")
            }
            let path = String(trimmed[trimmed.index(after: colon)...])
            guard !hasTraversalComponent(path) else {
                throw DesktopProjectIntakeError.invalidRemote("The Git SSH path cannot contain traversal components.")
            }
            let name = try repositoryName(from: path)
            return DesktopRemoteProjectReference(cloneURL: trimmed, suggestedName: name, displayName: trimmed)
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              Self.isSafeHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !components.path.split(separator: "/", omittingEmptySubsequences: false).contains(".") else {
            throw DesktopProjectIntakeError.invalidRemote(
                "Use a GitHub owner/repository, an HTTPS URL without embedded credentials, or a Git SSH URL."
            )
        }
        let name = try repositoryName(from: components.path)
        return DesktopRemoteProjectReference(cloneURL: trimmed, suggestedName: name, displayName: trimmed)
    }

    private static func detectProjectScripts(at directory: URL) -> (reference: String?, count: Int)? {
        let url = directory.appending(path: "kaname.json").standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attributes?[.type] as? FileAttributeType
        guard FileManager.default.fileExists(atPath: url.path),
              fileType != .typeSymbolicLink,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let scripts = object["scripts"] as? [Any] ?? []
        return (reference: "kaname.json", count: scripts.count)
    }

    private static func validatedDirectory(_ path: String) throws -> URL {
        try LocalDirectoryValidator.validate(path, errorDetail: "Choose an existing local folder.")
    }

    private static func isGitHubSlug(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func hasTraversalComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private static func detectedInstructions(at directory: URL, relativeTo scope: URL) -> [String] {
        let scopePrefix = scope.standardizedFileURL.path + "/"
        return instructionCandidates.compactMap { candidate in
            let url = directory.appending(path: candidate).standardizedFileURL
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileType = attributes?[.type] as? FileAttributeType
            guard url.path.hasPrefix(scopePrefix),
                  FileManager.default.fileExists(atPath: url.path),
                  fileType != .typeSymbolicLink else {
                return nil
            }
            return String(url.path.dropFirst(scopePrefix.count))
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func repositoryName(from path: String) throws -> String {
        let candidate = path.split(separator: "/").last.map(String.init) ?? ""
        let name = candidate.hasSuffix(".git") ? String(candidate.dropLast(4)) : candidate
        guard !name.isEmpty,
              name != ".", name != "..",
              name.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains) else {
            throw DesktopProjectIntakeError.invalidRemote("The repository URL does not contain a safe destination name.")
        }
        return name
    }

    private static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && host.unicodeScalars.allSatisfy(
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.")).contains
        )
    }

    private static func hostEnvironmentRemovals() -> Set<String> {
        Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("T3_") })
            .union(["CODEX_THREAD_ID"])
    }
}
