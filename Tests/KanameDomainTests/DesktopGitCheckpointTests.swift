import Foundation
import Testing
@testable import KanameConnectivity

struct DesktopGitCheckpointTests {
    @Test
    func sharedServiceSerializesConcurrentCaptureAndRevertAtTheTransactionBoundary() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }

        try fixture.write("tracked.txt", "before tracked\n")
        try fixture.write("staged.txt", "before staged\n")
        try await fixture.git(["add", "staged.txt"])
        try fixture.write("before-only.txt", "before untracked\n")
        let before = try await fixture.service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "shared-service",
            turnID: "revert-target"
        )

        try fixture.write("tracked.txt", "after tracked\n")
        try fixture.write("staged.txt", "after staged\n")
        try FileManager.default.removeItem(at: fixture.url("before-only.txt"))
        try fixture.write("after-only.txt", "after untracked\n")
        let bracket = try await fixture.service.createCheckpointAfter(
            worktree: fixture.repository,
            threadID: "shared-service",
            turnID: "revert-target",
            before: before
        )
        let aliasedRepository = fixture.managedRoot.appending(
            path: "repository-alias",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: aliasedRepository,
            withDestinationURL: fixture.repository
        )
        let target = GitCheckpointRestoreTarget(
            checkpointID: "checkpoint-shared-service",
            worktreePath: aliasedRepository.path,
            before: before,
            after: bracket.after
        )

        let gate = DesktopGitCheckpointTransactionGate()
        let barrier = GitProcessBarrier()
        let service = fixture.controlledService(gate: gate, barrier: barrier)
        await barrier.blockNextProcess()
        let concurrentCapture = Task {
            try await service.createCheckpointBefore(
                worktree: fixture.repository,
                threadID: "shared-service",
                turnID: "concurrent-capture"
            )
        }
        await barrier.waitUntilBlocked()

        let revert = Task {
            try await service.revertToCheckpoint(
                worktree: aliasedRepository,
                target: target,
                grant: LocalGitMutationGrant(
                    approvalID: "approved-shared-service",
                    kind: .revertCheckpoint,
                    exactTarget: target.approvalExactTarget
                )
            )
        }
        await gate.waitUntilQueued(worktreePath: fixture.repository.standardizedFileURL.path)

        #expect(await barrier.processCount == 1)
        await barrier.releaseBlockedProcess()
        let captured = try await concurrentCapture.value
        _ = try await revert.value

        #expect(captured.fingerprint == bracket.after.fingerprint)
        #expect(try fixture.read("tracked.txt") == "before tracked\n")
        #expect(try fixture.read("staged.txt") == "before staged\n")
        #expect(try fixture.read("before-only.txt") == "before untracked\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("after-only.txt").path))
        let status = try await fixture.git(["status", "--porcelain=v1", "--untracked-files=all"])
        #expect(status.contains(" M tracked.txt"))
        #expect(status.contains("M  staged.txt"))
        #expect(status.contains("?? before-only.txt"))
        #expect(!status.contains("after-only.txt"))
    }

    @Test
    func checkpointTransactionCancellationAndFailureReleaseTheNextWaiter() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.sandbox) }
        let gate = DesktopGitCheckpointTransactionGate()
        let barrier = GitProcessBarrier()
        let service = fixture.controlledService(gate: gate, barrier: barrier)
        let path = fixture.repository.standardizedFileURL.path

        await barrier.blockNextProcess()
        let active = Task {
            try await service.createCheckpointBefore(
                worktree: fixture.repository,
                threadID: "shared-service",
                turnID: "active"
            )
        }
        await barrier.waitUntilBlocked()

        let cancelled = Task {
            try await service.createCheckpointBefore(
                worktree: fixture.repository,
                threadID: "shared-service",
                turnID: "cancelled"
            )
        }
        await gate.waitUntilQueued(worktreePath: path)
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }

        let successor = Task {
            try await service.createCheckpointBefore(
                worktree: fixture.repository,
                threadID: "shared-service",
                turnID: "successor"
            )
        }
        await gate.waitUntilQueued(worktreePath: path)
        #expect(await barrier.processCount == 1)
        active.cancel()
        await #expect(throws: (any Error).self) { try await active.value }
        _ = try await successor.value

        await barrier.failNextProcess()
        await #expect(throws: (any Error).self) {
            try await service.createCheckpointBefore(
                worktree: fixture.repository,
                threadID: "shared-service",
                turnID: "failure"
            )
        }
        _ = try await service.createCheckpointBefore(
            worktree: fixture.repository,
            threadID: "shared-service",
            turnID: "after-failure"
        )
    }

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
        let managedRoot: URL
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
                managedRoot: managedRoot,
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

        func controlledService(
            gate: DesktopGitCheckpointTransactionGate,
            barrier: GitProcessBarrier
        ) -> DesktopGitControlService {
            DesktopGitControlService(
                managedRoot: managedRoot,
                timeout: .seconds(10),
                checkpointTransactions: gate,
                beforeGitProcess: { invocation in
                    try await barrier.intercept(invocation)
                }
            )
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

    private actor GitProcessBarrier {
        enum InjectedFailure: Error { case requested }

        private var shouldBlockNextProcess = false
        private var shouldFailNextProcess = false
        private var blockedContinuation: CheckedContinuation<Bool, Never>?
        private var blockedObservers: [CheckedContinuation<Void, Never>] = []
        private(set) var processCount = 0

        func blockNextProcess() {
            shouldBlockNextProcess = true
        }

        func failNextProcess() {
            shouldFailNextProcess = true
        }

        func intercept(_ invocation: DesktopGitProcessInvocation) async throws {
            _ = invocation
            processCount += 1
            if shouldFailNextProcess {
                shouldFailNextProcess = false
                throw InjectedFailure.requested
            }
            guard shouldBlockNextProcess else { return }
            shouldBlockNextProcess = false
            let shouldContinue = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                    let observers = blockedObservers
                    blockedObservers.removeAll()
                    observers.forEach { $0.resume() }
                }
            } onCancel: {
                Task { await self.cancelBlockedProcess() }
            }
            guard shouldContinue else { throw CancellationError() }
        }

        func waitUntilBlocked() async {
            if blockedContinuation != nil { return }
            await withCheckedContinuation { blockedObservers.append($0) }
        }

        func releaseBlockedProcess() {
            let continuation = blockedContinuation
            blockedContinuation = nil
            continuation?.resume(returning: true)
        }

        private func cancelBlockedProcess() {
            let continuation = blockedContinuation
            blockedContinuation = nil
            continuation?.resume(returning: false)
        }
    }
}
