import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopCodingControlViewModel: ObservableObject {
    @Published private(set) var busyWorktreeIDs: Set<String> = []
    @Published private(set) var changedPathsByWorktreeID: [String: [String]] = [:]
    @Published private(set) var message: String?

    private let service: DesktopGitControlService

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
        perform(worktree: worktree, model: model, initialState: .preparing) { service in
            let snapshot = try await service.createWorktree(
                repository: URL(fileURLWithPath: worktree.rootWorkspacePath, isDirectory: true),
                target: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                branch: worktree.branch,
                baseRevision: worktree.baseRevision,
                grant: LocalGitMutationGrant(
                    approvalID: approval.id,
                    kind: .createWorktree,
                    exactTarget: approval.exactTarget
                )
            )
            return (snapshot, "Created with local approval \(approval.id).")
        }
    }

    func refresh(model: DesktopAppModel, worktree: DesktopWorktreeRecord) {
        perform(worktree: worktree, model: model, initialState: worktree.state) { service in
            let snapshot = try await service.inspect(
                worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                rootRepository: URL(fileURLWithPath: worktree.rootWorkspacePath, isDirectory: true)
            )
            return (snapshot, "Reconciled local Git state.")
        }
    }

    func runVerification(model: DesktopAppModel, worktree: DesktopWorktreeRecord, command: String) {
        guard !busyWorktreeIDs.contains(worktree.id) else { return }
        busyWorktreeIDs.insert(worktree.id)
        model.updateWorktree(
            id: worktree.id,
            headRevision: worktree.headRevision,
            changedFileCount: worktree.changedFileCount,
            diffSummary: worktree.diffSummary,
            testCommand: command,
            testSummary: "Running…",
            state: worktree.state
        )
        Task {
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
            busyWorktreeIDs.remove(worktree.id)
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
        guard !busyWorktreeIDs.contains(worktree.id) else { return }
        busyWorktreeIDs.insert(worktree.id)
        Task {
            do {
                let snapshot = try await service.createSignedCommit(
                    worktree: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true),
                    relativePaths: paths,
                    message: clean,
                    grant: LocalGitMutationGrant(approvalID: approval.id, kind: .commit, exactTarget: approval.exactTarget)
                )
                changedPathsByWorktreeID[worktree.id] = snapshot.changedFiles
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: snapshot.headRevision,
                    changedFileCount: snapshot.changedFiles.count,
                    diffSummary: snapshot.diffSummary.isEmpty ? "Working tree clean after signed commit" : snapshot.diffSummary,
                    diagnosticSummary: "Signed local commit created with approval \(approval.id).",
                    state: snapshot.changedFiles.isEmpty ? .review : .dirty
                )
                self.message = "Signed local commit created; nothing was pushed."
            } catch {
                self.message = error.localizedDescription
            }
            busyWorktreeIDs.remove(worktree.id)
        }
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

    private func perform(
        worktree: DesktopWorktreeRecord,
        model: DesktopAppModel,
        initialState: DesktopWorktreeState,
        operation: @escaping @Sendable (DesktopGitControlService) async throws -> (GitWorktreeSnapshot, String)
    ) {
        guard !busyWorktreeIDs.contains(worktree.id) else { return }
        busyWorktreeIDs.insert(worktree.id)
        model.updateWorktree(
            id: worktree.id,
            headRevision: worktree.headRevision,
            changedFileCount: worktree.changedFileCount,
            diffSummary: worktree.diffSummary,
            state: initialState
        )
        Task {
            do {
                let (snapshot, detail) = try await operation(service)
                changedPathsByWorktreeID[worktree.id] = snapshot.changedFiles
                model.updateWorktree(
                    id: worktree.id,
                    headRevision: snapshot.headRevision,
                    changedFileCount: snapshot.changedFiles.count,
                    diffSummary: snapshot.diffSummary.isEmpty ? "Working tree clean" : snapshot.diffSummary,
                    diagnosticSummary: detail,
                    state: snapshot.changedFiles.isEmpty ? .ready : .dirty
                )
                message = detail
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
            busyWorktreeIDs.remove(worktree.id)
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
