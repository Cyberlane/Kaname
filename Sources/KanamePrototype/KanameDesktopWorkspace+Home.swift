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

struct DesktopHomeView: View {
    @Environment(\.kanameAccessibilityPreferences) private var accessibilityPreferences
    @ObservedObject var model: DesktopAppModel
    let searchText: String
    let openThread: (String) -> Void
    let requestArchive: (String) -> Void
    let openDestination: (DesktopDestination) -> Void
    let openAutomationRun: (String, String?) -> Void
    let startConversation: () -> Void
    let startConversationInProject: (String) -> Void
    /// Automation state that needs a decision, read from the durable run
    /// projection when Home appears and every minute after.
    @State private var automationAttention: AutomationAttentionState = .loading

    private enum AutomationAttentionState: Equatable {
        case loading
        case loaded(DesktopWorkflowAttentionSummary)
        case stale(DesktopWorkflowAttentionSummary, String)
        case unavailable(String)

        var summary: DesktopWorkflowAttentionSummary? {
            switch self {
            case .loaded(let summary), .stale(let summary, _): return summary
            case .loading, .unavailable: return nil
            }
        }
    }

    private func loadAutomationAttention() async {
        let previous = automationAttention.summary
        guard let runner = LocalCoreRunner.bundled() else {
            automationAttention = previous.map { .stale($0, "The local core is unavailable. Showing the last durable result.") }
                ?? .unavailable("The local core service that owns automation attention is unavailable.")
            return
        }
        let loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: runner),
            library: DesktopWorkflowV2LibraryClient(transport: runner)
        )
        do {
            let snapshot = try await loader.load(
                limit: 100,
                requestID: "home-attention:\(UUID().uuidString.lowercased())",
                attentionOnly: true
            )
            automationAttention = .loaded(.from(snapshot))
        } catch {
            automationAttention = previous.map {
                .stale($0, "The latest durable automation result could not be loaded. Showing the last successful result.")
            } ?? .unavailable("The local core service did not return durable automation evidence. It was not treated as caught up.")
        }
    }

    private var attentionThreads: [DesktopThread] {
        model.threads(matching: searchText).filter {
            $0.attention == .needsResponse || $0.attention == .needsApproval || $0.attention == .failed
        }
    }

    private var runningThreads: [DesktopThread] {
        model.threads(matching: searchText).filter { $0.attention == .running || $0.attention == .queued }.prefix(6).map { $0 }
    }

    private var openProjects: [DesktopProject] {
        model.snapshot.projects.filter { $0.archivedAtUnixMillis == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func threadCount(projectID: String) -> Int {
        model.snapshot.threads.filter { $0.projectID == projectID && $0.attention != .archived }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                SectionHeading(
                    title: "Needs attention",
                    detail: attentionSectionDetail
                )

                if let summary = automationAttention.summary, !summary.isEmpty {
                    automationAttentionCard(summary)
                }

                if case .loading = automationAttention {
                    attentionLoadingPanel
                } else if case .unavailable(let message) = automationAttention {
                    attentionUnavailablePanel(message)
                } else if case .stale(_, let message) = automationAttention {
                    attentionStalePanel(message)
                } else if case .loaded(let summary) = automationAttention,
                          attentionThreads.isEmpty, summary.isEmpty {
                    EmptyPanel(
                        symbol: "checkmark.circle.fill",
                        title: "Nothing needs a decision",
                        detail: "Running and recent work stays visible below."
                    )
                } else if !attentionThreads.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: usesSyntheticLargeText ? 380 : 300), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(attentionThreads) { thread in
                            ThreadCard(thread: thread) { openThread(thread.id) }
                                .contextMenu { threadActions(thread) }
                        }
                    }
                }

                if !runningThreads.isEmpty {
                    SectionHeading(title: "Running now", detail: "Provider turns in progress. Open one to watch its activity.")
                    ForEach(runningThreads) { thread in
                        ThreadRow(thread: thread) { openThread(thread.id) }
                            .contextMenu { threadActions(thread) }
                    }
                }

                primaryColumns
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.canvas)
        .kanameSemanticFont(.body)
        .task {
            await loadAutomationAttention()
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(60))
                await loadAutomationAttention()
            }
        }
    }

    private func automationAttentionCard(_ summary: DesktopWorkflowAttentionSummary) -> some View {
        let parts: [String] = [
            summary.proposedEffectCount > 0
                ? "\(summary.proposedEffectCount) effect\(summary.proposedEffectCount == 1 ? "" : "s") awaiting approval"
                : nil,
            summary.failedRunCount > 0
                ? "\(summary.failedRunCount) failed run\(summary.failedRunCount == 1 ? "" : "s")"
                : nil,
        ].compactMap { $0 }
        let tint = summary.failedRunCount > 0 ? KanameColor.danger : KanameColor.warning
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: summary.failedRunCount > 0 ? "xmark.octagon.fill" : "bolt.horizontal.circle.fill")
                    .foregroundStyle(summary.failedRunCount > 0 ? KanameColor.danger : KanameColor.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automations need you").font(.body.weight(.semibold))
                    Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Automations", systemImage: "arrow.right") { openDestination(.automations) }
                    .buttonStyle(.borderless).font(.caption)
            }
            ForEach(summary.items.prefix(8)) { item in
                Button { openAutomationRun(item.runID, item.effectID) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.kind == .effect ? "bolt.horizontal.circle" : "xmark.octagon")
                            .foregroundStyle(item.kind == .effect ? KanameColor.warning : KanameColor.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle").font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
            if summary.items.count > 8 {
                Text("Showing the 8 most recent unresolved items; open Automations for the complete list.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var attentionSectionDetail: String {
        switch automationAttention {
        case .loading: "Checking conversations and durable automations…"
        case .unavailable: "Automation attention is unavailable; no empty state is implied."
        case .stale: "Showing the last durable result while the latest check is unavailable."
        case .loaded(let summary):
            attentionThreads.isEmpty && summary.isEmpty
                ? "You are caught up."
                : "Open the exact context before deciding."
        }
    }

    private var attentionLoadingPanel: some View {
        Label("Checking durable automation attention…", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption).foregroundStyle(.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func attentionStalePanel(_ message: String) -> some View {
        Label(message, systemImage: "clock.badge.exclamationmark")
            .font(.caption).foregroundStyle(KanameColor.warning)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(KanameColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func attentionUnavailablePanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Automation attention unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(KanameColor.warning)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Try again", systemImage: "arrow.clockwise") { _Concurrency.Task { await loadAutomationAttention() } }
                .buttonStyle(.bordered)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var usesSyntheticLargeText: Bool {
        accessibilityPreferences.syntheticTextScale == .accessibility3
    }

    @ViewBuilder
    private var hero: some View {
        if usesSyntheticLargeText {
            VStack(alignment: .leading, spacing: 18) {
                heroIntroduction
                heroActions.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: 18) {
                heroIntroduction
                Spacer()
                heroActions
            }
        }
    }

    private var heroIntroduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            KanameMetadataChip(
                "Desktop dogfood · local-first",
                symbolName: "desktopcomputer",
                accessibilityLabel: "Environment: Desktop dogfood, local-first"
            )
            Text("Command centre")
                .kanameSemanticFont(.largeTitle.weight(.bold))
                .lineLimit(usesSyntheticLargeText ? 2 : 1)
                .minimumScaleFactor(usesSyntheticLargeText ? 1 : 0.82)
            Text("What needs you, what is running, and where you left off.")
                .kanameSemanticFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var heroActions: some View {
        VStack(alignment: usesSyntheticLargeText ? .leading : .trailing, spacing: 10) {
            Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                .buttonStyle(.borderedProminent)
            DesktopAuthorityCard(remote: model.snapshot.remote)
                .frame(width: usesSyntheticLargeText ? nil : 286)
        }
    }

    @ViewBuilder
    private var primaryColumns: some View {
        if usesSyntheticLargeText {
            VStack(alignment: .leading, spacing: 18) {
                recentWork
                projectsColumn
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                recentWork
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                projectsColumn
                    .frame(width: 360, alignment: .topLeading)
            }
        }
    }

    private var recentWork: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Recent work", detail: "Newest first. Everything else lives in Threads.")
            ForEach(model.threads(matching: searchText).prefix(8)) { thread in
                VStack(alignment: .leading, spacing: 2) {
                    ThreadRow(thread: thread) { openThread(thread.id) }
                        .contextMenu { threadActions(thread) }
                    if let project = model.project(id: thread.projectID) {
                        Text(project.name)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 14)
                    }
                }
            }
            if model.threads(matching: searchText).count > 8 {
                Button("All threads", systemImage: "arrow.right") { openDestination(.threads) }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func threadActions(_ thread: DesktopThread) -> some View {
        Button(thread.attention == .completed ? "Mark active" : "Mark complete") {
            model.setAttention(
                threadID: thread.id,
                attention: thread.attention == .completed ? .needsResponse : .completed
            )
        }
        if thread.messages.count >= 2 {
            Button("Compact thread") {
                DesktopCompactionSummarizer.compact(model, threadID: thread.id)
            }
        }
        Button("Archive", role: .destructive) {
            requestArchive(thread.id)
        }
    }

    private var projectsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Projects", detail: "Start a conversation where the code lives.")
            if openProjects.isEmpty {
                EmptyPanel(
                    symbol: "folder.badge.plus",
                    title: "No projects yet",
                    detail: "Add a repository in Projects, then start a conversation inside it."
                )
            } else {
                ForEach(openProjects.prefix(8)) { project in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(KanameColor.accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.body.weight(.semibold))
                            Text("\(threadCount(projectID: project.id)) thread\(threadCount(projectID: project.id) == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            startConversationInProject(project.id)
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("New conversation in \(project.name)")
                    }
                    .padding(.vertical, 4)
                }
            }
            QuickActionCard(
                title: "Automations",
                detail: "Runs, schedules, and effects waiting for approval.",
                symbol: DesktopDestination.automations.symbol,
                tint: KanameColor.warning
            ) { openDestination(.automations) }
        }
    }
}
