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
    let startConversation: () -> Void
    let startConversationInProject: (String) -> Void

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
                    detail: attentionThreads.isEmpty ? "You are caught up." : "Open the exact context before deciding."
                )

                if attentionThreads.isEmpty {
                    EmptyPanel(
                        symbol: "checkmark.circle.fill",
                        title: "Nothing needs a decision",
                        detail: "Running and recent work stays visible below."
                    )
                } else {
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
                model.compactThread(threadID: thread.id)
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
                detail: "\(model.snapshot.domains.automations.count) workflow\(model.snapshot.domains.automations.count == 1 ? "" : "s"). Runs, schedules, and effects waiting for approval.",
                symbol: DesktopDestination.automations.symbol,
                tint: KanameColor.warning
            ) { openDestination(.automations) }
        }
    }
}
