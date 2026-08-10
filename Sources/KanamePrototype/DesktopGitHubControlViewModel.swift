import Foundation
import KanameConnectivity
import KanameDesktop

@MainActor
final class DesktopGitHubControlViewModel: ObservableObject {
    @Published private(set) var refreshingWorkspaceIDs: Set<String> = []
    @Published private(set) var busyActionIDs: Set<String> = []
    @Published private(set) var repositoryByWorkspaceID: [String: String] = [:]
    @Published private(set) var message: String?

    private let service = GitHubControlService()

    func refresh(model: DesktopAppModel, workspace: DesktopGitWorkspace) {
        guard !refreshingWorkspaceIDs.contains(workspace.id) else { return }
        refreshingWorkspaceIDs.insert(workspace.id)
        Task {
            do {
                let result = try await service.inspect(repository: URL(fileURLWithPath: workspace.localPath, isDirectory: true))
                repositoryByWorkspaceID[workspace.id] = result.repository
                let stackLayers = model.snapshot.operations.gitStackLayers.filter { $0.workspaceID == workspace.id }
                let records = Self.records(result: result, stackLayers: stackLayers)
                model.replacePullRequests(workspaceID: workspace.id, records: records)
                message = "Reconciled \(records.count) pull request\(records.count == 1 ? "" : "s") for \(result.repository)."
            } catch {
                message = error.localizedDescription
            }
            refreshingWorkspaceIDs.remove(workspace.id)
        }
    }

    func requestPullRequestApproval(model: DesktopAppModel, workspace: DesktopGitWorkspace, layer: DesktopGitStackLayer) {
        guard let repository = repositoryByWorkspaceID[workspace.id] else {
            message = "Reconcile pull requests first so Kaname can resolve the exact repository."
            return
        }
        let target = GitHubControlService.pullRequestTarget(repository: repository, head: layer.branch, base: layer.baseBranch)
        guard approval(model: model, title: "Create pull request", target: target) == nil else { return }
        _ = model.createApproval(
            threadID: nil,
            title: "Create pull request",
            exactTarget: target,
            consequence: "Create a GitHub pull request titled \(layer.title) from \(layer.branch) into \(layer.baseBranch).",
            dataLeavingDevice: "Branch names, title, generated PR body, and repository identity",
            reversible: true,
            expiresAtUnixMillis: nil
        )
        message = "Pull-request approval is ready in Inbox."
    }

    func createPullRequest(model: DesktopAppModel, workspace: DesktopGitWorkspace, layer: DesktopGitStackLayer) {
        guard let repository = repositoryByWorkspaceID[workspace.id] else { return }
        let target = GitHubControlService.pullRequestTarget(repository: repository, head: layer.branch, base: layer.baseBranch)
        guard let approval = approved(model: model, title: "Create pull request", target: target) else {
            message = "Approve this exact pull request in Inbox first."
            return
        }
        guard !busyActionIDs.contains(layer.id) else { return }
        busyActionIDs.insert(layer.id)
        model.updateGitStackLayer(id: layer.id, pullRequestURL: nil, checkSummary: "Creating…", reviewSummary: "No remote review", state: .running)
        Task {
            do {
                let url = try await service.createPullRequest(
                    repository: repository,
                    localRepository: URL(fileURLWithPath: workspace.localPath, isDirectory: true),
                    head: layer.branch,
                    base: layer.baseBranch,
                    title: layer.title,
                    body: "Created through Kaname after exact local approval \(approval.id).",
                    grant: LocalGitMutationGrant(approvalID: approval.id, kind: .createPullRequest, exactTarget: target)
                )
                model.updateGitStackLayer(id: layer.id, pullRequestURL: url, checkSummary: "Pending reconciliation", reviewSummary: "No remote review", state: .completed)
                message = "Pull request created and recorded; reconcile to verify checks and review state."
                refresh(model: model, workspace: workspace)
            } catch {
                model.updateGitStackLayer(id: layer.id, pullRequestURL: nil, checkSummary: error.localizedDescription, reviewSummary: "Not created", state: .failed)
                message = error.localizedDescription
            }
            busyActionIDs.remove(layer.id)
        }
    }

    func requestMergeApproval(model: DesktopAppModel, pullRequest: DesktopPullRequestRecord) {
        let target = GitHubControlService.mergeTarget(repository: pullRequest.repository, number: pullRequest.number)
        guard approval(model: model, title: "Merge pull request", target: target) == nil else { return }
        _ = model.createApproval(
            threadID: nil,
            title: "Merge pull request",
            exactTarget: target,
            consequence: "Merge pull request #\(pullRequest.number) only after Kaname rechecks its current head, required checks, review state, and stack predecessors.",
            dataLeavingDevice: "Repository and pull-request identity",
            reversible: false,
            expiresAtUnixMillis: nil
        )
        message = "Merge approval is ready in Inbox."
    }

    func merge(model: DesktopAppModel, workspace: DesktopGitWorkspace, pullRequest: DesktopPullRequestRecord) {
        let target = GitHubControlService.mergeTarget(repository: pullRequest.repository, number: pullRequest.number)
        guard let approval = approved(model: model, title: "Merge pull request", target: target) else {
            message = "Approve this exact merge in Inbox first."
            return
        }
        let dependenciesMerged = pullRequest.mergeAfterIDs.allSatisfy { dependencyID in
            model.snapshot.operations.pullRequests.first { $0.id == dependencyID }?.state == .completed
        }
        guard !busyActionIDs.contains(pullRequest.id) else { return }
        busyActionIDs.insert(pullRequest.id)
        Task {
            do {
                try await service.mergePullRequest(
                    repository: pullRequest.repository,
                    number: pullRequest.number,
                    localRepository: URL(fileURLWithPath: workspace.localPath, isDirectory: true),
                    dependenciesAreMerged: dependenciesMerged,
                    grant: LocalGitMutationGrant(approvalID: approval.id, kind: .mergePullRequest, exactTarget: target)
                )
                message = "Pull request merged at its revalidated head."
                refresh(model: model, workspace: workspace)
            } catch {
                message = error.localizedDescription
            }
            busyActionIDs.remove(pullRequest.id)
        }
    }

    func approvalState(model: DesktopAppModel, title: String, target: String) -> DesktopActionState? {
        approval(model: model, title: title, target: target)?.state
    }

    private static func actionState(_ state: String) -> DesktopActionState {
        switch state.uppercased() {
        case "MERGED", "CLOSED": .completed
        case "OPEN": .running
        default: .reconciled
        }
    }

    private static func records(
        result: GitHubRepositorySnapshot,
        stackLayers: [DesktopGitStackLayer]
    ) -> [DesktopPullRequestReconciliation] {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        return result.pullRequests.map { pullRequest in
            let dependencyIDs: [String]
            if let layer = stackLayers.first(where: { $0.branch == pullRequest.headBranch }),
               let dependencyLayerID = layer.dependsOnLayerID,
               let dependencyURL = stackLayers.first(where: { $0.id == dependencyLayerID })?.pullRequestURL,
               let dependency = result.pullRequests.first(where: { $0.url == dependencyURL }) {
                dependencyIDs = ["\(result.repository)#\(dependency.number)"]
            } else {
                dependencyIDs = []
            }
            return (
                repository: result.repository,
                number: pullRequest.number,
                title: pullRequest.title,
                url: pullRequest.url,
                headBranch: pullRequest.headBranch,
                baseBranch: pullRequest.baseBranch,
                checkSummary: pullRequest.checkSummary,
                reviewSummary: pullRequest.reviewSummary,
                mergeAfterIDs: dependencyIDs,
                state: actionState(pullRequest.state),
                reconciledAtUnixMillis: timestamp
            )
        }
    }

    private func approval(model: DesktopAppModel, title: String, target: String) -> DesktopApprovalRecord? {
        model.snapshot.operations.approvals.last { $0.title == title && $0.exactTarget == target }
    }

    private func approved(model: DesktopAppModel, title: String, target: String) -> DesktopApprovalRecord? {
        approval(model: model, title: title, target: target).flatMap { $0.state == .approved ? $0 : nil }
    }
}
