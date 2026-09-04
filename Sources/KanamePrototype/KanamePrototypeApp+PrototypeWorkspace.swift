import Foundation
import SwiftUI
import KanameConnectivity
import KanameDesignSystem
import KanameDesktop
import KanameDomain
import KanameFixtures
import KanamePrototypeUI
#if os(macOS)
import AppKit
import Darwin
#endif

private struct PrototypeWorkspace: View {
    @State private var selectedFixtureName = Phase0Fixtures.codingReview.name
    @State private var selectedSurface: PrototypeSurface = .dashboard
    @State private var navigationHistory: [PrototypeSurface] = []
    @State private var newFlow: NewFlow?
    @State private var showsSettings = false

    private var selectedFixture: Phase0Fixture {
        Phase0Fixtures.all.first { $0.name == selectedFixtureName }
            ?? Phase0Fixtures.codingReview
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section("Workspace") {
                        ForEach(PrototypeSurface.workspaceSurfaces) { surface in
                            SurfaceButton(
                                surface: surface,
                                isSelected: selectedSurface == surface
                            ) {
                                selectTopLevelSurface(surface)
                            }
                        }
                    }

                    Section("Domains") {
                        ForEach(PrototypeSurface.domainSurfaces) { surface in
                            SurfaceButton(
                                surface: surface,
                                isSelected: selectedSurface == surface
                            ) {
                                selectTopLevelSurface(surface)
                            }
                        }
                    }

                    Section("Validation") {
                        ForEach(PrototypeSurface.validationSurfaces) { surface in
                            SurfaceButton(
                                surface: surface,
                                isSelected: selectedSurface == surface
                            ) {
                                selectTopLevelSurface(surface)
                            }
                        }
                    }

                    Section("Deterministic fixtures") {
                        ForEach(Phase0Fixtures.all, id: \.name) { fixture in
                            Button {
                                openThread(fixture)
                            } label: {
                                FixtureRow(
                                    fixture: fixture,
                                    isSelected: fixture.name == selectedFixtureName
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(KanameColor.surface)
                .frame(maxHeight: .infinity)

                    Divider()
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KanameColor.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .navigationTitle("Kaname")
            .background(KanameColor.surface)
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            } content: {
            content
                .background(KanameColor.canvas)
                .navigationTitle(selectedSurface.title)
                .navigationSplitViewColumnWidth(min: 520, ideal: 720)
                .toolbar {
                    if let backTarget = navigationHistory.last {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                _ = goBack()
                            } label: {
                                Label("Back to \(backTarget.title)", systemImage: "chevron.left")
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("New", systemImage: "plus") {
                            ForEach(NewFlow.allCases) { flow in
                                Button(flow.title) {
                                    newFlow = flow
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("Switch surface", systemImage: "rectangle.3.group") {
                            ForEach(PrototypeSurface.allCases) { surface in
                                Button(surface.title) {
                                    selectTopLevelSurface(surface)
                                }
                            }
                        }
                    }
                }
            } detail: {
            inspector
                .background(KanameColor.surface)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
            }
            .navigationSplitViewStyle(.balanced)
            .onAppear {
                DesktopBackCommandRouter.shared.install {
                    if showsSettings {
                        showsSettings = false
                        return true
                    }
                    return goBack()
                }
            }
            .onDisappear {
                DesktopBackCommandRouter.shared.removeHandler()
            }
            .sheet(item: $newFlow) { flow in
                NewFlowSheet(flow: flow)
            }
            .allowsHitTesting(!showsSettings)
            .disabled(showsSettings)

            if showsSettings {
                SettingsModal(isPresented: $showsSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: showsSettings)
    }

    @ViewBuilder
    private var inspector: some View {
        if selectedSurface == .liveCodex {
            LiveCodexContextInspector()
        } else {
            ContextInspector(fixture: selectedFixture)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSurface {
        case .dashboard:
            DashboardView(fixtures: Phase0Fixtures.all) { fixture in
                openThread(fixture)
            }
        case .threads:
            ThreadsView(fixtures: Phase0Fixtures.all) { fixture in
                openThread(fixture)
            }
        case .inbox:
            InboxView(fixtures: Phase0Fixtures.all) { fixture in
                openThread(fixture)
            }
        case .thread:
            ThreadWorkspaceView(
                fixture: selectedFixture,
                returnTitle: navigationHistory.last?.title,
                onBack: { _ = goBack() }
            )
        case .stack:
            StackPrototypeView()
        case .localCore:
            LocalCoreWorkspace()
        case .liveCodex:
            CodexLiveWorkspace()
        case .projects, .research, .obsidian, .email, .calendar, .automations:
            DomainHomeView(surface: selectedSurface) { flow in
                newFlow = flow
            }
        }
    }

    private func selectTopLevelSurface(_ surface: PrototypeSurface) {
        selectedSurface = surface
        navigationHistory.removeAll()
    }

    private func openThread(_ fixture: Phase0Fixture) {
        selectedFixtureName = fixture.name
        if selectedSurface != .thread {
            navigationHistory.append(selectedSurface)
        }
        selectedSurface = .thread
    }

    @discardableResult
    private func goBack() -> Bool {
        guard let destination = navigationHistory.popLast() else {
            if selectedSurface == .thread {
                selectedSurface = .threads
                return true
            }
            return false
        }
        selectedSurface = destination
        return true
    }
}

private enum PrototypeSurface: String, CaseIterable, Identifiable {
    case dashboard
    case threads
    case inbox
    case thread
    case projects
    case research
    case obsidian
    case email
    case calendar
    case automations
    case stack
    case localCore
    case liveCodex

    static let workspaceSurfaces: [PrototypeSurface] = [.dashboard, .threads, .inbox]
    static let domainSurfaces: [PrototypeSurface] = [.projects, .research, .obsidian, .email, .calendar, .automations]
    static let validationSurfaces: [PrototypeSurface] = [.liveCodex, .localCore, .stack]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .threads: "Threads"
        case .inbox: "Inbox"
        case .thread: "Conversation"
        case .projects: "Projects"
        case .research: "Research"
        case .obsidian: "Obsidian"
        case .email: "Email"
        case .calendar: "Calendar & schedules"
        case .automations: "Automations"
        case .stack: "GitHub stack"
        case .localCore: "Local core"
        case .liveCodex: "Codex live review"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .threads: "text.bubble"
        case .inbox: "tray"
        case .thread: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .research: "text.magnifyingglass"
        case .obsidian: "book.closed"
        case .email: "envelope"
        case .calendar: "calendar"
        case .automations: "arrow.triangle.2.circlepath"
        case .stack: "square.3.layers.3d.down.right"
        case .localCore: "internaldrive"
        case .liveCodex: "shield.lefthalf.filled"
        }
    }
}

private enum NewFlow: String, CaseIterable, Identifiable {
    case project
    case conversation
    case research
    case calendar
    case email
    case scheduledWork
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "New project"
        case .conversation: "New conversation"
        case .research: "New research"
        case .calendar: "New calendar task"
        case .email: "New email task"
        case .scheduledWork: "New scheduled work"
        case .automation: "New automation"
        }
    }

    var symbolName: String {
        switch self {
        case .project: "folder.badge.plus"
        case .conversation: "bubble.left.and.bubble.right"
        case .research: "text.magnifyingglass"
        case .calendar: "calendar.badge.plus"
        case .email: "envelope.badge"
        case .scheduledWork: "clock.badge.plus"
        case .automation: "arrow.triangle.2.circlepath"
        }
    }

    var contextPrompt: String {
        switch self {
        case .project:
            "Choose its purpose and repository or local folder. Context, instructions, skills, and worktree policy remain inspectable before the first task."
        case .conversation:
            "Choose an existing project or a standalone context, then attach only the notes, files, accounts, or domains intended for this conversation."
        case .research:
            "Set the question, desired decision, source boundaries, and any sensitivity restriction. A coding project is optional."
        case .calendar:
            "Choose the account, source calendar, event scope, and desired outcome. The fixture never changes a calendar."
        case .email:
            "Choose the isolated account and message scope. A draft, queued send, and sent message remain distinct states."
        case .scheduledWork:
            "Choose the context, human schedule or cron expression, time zone, notification rule, and missed-run policy. The default is skip/do nothing."
        case .automation:
            "Define the trigger, exact inputs, outputs, and authority. A dry run and explicit approval precede enablement."
        }
    }
}

private struct NewFlowSheet: View {
    let flow: NewFlow
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var drafted = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label(flow.title, systemImage: flow.symbolName)
                    .font(.title2.weight(.bold))
                Text(flow.contextPrompt)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Name the local draft")
                        .font(.headline)
                    TextField("What should this start?", text: $subject)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("2. Confirm boundaries")
                        .font(.headline)
                    Text("No provider, account, repository, calendar, email, or schedule is created in this Phase 0 fixture. The production flow presents the selected context and consequential boundaries before it runs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))

                if drafted {
                    Label("Local starter draft created — no external action taken", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KanameColor.success)
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 500, minHeight: 380, alignment: .topLeading)
            .background(KanameColor.canvas)
            .navigationTitle("Start work")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create local draft") {
                        drafted = true
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .modifier(KanameAppearanceModifier())
        .tint(KanameColor.accent)
    }
}

private struct DomainHomeView: View {
    let surface: PrototypeSurface
    let start: (NewFlow) -> Void

    private var flow: NewFlow {
        switch surface {
        case .projects: .project
        case .research: .research
        case .obsidian: .conversation
        case .email: .email
        case .calendar: .scheduledWork
        case .automations: .automation
        default: .conversation
        }
    }

    private var detail: String {
        switch surface {
        case .projects:
            "Projects gather deliberate repository, worktree, instruction, skill, and knowledge boundaries. They are not required for standalone research or personal work."
        case .research:
            "Research starts without manufacturing a coding project. Findings retain sources, retrieval dates, gaps, and an explicit decision boundary."
        case .obsidian:
            "The native knowledge surface will show current focus, decisions, wikilinks, provenance, and proposed note-edit diffs without silently joining contexts."
        case .email:
            "Account-scoped email work distinguishes suggested drafts, saved drafts, queued sends, sent mail, and reversible organization actions."
        case .calendar:
            "Calendar and scheduled work share visible source, time zone, recurrence, conflict, next-run, run-history, and missed-run-policy state. Default missed runs skip/do nothing."
        case .automations:
            "Automations are explicit trigger-to-action contracts with dry-run, authority, audit, pause, and recovery states — never background magic."
        default:
            "This Phase 0 surface is a local-only entry point."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhaseBanner()
                Label(surface.title, systemImage: surface.symbolName)
                    .font(.largeTitle.weight(.bold))
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                if surface == .calendar {
                    ScheduleFixtureCard {
                        start(.scheduledWork)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start here")
                            .font(.headline)
                        Text("The complete end-to-end flow is proposed in Obsidian. This fixture makes the non-coding entry path visible without pretending that an integration exists.")
                            .foregroundStyle(.secondary)
                        Button(flow.title) {
                            start(flow)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(18)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ScheduleFixtureCard: View {
    let startScheduledWork: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scheduled work")
                    .font(.headline)
                Spacer()
                Text("Fixture only")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.accent)
            }
            LabeledContent("Next run", value: "Monday 09:00 JST")
            LabeledContent("Trigger", value: "Weekdays at 09:00 · human preview required")
            LabeledContent("Missed run", value: "Skip / do nothing")
            LabeledContent("Last result", value: "Not run — no schedule exists")
            Text("A production schedule has a durable history, pause/edit/run-once controls, explicit time zone, notifications, and recovery rather than a hidden cron job.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("New scheduled work", action: startScheduledWork)
                .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SurfaceButton: View {
    let surface: PrototypeSurface
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(surface.title, systemImage: surface.symbolName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .font(isSelected ? .body.weight(.semibold) : .body)
    }
}

private struct FixtureRow: View {
    let fixture: Phase0Fixture
    let isSelected: Bool

    var body: some View {
        let projection = try? fixture.makeProjection()

        HStack(spacing: 8) {
            Circle()
                .fill((projection?.attention ?? .none).tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.thread.title)
                    .lineLimit(1)
                Text((projection?.attention ?? .none).displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .font(isSelected ? .body.weight(.semibold) : .body)
    }
}

struct PhaseBanner: View {
    var body: some View {
        Label("Phase 0 validation — deterministic fixtures only", systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .foregroundStyle(KanameColor.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(KanameColor.raised, in: Capsule())
    }
}

private struct DashboardView: View {
    let fixtures: [Phase0Fixture]
    let openFixture: (Phase0Fixture) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        PhaseBanner()
                        Text("What needs your attention?")
                            .font(.largeTitle.weight(.bold))
                        Text("The dashboard is an attention projection, not a second copy of your work.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HealthSummary()
                }

                ForEach(AttentionState.dashboardOrder, id: \.self) { attention in
                    let matchingFixtures = fixtures.filter {
                        (try? $0.makeProjection())?.attention == attention
                    }

                    if !matchingFixtures.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(attention.displayName)
                                    .font(.headline)
                                Text("\(matchingFixtures.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(attention.tint)
                                Spacer()
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(matchingFixtures, id: \.name) { fixture in
                                    AttentionCard(fixture: fixture) {
                                        openFixture(fixture)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HealthSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local authority", systemImage: "desktopcomputer")
                .font(.headline)
            StatusLine(label: "Fixture provider", detail: "available", tint: KanameColor.success)
            StatusLine(label: "External accounts", detail: "not connected", tint: KanameColor.separator)
            StatusLine(label: "Mobile design", detail: "separate redesign pending", tint: KanameColor.accent)
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatusLine: View {
    let label: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
            Spacer(minLength: 12)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct AttentionCard: View {
    let fixture: Phase0Fixture
    let action: () -> Void

    var body: some View {
        let projection = try? fixture.makeProjection()

        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    KanameStatusBadge(
                        (projection?.attention ?? .none).legacyStatusPresentation,
                        density: .compact
                    )
                    Spacer()
                    Image(systemName: fixture.thread.workspaceKind.symbolName)
                        .foregroundStyle(.secondary)
                }
                Text(fixture.thread.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Text(fixture.task.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text(fixture.providerSession.provider)
                    Spacer()
                    Text("Open thread")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open the thread for \(fixture.thread.title)")
    }
}

extension AttentionState {
    var legacyStatusPresentation: KanameStatusPresentation {
        let tone: KanameStatusTone
        let symbolName: String
        switch self {
        case .none:
            (tone, symbolName) = (.neutral, "checkmark.circle")
        case .queued:
            (tone, symbolName) = (.informational, "clock")
        case .running:
            (tone, symbolName) = (.active, "arrow.triangle.2.circlepath")
        case .needsResponse:
            (tone, symbolName) = (.attention, "bubble.left")
        case .needsReview:
            (tone, symbolName) = (.attention, "eye.circle")
        case .failed:
            (tone, symbolName) = (.danger, "exclamationmark.triangle")
        case .interrupted:
            (tone, symbolName) = (.blocked, "pause.circle")
        }
        return KanameStatusPresentation(
            label: displayName,
            tone: tone,
            symbolName: symbolName,
            accessibilityLabel: "Attention: \(displayName)"
        )
    }
}

private struct InboxView: View {
    let fixtures: [Phase0Fixture]
    let openFixture: (Phase0Fixture) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    PhaseBanner()
                    Text("Same work, organized by attention")
                        .font(.title2.weight(.bold))
                    Text("Opening an item preserves its thread; Inbox does not move or duplicate it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            ForEach(AttentionState.dashboardOrder, id: \.self) { attention in
                let matchingFixtures = fixtures.filter {
                    (try? $0.makeProjection())?.attention == attention
                }

                if !matchingFixtures.isEmpty {
                    Section(attention.displayName) {
                        ForEach(matchingFixtures, id: \.name) { fixture in
                            Button {
                                openFixture(fixture)
                            } label: {
                                InboxRow(fixture: fixture)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct InboxRow: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        HStack(spacing: 12) {
            Circle()
                .fill((projection?.attention ?? .none).tint)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(fixture.thread.title)
                Text("\(fixture.thread.workspaceKind.displayName) · \(fixture.providerSession.provider)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}
