import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@MainActor
private final class DesktopLocalReadViewModel: ObservableObject {
    @Published private(set) var obsidianPreview: ObsidianNotePreview?
    @Published private(set) var gitInspection: LocalGitInspection?
    @Published private(set) var obsidianError: String?
    @Published private(set) var gitError: String?
    @Published private(set) var isReadingObsidian = false
    @Published private(set) var isReadingGit = false

    private let service = DesktopLocalReadService()

    func readObsidian(path: String) {
        guard !isReadingObsidian else { return }
        isReadingObsidian = true
        obsidianError = nil
        _Concurrency.Task {
            do {
                obsidianPreview = try await service.readObsidianNote(path: path)
            } catch {
                obsidianError = error.localizedDescription
            }
            isReadingObsidian = false
        }
    }

    func inspectGit(path: String) {
        guard !isReadingGit else { return }
        isReadingGit = true
        gitError = nil
        _Concurrency.Task {
            do {
                gitInspection = try await service.inspectGitWorkspace(path: path)
            } catch {
                gitError = error.localizedDescription
            }
            isReadingGit = false
        }
    }
}

struct DesktopGitHubView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @StateObject private var localReads = DesktopLocalReadViewModel()
    @StateObject private var githubControl = DesktopGitHubControlViewModel()
    @State private var showsNewLayer = false

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter { $0.service == .github }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "GitHub",
                    detail: "Local repositories, remote state, pull requests, checks, and stack dependencies",
                    symbol: DesktopDestination.github.symbol
                ) {
                    ControlGroup {
                        Button("Refresh gh access", systemImage: "person.crop.circle.badge.checkmark") {
                            integrations.refreshGitHub(model: model)
                        }
                        .disabled(integrations.isRefreshingGitHub)
                        Button("Refresh local Git", systemImage: "arrow.clockwise") {
                            if let workspace = model.snapshot.domains.gitWorkspaces.first {
                                localReads.inspectGit(path: workspace.localPath)
                            }
                        }
                        Button("Reconcile pull requests", systemImage: "arrow.triangle.pull") {
                            if let workspace = model.snapshot.domains.gitWorkspaces.first {
                                githubControl.refresh(model: model, workspace: workspace)
                            }
                        }
                        .disabled(model.snapshot.domains.gitWorkspaces.first.map {
                            githubControl.refreshingWorkspaceIDs.contains($0.id)
                        } ?? true)
                        Button("New stack layer", systemImage: "arrow.triangle.branch") {
                            showsNewLayer = true
                        }
                        .disabled(model.snapshot.domains.gitWorkspaces.isEmpty)
                    }
                    .controlGroupStyle(.navigation)
                }
                AccountStrip(accounts: accounts)

                SectionHeading(
                    title: "Local workspaces",
                    detail: "Local inspection does not imply push, pull-request, review, merge, or release authority."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    ForEach(model.snapshot.domains.gitWorkspaces) { workspace in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.title2)
                                    .foregroundStyle(KanameColor.active)
                                Spacer()
                                KanameStatusBadge(
                                    KanameDesktopStatusPresentation.record(workspace.status),
                                    density: .compact
                                )
                            }
                            Text(workspace.name).font(.headline)
                            Text(workspace.localPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Divider()
                            LabeledContent("Branch", value: workspace.branch)
                            LabeledContent("Remote", value: workspace.remoteSummary)
                        }
                        .font(.caption)
                        .panelStyle()
                    }
                }

                if localReads.isReadingGit {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Inspecting local Git state…")
                    }
                    .panelStyle()
                } else if let inspection = localReads.gitInspection {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label("Live local state", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                            Spacer()
                            KanameStatusBadge(
                                KanameDesktopStatusPresentation.record(inspection.isClean ? .ready : .needsReview),
                                density: .compact
                            )
                        }
                        LabeledContent("Branch", value: inspection.branch)
                        LabeledContent("HEAD", value: inspection.head)
                        LabeledContent("Changed paths", value: "\(inspection.changedPaths.count)")
                        if inspection.wasTruncated {
                            Text("The bounded Git response was truncated.")
                                .font(.caption)
                                .foregroundStyle(KanameColor.warning)
                        }
                    }
                    .font(.caption)
                    .panelStyle()
                }

                if let error = localReads.gitError {
                    BoundaryCallout(title: "Local Git read unavailable", detail: error)
                }

                if let message = githubControl.message {
                    BoundaryCallout(title: "GitHub reconciliation", detail: message)
                }

                SectionHeading(
                    title: "Pull requests",
                    detail: "Checks, review state, and stack dependencies are read back from GitHub. Creation and merge still require exact approvals."
                )
                if model.snapshot.operations.pullRequests.isEmpty {
                    EmptyPanel(
                        symbol: "arrow.triangle.pull",
                        title: "No reconciled pull requests",
                        detail: "Refresh an authenticated workspace to inspect remote pull requests without changing them."
                    )
                    .frame(minHeight: 160)
                } else {
                    ForEach(model.snapshot.operations.pullRequests.sorted { $0.lastReconciledAtUnixMillis > $1.lastReconciledAtUnixMillis }) { pullRequest in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("#\(pullRequest.number) \(pullRequest.title)").font(.headline)
                                Spacer()
                                KanameStatusBadge(
                                    KanameDesktopStatusPresentation.action(pullRequest.state),
                                    density: .compact
                                )
                            }
                            Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch)")
                                .font(.system(.caption, design: .monospaced))
                            HStack {
                                Label(pullRequest.checkSummary, systemImage: "checkmark.circle")
                                Label(pullRequest.reviewSummary, systemImage: "person.crop.circle.badge.checkmark")
                                if !pullRequest.mergeAfterIDs.isEmpty {
                                    Label("After \(pullRequest.mergeAfterIDs.joined(separator: ", "))", systemImage: "arrow.down")
                                }
                                Spacer()
                                if let url = URL(string: pullRequest.url) {
                                    Link("Open on GitHub", destination: url)
                                }
                                pullRequestMergeButton(pullRequest)
                            }
                            .font(.caption)
                        }
                        .panelStyle()
                    }
                }

                SectionHeading(
                    title: "Stack graph",
                    detail: "Dependencies are local proposals until GitHub is connected and exact remote state is reconciled."
                )
                if model.snapshot.operations.gitStackLayers.isEmpty {
                    EmptyPanel(
                        symbol: "arrow.triangle.branch",
                        title: "No stack layers",
                        detail: "Model branch and pull-request dependencies locally before publishing anything."
                    )
                    .frame(minHeight: 180)
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.snapshot.operations.gitStackLayers) { layer in
                            HStack(alignment: .top, spacing: 13) {
                                Image(systemName: "circle.hexagongrid.fill")
                                    .foregroundStyle(KanameColor.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(layer.title).font(.headline)
                                    Text("\(layer.branch) → \(layer.baseBranch)")
                                        .font(.system(.caption, design: .monospaced))
                                    Text("\(layer.checkSummary) · \(layer.reviewSummary)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                KanameStatusBadge(
                                    KanameDesktopStatusPresentation.action(layer.state),
                                    density: .compact
                                )
                                stackPullRequestButton(layer)
                            }
                            .panelStyle()
                        }
                    }
                }

                BoundaryCallout(
                    title: "Publishing remains explicit",
                    detail: "Push, pull-request creation, review replies, merges, releases, and other remote mutations require an exact proposal, approval, and independently reconciled result."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .sheet(isPresented: $showsNewLayer) {
            NewGitStackLayerSheet(model: model)
        }
    }

    @ViewBuilder
    private func stackPullRequestButton(_ layer: DesktopGitStackLayer) -> some View {
        if let workspace = model.snapshot.domains.gitWorkspaces.first(where: { $0.id == layer.workspaceID }),
           layer.pullRequestURL == nil,
           let repository = githubControl.repositoryByWorkspaceID[workspace.id] {
            let target = GitHubControlService.pullRequestTarget(repository: repository, head: layer.branch, base: layer.baseBranch)
            switch githubControl.approvalState(model: model, title: "Create pull request", target: target) {
            case .approved:
                Button("Create approved PR") {
                    githubControl.createPullRequest(model: model, workspace: workspace, layer: layer)
                }
                .buttonStyle(.borderedProminent)
            case .awaitingApproval:
                Text("Awaiting approval").font(.caption).foregroundStyle(KanameColor.warning)
            default:
                Button("Request PR approval") {
                    githubControl.requestPullRequestApproval(model: model, workspace: workspace, layer: layer)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func pullRequestMergeButton(_ pullRequest: DesktopPullRequestRecord) -> some View {
        if pullRequest.state != .completed,
           let workspace = model.snapshot.domains.gitWorkspaces.first(where: { $0.id == pullRequest.workspaceID }) {
            let target = GitHubControlService.mergeTarget(repository: pullRequest.repository, number: pullRequest.number)
            switch githubControl.approvalState(model: model, title: "Merge pull request", target: target) {
            case .approved:
                Button("Merge approved PR") {
                    githubControl.merge(model: model, workspace: workspace, pullRequest: pullRequest)
                }
                .buttonStyle(.borderedProminent)
            case .awaitingApproval:
                Text("Merge awaiting approval").foregroundStyle(KanameColor.warning)
            default:
                Button("Request merge approval") {
                    githubControl.requestMergeApproval(model: model, pullRequest: pullRequest)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
