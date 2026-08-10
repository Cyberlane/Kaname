import Foundation

public enum LocalGitMutationKind: String, Codable, Equatable, Sendable {
    case createWorktree
    case commit
    case cleanupWorktree
    case createPullRequest
    case mergePullRequest
}

public struct LocalGitMutationGrant: Equatable, Sendable {
    public let approvalID: String
    public let kind: LocalGitMutationKind
    public let exactTarget: String

    public init(approvalID: String, kind: LocalGitMutationKind, exactTarget: String) {
        (self.approvalID, self.kind, self.exactTarget) = (approvalID, kind, exactTarget)
    }
}

public struct GitWorktreeSnapshot: Equatable, Sendable {
    public let rootPath: String
    public let worktreePath: String
    public let branch: String
    public let headRevision: String
    public let changedFiles: [String]
    public let diffSummary: String
}

public struct GitVerificationSnapshot: Equatable, Sendable {
    public let command: String
    public let succeeded: Bool
    public let summary: String
}

public enum DesktopGitControlError: Error, Equatable, LocalizedError, Sendable {
    case invalidRepository
    case invalidTarget
    case invalidBranch
    case approvalMismatch
    case worktreeDirty
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: "Choose a valid Git repository."
        case .invalidTarget: "Kaname rejected the worktree path because it is outside its private managed root."
        case .invalidBranch: "Choose a branch name accepted by Git."
        case .approvalMismatch: "The approval does not match this exact Git action and target."
        case .worktreeDirty: "The worktree has uncommitted changes. Review or commit them before cleanup."
        case let .commandFailed(detail): detail
        }
    }
}

public actor DesktopGitControlService {
    private let managedRoot: URL
    private let timeout: Duration

    public init(managedRoot: URL, timeout: Duration = .seconds(120)) {
        self.managedRoot = managedRoot.standardizedFileURL
        self.timeout = timeout
    }

    public func inspect(worktree: URL, rootRepository: URL? = nil) async throws -> GitWorktreeSnapshot {
        let path = worktree.standardizedFileURL
        let hasGitMarker = FileManager.default.fileExists(atPath: path.appending(path: ".git").path)
        let isWorktree: Bool
        if hasGitMarker {
            isWorktree = true
        } else {
            isWorktree = (try? await git(["rev-parse", "--is-inside-work-tree"], at: path)) == "true"
        }
        guard isWorktree else {
            throw DesktopGitControlError.invalidRepository
        }
        let branch = try await git(["branch", "--show-current"], at: path)
        let head = try await git(["rev-parse", "HEAD"], at: path)
        let porcelain = try await git(["status", "--porcelain=v1", "-z"], at: path, preserveWhitespace: true)
        let files = porcelain.split(separator: "\0").compactMap { line -> String? in
            let value = String(line)
            guard value.count > 3 else { return nil }
            return String(value.dropFirst(3))
        }
        let summary = try await git(["diff", "--stat", "HEAD"], at: path, preserveWhitespace: true)
        return GitWorktreeSnapshot(
            rootPath: (rootRepository ?? path).standardizedFileURL.path,
            worktreePath: path.path,
            branch: branch,
            headRevision: head,
            changedFiles: files,
            diffSummary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func createWorktree(
        repository: URL,
        target: URL,
        branch: String,
        baseRevision: String,
        grant: LocalGitMutationGrant
    ) async throws -> GitWorktreeSnapshot {
        let root = repository.standardizedFileURL
        let destination = target.standardizedFileURL
        try validateManagedTarget(destination)
        guard grant.kind == .createWorktree, grant.exactTarget == destination.path else {
            throw DesktopGitControlError.approvalMismatch
        }
        guard branch.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$", options: .regularExpression) != nil,
              !branch.contains(".."), !branch.hasSuffix("/") else {
            throw DesktopGitControlError.invalidBranch
        }
        guard (try? await git(["rev-parse", "--is-inside-work-tree"], at: root)) == "true" else {
            throw DesktopGitControlError.invalidRepository
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try await git(
            ["worktree", "add", "-b", branch, destination.path, baseRevision],
            at: root,
            preserveWhitespace: true
        )
        return try await inspect(worktree: destination, rootRepository: root)
    }

    public func createSignedCommit(
        worktree: URL,
        relativePaths: [String],
        message: String,
        grant: LocalGitMutationGrant
    ) async throws -> GitWorktreeSnapshot {
        let target = worktree.standardizedFileURL
        guard grant.kind == .commit, grant.exactTarget == target.path else {
            throw DesktopGitControlError.approvalMismatch
        }
        let paths = relativePaths.filter(Self.isSafeRelativePath)
        guard !paths.isEmpty, paths.count == relativePaths.count else { throw DesktopGitControlError.invalidTarget }
        _ = try await git(["add", "--"] + paths, at: target, preserveWhitespace: true)
        _ = try await git(["commit", "-S", "-m", String(message.prefix(998))], at: target, preserveWhitespace: true)
        return try await inspect(worktree: target)
    }

    public func removeWorktree(
        repository: URL,
        target: URL,
        grant: LocalGitMutationGrant
    ) async throws {
        let root = repository.standardizedFileURL
        let destination = target.standardizedFileURL
        try validateManagedTarget(destination)
        guard grant.kind == .cleanupWorktree, grant.exactTarget == destination.path else {
            throw DesktopGitControlError.approvalMismatch
        }
        let status = try await git(["status", "--porcelain=v1"], at: destination, preserveWhitespace: true)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopGitControlError.worktreeDirty
        }
        _ = try await git(["worktree", "remove", destination.path], at: root, preserveWhitespace: true)
    }

    public func runVerification(command: String, worktree: URL) async throws -> GitVerificationSnapshot {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 4_096 else { throw DesktopGitControlError.invalidTarget }
        let output = try await LocalProcess.capture(
            executable: "/bin/zsh",
            arguments: ["-lc", clean],
            workingDirectory: worktree.standardizedFileURL,
            timeout: timeout,
            environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
            maximumOutputBytes: 1_048_576
        )
        let text = (output.standardOutput + output.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitVerificationSnapshot(
            command: clean,
            succeeded: output.exitStatus == 0,
            summary: String((text.isEmpty ? "Exited with status \(output.exitStatus)." : text).suffix(32_000))
        )
    }

    private func git(_ arguments: [String], at directory: URL, preserveWhitespace: Bool = false) async throws -> String {
        do {
            return try await LocalProcess.captureSuccessfulText(
                executable: "git",
                arguments: arguments,
                workingDirectory: directory,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                preserveWhitespace: preserveWhitespace
            )
        } catch {
            throw DesktopGitControlError.commandFailed(error.localizedDescription)
        }
    }

    private func validateManagedTarget(_ target: URL) throws {
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard target != managedRoot, parent.path.hasPrefix(managedRoot.path + "/") || parent == managedRoot else {
            throw DesktopGitControlError.invalidTarget
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.split(separator: "/").contains("..")
    }
}
