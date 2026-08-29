import CryptoKit
import Foundation

public enum LocalGitMutationKind: String, Codable, Equatable, Sendable {
    case createWorktree
    case commit
    case cleanupWorktree
    case createPullRequest
    case mergePullRequest
    case revertCheckpoint
}

public struct LocalGitMutationGrant: Equatable, Sendable {
    public let approvalID: String
    public let kind: LocalGitMutationKind
    public let exactTarget: String
    public let expiresAtUnixMillis: Int64?

    public init(
        approvalID: String,
        kind: LocalGitMutationKind,
        exactTarget: String,
        expiresAtUnixMillis: Int64? = nil
    ) {
        (self.approvalID, self.kind, self.exactTarget) = (approvalID, kind, exactTarget)
        self.expiresAtUnixMillis = expiresAtUnixMillis
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

/// An immutable description of Git's three user-visible state layers at one
/// instant. `worktreeTree` contains every tracked and non-ignored untracked
/// path without changing the real index. `indexTree` independently preserves
/// staged state. The hidden ref keeps both trees reachable from Git GC.
public struct GitCheckpointSnapshot: Equatable, Sendable {
    public let ref: String
    public let headRevision: String
    public let indexTree: String
    public let worktreeTree: String
    public let fingerprint: String

    public static func captured(
        ref: String,
        headRevision: String,
        indexTree: String,
        worktreeTree: String,
        fingerprint: String
    ) -> Self {
        Self(
            ref: ref,
            headRevision: headRevision,
            indexTree: indexTree,
            worktreeTree: worktreeTree,
            fingerprint: fingerprint
        )
    }
}

public struct GitCheckpointBracket: Equatable, Sendable {
    public let after: GitCheckpointSnapshot
    public let diffStat: String
    public let diffSummary: String
}

public struct GitCheckpointRestoreTarget: Equatable, Sendable {
    public let checkpointID: String
    public let worktreePath: String
    public let before: GitCheckpointSnapshot
    public let after: GitCheckpointSnapshot

    public init(
        checkpointID: String,
        worktreePath: String,
        before: GitCheckpointSnapshot,
        after: GitCheckpointSnapshot
    ) {
        self.checkpointID = checkpointID
        self.worktreePath = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path
        self.before = before
        self.after = after
    }

    public var approvalExactTarget: String {
        let pathDigest = SHA256.hash(data: Data(worktreePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "checkpoint:\(checkpointID):\(pathDigest):\(before.fingerprint):\(after.fingerprint)"
    }
}

public enum DesktopGitControlError: Error, Equatable, LocalizedError, Sendable {
    case invalidRepository
    case invalidTarget
    case invalidBranch
    case approvalMismatch
    case checkpointStateMismatch
    case worktreeDirty
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository: "Choose a valid Git repository."
        case .invalidTarget: "Kaname rejected the worktree path because it is outside its private managed root."
        case .invalidBranch: "Choose a branch name accepted by Git."
        case .approvalMismatch: "The approval does not match this exact Git action and target."
        case .checkpointStateMismatch:
            "The worktree changed after this checkpoint was captured. Refresh and request a new revert approval."
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

    /// Reads one file's patch on demand. Keeping this file-scoped avoids
    /// loading an enormous repository diff into the conversation process.
    public func diff(worktree: URL, relativePath: String) async throws -> String {
        let path = worktree.standardizedFileURL
        guard Self.isSafeRelativePath(relativePath),
              (try? await git(["rev-parse", "--is-inside-work-tree"], at: path)) == "true" else {
            throw DesktopGitControlError.invalidTarget
        }
        let isTracked = (try? await git(["ls-files", "--error-unmatch", "--", relativePath], at: path)) != nil
        let arguments = isTracked
            ? ["diff", "--no-ext-diff", "--no-color", "--unified=3", "HEAD", "--", relativePath]
            : ["diff", "--no-index", "--no-color", "--unified=3", "--", "/dev/null", relativePath]
        do {
            let output = try await LocalProcess.capture(
                executable: "git",
                arguments: arguments,
                workingDirectory: path,
                timeout: timeout,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: 2_097_152
            )
            guard (output.exitStatus == 0 || output.exitStatus == 1),
                  !output.standardOutputWasTruncated,
                  !output.standardErrorWasTruncated else {
                let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DesktopGitControlError.commandFailed(
                    detail.isEmpty ? "The selected patch exceeded Kaname's 2 MB review limit." : detail
                )
            }
            return output.standardOutput
        } catch {
            if let controlError = error as? DesktopGitControlError { throw controlError }
            throw DesktopGitControlError.commandFailed(error.localizedDescription)
        }
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

    /// Creates a hidden local ref before an implementation turn. Does not require
    /// mutation approval because it only writes Kaname-owned refs.
    public func createCheckpointBefore(
        worktree: URL,
        threadID: String,
        turnID: String
    ) async throws -> GitCheckpointSnapshot {
        let path = worktree.standardizedFileURL
        guard (try? await git(["rev-parse", "--is-inside-work-tree"], at: path)) == "true" else {
            throw DesktopGitControlError.invalidRepository
        }
        let ref = Self.checkpointRef(threadID: threadID, turnID: turnID, bracket: "before")
        return try await captureCheckpoint(at: path, ref: ref)
    }

    /// Creates the after-bracket ref and returns a bounded turn diff summary.
    public func createCheckpointAfter(
        worktree: URL,
        threadID: String,
        turnID: String,
        before: GitCheckpointSnapshot
    ) async throws -> GitCheckpointBracket {
        let path = worktree.standardizedFileURL
        guard (try? await git(["rev-parse", "--is-inside-work-tree"], at: path)) == "true" else {
            throw DesktopGitControlError.invalidRepository
        }
        guard (try? await git(["rev-parse", "--verify", "\(before.ref)^{commit}"], at: path)) != nil else {
            throw DesktopGitControlError.invalidTarget
        }
        let ref = Self.checkpointRef(threadID: threadID, turnID: turnID, bracket: "after")
        let after = try await captureCheckpoint(at: path, ref: ref)
        let worktreeStat = try await git(
            ["diff", "--stat", before.worktreeTree, after.worktreeTree],
            at: path,
            preserveWhitespace: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexStat = try await git(
            ["diff", "--stat", before.indexTree, after.indexTree],
            at: path,
            preserveWhitespace: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeSummary = try await git(
            ["diff", "--name-status", before.worktreeTree, after.worktreeTree],
            at: path,
            preserveWhitespace: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexSummary = try await git(
            ["diff", "--name-status", before.indexTree, after.indexTree],
            at: path,
            preserveWhitespace: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return GitCheckpointBracket(
            after: after,
            diffStat: String(Self.layeredDiff(worktree: worktreeStat, index: indexStat).suffix(8_192)),
            diffSummary: String(Self.layeredDiff(worktree: worktreeSummary, index: indexSummary).suffix(8_192))
        )
    }

    /// Restores the worktree to the checkpoint before-ref. Requires an exact
    /// revertCheckpoint grant and never touches the primary checkout.
    public func revertToCheckpoint(
        worktree: URL,
        target: GitCheckpointRestoreTarget,
        grant: LocalGitMutationGrant
    ) async throws -> GitWorktreeSnapshot {
        let path = worktree.standardizedFileURL
        try validateManagedTarget(path)
        guard grant.kind == .revertCheckpoint,
              path.path == target.worktreePath,
              grant.exactTarget == target.approvalExactTarget,
              grant.expiresAtUnixMillis.map({ $0 >= Int64(Date().timeIntervalSince1970 * 1_000) }) ?? true else {
            throw DesktopGitControlError.approvalMismatch
        }
        try await validateStoredCheckpoint(target.before, at: path)
        try await validateStoredCheckpoint(target.after, at: path)
        let current = try await captureCheckpoint(at: path, ref: nil)
        guard current.fingerprint == target.after.fingerprint,
              current.headRevision == target.after.headRevision,
              current.indexTree == target.after.indexTree,
              current.worktreeTree == target.after.worktreeTree else {
            throw DesktopGitControlError.checkpointStateMismatch
        }

        // Use a disposable index representing the exact current worktree so
        // read-tree -u deletes only paths known to this checkpoint transition.
        // Ignored files were never added to either snapshot and are untouched.
        let temporaryIndex = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: temporaryIndex) }
        let temporaryEnvironment = ["GIT_INDEX_FILE": temporaryIndex.path]
        do {
            try await restoreSnapshot(
                target.before,
                fromWorktreeTree: current.worktreeTree,
                at: path,
                temporaryEnvironment: temporaryEnvironment
            )
            _ = try await git(
                ["update-ref", "HEAD", target.before.headRevision, current.headRevision],
                at: path,
                preserveWhitespace: true
            )
            let restored = try await captureCheckpoint(at: path, ref: nil)
            guard Self.sameState(restored, target.before) else {
                throw DesktopGitControlError.checkpointStateMismatch
            }
        } catch {
            // The after ref remains durable independently of this best-effort
            // rollback. Restore HEAD plus both visible layers before reporting
            // failure, but never overwrite an unrelated concurrent HEAD.
            do {
                let observedHead = try await git(["rev-parse", "HEAD"], at: path)
                if observedHead == target.before.headRevision,
                   target.before.headRevision != current.headRevision {
                    _ = try await git(
                        ["update-ref", "HEAD", current.headRevision, target.before.headRevision],
                        at: path,
                        preserveWhitespace: true
                    )
                } else if observedHead != current.headRevision {
                    throw DesktopGitControlError.commandFailed(
                        "HEAD changed concurrently to \(observedHead); Kaname did not overwrite it."
                    )
                }
                try await restoreSnapshot(
                    current,
                    fromWorktreeTree: target.before.worktreeTree,
                    at: path,
                    temporaryEnvironment: temporaryEnvironment
                )
                let rolledBack = try await captureCheckpoint(at: path, ref: nil)
                guard Self.sameState(rolledBack, current) else {
                    throw DesktopGitControlError.checkpointStateMismatch
                }
            } catch let rollbackError {
                throw DesktopGitControlError.commandFailed(
                    "Checkpoint restore failed and automatic rollback also failed. The recoverable after snapshot remains at \(target.after.ref). Restore error: \(error.localizedDescription). Rollback error: \(rollbackError.localizedDescription)"
                )
            }
            throw DesktopGitControlError.commandFailed(
                "Checkpoint restore failed; Kaname restored the captured after-state. \(error.localizedDescription)"
            )
        }
        return try await inspect(worktree: path)
    }

    private func restoreSnapshot(
        _ snapshot: GitCheckpointSnapshot,
        fromWorktreeTree: String,
        at path: URL,
        temporaryEnvironment: [String: String]
    ) async throws {
        _ = try await git(
            ["read-tree", fromWorktreeTree],
            at: path,
            environmentOverrides: temporaryEnvironment
        )
        _ = try await git(
            ["read-tree", "--reset", "-u", snapshot.worktreeTree],
            at: path,
            environmentOverrides: temporaryEnvironment
        )
        _ = try await git(["read-tree", snapshot.indexTree], at: path)
    }

    private static func layeredDiff(worktree: String, index: String) -> String {
        var sections: [String] = []
        if !worktree.isEmpty { sections.append("Worktree:\n\(worktree)") }
        if !index.isEmpty { sections.append("Index:\n\(index)") }
        return sections.joined(separator: "\n")
    }

    private static func sameState(_ lhs: GitCheckpointSnapshot, _ rhs: GitCheckpointSnapshot) -> Bool {
        lhs.headRevision == rhs.headRevision
            && lhs.indexTree == rhs.indexTree
            && lhs.worktreeTree == rhs.worktreeTree
            && lhs.fingerprint == rhs.fingerprint
    }

    private func validateStoredCheckpoint(_ snapshot: GitCheckpointSnapshot, at path: URL) async throws {
        guard Self.checkpointFingerprint(
            headRevision: snapshot.headRevision,
            indexTree: snapshot.indexTree,
            worktreeTree: snapshot.worktreeTree
        ) == snapshot.fingerprint,
              (try? await git(["rev-parse", "--verify", "\(snapshot.ref)^{commit}"], at: path)) != nil,
              (try? await git(["rev-parse", "\(snapshot.ref)^{tree}"], at: path)) == snapshot.worktreeTree,
              (try? await git(["rev-parse", "\(snapshot.ref)^1^{tree}"], at: path)) == snapshot.indexTree,
              (try? await git(["rev-parse", "\(snapshot.ref)~2"], at: path)) == snapshot.headRevision else {
            throw DesktopGitControlError.invalidTarget
        }
    }

    public static func checkpointRef(threadID: String, turnID: String, bracket: String) -> String {
        let safeThread = sanitizeRefComponent(threadID)
        let safeTurn = sanitizeRefComponent(turnID)
        let safeBracket = sanitizeRefComponent(bracket)
        return "refs/kaname/checkpoints/\(safeThread)/\(safeTurn)/\(safeBracket)"
    }

    private static func sanitizeRefComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return String(filtered.prefix(120))
    }

    private func captureCheckpoint(at path: URL, ref: String?) async throws -> GitCheckpointSnapshot {
        let head = try await git(["rev-parse", "HEAD"], at: path)
        let indexTree = try await git(["write-tree"], at: path)
        let temporaryIndex = temporaryIndexURL()
        defer { try? FileManager.default.removeItem(at: temporaryIndex) }
        let temporaryEnvironment = ["GIT_INDEX_FILE": temporaryIndex.path]
        _ = try await git(["read-tree", "--reset", head], at: path, environmentOverrides: temporaryEnvironment)
        _ = try await git(["add", "-A", "--", "."], at: path, environmentOverrides: temporaryEnvironment)
        let worktreeTree = try await git(["write-tree"], at: path, environmentOverrides: temporaryEnvironment)
        let fingerprint = Self.checkpointFingerprint(
            headRevision: head,
            indexTree: indexTree,
            worktreeTree: worktreeTree
        )
        let storedRef: String
        if let ref {
            let identity = [
                "GIT_AUTHOR_NAME": "Kaname Checkpoint",
                "GIT_AUTHOR_EMAIL": "checkpoint@kaname.invalid",
                "GIT_COMMITTER_NAME": "Kaname Checkpoint",
                "GIT_COMMITTER_EMAIL": "checkpoint@kaname.invalid",
            ]
            let indexCommit = try await git(
                ["commit-tree", indexTree, "-p", head, "-m", "Kaname checkpoint index \(fingerprint)"],
                at: path,
                environmentOverrides: identity
            )
            let snapshotCommit = try await git(
                ["commit-tree", worktreeTree, "-p", indexCommit, "-m", "Kaname checkpoint worktree \(fingerprint)"],
                at: path,
                environmentOverrides: identity
            )
            _ = try await git(["update-ref", ref, snapshotCommit], at: path, preserveWhitespace: true)
            storedRef = ref
        } else {
            storedRef = ""
        }
        return GitCheckpointSnapshot.captured(
            ref: storedRef,
            headRevision: head,
            indexTree: indexTree,
            worktreeTree: worktreeTree,
            fingerprint: fingerprint
        )
    }

    private static func checkpointFingerprint(
        headRevision: String,
        indexTree: String,
        worktreeTree: String
    ) -> String {
        let payload = Data("checkpoint-v1\0\(headRevision)\0\(indexTree)\0\(worktreeTree)".utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kaname-checkpoint-index-\(UUID().uuidString)")
    }

    private func git(
        _ arguments: [String],
        at directory: URL,
        preserveWhitespace: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) async throws -> String {
        do {
            let output = try await LocalProcess.capture(
                executable: "git",
                arguments: arguments,
                workingDirectory: directory,
                timeout: timeout,
                environmentOverrides: environmentOverrides,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals(),
                maximumOutputBytes: 1_048_576
            )
            guard output.exitStatus == 0,
                  !output.standardOutputWasTruncated,
                  !output.standardErrorWasTruncated else {
                let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ProviderConnectivityError.processExited(
                    command: (["git"] + arguments).joined(separator: " "),
                    status: output.exitStatus,
                    detail: detail.isEmpty ? nil : String(detail.prefix(4_096))
                )
            }
            return preserveWhitespace
                ? output.standardOutput
                : output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
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
