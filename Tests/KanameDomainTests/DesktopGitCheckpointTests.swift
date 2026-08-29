import Foundation
import Testing
@testable import KanameConnectivity

struct DesktopGitCheckpointTests {
    @Test
    func checkpointRestoresTrackedStagedUnstagedAndUntrackedStateWithoutDeletingIgnoredFiles() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        try fixture.write("tracked.txt", "base\nbefore unstaged\n")
        try fixture.write("staged.txt", "base\nstaged before\n")
        try await fixture.git(["add", "staged.txt"])
        try fixture.write("staged.txt", "base\nstaged before\nbefore unstaged tail\n")
        try fixture.write("before-untracked.txt", "keep me\n")

        let before = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "thread-1",
            turnID: "turn-1"
        )

        try fixture.write("tracked.txt", "base\nprovider edit\n")
        try fixture.write("staged.txt", "base\nprovider edit\n")
        try FileManager.default.removeItem(at: fixture.url("before-untracked.txt"))
        try fixture.write("turn-untracked.txt", "remove me\n")
        let bracket = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "thread-1",
            turnID: "turn-1",
            before: before
        )
        #expect(bracket.diffSummary.contains("tracked.txt"))
        #expect(bracket.diffSummary.contains("before-untracked.txt"))
        #expect(bracket.diffSummary.contains("turn-untracked.txt"))

        // Ignored state is intentionally outside the checkpoint contract and
        // must not be collateral damage during a valid restore.
        try fixture.write("ignored.log", "local cache\n")
        let target = GitCheckpointRestoreTarget(
            checkpointID: "checkpoint-turn-1",
            worktreePath: fixture.repository.path,
            before: before,
            after: bracket.after
        )
        _ = try await fixture.service.revertToCheckpoint(
            worktree: fixture.repository,
            target: target,
            grant: LocalGitMutationGrant(
                approvalID: "approved",
                kind: .revertCheckpoint,
                exactTarget: target.approvalExactTarget
            )
        )

        #expect(try fixture.read("tracked.txt") == "base\nbefore unstaged\n")
        #expect(try fixture.read("staged.txt") == "base\nstaged before\nbefore unstaged tail\n")
        #expect(try fixture.read("before-untracked.txt") == "keep me\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("turn-untracked.txt").path))
        #expect(try fixture.read("ignored.log") == "local cache\n")

        let stagedPatch = try await fixture.git(["diff", "--cached", "--", "staged.txt"])
        let unstagedPatch = try await fixture.git(["diff", "--", "staged.txt"])
        let status = try await fixture.git(["status", "--porcelain=v1", "--untracked-files=all"])
        #expect(stagedPatch.contains("+staged before"))
        #expect(unstagedPatch.contains("+before unstaged tail"))
        #expect(status.contains(" M tracked.txt"))
        #expect(status.contains("MM staged.txt"))
        #expect(status.contains("?? before-untracked.txt"))
        #expect(!status.contains("turn-untracked.txt"))
        #expect(!status.contains("ignored.log"))
    }

    @Test
    func checkpointRefPreservesProviderCommitAndMultipleTurnsCanBeRestoredInOrder() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let initialHead = try await fixture.git(["rev-parse", "HEAD"])

        let beforeFirst = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "first"
        )
        try fixture.write("tracked.txt", "base\ncommitted by provider\n")
        try await fixture.git(["add", "tracked.txt"])
        try await fixture.commit("provider commit")
        let providerHead = try await fixture.git(["rev-parse", "HEAD"])
        let afterFirst = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "first",
            before: beforeFirst
        )
        #expect(afterFirst.after.headRevision == providerHead)

        let beforeSecond = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "second"
        )
        try fixture.write("tracked.txt", "base\ncommitted by provider\nsecond turn\n")
        try fixture.write("second.txt", "second\n")
        let afterSecond = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "second",
            before: beforeSecond
        )

        try await fixture.restore(id: "second", before: beforeSecond, after: afterSecond.after)
        #expect(try await fixture.git(["rev-parse", "HEAD"]) == providerHead)
        #expect(try fixture.read("tracked.txt") == "base\ncommitted by provider\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("second.txt").path))

        try await fixture.restore(id: "first", before: beforeFirst, after: afterFirst.after)
        #expect(try await fixture.git(["rev-parse", "HEAD"]) == initialHead)
        #expect(try fixture.read("tracked.txt") == "base\n")
    }

    @Test
    func staleCurrentStateAndWrongWorktreeApprovalFailBeforeMutation() async throws {
        let fixture = try await Fixture.make()
        let other = try await Fixture.make()
        defer {
            try? FileManager.default.removeItem(at: fixture.sandbox)
            try? FileManager.default.removeItem(at: other.sandbox)
        }

        let before = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "turn"
        )
        try fixture.write("tracked.txt", "after\n")
        let bracket = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "turn",
            before: before
        )
        let target = GitCheckpointRestoreTarget(
            checkpointID: "checkpoint-turn",
            worktreePath: fixture.repository.path,
            before: before,
            after: bracket.after
        )

        try fixture.write("late.txt", "do not delete\n")
        await expectRevertFailure(
            .checkpointStateMismatch,
            fixture: fixture,
            target: target,
            approvalID: "approved"
        )
        #expect(try fixture.read("tracked.txt") == "after\n")
        #expect(try fixture.read("late.txt") == "do not delete\n")

        await expectRevertFailure(
            .approvalMismatch,
            fixture: other,
            target: target,
            approvalID: "approved"
        )
        #expect(try other.read("tracked.txt") == "base\n")
    }

    @Test
    func checkpointReportsPureIndexChangesAndRejectsExpiredGrant() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        try fixture.write("index-only.txt", "same worktree bytes\n")
        let before = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "index-only"
        )
        try await fixture.git(["add", "index-only.txt"])
        let bracket = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "thread",
            turnID: "index-only",
            before: before
        )
        #expect(bracket.diffSummary.contains("Index:"))
        #expect(bracket.diffSummary.contains("index-only.txt"))

        let target = GitCheckpointRestoreTarget(
            checkpointID: "checkpoint-index-only",
            worktreePath: fixture.repository.path,
            before: before,
            after: bracket.after
        )
        await expectRevertFailure(
            .approvalMismatch,
            fixture: fixture,
            target: target,
            approvalID: "expired",
            expiresAtUnixMillis: 1
        )
        let status = try await fixture.git(["status", "--porcelain=v1", "--untracked-files=all"])
        #expect(status.contains("A  index-only.txt"))
    }

    private func expectRevertFailure(
        _ expected: DesktopGitControlError,
        fixture: Fixture,
        target: GitCheckpointRestoreTarget,
        approvalID: String,
        expiresAtUnixMillis: Int64? = nil
    ) async {
        await #expect(throws: expected) {
            try await fixture.service.revertToCheckpoint(
                worktree: fixture.repository,
                target: target,
                grant: LocalGitMutationGrant(
                    approvalID: approvalID,
                    kind: .revertCheckpoint,
                    exactTarget: target.approvalExactTarget,
                    expiresAtUnixMillis: expiresAtUnixMillis
                )
            )
        }
    }

    private struct Fixture {
        let sandbox: URL
        let repository: URL
        let service: DesktopGitControlService

        static func make() async throws -> Fixture {
            let sandbox = FileManager.default.temporaryDirectory
                .appending(path: "kaname-checkpoint-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            let managedRoot = sandbox.appending(path: "managed", directoryHint: .isDirectory)
            let repository = managedRoot.appending(path: "repository", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let fixture = Fixture(
                sandbox: sandbox,
                repository: repository,
                service: DesktopGitControlService(managedRoot: managedRoot, timeout: .seconds(10))
            )
            try await fixture.git(["init", "-b", "main"])
            try fixture.write(".gitignore", "*.log\n")
            try fixture.write("tracked.txt", "base\n")
            try fixture.write("staged.txt", "base\n")
            try await fixture.git(["add", ".gitignore", "tracked.txt", "staged.txt"])
            try await fixture.commit("initial")
            return fixture
        }

        func url(_ path: String) -> URL { repository.appending(path: path) }

        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: url(path))
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: url(path), encoding: .utf8)
        }

        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            let output = try await LocalProcess.capture(
                executable: "git",
                arguments: arguments,
                workingDirectory: repository,
                timeout: .seconds(10),
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals()
            )
            guard output.exitStatus == 0 else {
                throw DesktopGitControlError.commandFailed(output.standardError)
            }
            return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func commit(_ message: String) async throws {
            try await git([
                "-c", "user.name=Kaname Test",
                "-c", "user.email=test@kaname.invalid",
                "-c", "commit.gpgsign=false",
                "commit", "-m", message,
            ])
        }

        func restore(id: String, before: GitCheckpointSnapshot, after: GitCheckpointSnapshot) async throws {
            let target = GitCheckpointRestoreTarget(
                checkpointID: id,
                worktreePath: repository.path,
                before: before,
                after: after
            )
            _ = try await service.revertToCheckpoint(
                worktree: repository,
                target: target,
                grant: LocalGitMutationGrant(
                    approvalID: "approved-\(id)",
                    kind: .revertCheckpoint,
                    exactTarget: target.approvalExactTarget
                )
            )
        }
    }
}
