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

struct DesktopCodingView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var runtime: DesktopConversationRuntime
    let openThread: (String) -> Void
    let startConversation: (String?) -> Void
    @StateObject private var control: DesktopCodingControlViewModel
    @State private var panel = Panel.overview
    @State private var showsNewComparison = false
    @State private var showsNewWorktree = false
    @State private var commitMessages: [String: String] = [:]

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        runtime: DesktopConversationRuntime,
        gitControl: DesktopGitControlService,
        openThread: @escaping (String) -> Void,
        startConversation: @escaping (String?) -> Void
    ) {
        self.model = model
        self.integrations = integrations
        self.runtime = runtime
        self.openThread = openThread
        self.startConversation = startConversation
        _control = StateObject(wrappedValue: DesktopCodingControlViewModel(service: gitControl))
    }

    private enum Panel: String, CaseIterable, Identifiable {
        case overview
        case sessions
        case worktrees
        case comparisons
        case quality

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overview: "Control plane"
            case .sessions: "Sessions"
            case .worktrees: "Worktrees"
            case .comparisons: "Compare"
            case .quality: "Evidence"
            }
        }
    }

    private let providers = [
        LocalProviderDescriptor(
            name: "Codex",
            executable: "codex",
            adapter: "Live adapter",
            capabilities: "Plan · approve writes · interrupt · evidence · accept"
        ),
        LocalProviderDescriptor(
            name: "Claude",
            executable: "claude",
            adapter: "Live adapter",
            capabilities: "Streaming · native resume · plan permission mode · bounded budget · no persisted Kaname token"
        ),
        LocalProviderDescriptor(
            name: "OpenCode",
            executable: "opencode",
            adapter: "Live adapter",
            capabilities: "JSON event stream · native resume · plan agent · auto-approval disabled"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Coding panel", selection: $panel) {
                    ForEach(Panel.allCases) { panel in
                        Text(panel.label).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Spacer()
                if let message = control.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(KanameColor.surface)

            Divider()

            switch panel {
            case .overview:
                overview
            case .sessions:
                sessions
            case .worktrees:
                worktrees
            case .comparisons:
                comparisons
            case .quality:
                qualityEvidence
            }
        }
        .background(KanameColor.canvas)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Coding control plane",
                    detail: "Native provider semantics, isolated workspaces, explicit comparisons, and verified acceptance",
                    symbol: DesktopDestination.liveCodex.symbol
                ) {
                    ControlGroup {
                        Menu("New coding conversation", systemImage: "square.and.pencil") {
                            Button("Standalone") { startConversation(nil) }
                            if !model.activeProjects.isEmpty {
                                Divider()
                                ForEach(model.activeProjects) { project in
                                    Button(project.name) { startConversation(project.id) }
                                }
                            }
                        }
                        Button("Refresh sessions", systemImage: "arrow.clockwise") {
                            integrations.refreshProviders()
                        }
                        .disabled(integrations.isRefreshingProviders)
                        Button("New worktree", systemImage: "arrow.triangle.branch") {
                            showsNewWorktree = true
                        }
                    }
                    .controlGroupStyle(.navigation)
                }

                HStack(spacing: 12) {
                    codingPulse(
                        title: "Running",
                        value: model.activeThreads.filter { $0.kind == .coding && $0.attention == .running }.count,
                        symbol: "bolt.fill",
                        tint: KanameColor.accent
                    )
                    codingPulse(
                        title: "Needs input",
                        value: model.activeThreads.filter {
                            $0.kind == .coding && ($0.attention == .needsInput || $0.attention == .needsApproval)
                        }.count,
                        symbol: "person.crop.circle.badge.questionmark",
                        tint: KanameColor.warning
                    )
                    codingPulse(
                        title: "Worktrees",
                        value: model.snapshot.operations.worktrees.filter { $0.state != .removed }.count,
                        symbol: "arrow.triangle.branch",
                        tint: KanameColor.accent
                    )
                    codingPulse(
                        title: "Checks",
                        value: model.snapshot.operations.qualityGates.count,
                        symbol: "checkmark.seal.fill",
                        tint: KanameColor.success
                    )
                }

                SectionHeading(
                    title: "Provider inventory",
                    detail: "Availability is discovered from local executable paths only. Authentication is not opened or inferred."
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                    ForEach(providers) { provider in
                        ProviderCapabilityCard(
                            provider: provider,
                            snapshot: integrations.providerCapabilities.first {
                                $0.instance.displayName == provider.name
                            }
                        )
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label("Explicit comparison", systemImage: "rectangle.split.3x1.fill")
                                .font(.headline)
                            Spacer()
                            Button("New comparison") { showsNewComparison = true }
                                .buttonStyle(.bordered)
                        }
                        Text("A comparison creates separate provider runs from the same approved brief. Results stay side by side; histories and contexts are never silently merged.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            KanameStatusBadge(
                                KanameDesktopStatusPresentation.record(.needsReview),
                                density: .compact
                            )
                            Text("Select providers and cost limits before execution")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .panelStyle()

                    VStack(alignment: .leading, spacing: 11) {
                        Label("Context & usage", systemImage: "gauge.with.dots.needle.33percent")
                            .font(.headline)
                        Text("Each run records selected files, notes, skills, result pages, provider model, compaction, and any available token or cost evidence.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("No run selected")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("0 context references")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .panelStyle()
                }

                BoundaryCallout(
                    title: "One conversation surface",
                    detail: "Choose Codex, Claude, or OpenCode in an ordinary thread. Every provider streams into the same timeline; this control plane only reconciles sessions, isolated workspaces, comparisons, and evidence."
                )

                if !model.snapshot.operations.comparisons.isEmpty {
                    SectionHeading(
                        title: "Comparison drafts",
                        detail: "Each provider receives a separate run identity from the same frozen brief."
                    )
                    ForEach(model.snapshot.operations.comparisons) { comparison in
                        VStack(alignment: .leading, spacing: 8) {
                            comparisonHeader(comparison)
                            Text(comparison.brief)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(model.snapshot.operations.providerRuns.filter { comparison.runIDs.contains($0.id) }) { run in
                                    Label(run.provider, systemImage: "cpu")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(KanameColor.canvas, in: Capsule())
                                }
                            }
                        }
                        .panelStyle()
                    }
                }

                SectionHeading(
                    title: "Quality loop",
                    detail: "Provider completion and accepted completion remain different states."
                )
                HStack(spacing: 0) {
                    ForEach(Array(["Discuss", "Plan", "Approve", "Implement", "Review evidence", "Accept", "Update knowledge"].enumerated()), id: \.offset) { index, step in
                        VStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .fill(index == 0 ? KanameColor.accent : KanameColor.raised)
                                    .frame(width: 28, height: 28)
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(index == 0 ? KanameColor.canvas : .secondary)
                            }
                            Text(step)
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        if index < 6 {
                            Rectangle()
                                .fill(KanameColor.separator)
                                .frame(height: 1)
                                .offset(y: -11)
                        }
                    }
                }
                .padding(18)
                .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsNewComparison) {
            NewProviderComparisonSheet(model: model, availableProviders: providers.map(\.name))
        }
        .sheet(isPresented: $showsNewWorktree) {
            NewManagedWorktreeSheet(model: model)
        }
    }

    private func codingPulse(title: String, value: Int, symbol: String, tint: Color) -> some View {
        Label {
            LabeledContent(title) {
                Text("\(value)").font(.headline.monospacedDigit())
            }
            .font(.caption2)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    private var sessions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceHeader(
                    title: "Provider sessions",
                    detail: "Recoverable native identities mapped to ordinary Kaname conversations",
                    symbol: "link.circle.fill"
                )
                if model.snapshot.operations.providerSessions.isEmpty {
                    EmptyPanel(
                        symbol: "message.badge.waveform.fill",
                        title: "No provider sessions yet",
                        detail: "Start a normal conversation and send a message. Kaname records the provider's native session identity when it becomes available."
                    )
                    .frame(minHeight: 200)
                } else {
                    ForEach(model.snapshot.operations.providerSessions.sorted { $0.lastReconciledAtUnixMillis > $1.lastReconciledAtUnixMillis }) { session in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(session.provider, systemImage: "cpu.fill").font(.headline)
                                Spacer()
                                Text(session.state.label).font(.caption.weight(.semibold))
                            }
                            Text(session.nativeSessionID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(session.source).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(session.capabilities.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Open conversation") { openThread(session.threadID) }
                                    .buttonStyle(.bordered)
                            }
                            if !session.limitations.isEmpty {
                                Text("Limits: \(session.limitations.joined(separator: " · "))")
                                    .font(.caption2)
                                    .foregroundStyle(KanameColor.warning)
                            }
                        }
                        .panelStyle()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var worktrees: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceHeader(
                    title: "Isolated worktrees",
                    detail: "Exact local targets, explicit approvals, reviewable verification, and clean-only cleanup",
                    symbol: "arrow.triangle.branch"
                ) {
                    Button("New worktree", systemImage: "plus") { showsNewWorktree = true }
                        .buttonStyle(.borderedProminent)
                }
                if model.snapshot.operations.worktrees.isEmpty {
                    EmptyPanel(
                        symbol: "arrow.triangle.branch",
                        title: "No managed worktrees",
                        detail: "Create an isolated branch for a project conversation. Kaname keeps it inside its private managed directory and requires an exact approval before creation."
                    )
                    .frame(minHeight: 200)
                } else {
                    ForEach(model.snapshot.operations.worktrees.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { worktree in
                        worktreeCard(worktree)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsNewWorktree) { NewManagedWorktreeSheet(model: model) }
    }

    private func worktreeCard(_ worktree: DesktopWorktreeRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(worktree.branch).font(.headline)
                    Text(worktree.worktreePath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(worktree.state.label).font(.caption.weight(.semibold))
            }
            Divider()
            LabeledContent("Base", value: worktree.baseRevision)
            LabeledContent("HEAD", value: worktree.headRevision.map { String($0.prefix(12)) } ?? "Not created")
            LabeledContent("Changed files", value: "\(worktree.changedFileCount)")
            Text(worktree.diffSummary).font(.caption).foregroundStyle(.secondary)
            if !worktree.testCommand.isEmpty {
                DisclosureGroup("Verification: \(worktree.testCommand)") {
                    Text(worktree.testSummary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let paths = control.changedPathsByWorktreeID[worktree.id], !paths.isEmpty {
                Text("Exact changed paths: \(paths.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    TextField("Signed commit message", text: Binding(
                        get: { commitMessages[worktree.id] ?? "" },
                        set: { commitMessages[worktree.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    commitButton(worktree)
                }
            }
            HStack {
                Button("Conversation") { openThread(worktree.threadID) }
                Spacer()
                if worktree.state == .proposed {
                    worktreeCreationButton(worktree)
                } else if worktree.state != .removed {
                    Button("Refresh") { control.refresh(model: model, worktree: worktree) }
                    Button("Run swift test") {
                        control.runVerification(model: model, worktree: worktree, command: "swift test")
                    }
                    worktreeCleanupButton(worktree)
                }
            }
            .buttonStyle(.bordered)
            .disabled(control.busyWorktreeIDs.contains(worktree.id))
        }
        .font(.caption)
        .panelStyle()
    }

    @ViewBuilder
    private func commitButton(_ worktree: DesktopWorktreeRecord) -> some View {
        let message = commitMessages[worktree.id] ?? ""
        switch control.approvalState(model: model, worktree: worktree, action: "Create signed commit") {
        case .approved:
            Button("Commit approved paths") { control.commit(model: model, worktree: worktree, message: message) }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .awaitingApproval:
            Text("Awaiting approval").foregroundStyle(KanameColor.warning)
        default:
            Button("Request commit approval") { control.requestCommitApproval(model: model, worktree: worktree, message: message) }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func worktreeCreationButton(_ worktree: DesktopWorktreeRecord) -> some View {
        switch control.approvalState(model: model, worktree: worktree, action: "Create isolated worktree") {
        case .approved:
            Button("Create approved worktree") { control.create(model: model, worktree: worktree) }
                .buttonStyle(.borderedProminent)
        case .awaitingApproval:
            Text("Awaiting Inbox approval").foregroundStyle(KanameColor.warning)
        case .rejected:
            Text("Creation rejected").foregroundStyle(.secondary)
        default:
            Button("Request creation approval") { control.requestCreationApproval(model: model, worktree: worktree) }
        }
    }

    @ViewBuilder
    private func worktreeCleanupButton(_ worktree: DesktopWorktreeRecord) -> some View {
        switch control.approvalState(model: model, worktree: worktree, action: "Remove clean worktree") {
        case .approved:
            Button("Remove approved worktree", role: .destructive) { control.cleanup(model: model, worktree: worktree) }
        case .awaitingApproval:
            Text("Cleanup awaiting approval").foregroundStyle(KanameColor.warning)
        default:
            Button("Request cleanup", role: .destructive) { control.requestCleanupApproval(model: model, worktree: worktree) }
        }
    }

    private var comparisons: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceHeader(
                    title: "Equal-context comparisons",
                    detail: "Separate provider histories from one frozen brief; select a result only after review",
                    symbol: "rectangle.split.3x1.fill"
                ) {
                    Button("New comparison", systemImage: "plus") { showsNewComparison = true }
                        .buttonStyle(.borderedProminent)
                }
                if model.snapshot.operations.comparisons.isEmpty {
                    EmptyPanel(symbol: "rectangle.split.3x1", title: "No comparisons", detail: "Compare two or more providers without merging their hidden context or session history.")
                        .frame(minHeight: 200)
                }
                ForEach(model.snapshot.operations.comparisons.sorted { $0.createdAtUnixMillis > $1.createdAtUnixMillis }) { comparison in
                    VStack(alignment: .leading, spacing: 10) {
                        comparisonHeader(comparison)
                        Text(comparison.brief).font(.subheadline).foregroundStyle(.secondary)
                        ForEach(model.snapshot.operations.providerRuns.filter { comparison.runIDs.contains($0.id) }) { run in
                            HStack {
                                Label(run.provider, systemImage: "cpu")
                                Text(run.state.label).foregroundStyle(.secondary)
                                Spacer()
                                if let threadID = run.threadID { Button("Open") { openThread(threadID) } }
                                if run.state == .completed {
                                    Button("Use this result") {
                                        if let threadID = model.selectProviderComparisonResult(comparisonID: comparison.id, runID: run.id) {
                                            openThread(threadID)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .font(.caption)
                        }
                        if comparison.state == .proposed {
                            Button("Run equal-context comparison") {
                                runtime.startComparison(id: comparison.id, projectID: model.snapshot.projects.first { $0.archivedAtUnixMillis == nil }?.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .panelStyle()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsNewComparison) { NewProviderComparisonSheet(model: model, availableProviders: providers.map(\.name)) }
    }

    private var qualityEvidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceHeader(title: "Coding evidence", detail: "Tests, diagnostics, structural review, context, artifacts, and subagent activity", symbol: "checkmark.seal.fill")
                evidenceSummary(title: "Quality gates", count: model.snapshot.operations.qualityGates.count, empty: "No verification evidence has been recorded.") {
                    ForEach(model.snapshot.operations.qualityGates.sorted { $0.recordedAtUnixMillis > $1.recordedAtUnixMillis }) { gate in
                        HStack {
                            Text(gate.kind.label).font(.headline)
                            Text(gate.command).font(.system(.caption, design: .monospaced))
                            Spacer()
                            KanameStatusBadge(
                                KanameDesktopStatusPresentation.action(gate.state),
                                density: .compact
                            )
                        }
                    }
                }
                evidenceSummary(title: "Subagents", count: model.snapshot.operations.subagents.count, empty: "No provider has reported subagent activity.") {
                    ForEach(model.snapshot.operations.subagents.sorted { $0.startedAtUnixMillis > $1.startedAtUnixMillis }) { agent in
                        HStack { Label(agent.title, systemImage: "person.2.fill"); Text(agent.provider).foregroundStyle(.secondary); Spacer(); Text(agent.state.label).font(.caption.weight(.semibold)) }
                    }
                }
                evidenceSummary(title: "Artifacts", count: model.snapshot.operations.artifacts.count, empty: "No local artifacts have been registered.") {
                    ForEach(model.snapshot.operations.artifacts.sorted { $0.createdAtUnixMillis > $1.createdAtUnixMillis }.prefix(20)) { artifact in
                        HStack { Label(artifact.name, systemImage: "doc.fill"); Spacer(); Text(artifact.provenance).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func comparisonHeader(_ comparison: DesktopComparisonRecord) -> some View {
        HStack {
            Text(comparison.title).font(.headline)
            Spacer()
            KanameStatusBadge(
                KanameDesktopStatusPresentation.action(comparison.state),
                density: .compact
            )
        }
    }

    private func evidenceSummary<Content: View>(title: String, count: Int, empty: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(count)").font(.caption.weight(.bold)) }
            if count == 0 { Text(empty).foregroundStyle(.secondary) } else { content() }
        }
        .font(.caption)
        .panelStyle()
    }
}

private struct LocalProviderDescriptor: Identifiable {
    let name: String
    let executable: String
    let adapter: String
    let capabilities: String

    var id: String { executable }

    var executableURL: URL? {
        ProviderExecutableLocator.url(named: executable)
    }
}

private struct ProviderCapabilityCard: View {
    let provider: LocalProviderDescriptor
    let snapshot: ProviderCapabilitySnapshot?

    private var status: DesktopRecordState {
        guard let snapshot else { return provider.executableURL == nil ? .disconnected : .ready }
        switch snapshot.state {
        case .ready: return .ready
        case .degraded: return .needsReview
        case .authenticationRequired: return .needsReview
        case .unavailable, .unsupported: return .disconnected
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(status == .ready ? KanameColor.accent : .secondary)
                Text(provider.name).font(.headline)
                Spacer()
                KanameStatusBadge(
                    KanameDesktopStatusPresentation.record(status),
                    density: .compact
                )
            }
            Text(snapshot.map { "\(provider.adapter) · \($0.state.rawValue)" } ?? provider.adapter)
                .font(.subheadline.weight(.semibold))
            Text(provider.capabilities)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(snapshot?.version.map { "Version \($0)" } ?? provider.executableURL?.path ?? "Executable not found")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(snapshot?.detail ?? provider.executableURL?.path ?? "Executable not found")
        }
        .panelStyle()
    }
}
