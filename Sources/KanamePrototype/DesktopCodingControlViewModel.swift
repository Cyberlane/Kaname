import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopCodingControlViewModel: ObservableObject {
    @Published private(set) var busyWorktreeIDs: Set<String> = []
    @Published private(set) var changedPathsByWorktreeID: [String: [String]] = [:]
    @Published private(set) var message: String?

    private let service: DesktopGitControlService

    private struct GitMutationOutcome: Sendable {
        var snapshot: GitWorktreeSnapshot
        var userMessage: String
        var diagnosticSummary: String
        var emptyDiffSummary: String = "Working tree clean"
        var cleanState: DesktopWorktreeState = .ready

        static func messaging(
            snapshot: GitWorktreeSnapshot,
            userMessage: String,
            diagnosticSummary: String? = nil
        ) -> GitMutationOutcome {
            let detail = diagnosticSummary ?? userMessage
            return GitMutationOutcome(
                snapshot: snapshot,
                userMessage: userMessage,
                diagnosticSummary: detail
            )
        }
    }

    private enum ManagedGitMutation: Sendable {
        case create(approvalID: String, exactTarget: String)
        case refresh
        case commit(approvalID: String, exactTarget: String, paths: [String], message: String)
        case revertCheckpoint(
            approvalID: String,
            exactTarget: String,
            expiresAtUnixMillis: Int64?,
            target: GitCheckpointRestoreTarget
        )
    }

    init(environment: KanameDesktopEnvironment = .current) {
        service = DesktopGitControlService(managedRoot: environment.worktreeDirectory)
    }

    func requestCreationApproval(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        guard approval(model: model, worktree: worktree, action: "Create isolated worktree") == nil else { return }
        _ = model.createApproval(
            threadID: worktree.threadID,
            title: "Create isolated worktree",
            exactTarget: worktree.worktreePath,
            consequence: "Create branch \(worktree.branch) from \(worktree.baseRevision) in Kaname's managed worktree directory.",
            dataLeavingDevice: "None",
            reversible: true,
            expiresAtUnixMillis: nil
        )
        message = "Creation approval is ready in Inbox."
    }

    func create(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        guard let approval = approved(model: model, worktree: worktree, action: "Create isolated worktree") else {
            message = "Approve this exact worktree creation in Inbox first."
            return
        }
        perform(
            worktree: worktree,
            model: model,
            initialState: .preparing,
            mutation: .create(approvalID: approval.id, exactTarget: approval.exactTarget)
        )
    }

    func refresh(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        perform(worktree: worktree, model: model, initialState: worktree.state, mutation: .refresh)
    }

    func runVerification(model: DesktopAppModel, worktree: DesktopWorktreeRecord, command: String) {
        runWhileBusy(worktreeID: worktree.id) { [self] in
            model.updateWorktree(
                id: worktree.id,
                headRevision: worktree.headRevision,
                changedFileCount: worktree.changedFileCount,
                diffSummary: worktree.diffSummary,
                testCommand: command,
                testSummary: "Running…",
                state: worktree.state
            )
            do {
                let result = try await service.runVerification(
                    command: command,
                    worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
                )
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: worktree.headRevision,
                    changedFileCount: worktree.changedFileCount,
                    diffSummary: worktree.diffSummary,
                    testCommand: command,
                    testSummary: result.summary,
                    diagnosticSummary: result.succeeded ? "Command exited successfully." : "Command reported a failure.",
                    state: result.succeeded ? .review : .dirty
                )
                _ = model.recordQualityGate(
                    threadID: worktree.threadID,
                    worktreeID: worktree.id,
                    kind: .tests,
                    command: command,
                    summary: result.summary,
                    state: result.succeeded ? .completed : .failed
                )
                message = result.succeeded ? "Verification passed." : "Verification failed; the evidence is preserved."
            } catch {
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: worktree.headRevision,
                    changedFileCount: worktree.changedFileCount,
                    diffSummary: worktree.diffSummary,
                    testCommand: command,
                    testSummary: error.localizedDescription,
                    state: .failed
                )
                message = error.localizedDescription
            }
        }
    }

    func requestCommitApproval(model: DesktopAppModel, worktree: DesktopWorktreeRecord, message: String) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let paths = changedPathsByWorktreeID[worktree.id], !paths.isEmpty else {
            self.message = "Refresh the worktree and enter a commit message first."
            return
        }
        guard approval(model: model, worktree: worktree, action: "Create signed commit") == nil else { return }
        _ = model.createApproval(
            threadID: worktree.threadID,
            title: "Create signed commit",
            exactTarget: worktree.worktreePath,
            consequence: "Stage exactly \(paths.joined(separator: ", ")) and create a signed local commit: \(clean)",
            dataLeavingDevice: "None",
            reversible: true,
            expiresAtUnixMillis: nil
        )
        self.message = "Signed-commit approval is ready in Inbox."
    }

    func commit(model: DesktopAppModel, worktree: DesktopWorktreeRecord, message: String) {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let approval = approved(model: model, worktree: worktree, action: "Create signed commit"),
              let paths = changedPathsByWorktreeID[worktree.id], !paths.isEmpty, !clean.isEmpty else {
            self.message = "Approve the exact signed commit in Inbox first."
            return
        }
        perform(
            worktree: worktree,
            model: model,
            initialState: worktree.state,
            mutation: .commit(
                approvalID: approval.id,
                exactTarget: approval.exactTarget,
                paths: paths,
                message: clean
            )
        )
    }

    func requestCleanupApproval(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        guard approval(model: model, worktree: worktree, action: "Remove clean worktree") == nil else { return }
        _ = model.createApproval(
            threadID: worktree.threadID,
            title: "Remove clean worktree",
            exactTarget: worktree.worktreePath,
            consequence: "Remove this managed worktree only if Git confirms it has no uncommitted changes.",
            dataLeavingDevice: "None",
            reversible: false,
            expiresAtUnixMillis: nil
        )
        model.updateWorktree(
            id: worktree.id,
            headRevision: worktree.headRevision,
            changedFileCount: worktree.changedFileCount,
            diffSummary: worktree.diffSummary,
            state: .cleanupPending
        )
        message = "Cleanup approval is ready in Inbox."
    }

    func executeCheckpointRevert(
        model: DesktopAppModel,
        worktree: DesktopWorktreeRecord,
        checkpoint: DesktopCodingCheckpointRecord
    ) {
        guard let exactTarget = checkpoint.approvalExactTarget(worktreePath: worktree.worktreePath),
              let restoreTarget = checkpoint.restoreTarget(worktreePath: worktree.worktreePath) else {
            message = "This legacy checkpoint cannot be restored safely. Run a new implementation turn first."
            return
        }
        guard let approval = model.snapshot.operations.approvals.last(where: {
            $0.threadID == worktree.threadID
                && $0.exactTarget == exactTarget
                && $0.title == "Revert implementation turn"
                && $0.state == .approved
        }), model.isApprovalGranted(id: approval.id, exactTarget: exactTarget) else {
            message = "Approve the exact checkpoint revert in Inbox first."
            return
        }
        perform(
            worktree: worktree,
            model: model,
            initialState: worktree.state,
            mutation: .revertCheckpoint(
                approvalID: approval.id,
                exactTarget: approval.exactTarget,
                expiresAtUnixMillis: approval.expiresAtUnixMillis,
                target: restoreTarget
            )
        )
    }

    func cleanup(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        guard let approval = approved(model: model, worktree: worktree, action: "Remove clean worktree") else {
            message = "Approve this exact cleanup in Inbox first."
            return
        }
        guard !busyWorktreeIDs.contains(worktree.id) else { return }
        busyWorktreeIDs.insert(worktree.id)
        Task {
            do {
                try await service.removeWorktree(
                    repository: URL(fileURLWithPath: worktree.rootWorkspacePath, isDirectory: true),
                    target: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                    grant: LocalGitMutationGrant(
                        approvalID: approval.id,
                        kind: .cleanupWorktree,
                        exactTarget: approval.exactTarget
                    )
                )
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: worktree.headRevision,
                    changedFileCount: 0,
                    diffSummary: "Removed after clean-state verification.",
                    state: .removed
                )
                message = "The clean managed worktree was removed."
            } catch {
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: worktree.headRevision,
                    changedFileCount: worktree.changedFileCount,
                    diffSummary: worktree.diffSummary,
                    diagnosticSummary: error.localizedDescription,
                    state: error as? DesktopGitControlError == .worktreeDirty ? .dirty : .failed
                )
                message = error.localizedDescription
            }
            busyWorktreeIDs.remove(worktree.id)
        }
    }

    func approvalState(model: DesktopAppModel, worktree: DesktopWorktreeRecord, action: String) -> DesktopActionState? {
        approval(model: model, worktree: worktree, action: action)?.state
    }

    private func runWhileBusy(
        worktreeID: String,
        work: @escaping @MainActor () async -> Void
    ) {
        guard !busyWorktreeIDs.contains(worktreeID) else { return }
        busyWorktreeIDs.insert(worktreeID)
        Task {
            defer { busyWorktreeIDs.remove(worktreeID) }
            await work()
        }
    }

    private func perform(
        worktree: DesktopWorktreeRecord,
        model: DesktopAppModel,
        initialState: DesktopWorktreeState,
        mutation: ManagedGitMutation
    ) {
        runWhileBusy(worktreeID: worktree.id) { [self] in
            model.updateWorktree(
                id: worktree.id,
                headRevision: worktree.headRevision,
                changedFileCount: worktree.changedFileCount,
                diffSummary: worktree.diffSummary,
                state: initialState
            )
            await publishGitMutation(mutation, worktree: worktree, model: model)
        }
    }

    private func publishGitMutation(
        _ mutation: ManagedGitMutation,
        worktree: DesktopWorktreeRecord,
        model: DesktopAppModel
    ) async {
        do {
            let outcome = try await execute(mutation, worktree: worktree)
            changedPathsByWorktreeID[worktree.id] = outcome.snapshot.changedFiles
            let diff = outcome.snapshot.diffSummary.isEmpty
                ? outcome.emptyDiffSummary
                : outcome.snapshot.diffSummary
            let nextState = outcome.snapshot.changedFiles.isEmpty ? outcome.cleanState : .dirty
            model.updateWorktree(
                id: worktree.id,
                headRevision: outcome.snapshot.headRevision,
                changedFileCount: outcome.snapshot.changedFiles.count,
                diffSummary: diff,
                diagnosticSummary: outcome.diagnosticSummary,
                state: nextState
            )
            if case let .revertCheckpoint(approvalID, exactTarget, _, _) = mutation {
                guard model.consumeApproval(id: approvalID, exactTarget: exactTarget) else {
                    message = "The checkpoint was restored, but Kaname could not record one-shot approval consumption."
                    return
                }
            }
            message = outcome.userMessage
        } catch {
            model.updateWorktree(
                id: worktree.id,
                headRevision: worktree.headRevision,
                changedFileCount: worktree.changedFileCount,
                diffSummary: worktree.diffSummary,
                diagnosticSummary: error.localizedDescription,
                state: .failed
            )
            message = error.localizedDescription
        }
    }

    private func execute(
        _ mutation: ManagedGitMutation,
        worktree: DesktopWorktreeRecord
    ) async throws -> GitMutationOutcome {
        let worktreeURL = URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
        let rootURL = URL(fileURLWithPath: worktree.rootWorkspacePath, isDirectory: true)
        switch mutation {
        case let .create(approvalID, exactTarget):
            let snapshot = try await service.createWorktree(
                repository: rootURL,
                target: worktreeURL,
                branch: worktree.branch,
                baseRevision: worktree.baseRevision,
                grant: LocalGitMutationGrant(
                    approvalID: approvalID,
                    kind: .createWorktree,
                    exactTarget: exactTarget
                )
            )
            return .messaging(snapshot: snapshot, userMessage: "Created with local approval \(approvalID).")

        case .refresh:
            let snapshot = try await service.inspect(worktree: worktreeURL, rootRepository: rootURL)
            return .messaging(snapshot: snapshot, userMessage: "Reconciled local Git state.")

        case let .commit(approvalID, exactTarget, paths, message):
            let snapshot = try await service.createSignedCommit(
                worktree: worktreeURL,
                relativePaths: paths,
                message: message,
                grant: LocalGitMutationGrant(approvalID: approvalID, kind: .commit, exactTarget: exactTarget)
            )
            var outcome = GitMutationOutcome.messaging(
                snapshot: snapshot,
                userMessage: "Signed local commit created; nothing was pushed.",
                diagnosticSummary: "Signed local commit created with approval \(approvalID)."
            )
            outcome.emptyDiffSummary = "Working tree clean after signed commit"
            outcome.cleanState = .review
            return outcome

        case let .revertCheckpoint(approvalID, exactTarget, expiresAtUnixMillis, target):
            let snapshot = try await service.revertToCheckpoint(
                worktree: worktreeURL,
                target: target,
                grant: LocalGitMutationGrant(
                    approvalID: approvalID,
                    kind: .revertCheckpoint,
                    exactTarget: exactTarget,
                    expiresAtUnixMillis: expiresAtUnixMillis
                )
            )
            var outcome = GitMutationOutcome.messaging(
                snapshot: snapshot,
                userMessage: "Tracked and non-ignored files plus staged state were restored to the approved checkpoint. Ignored files and empty directories were left untouched.",
                diagnosticSummary: "Checkpoint revert executed with approval \(approvalID)."
            )
            outcome.emptyDiffSummary = "Restored to checkpoint \(target.before.ref)"
            return outcome
        }
    }

    private func approval(model: DesktopAppModel, worktree: DesktopWorktreeRecord, action: String) -> DesktopApprovalRecord? {
        model.snapshot.operations.approvals.last {
            $0.threadID == worktree.threadID && $0.exactTarget == worktree.worktreePath && $0.title == action
        }
    }

    private func approved(model: DesktopAppModel, worktree: DesktopWorktreeRecord, action: String) -> DesktopApprovalRecord? {
        approval(model: model, worktree: worktree, action: action).flatMap { $0.state == .approved ? $0 : nil }
    }
}
