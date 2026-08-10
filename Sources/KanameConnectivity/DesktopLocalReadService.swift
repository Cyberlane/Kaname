import Foundation

public struct ObsidianNotePreview: Equatable, Sendable {
    public let path: String
    public let content: String
    public let wasTruncated: Bool
}

public struct LocalGitInspection: Equatable, Sendable {
    public let root: String
    public let branch: String
    public let head: String
    public let changedPaths: [String]
    public let wasTruncated: Bool

    public var isClean: Bool { changedPaths.isEmpty }
}

public enum DesktopLocalReadError: Error, LocalizedError, Sendable {
    case invalidScope(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidScope(let detail), .commandFailed(let detail): detail
        }
    }
}

public actor DesktopLocalReadService {
    public init() {}

    public func readObsidianNote(path: String) async throws -> ObsidianNotePreview {
        let validatedPath = try Self.validatedVaultPath(path)
        let result = try await LocalProcess.capture(
            executable: "obsidian",
            arguments: ["read", "path=\(validatedPath)"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: .seconds(5),
            environmentRemovals: Self.hostEnvironmentRemovals(),
            maximumOutputBytes: 131_072
        )
        guard result.exitStatus == 0 else {
            throw DesktopLocalReadError.commandFailed(
                Self.failureDetail(command: "obsidian read", output: result)
            )
        }
        return ObsidianNotePreview(
            path: validatedPath,
            content: result.standardOutput,
            wasTruncated: result.standardOutputWasTruncated
        )
    }

    public func inspectGitWorkspace(path: String) async throws -> LocalGitInspection {
        let directory = try Self.validatedDirectory(path)
        async let rootResult = Self.git(["rev-parse", "--show-toplevel"], directory: directory)
        async let headResult = Self.git(["rev-parse", "--short=12", "HEAD"], directory: directory)
        async let statusResult = Self.git(["status", "--short", "--branch"], directory: directory)
        let (root, head, status) = try await (rootResult, headResult, statusResult)

        let statusLines = status.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
        let branch = Self.branch(from: statusLines.first)
        return LocalGitInspection(
            root: root.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: branch,
            head: head.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            changedPaths: Array(statusLines.dropFirst()),
            wasTruncated: root.standardOutputWasTruncated
                || head.standardOutputWasTruncated
                || status.standardOutputWasTruncated
        )
    }

    static func validatedVaultPath(_ path: String) throws -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty, normalized.utf8.count <= 1_024,
              !normalized.hasPrefix("/"),
              !components.contains(".."), !components.contains(".") else {
            throw DesktopLocalReadError.invalidScope("Obsidian reads require a vault-relative path without traversal components.")
        }
        return normalized
    }

    static func branch(from statusHeader: String?) -> String {
        guard let statusHeader, statusHeader.hasPrefix("## ") else { return "Unknown" }
        let value = String(statusHeader.dropFirst(3)).components(separatedBy: "...").first ?? "Unknown"
        return value.split(separator: " ").first.map(String.init) ?? value
    }

    private static func validatedDirectory(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DesktopLocalReadError.invalidScope("Git inspection requires an existing local directory.")
        }
        return url
    }

    private static func git(_ arguments: [String], directory: URL) async throws -> CapturedProcessOutput {
        let result = try await LocalProcess.capture(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path] + arguments,
            workingDirectory: directory,
            timeout: .seconds(5),
            environmentRemovals: hostEnvironmentRemovals(),
            maximumOutputBytes: 131_072
        )
        guard result.exitStatus == 0 else {
            throw DesktopLocalReadError.commandFailed(failureDetail(command: "git", output: result))
        }
        return result
    }

    private static func failureDetail(command: String, output: CapturedProcessOutput) -> String {
        let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "\(command) exited with status \(output.exitStatus)." : detail
    }

    private static func hostEnvironmentRemovals() -> Set<String> {
        Set(ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("T3_") })
            .union(["CODEX_THREAD_ID"])
    }
}
