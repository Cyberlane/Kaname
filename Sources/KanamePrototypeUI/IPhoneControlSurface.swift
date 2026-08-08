#if os(iOS)
import SwiftUI
import UIKit
import KanameDomain
import KanameFixtures

public struct IPhoneControlSurface: View {
    @State private var selectedTab: IPhoneTab = .home
    @State private var workProjection: IPhoneWorkProjection = .inbox
    @State private var isMacReachable = false
    @State private var queuedCommands = PhoneQueuedCommand.fixtureItems
    @State private var notificationRoute: PhoneNotificationRoute?
    @State private var newDraftRoute: IPhoneNewDraftRoute?
    @State private var showsSettings = false
    @State private var approvalReceipt: String?

    public init() {
        let polarNight = UIColor(red: 46 / 255, green: 52 / 255, blue: 64 / 255, alpha: 1)
        let snowStorm = UIColor(red: 216 / 255, green: 222 / 255, blue: 233 / 255, alpha: 1)

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = polarNight
        navigationAppearance.titleTextAttributes = [.foregroundColor: snowStorm]
        navigationAppearance.largeTitleTextAttributes = [.foregroundColor: snowStorm]
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = polarNight
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    public var body: some View {
        ZStack {
            Nord.polarNight0
                .ignoresSafeArea()

            TabView(selection: $selectedTab) {
                NavigationStack {
                    IPhoneCommandCenter(
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands,
                        approvalReceipt: $approvalReceipt,
                        startNewDraft: {
                            newDraftRoute = IPhoneNewDraftRoute(projectName: nil)
                        },
                        chooseTab: { selectedTab = $0 },
                        chooseWorkProjection: {
                            workProjection = $0
                            selectedTab = .work
                        },
                        openSettings: { showsSettings = true }
                    )
                }
                .tabItem {
                    Label("Home", systemImage: "rectangle.grid.2x2.fill")
                }
                .tag(IPhoneTab.home)
                .background(Nord.polarNight0.ignoresSafeArea())
                .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)

                NavigationStack {
                    IPhoneWorkHub(
                        projection: $workProjection,
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands,
                        approvalReceipt: $approvalReceipt,
                        startNewDraft: {
                            newDraftRoute = IPhoneNewDraftRoute(projectName: nil)
                        }
                    )
                }
                .tabItem {
                    Label("Work", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(IPhoneTab.work)
                .background(Nord.polarNight0.ignoresSafeArea())
                .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)

                NavigationStack {
                    IPhoneProjectsHub(
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands,
                        approvalReceipt: $approvalReceipt,
                        startNewDraft: { projectName in
                            newDraftRoute = IPhoneNewDraftRoute(projectName: projectName)
                        }
                    )
                }
                .tabItem {
                    Label("Projects", systemImage: "folder.fill")
                }
                .tag(IPhoneTab.projects)
                .background(Nord.polarNight0.ignoresSafeArea())
                .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)

                NavigationStack {
                    IPhoneOperationsHub(
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands,
                        approvalReceipt: $approvalReceipt,
                        openApproval: { notificationRoute = .calendarApproval }
                    )
                }
                .tabItem {
                    Label("Operate", systemImage: "slider.horizontal.3")
                }
                .tag(IPhoneTab.operate)
                .background(Nord.polarNight0.ignoresSafeArea())
                .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)

                NavigationStack {
                    IPhoneLibraryHub(
                        isMacReachable: isMacReachable,
                        queuedCount: queuedCommands.count,
                        openSettings: { showsSettings = true }
                    )
                }
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .tag(IPhoneTab.library)
                .background(Nord.polarNight0.ignoresSafeArea())
                .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
                .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            }
            .tint(Nord.frost1)
            .background(Nord.polarNight0.ignoresSafeArea())
            .toolbarBackground(Nord.polarNight0, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height),
                              abs(value.translation.width) > 72 else {
                            return
                        }
                        selectedTab = selectedTab.adjacent(forHorizontalSwipe: value.translation.width)
                    }
            )
        }
        .sheet(item: $notificationRoute) { route in
            IPhoneApprovalSheet(
                fixture: route.fixture,
                isMacReachable: isMacReachable,
                approvalReceipt: $approvalReceipt
            )
        }
        .sheet(item: $newDraftRoute) { route in
            IPhoneNewDraftSheet(projectName: route.projectName)
        }
        .fullScreenCover(isPresented: $showsSettings) {
            IPhoneSettingsControlSurface()
        }
    }
}

private enum IPhoneTab: String, CaseIterable, Identifiable {
    case home
    case work
    case projects
    case operate
    case library

    var id: String { rawValue }

    func adjacent(forHorizontalSwipe translation: CGFloat) -> IPhoneTab {
        guard let currentIndex = Self.allCases.firstIndex(of: self) else { return self }
        let step = translation < 0 ? 1 : -1
        let targetIndex = min(max(currentIndex + step, 0), Self.allCases.count - 1)
        return Self.allCases[targetIndex]
    }
}

private struct IPhoneNewDraftRoute: Identifiable {
    let id = UUID()
    let projectName: String?
}

private enum IPhoneFixtureRefresh {
    static func wait() async {
        try? await _Concurrency.Task<Never, Never>.sleep(nanoseconds: 350_000_000)
    }
}

private extension View {
    func iPhoneFixtureRefreshable() -> some View {
        refreshable {
            await IPhoneFixtureRefresh.wait()
        }
    }
}

// MARK: - Full remote control centre

private struct IPhoneCommandCenter: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let startNewDraft: () -> Void
    let chooseTab: (IPhoneTab) -> Void
    let chooseWorkProjection: (IPhoneWorkProjection) -> Void
    let openSettings: () -> Void
    @State private var localNotice: String?

    private let attentionFixtures = Phase0Fixtures.all.filter { $0.phoneAttention != .none }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneControlTitle(
                    title: "Kaname",
                    eyebrow: "COMMAND CENTRE",
                    trailingLabel: "Full remote"
                )

                NavigationLink {
                    IPhoneQueueView(
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands
                    )
                } label: {
                    IPhoneReachabilityCard(
                        isMacReachable: isMacReachable,
                        queuedCount: queuedCommands.count
                    )
                }
                .buttonStyle(.plain)

                IPhoneSectionHeader(
                    title: "Needs attention",
                    detail: "Decisions, reviews, and failures"
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(attentionFixtures, id: \.name) { fixture in
                            NavigationLink {
                                IPhoneThreadDetail(
                                    fixture: fixture,
                                    isMacReachable: $isMacReachable,
                                    queuedCommands: $queuedCommands,
                                    approvalReceipt: $approvalReceipt
                                )
                            } label: {
                                IPhoneAttentionCard(fixture: fixture)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }

                IPhoneSectionHeader(
                    title: "Quick control",
                    detail: "Frequent actions, one tap away"
                )

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    IPhoneActionTile(
                        title: "Start work",
                        detail: "New project or task",
                        icon: "plus.circle.fill",
                        tint: Nord.frost1,
                        action: startNewDraft
                    )
                    IPhoneActionTile(
                        title: "Ask an agent",
                        detail: "Open Work",
                        icon: "sparkles",
                        tint: Nord.auroraPurple,
                        action: { chooseTab(.work) }
                    )
                    IPhoneActionTile(
                        title: "Review changes",
                        detail: "Diffs and checks",
                        icon: "doc.text.magnifyingglass",
                        tint: Nord.auroraGreen,
                        action: { chooseTab(.projects) }
                    )
                    IPhoneActionTile(
                        title: "Run schedule",
                        detail: "Automations",
                        icon: "play.circle.fill",
                        tint: Nord.auroraYellow,
                        action: { chooseTab(.operate) }
                    )
                }

                IPhoneSectionHeader(
                    title: "Everything in Kaname",
                    detail: "All product areas, always visible"
                )

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    IPhoneAreaTile("Projects", detail: "Worktrees & sessions", icon: "folder.fill", tint: Nord.frost1) {
                        chooseTab(.projects)
                    }
                    IPhoneAreaTile("Work", detail: "Inbox & threads", icon: "bubble.left.and.bubble.right.fill", tint: Nord.auroraPurple) {
                        chooseWorkProjection(.inbox)
                    }
                    IPhoneAreaTile("GitHub & CI", detail: "Stack, runs & failures", icon: "arrow.triangle.branch", tint: Nord.auroraGreen) {
                        chooseTab(.projects)
                    }
                    IPhoneAreaTile("Review & diffs", detail: "Syntax-highlighted", icon: "chevron.left.forwardslash.chevron.right", tint: Nord.frost0) {
                        chooseTab(.projects)
                    }
                    IPhoneAreaTile("Agents", detail: "Sessions & providers", icon: "cpu", tint: Nord.auroraYellow) {
                        chooseTab(.operate)
                    }
                    IPhoneAreaTile("Calendar", detail: "Events & approvals", icon: "calendar", tint: Nord.auroraOrange) {
                        chooseTab(.operate)
                    }
                    IPhoneAreaTile("Schedules", detail: "Cron & automation", icon: "clock.badge.checkmark", tint: Nord.auroraGreen) {
                        chooseTab(.operate)
                    }
                    IPhoneAreaTile("Research", detail: "Evidence & sources", icon: "magnifyingglass", tint: Nord.frost3) {
                        chooseTab(.library)
                    }
                    IPhoneAreaTile("Obsidian", detail: "Project memory", icon: "book.closed.fill", tint: Nord.auroraPurple) {
                        chooseTab(.library)
                    }
                    IPhoneAreaTile("Email", detail: "Drafts & approval", icon: "envelope.fill", tint: Nord.auroraYellow) {
                        chooseWorkProjection(.mail)
                    }
                    IPhoneAreaTile("Files", detail: "Workspace context", icon: "folder.badge.gearshape", tint: Nord.frost2) {
                        chooseTab(.projects)
                    }
                    IPhoneAreaTile("Settings", detail: "Appearance & control", icon: "gearshape.fill", tint: Nord.polarNight3) {
                        openSettings()
                    }
                }

                IPhoneSectionHeader(title: "Now", detail: "Current work and next run")
                IPhoneNowCard(
                    isMacReachable: isMacReachable,
                    queuedCount: queuedCommands.count
                )

                if let approvalReceipt {
                    IPhoneFixtureNotice(text: approvalReceipt)
                }
                if let localNotice {
                    IPhoneFixtureNotice(text: localNotice)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .padding(.bottom, 12)
        }
        .background(Nord.polarNight0)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await IPhoneFixtureRefresh.wait()
            localNotice = "Command Centre refreshed locally. No Mac, provider, or account was contacted."
        }
    }
}

private struct IPhoneWorkHub: View {
    @Binding var projection: IPhoneWorkProjection
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let startNewDraft: () -> Void
    @State private var refreshNotice: String?

    private var visibleFixtures: [Phase0Fixture] {
        switch projection {
        case .inbox:
            Phase0Fixtures.all.filter {
                $0.phoneAttention == .needsResponse ||
                $0.phoneAttention == .needsReview ||
                $0.phoneAttention == .failed
            }
        case .threads:
            Phase0Fixtures.all
        case .mail:
            Phase0Fixtures.all.filter { $0.thread.workspaceKind == .email }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IPhoneControlTitle(
                    title: "Work",
                    eyebrow: "CONVERSATIONS",
                    trailingLabel: "New"
                )

                Picker("Work projection", selection: $projection) {
                    ForEach(IPhoneWorkProjection.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                IPhoneReachabilityCompact(
                    isMacReachable: isMacReachable,
                    queuedCount: queuedCommands.count
                )

                switch projection {
                case .inbox:
                    IPhoneWorkProjectionSummary(
                        title: "Inbox",
                        count: visibleFixtures.count,
                        detail: "Only work that needs a decision, review, or recovery",
                        icon: "tray.full.fill",
                        tint: Nord.auroraYellow
                    )
                case .threads:
                    IPhoneWorkProjectionSummary(
                        title: "Threads",
                        count: visibleFixtures.count,
                        detail: "Every conversation, including active work and history",
                        icon: "bubble.left.and.bubble.right.fill",
                        tint: Nord.frost1
                    )
                case .mail:
                    IPhoneWorkProjectionSummary(
                        title: "Mail",
                        count: visibleFixtures.count,
                        detail: "Drafts and approvals that need a deliberate response",
                        icon: "envelope.fill",
                        tint: Nord.auroraYellow
                    )
                }

                VStack(spacing: 10) {
                    ForEach(visibleFixtures, id: \.name) { fixture in
                        NavigationLink {
                            IPhoneThreadDetail(
                                fixture: fixture,
                                isMacReachable: $isMacReachable,
                                queuedCommands: $queuedCommands,
                                approvalReceipt: $approvalReceipt
                            )
                        } label: {
                            if projection == .inbox {
                                IPhoneWorkRow(fixture: fixture)
                            } else {
                                IPhoneThreadDirectoryRow(fixture: fixture)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id(projection)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                if let refreshNotice {
                    IPhoneFixtureNotice(text: refreshNotice)
                }
            }
            .padding(14)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Work")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.18), value: projection)
        .refreshable {
            await IPhoneFixtureRefresh.wait()
            refreshNotice = "Work refreshed locally. No thread, provider, or email account was contacted."
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                IPhoneFloatingNewAction(action: startNewDraft)
            }
            .padding(.trailing, 18)
            .padding(.vertical, 8)
        }
    }
}

private struct IPhoneProjectsHub: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let startNewDraft: (String?) -> Void
    @State private var searchQuery = ""
    @State private var refreshNotice: String?

    private var matchingProjects: [IPhoneProject] {
        IPhoneProject.fixtureProjects.filter { project in
            searchQuery.isEmpty ||
            project.name.localizedCaseInsensitiveContains(searchQuery) ||
            project.summary.localizedCaseInsensitiveContains(searchQuery) ||
            project.kind.localizedCaseInsensitiveContains(searchQuery) ||
            project.branch.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IPhoneControlTitle(
                    title: "Projects",
                    eyebrow: "CODE & DELIVERY",
                    trailingLabel: "\(IPhoneProject.fixtureProjects.count) total"
                )

                IPhoneProjectSearchField(text: $searchQuery)

                IPhoneProjectDirectorySummary(
                    matchingCount: matchingProjects.count,
                    totalCount: IPhoneProject.fixtureProjects.count
                )

                IPhoneSectionHeader(
                    title: searchQuery.isEmpty ? "Your projects" : "Search results",
                    detail: searchQuery.isEmpty
                        ? "Open a project to inspect only that project’s delivery"
                        : "Results update as you type"
                )

                if matchingProjects.isEmpty {
                    IPhoneEmptyProjectSearch(query: searchQuery)
                } else {
                    VStack(spacing: 9) {
                        ForEach(matchingProjects) { project in
                            NavigationLink {
                                IPhoneProjectOverview(
                                    project: project,
                                    isMacReachable: $isMacReachable,
                                    queuedCommands: $queuedCommands,
                                    startNewDraft: { startNewDraft(project.name) }
                                )
                            } label: {
                                IPhoneProjectDirectoryRow(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                IPhoneFixtureBoundaryCard(
                    title: "Project scope is explicit",
                    detail: "The directory never merges delivery state across projects. Search is local type-ahead fixture data; live projects will preserve the same boundary."
                )
                if let refreshNotice {
                    IPhoneFixtureNotice(text: refreshNotice)
                }
            }
            .padding(14)
            .padding(.bottom, 12)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await IPhoneFixtureRefresh.wait()
            refreshNotice = "Projects refreshed locally. No repository or GitHub API was contacted."
        }
    }
}

private struct IPhoneOperationsHub: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let openApproval: () -> Void
    @State private var refreshNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IPhoneControlTitle(
                    title: "Operate",
                    eyebrow: "AGENTS & AUTOMATION",
                    trailingLabel: "3 healthy"
                )

                IPhoneOperationsHeroCard(isMacReachable: isMacReachable, queuedCount: queuedCommands.count)

                IPhoneSectionHeader(title: "Control plane", detail: "Current state, logs, and safe actions")

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    NavigationLink {
                        IPhoneAgentsView()
                    } label: {
                        IPhoneNavigationTile("Agents", detail: "2 sessions", icon: "cpu", tint: Nord.frost1)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneSchedulesView()
                    } label: {
                        IPhoneNavigationTile("Schedules", detail: "2 planned", icon: "clock.badge.checkmark", tint: Nord.auroraGreen)
                    }
                    .buttonStyle(.plain)

                    Button(action: openApproval) {
                        IPhoneNavigationTile("Calendar", detail: "1 approval", icon: "calendar", tint: Nord.auroraOrange)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneAutomationsView()
                    } label: {
                        IPhoneNavigationTile("Automations", detail: "4 workflows", icon: "bolt.badge.clock", tint: Nord.auroraPurple)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneIntegrationsView()
                    } label: {
                        IPhoneNavigationTile("Integrations", detail: "5 connected", icon: "point.3.connected.trianglepath.dotted", tint: Nord.frost2)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneNotificationRoutesView()
                    } label: {
                        IPhoneNavigationTile("Notifications", detail: "2 rules", icon: "bell.badge", tint: Nord.auroraYellow)
                    }
                    .buttonStyle(.plain)
                }

                IPhoneSectionHeader(title: "Next up", detail: "The plan is visible before it runs")
                IPhoneTimelineCard()

                if let approvalReceipt {
                    IPhoneFixtureNotice(text: approvalReceipt)
                }
                if let refreshNotice {
                    IPhoneFixtureNotice(text: refreshNotice)
                }
            }
            .padding(14)
            .padding(.bottom, 12)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Operate")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await IPhoneFixtureRefresh.wait()
            refreshNotice = "Operations refreshed locally. No agent, schedule, or integration was contacted."
        }
    }
}

private struct IPhoneLibraryHub: View {
    let isMacReachable: Bool
    let queuedCount: Int
    let openSettings: () -> Void
    @State private var refreshNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IPhoneControlTitle(
                    title: "Library",
                    eyebrow: "RESEARCH & PROJECT MEMORY",
                    trailingLabel: "4 collections"
                )

                IPhoneFixtureBoundaryCard(
                    title: isMacReachable ? "Context is available" : "Context is cached for the fixture",
                    detail: isMacReachable
                        ? "No real provider or account is connected in this build."
                        : "\(queuedCount) local commands are waiting for Mac reconciliation."
                )

                IPhoneSectionHeader(title: "Knowledge collections", detail: "Evidence, memory, and decisions in one coherent library")

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    NavigationLink { IPhoneKnowledgeDetailView(collection: .research) } label: {
                        IPhoneNavigationTile("Research", detail: "Sources & evidence", icon: "magnifyingglass", tint: Nord.frost1)
                    }
                    .buttonStyle(.plain)
                    NavigationLink { IPhoneKnowledgeDetailView(collection: .projectMemory) } label: {
                        IPhoneNavigationTile("Project memory", detail: "Notes & acceptance gates", icon: "book.closed.fill", tint: Nord.auroraPurple)
                    }
                    .buttonStyle(.plain)
                    NavigationLink { IPhoneKnowledgeDetailView(collection: .decisions) } label: {
                        IPhoneNavigationTile("Decisions", detail: "Accepted & proposed", icon: "checkmark.seal.fill", tint: Nord.auroraGreen)
                    }
                    .buttonStyle(.plain)
                    NavigationLink { IPhoneKnowledgeDetailView(collection: .sourceInbox) } label: {
                        IPhoneNavigationTile("Source inbox", detail: "Capture & triage", icon: "tray.full.fill", tint: Nord.frost2)
                    }
                    .buttonStyle(.plain)
                }
                if let refreshNotice {
                    IPhoneFixtureNotice(text: refreshNotice)
                }
            }
            .padding(14)
            .padding(.bottom, 12)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .refreshable {
            await IPhoneFixtureRefresh.wait()
            refreshNotice = "Library refreshed locally. No Obsidian vault or external source was contacted."
        }
    }
}

private enum IPhoneWorkProjection: String, CaseIterable, Identifiable {
    case inbox
    case threads
    case mail

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct IPhoneProject: Identifiable {
    let id: String
    let name: String
    let kind: String
    let summary: String
    let branch: String
    let deliveryState: String
    let deliveryDetail: String
    let changedFiles: String
    let checks: String
    let ciStatus: String
    let tint: Color
    let icon: String

    static let kaname = IPhoneProject(
        id: "kaname",
        name: "Kaname",
        kind: "Agent operating system",
        summary: "iPhone full-remote rebuild",
        branch: "feature/iphone-full-remote",
        deliveryState: "Active",
        deliveryDetail: "Coding session running",
        changedFiles: "3 files changed",
        checks: "4 checks passed",
        ciStatus: "1 failure",
        tint: Nord.frost1,
        icon: "square.grid.2x2.fill"
    )

    static let fixtureProjects: [IPhoneProject] = [
        kaname,
        IPhoneProject(
            id: "mori",
            name: "Mori",
            kind: "Code quality",
            summary: "Release and stacked pull-request workflow",
            branch: "release/v0.3.0",
            deliveryState: "Ready",
            deliveryDetail: "Release checks are green",
            changedFiles: "1 documentation file",
            checks: "All checks passed",
            ciStatus: "Healthy",
            tint: Nord.auroraGreen,
            icon: "leaf.fill"
        ),
        IPhoneProject(
            id: "vlc-media-watcher",
            name: "VLC Media Watcher",
            kind: "Media automation",
            summary: "Provider-agnostic credential planning",
            branch: "main",
            deliveryState: "Needs decision",
            deliveryDetail: "Credential design review",
            changedFiles: "No pending code changes",
            checks: "Planning boundary",
            ciStatus: "No run",
            tint: Nord.auroraYellow,
            icon: "play.rectangle.fill"
        ),
        IPhoneProject(
            id: "tanktics",
            name: "Tanktics",
            kind: "Game preservation",
            summary: "Compatibility evidence and validation gates",
            branch: "phase-9",
            deliveryState: "Research",
            deliveryDetail: "Evidence review in progress",
            changedFiles: "2 research notes",
            checks: "Gate review",
            ciStatus: "Not applicable",
            tint: Nord.auroraPurple,
            icon: "cube.fill"
        ),
        IPhoneProject(
            id: "study-bot",
            name: "Study Bot",
            kind: "Japanese learning",
            summary: "Classroom and learner workflow",
            branch: "feature/classroom-flow",
            deliveryState: "Paused",
            deliveryDetail: "Awaiting next study session",
            changedFiles: "0 files changed",
            checks: "Last run passed",
            ciStatus: "Healthy",
            tint: Nord.auroraOrange,
            icon: "character.book.closed.fill"
        ),
    ]
}

private struct IPhoneProjectSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Nord.frost1)
            TextField("Search projects", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Nord.snowStorm0)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Nord.snowStorm0.opacity(0.48))
                }
                .accessibilityLabel("Clear project search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Nord.polarNight3.opacity(0.72), lineWidth: 1)
        }
    }
}

private struct IPhoneProjectDirectorySummary: View {
    let matchingCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Nord.frost1)
            Text("\(matchingCount) of \(totalCount) projects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Nord.snowStorm0)
            Spacer()
            Text("Type to filter")
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.56))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Nord.frost3.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct IPhoneProjectDirectoryRow: View {
    let project: IPhoneProject

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: project.icon)
                .foregroundStyle(project.tint)
                .frame(width: 38, height: 38)
                .background(project.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Nord.snowStorm0)
                    Spacer(minLength: 4)
                    IPhonePill(project.deliveryState, tint: project.tint)
                }
                Text(project.summary)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.68))
                    .lineLimit(1)
                Text("\(project.kind) · \(project.branch)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Nord.snowStorm0.opacity(0.46))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Nord.snowStorm0.opacity(0.38))
        }
        .padding(12)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneEmptyProjectSearch: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.title3)
                .foregroundStyle(Nord.frost1)
            Text("No projects match “\(query)”")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Nord.snowStorm0)
            Text("Try a project name, branch, or project type.")
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.60))
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneControlTitle: View {
    let title: String
    let eyebrow: String
    let trailingLabel: String

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Nord.frost1)
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(Nord.snowStorm0)
            }
            Spacer()
            Text(trailingLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Nord.frost1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Nord.frost3.opacity(0.20), in: Capsule())
        }
    }
}

private struct IPhoneSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Nord.snowStorm0)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.62))
        }
    }
}

private struct IPhoneReachabilityCard: View {
    let isMacReachable: Bool
    let queuedCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: isMacReachable ? "desktopcomputer.and.macbook" : "wifi.slash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isMacReachable ? Nord.auroraGreen : Nord.auroraOrange)
                .frame(width: 36, height: 36)
                .background((isMacReachable ? Nord.auroraGreen : Nord.auroraOrange).opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(isMacReachable ? "Mac reachable" : "Mac unavailable")
                    .font(.headline)
                    .foregroundStyle(Nord.snowStorm0)
                Text(isMacReachable
                    ? "Control is available. This fixture dispatches nothing."
                    : "\(queuedCount) local commands held locally. Tap to edit.")
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Nord.snowStorm0.opacity(0.45))
                .padding(.top, 5)
        }
        .padding(12)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(isMacReachable ? Nord.auroraGreen : Nord.auroraOrange)
                .frame(width: 3)
                .padding(.vertical, 12)
        }
    }
}

private struct IPhoneReachabilityCompact: View {
    let isMacReachable: Bool
    let queuedCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMacReachable ? "checkmark.circle.fill" : "wifi.slash")
                .foregroundStyle(isMacReachable ? Nord.auroraGreen : Nord.auroraOrange)
            Text(isMacReachable ? "Mac reachable" : "Mac unavailable")
                .font(.caption.weight(.semibold))
            Spacer()
            Text("Queue \(queuedCount)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Nord.frost1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IPhoneAttentionCard: View {
    let fixture: Phase0Fixture

    var body: some View {
        let attention = fixture.phoneAttention
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: attention.phoneSymbolName)
                    .foregroundStyle(attention.tint)
                Spacer()
                Text(attention.displayName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(attention.tint)
            }
            Text(fixture.thread.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Nord.snowStorm0)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(fixture.thread.workspaceKind.displayName)
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.62))
        }
        .frame(width: 124, height: 86, alignment: .topLeading)
        .padding(10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(attention.tint.opacity(0.30), lineWidth: 1)
        }
    }
}

private struct IPhoneActionTile: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.62))
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .padding(10)
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct IPhoneAreaTile: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void

    init(_ title: String, detail: String, icon: String, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Nord.snowStorm0)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Nord.snowStorm0.opacity(0.60))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Nord.polarNight1.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct IPhoneNowCard: View {
    let isMacReachable: Bool
    let queuedCount: Int

    var body: some View {
        VStack(spacing: 0) {
            IPhoneMetricRow(label: "Coding session", value: "Implementing iPhone remote", icon: "hammer.fill", tint: Nord.frost1)
            Divider().overlay(Nord.polarNight3)
            IPhoneMetricRow(label: "Next schedule", value: "Context refresh · 20:00 JST", icon: "clock", tint: Nord.auroraGreen)
            Divider().overlay(Nord.polarNight3)
            IPhoneMetricRow(label: "Local queue", value: "\(queuedCount) pending · \(isMacReachable ? "reconciliation ready" : "Mac unavailable")", icon: "arrow.up.arrow.down", tint: Nord.auroraOrange)
        }
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneMetricRow: View {
    let label: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.62))
            }
            Spacer()
        }
        .padding(13)
    }
}

private struct IPhoneWorkRow: View {
    let fixture: Phase0Fixture

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fixture.phoneAttention.phoneSymbolName)
                .foregroundStyle(fixture.phoneAttention.tint)
                .frame(width: 34, height: 34)
                .background(fixture.phoneAttention.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fixture.thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Nord.snowStorm0)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(fixture.phoneAttention.displayName)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(fixture.phoneAttention.tint)
                }
                Text("\(fixture.thread.workspaceKind.displayName) · \(fixture.providerSession.provider)")
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.64))
                    .lineLimit(1)
                Text(fixture.phoneAgentSummary)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.52))
                    .lineLimit(2)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Nord.snowStorm0.opacity(0.38))
                .padding(.top, 5)
        }
        .padding(13)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneWorkProjectionSummary: View {
    let title: String
    let count: Int
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(11)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct IPhoneThreadDirectoryRow: View {
    let fixture: Phase0Fixture

    private var activityLabel: String {
        switch fixture.phoneAttention {
        case .running: "Active now"
        case .queued: "Queued"
        case .needsResponse: "Waiting on you"
        case .needsReview: "Review ready"
        case .failed: "Failure retained"
        case .interrupted: "Interrupted"
        case .none: "No action needed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: fixture.thread.workspaceKind.symbolName)
                .foregroundStyle(fixture.phoneAttention.tint)
                .frame(width: 32, height: 32)
                .background(fixture.phoneAttention.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fixture.thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Nord.snowStorm0)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(activityLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(fixture.phoneAttention.tint)
                }
                Text("\(fixture.thread.workspaceKind.displayName) · \(fixture.providerSession.provider)")
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.60))
                Text(fixture.phoneAgentSummary)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.48))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Nord.snowStorm0.opacity(0.36))
                .padding(.top, 4)
        }
        .padding(11)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct IPhoneProjectHeroCard: View {
    let project: IPhoneProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(project.deliveryState.uppercased()) PROJECT", systemImage: "circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(project.tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nord.snowStorm0.opacity(0.48))
            }
            Text(project.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Nord.snowStorm0)
            Text(project.summary)
                .font(.subheadline)
                .foregroundStyle(Nord.snowStorm0.opacity(0.68))
            HStack(spacing: 8) {
                IPhonePill(project.changedFiles, tint: project.tint)
                IPhonePill(project.checks, tint: Nord.auroraGreen)
                IPhonePill(project.ciStatus, tint: project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraYellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(
            LinearGradient(
                colors: [Nord.polarNight2, Nord.polarNight1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(project.tint.opacity(0.34), lineWidth: 1)
        }
    }
}

private struct IPhonePill: View {
    let title: String
    let tint: Color

    init(_ title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct IPhoneProjectControlRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let badge: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 7) {
                IPhonePill(badge, tint: tint)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nord.snowStorm0.opacity(0.40))
            }
        }
        .padding(13)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct IPhoneOperationsHeroCard: View {
    let isMacReachable: Bool
    let queuedCount: Int

    var body: some View {
        HStack(spacing: 0) {
            IPhoneOperationMetric(value: "2", label: "sessions", tint: Nord.frost1)
            Divider().overlay(Nord.polarNight3).padding(.vertical, 14)
            IPhoneOperationMetric(value: "2", label: "schedules", tint: Nord.auroraGreen)
            Divider().overlay(Nord.polarNight3).padding(.vertical, 14)
            IPhoneOperationMetric(value: "\(queuedCount)", label: isMacReachable ? "queued" : "held local", tint: Nord.auroraOrange)
        }
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneOperationMetric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Nord.snowStorm0.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct IPhoneNavigationTile: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    init(_ title: String, detail: String, icon: String, tint: Color) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 37, height: 37)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 1)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Nord.snowStorm0)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.62))
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct IPhoneTimelineCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            IPhoneTimelineRow(time: "Now", title: "iPhone remote rebuild", detail: "Coding session active", tint: Nord.frost1)
            IPhoneTimelineRow(time: "17:30", title: "Review current diff", detail: "3 files · checks green", tint: Nord.auroraGreen)
            IPhoneTimelineRow(time: "20:00", title: "Project-context refresh", detail: "Scheduled · waits for Mac", tint: Nord.auroraOrange)
        }
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneTimelineRow: View {
    let time: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .leading)
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.60))
            }
        }
    }
}

private struct IPhoneFixtureBoundaryCard: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Nord.frost1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Nord.snowStorm0)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(Nord.frost3.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneFixtureNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(Nord.frost1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Nord.frost3.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IPhoneFloatingNewAction: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title3.weight(.bold))
                .frame(width: 54, height: 54)
                .background(Nord.frost2, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Nord.frost0.opacity(0.7), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Nord.polarNight0)
        .accessibilityLabel("Start a new conversation or task")
        .accessibilityHint("Opens a new task or conversation draft")
    }
}

private struct IPhoneProjectFloatingAction: View {
    let projectName: String
    let isMacReachable: Bool
    let startTask: () -> Void
    let refreshProject: () -> Void

    var body: some View {
        Button(action: startTask) {
            Image(systemName: "plus")
                .font(.title3.weight(.bold))
                .frame(width: 54, height: 54)
                .background(Nord.frost2, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Nord.frost0.opacity(0.7), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Nord.polarNight0)
        .contextMenu {
            Button(action: startTask) {
                Label("Start task", systemImage: "plus")
            }
            Button(action: refreshProject) {
                Label(isMacReachable ? "Refresh project" : "Queue project refresh", systemImage: "arrow.clockwise")
            }
        }
        .accessibilityLabel("Project actions")
        .accessibilityHint("Double-tap to start a task for \(projectName). Touch and hold for project actions.")
    }
}

// MARK: - Project, review, and delivery surfaces

private struct IPhoneProjectOverview: View {
    let project: IPhoneProject
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    let startNewDraft: () -> Void
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IPhoneProjectHeroCard(project: project)
                IPhoneSectionHeader(
                    title: "\(project.name) delivery",
                    detail: "Everything below belongs to this project only"
                )
                IPhoneProjectStatusTable(project: project)

                VStack(spacing: 10) {
                    NavigationLink {
                        IPhoneMobileDiffView(project: project)
                    } label: {
                        IPhoneProjectControlRow(
                            title: "Work Review",
                            detail: "\(project.changedFiles) · \(project.checks)",
                            icon: "doc.text.magnifyingglass",
                            tint: Nord.auroraGreen,
                            badge: project.deliveryState
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneGitHubStackView(project: project)
                    } label: {
                        IPhoneProjectControlRow(
                            title: "GitHub & CI",
                            detail: project.ciStatus == "Healthy" ? "Checks are healthy" : project.ciStatus,
                            icon: "arrow.triangle.branch",
                            tint: project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraRed,
                            badge: project.ciStatus
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneProjectSessionsView()
                    } label: {
                        IPhoneProjectControlRow(
                            title: "Agent sessions",
                            detail: "\(project.name) context and provider runs",
                            icon: "cpu",
                            tint: Nord.frost1,
                            badge: "2"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        IPhoneWorktreeView()
                    } label: {
                        IPhoneProjectControlRow(
                            title: "Worktrees & files",
                            detail: project.branch,
                            icon: "folder.badge.gearshape",
                            tint: Nord.auroraPurple,
                            badge: project.changedFiles
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let notice {
                    IPhoneFixtureNotice(text: notice)
                }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                IPhoneProjectFloatingAction(
                    projectName: project.name,
                    isMacReachable: isMacReachable,
                    startTask: startNewDraft,
                    refreshProject: refreshProjectState
                )
            }
            .padding(.trailing, 18)
            .padding(.vertical, 8)
        }
    }

    private func refreshProjectState() {
        if isMacReachable {
            notice = "Local fixture sync requested. No workspace, agent, or GitHub API was contacted."
        } else {
            queuedCommands.append(
                PhoneQueuedCommand(
                    id: UUID(),
                    position: queuedCommands.count + 1,
                    threadTitle: "\(project.name) project",
                    body: "Refresh project state",
                    createdLabel: "Just now"
                )
            )
            notice = "Project refresh queued locally at position \(queuedCommands.count)."
        }
    }
}

private struct IPhoneProjectStatusTable: View {
    let project: IPhoneProject

    var body: some View {
        VStack(spacing: 0) {
            IPhoneMetricRow(label: "Branch", value: project.branch, icon: "arrow.triangle.branch", tint: project.tint)
            Divider().overlay(Nord.polarNight3)
            IPhoneMetricRow(label: "Delivery", value: project.deliveryDetail, icon: "cpu", tint: project.tint)
            Divider().overlay(Nord.polarNight3)
            IPhoneMetricRow(label: "Checks", value: project.checks, icon: "checkmark.seal", tint: Nord.auroraGreen)
            Divider().overlay(Nord.polarNight3)
            IPhoneMetricRow(label: "CI / CD", value: project.ciStatus, icon: "arrow.triangle.branch", tint: project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraYellow)
        }
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneMobileDiffView: View {
    let project: IPhoneProject
    @State private var reviewNotice: String?

    init(project: IPhoneProject = .kaname) {
        self.project = project
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneControlTitle(title: "Review", eyebrow: "\(project.name.uppercased()) · MOBILE DIFF", trailingLabel: project.changedFiles)
                IPhoneFixtureBoundaryCard(
                    title: "Syntax-highlighted review",
                    detail: "Code is readable and actionable on the phone. Comment, approve, and fix flows remain explicit before any real write happens."
                )

                IPhoneSectionHeader(title: "IPhoneControlSurface.swift", detail: "\(project.name) fixture hunk · +86 · −19")
                IPhoneDiffCard()

                IPhoneSectionHeader(title: "Checks", detail: "Result from the local fixture")
                VStack(spacing: 0) {
                    IPhoneCheckRow(name: "Swift tests", result: "Passed", tint: Nord.auroraGreen)
                    Divider().overlay(Nord.polarNight3)
                    IPhoneCheckRow(name: "iOS simulator build", result: "Passed", tint: Nord.auroraGreen)
                    Divider().overlay(Nord.polarNight3)
                    IPhoneCheckRow(name: "GitHub CI", result: "1 failed", tint: Nord.auroraRed)
                }
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 10) {
                    Button("Request changes") {
                        reviewNotice = "Local fixture review request saved. No GitHub comment was created."
                    }
                    .buttonStyle(.bordered)
                    .tint(Nord.auroraYellow)
                    Button("Approve review") {
                        reviewNotice = "Local fixture approval recorded. A real merge would require current checks and explicit authority."
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Nord.frost3)
                }
                .frame(maxWidth: .infinity)

                if let reviewNotice {
                    IPhoneFixtureNotice(text: reviewNotice)
                }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Work Review")
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
    }
}

private enum IPhoneDiffKind {
    case context
    case addition
    case removal
}

private struct IPhoneCodeToken {
    let text: String
    let tint: Color
}

private struct IPhoneDiffLine: View {
    let kind: IPhoneDiffKind
    let number: String
    let tokens: [IPhoneCodeToken]

    private var marker: String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .removal: "−"
        }
    }

    private var markerTint: Color {
        switch kind {
        case .context: Nord.polarNight3
        case .addition: Nord.auroraGreen
        case .removal: Nord.auroraRed
        }
    }

    private var background: Color {
        switch kind {
        case .context: .clear
        case .addition: Nord.auroraGreen.opacity(0.10)
        case .removal: Nord.auroraRed.opacity(0.10)
        }
    }

    private var rendered: Text {
        tokens.reduce(Text("")) { rendered, token in
            rendered + Text(token.text).foregroundColor(token.tint)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .foregroundStyle(Nord.polarNight3)
                .frame(width: 22, alignment: .trailing)
            Text(marker)
                .foregroundStyle(markerTint)
                .frame(width: 8)
            rendered
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(background)
    }
}

private struct IPhoneDiffCard: View {
    private func token(_ text: String, _ tint: Color) -> IPhoneCodeToken {
        IPhoneCodeToken(text: text, tint: tint)
    }

    var body: some View {
        VStack(spacing: 0) {
            IPhoneDiffLine(kind: .context, number: "24", tokens: [token("private enum ", Nord.auroraPurple), token("IPhoneTab", Nord.frost1), token(": String {", Nord.snowStorm0)])
            IPhoneDiffLine(kind: .removal, number: "25", tokens: [token("    case ", Nord.auroraRed), token("activity", Nord.snowStorm0)])
            IPhoneDiffLine(kind: .removal, number: "26", tokens: [token("    case ", Nord.auroraRed), token("inbox", Nord.snowStorm0)])
            IPhoneDiffLine(kind: .removal, number: "27", tokens: [token("    case ", Nord.auroraRed), token("threads", Nord.snowStorm0)])
            IPhoneDiffLine(kind: .addition, number: "25", tokens: [token("    case ", Nord.auroraGreen), token("home", Nord.frost1)])
            IPhoneDiffLine(kind: .addition, number: "26", tokens: [token("    case ", Nord.auroraGreen), token("work", Nord.frost1)])
            IPhoneDiffLine(kind: .addition, number: "27", tokens: [token("    case ", Nord.auroraGreen), token("projects", Nord.frost1)])
            IPhoneDiffLine(kind: .addition, number: "28", tokens: [token("    case ", Nord.auroraGreen), token("operate", Nord.frost1)])
            IPhoneDiffLine(kind: .addition, number: "29", tokens: [token("    case ", Nord.auroraGreen), token("spaces", Nord.frost1)])
            IPhoneDiffLine(kind: .context, number: "30", tokens: [token("}", Nord.snowStorm0)])
        }
        .padding(.vertical, 8)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Nord.polarNight3.opacity(0.75), lineWidth: 1)
        }
    }
}

private struct IPhoneCheckRow: View {
    let name: String
    let result: String
    let tint: Color

    var body: some View {
        HStack {
            Image(systemName: result == "Passed" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(tint)
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Nord.snowStorm0)
            Spacer()
            Text(result)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(13)
    }
}

private struct IPhoneGitHubStackView: View {
    let project: IPhoneProject
    @State private var notice: String?

    init(project: IPhoneProject = .kaname) {
        self.project = project
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneFixtureBoundaryCard(
                    title: "\(project.name) GitHub delivery",
                    detail: "This scope belongs only to \(project.name). A real remote will load live links, run detail, logs, and safe agent handoff from its selected repository."
                )
                IPhoneSectionHeader(title: "Stack", detail: project.branch)
                VStack(spacing: 10) {
                    IPhonePullRequestCard(number: "#18", title: project.summary, branch: project.branch, state: project.deliveryState, tint: project.tint)
                    IPhonePullRequestCard(number: "#15", title: "Project delivery baseline", branch: "main", state: project.checks, tint: Nord.auroraGreen)
                }
                IPhoneSectionHeader(title: "CI / CD", detail: "Errors belong beside the action that can resolve them")
                IPhoneCIFailureCard(project: project)
                Button {
                    notice = "A local task draft to investigate \(project.name)’s CI state was prepared. No agent or GitHub workflow was started."
                } label: {
                    Label("Ask agent to investigate CI", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Nord.frost3)
                if let notice {
                    IPhoneFixtureNotice(text: notice)
                }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle("\(project.name) GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhonePullRequestCard: View {
    let number: String
    let title: String
    let branch: String
    let state: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                IPhonePill(state, tint: tint)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Nord.snowStorm0)
            Text(branch)
                .font(.caption.monospaced())
                .foregroundStyle(Nord.snowStorm0.opacity(0.60))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

private struct IPhoneCIFailureCard: View {
    let project: IPhoneProject

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Build and test", systemImage: project.ciStatus == "Healthy" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraRed)
                Spacer()
                Text(project.ciStatus == "Healthy" ? "last run passed" : "needs triage")
                    .font(.caption)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.55))
            }
            Text(project.ciStatus == "Healthy"
                 ? "The fixture reports no blocking CI issue for this project."
                 : "SwiftLint · IPhoneControlSurface.swift: tab label exceeds the configured length")
                .font(.caption)
                .foregroundStyle(Nord.snowStorm0.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                IPhonePill("Logs", tint: Nord.frost1)
                IPhonePill("Workflow", tint: Nord.frost1)
                IPhonePill(project.ciStatus == "Healthy" ? "No retry needed" : "Retry needs approval", tint: project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraYellow)
            }
        }
        .padding(14)
        .background((project.ciStatus == "Healthy" ? Nord.auroraGreen : Nord.auroraRed).opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneProjectSessionsView: View {
    var body: some View {
        List {
            Section("Active") {
                IPhoneSessionRow(name: "iPhone full remote", provider: "Codex", state: "Running", tint: Nord.frost1)
                IPhoneSessionRow(name: "GitHub CI triage", provider: "Codex", state: "Needs start", tint: Nord.auroraYellow)
            }
            Section("Recent") {
                IPhoneSessionRow(name: "Provider research", provider: "OpenCode", state: "Paused", tint: Nord.auroraPurple)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Agent sessions")
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneSessionRow: View {
    let name: String
    let provider: String
    let state: String
    let tint: Color

    var body: some View {
        HStack {
            Image(systemName: "cpu")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium))
                Text(provider).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
    }
}

private struct IPhoneWorktreeView: View {
    var body: some View {
        List {
            Section("Worktrees") {
                IPhoneSessionRow(name: "main", provider: "clean · 0 changes", state: "Ready", tint: Nord.auroraGreen)
                IPhoneSessionRow(name: "feature/iphone-full-remote", provider: "3 changed files", state: "Active", tint: Nord.frost1)
            }
            Section("Changed files") {
                Text("IPhoneControlSurface.swift")
                Text("PrototypeStyle.swift")
                Text("iPhone Full Remote UX Research and Direction.md")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Worktrees & files")
        .iPhoneFixtureRefreshable()
    }
}

// MARK: - Operations

private struct IPhoneAgentsView: View {
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneFixtureBoundaryCard(title: "Agent control", detail: "Sessions expose status, context, and safe task entry. This fixture does not contact a provider.")
                IPhoneProjectControlRow(title: "Codex", detail: "1 active coding session · tools available", icon: "cpu", tint: Nord.frost1, badge: "Ready")
                IPhoneProjectControlRow(title: "OpenCode", detail: "1 paused research session", icon: "sparkles", tint: Nord.auroraPurple, badge: "Paused")
                Button("Start a local agent task") {
                    notice = "Local agent-task draft created. No provider was contacted."
                }
                .buttonStyle(.borderedProminent)
                .tint(Nord.frost3)
                .frame(maxWidth: .infinity)
                if let notice { IPhoneFixtureNotice(text: notice) }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneSchedulesView: View {
    @State private var contextRefreshEnabled = true
    @State private var digestEnabled = true
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneFixtureBoundaryCard(title: "Scheduled work", detail: "Pause and run controls only change local fixture state. Production will show authority, time zone, next run, and full run evidence.")
                IPhoneScheduleCard(title: "Project-context refresh", schedule: "Daily · 20:00 JST", enabled: $contextRefreshEnabled, notice: $notice)
                IPhoneScheduleCard(title: "Morning delivery digest", schedule: "Weekdays · 08:30 JST", enabled: $digestEnabled, notice: $notice)
                if let notice { IPhoneFixtureNotice(text: notice) }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneScheduleCard: View {
    let title: String
    let schedule: String
    @Binding var enabled: Bool
    @Binding var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Nord.snowStorm0)
                    Text(schedule).font(.caption).foregroundStyle(Nord.snowStorm0.opacity(0.60))
                }
                Spacer()
                Toggle(title, isOn: $enabled)
                    .labelsHidden()
                    .tint(Nord.frost1)
            }
            HStack {
                Text(enabled ? "Next: today" : "Paused")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(enabled ? Nord.auroraGreen : Nord.auroraYellow)
                Spacer()
                Button("Run now") {
                    notice = "Local run request recorded for \(title). No automation was dispatched."
                }
                .buttonStyle(.bordered)
                .tint(Nord.frost1)
            }
        }
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct IPhoneAutomationsView: View {
    var body: some View {
        List {
            Section("Workflows") {
                IPhoneSessionRow(name: "CI failure triage", provider: "Awaiting explicit start", state: "Manual", tint: Nord.auroraYellow)
                IPhoneSessionRow(name: "Knowledge refresh", provider: "Writes proposed note", state: "Scheduled", tint: Nord.auroraGreen)
                IPhoneSessionRow(name: "Calendar handoff", provider: "Approval-gated", state: "Protected", tint: Nord.auroraOrange)
                IPhoneSessionRow(name: "Release stack", provider: "Checks then delivery", state: "Manual", tint: Nord.frost1)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Automations")
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneIntegrationsView: View {
    var body: some View {
        List {
            Section("Connected surfaces") {
                IPhoneSessionRow(name: "GitHub", provider: "PRs, CI, stack", state: "Fixture", tint: Nord.frost1)
                IPhoneSessionRow(name: "Obsidian", provider: "Project memory", state: "Fixture", tint: Nord.auroraPurple)
                IPhoneSessionRow(name: "Calendar", provider: "Approval path", state: "Fixture", tint: Nord.auroraOrange)
                IPhoneSessionRow(name: "Email", provider: "Draft and send", state: "Fixture", tint: Nord.auroraYellow)
                IPhoneSessionRow(name: "Providers", provider: "Agent sessions", state: "Fixture", tint: Nord.auroraGreen)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Integrations")
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneNotificationRoutesView: View {
    var body: some View {
        List {
            Section("Current rules") {
                IPhoneSessionRow(name: "Approval required", provider: "Calendar decision", state: "Enabled", tint: Nord.auroraYellow)
                IPhoneSessionRow(name: "CI failure", provider: "GitHub workflow", state: "Enabled", tint: Nord.auroraRed)
            }
            Section("Privacy boundary") {
                Text("The fixture shows no sensitive content in notification previews and sends no notification.")
                    .font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Notifications")
        .iPhoneFixtureRefreshable()
    }
}

// MARK: - Knowledge and settings

private enum IPhoneKnowledgeCollection: String {
    case research
    case projectMemory
    case decisions
    case sourceInbox

    var title: String {
        switch self {
        case .research: "Research"
        case .projectMemory: "Project memory"
        case .decisions: "Decisions"
        case .sourceInbox: "Source inbox"
        }
    }

    var detail: String {
        switch self {
        case .research: "Evidence maps, source links, and open questions remain visible alongside the work they guide."
        case .projectMemory: "The selected project’s durable notes, acceptance gates, and working context are available here."
        case .decisions: "Accepted choices, proposals, and their evidence remain separate from open tasks and conversation history."
        case .sourceInbox: "Untriaged sources and captures wait here until they become research evidence, project memory, or a task."
        }
    }

    var icon: String {
        switch self {
        case .research: "magnifyingglass"
        case .projectMemory: "book.closed.fill"
        case .decisions: "checkmark.seal.fill"
        case .sourceInbox: "tray.full.fill"
        }
    }
}

private struct IPhoneKnowledgeDetailView: View {
    let collection: IPhoneKnowledgeCollection
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: collection.icon)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Nord.frost1)
                    .frame(width: 56, height: 56)
                    .background(Nord.frost3.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(collection.detail)
                    .font(.body)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.78))
                IPhoneSectionHeader(title: "Fixture content", detail: "The destination is intentionally present, awaiting its live adapter")
                VStack(spacing: 0) {
                    IPhoneMetricRow(label: "Selected project", value: "Kaname", icon: "folder.fill", tint: Nord.frost1)
                    Divider().overlay(Nord.polarNight3)
                    IPhoneMetricRow(label: "Last update", value: "Just now · local fixture", icon: "clock", tint: Nord.auroraGreen)
                    Divider().overlay(Nord.polarNight3)
                    IPhoneMetricRow(label: "Authority", value: "No external service contacted", icon: "checkmark.shield", tint: Nord.auroraYellow)
                }
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button("Create local \(collection.title.lowercased()) draft") {
                    notice = "Local \(collection.title.lowercased()) draft created. No external state changed."
                }
                .buttonStyle(.borderedProminent)
                .tint(Nord.frost3)
                .frame(maxWidth: .infinity)
                if let notice { IPhoneFixtureNotice(text: notice) }
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
    }
}

private struct IPhoneSettingsControlSurface: View {
    @Environment(\.dismiss) private var dismiss
    @State private var usesNord = true
    @State private var haptics = true
    @State private var showSensitivePreviews = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title)
                            .foregroundStyle(Nord.frost1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Justin’s Kaname")
                                .font(.headline)
                            Text("iPhone remote control")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Appearance") {
                    Toggle("Use Nord", isOn: $usesNord)
                    NavigationLink("Theme and contrast") {
                        IPhoneSettingsDetail(title: "Theme and contrast", detail: "Nord is the personal default. The open-source product will offer configurable themes with the same accessible state hierarchy.")
                    }
                    Toggle("Haptic feedback", isOn: $haptics)
                }

                Section("Remote control") {
                    NavigationLink("Mac connection and queue") {
                        IPhoneSettingsDetail(title: "Mac connection and queue", detail: "Production will configure authority, encrypted local intent, delivery receipts, stale-decision rejection, and recovery without exposing secrets in the app.")
                    }
                    NavigationLink("Agent and provider defaults") {
                        IPhoneSettingsDetail(title: "Agent and provider defaults", detail: "Choose providers, workspace policy, safety boundaries, and notification routes per project.")
                    }
                    NavigationLink("Tab customisation") {
                        IPhoneSettingsDetail(title: "Tab customisation", detail: "The default keeps five visible control domains with no hidden More destination. Future configurable order must preserve this full-remote access principle.")
                    }
                }

                Section("Privacy and notifications") {
                    Toggle("Sensitive notification previews", isOn: $showSensitivePreviews)
                    NavigationLink("Approval defaults") {
                        IPhoneSettingsDetail(title: "Approval defaults", detail: "High-consequence work always shows target, consequence, egress, alternative, freshness, and current authority before it can proceed.")
                    }
                }

                Section("About this fixture") {
                    Text("Local deterministic prototype · no provider, Mac, account, notification, repository, calendar, or email action is connected.")
                        .font(.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nord.polarNight0)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .tint(Nord.frost1)
    }
}

private struct IPhoneSettingsDetail: View {
    let title: String
    let detail: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IPhoneFixtureBoundaryCard(title: title, detail: detail)
                Text("This dedicated settings path is deliberately separate from the working control surface.")
                    .font(.body)
                    .foregroundStyle(Nord.snowStorm0.opacity(0.72))
            }
            .padding(16)
        }
        .background(Nord.polarNight0)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum PhoneNotificationRoute: Identifiable {
    case calendarApproval

    var id: String {
        switch self {
        case .calendarApproval: "calendar-approval"
        }
    }

    var fixture: Phase0Fixture {
        switch self {
        case .calendarApproval: Phase0Fixtures.waitingForCalendarApproval
        }
    }
}

private struct PhoneQueuedCommand: Identifiable, Equatable {
    let id: UUID
    var position: Int
    var threadTitle: String
    var body: String
    var createdLabel: String

    static let fixtureItems = [
        PhoneQueuedCommand(
            id: UUID(),
            position: 1,
            threadTitle: "Reschedule a calendar event",
            body: "Please preserve the existing attendees.",
            createdLabel: "Just now"
        ),
        PhoneQueuedCommand(
            id: UUID(),
            position: 2,
            threadTitle: "Map the repository knowledge boundary",
            body: "After the current scan, summarize the missing project instructions.",
            createdLabel: "2 min ago"
        ),
    ]
}

private struct IPhoneActivityView: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let openNotificationApproval: () -> Void
    let startNewDraft: () -> Void

    private let fixtures = Phase0Fixtures.all

    var body: some View {
        List {
            Section {
                NavigationLink {
                    IPhoneQueueView(
                        isMacReachable: $isMacReachable,
                        queuedCommands: $queuedCommands
                    )
                } label: {
                    IPhoneReachabilityRow(
                        isMacReachable: isMacReachable,
                        queuedCount: queuedCommands.count
                    )
                }
            }
            .listRowBackground(Nord.polarNight1)

            Section("From a notification") {
                Button(action: openNotificationApproval) {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(Nord.auroraYellow)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Approval required")
                                .font(.subheadline.weight(.semibold))
                            Text("Reschedule a calendar event")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            attentionSection(
                title: "Needs your response",
                fixtures: fixtures.filter { $0.phoneAttention == .needsResponse }
            )
            attentionSection(
                title: "Needs review",
                fixtures: fixtures.filter { $0.phoneAttention == .needsReview }
            )
            attentionSection(
                title: "Running now",
                fixtures: fixtures.filter { $0.phoneAttention == .running }
            )
            attentionSection(
                title: "Failed or degraded",
                fixtures: fixtures.filter { $0.phoneAttention == .failed }
            )

            Section("Scheduled next") {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Weekly project-context refresh")
                        Text("Tonight · 20:00 JST · Skip if the Mac is unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge")
                        .foregroundStyle(Nord.frost0)
                }
            }

            if let approvalReceipt {
                Section("Local fixture receipt") {
                    IPhoneReceiptRow(text: approvalReceipt)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startNewDraft) {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private func attentionSection(title: String, fixtures: [Phase0Fixture]) -> some View {
        if !fixtures.isEmpty {
            Section(title) {
                ForEach(fixtures, id: \.name) { fixture in
                    NavigationLink {
                        IPhoneThreadDetail(
                            fixture: fixture,
                            isMacReachable: $isMacReachable,
                            queuedCommands: $queuedCommands,
                            approvalReceipt: $approvalReceipt
                        )
                    } label: {
                        IPhoneThreadRow(fixture: fixture)
                    }
                }
            }
        }
    }
}

private struct IPhoneInboxView: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let startNewDraft: () -> Void

    private var inboxFixtures: [Phase0Fixture] {
        Phase0Fixtures.all.filter { $0.phoneAttention != .none }
    }

    var body: some View {
        List {
            Section {
                IPhoneReachabilityRow(
                    isMacReachable: isMacReachable,
                    queuedCount: queuedCommands.count
                )
            }
            .listRowBackground(Nord.polarNight1)

            Section("Attention projection") {
                ForEach(inboxFixtures, id: \.name) { fixture in
                    NavigationLink {
                        IPhoneThreadDetail(
                            fixture: fixture,
                            isMacReachable: $isMacReachable,
                            queuedCommands: $queuedCommands,
                            approvalReceipt: $approvalReceipt
                        )
                    } label: {
                        IPhoneThreadRow(fixture: fixture, showsWorkspace: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startNewDraft) {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }
}

private struct IPhoneThreadsView: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    let startNewDraft: () -> Void

    var body: some View {
        List {
            Section("Recent threads") {
                ForEach(Phase0Fixtures.all, id: \.name) { fixture in
                    NavigationLink {
                        IPhoneThreadDetail(
                            fixture: fixture,
                            isMacReachable: $isMacReachable,
                            queuedCommands: $queuedCommands,
                            approvalReceipt: $approvalReceipt
                        )
                    } label: {
                        IPhoneThreadRow(fixture: fixture, showsWorkspace: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: startNewDraft) {
                    Label("New", systemImage: "plus")
                }
            }
        }
    }
}

private struct IPhoneReachabilityRow: View {
    let isMacReachable: Bool
    let queuedCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMacReachable ? "desktopcomputer.and.macbook" : "wifi.slash")
                .font(.title3)
                .foregroundStyle(isMacReachable ? Nord.auroraGreen : Nord.auroraOrange)
            VStack(alignment: .leading, spacing: 3) {
                Text(isMacReachable ? "Mac reachable" : "Mac unavailable")
                    .font(.subheadline.weight(.semibold))
                Text(
                    isMacReachable
                        ? "No command is dispatched by this fixture."
                        : "\(queuedCount) queued \(queuedCount == 1 ? "command" : "commands") remain editable."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct IPhoneThreadRow: View {
    let fixture: Phase0Fixture
    var showsWorkspace = false

    var body: some View {
        let attention = fixture.phoneAttention
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: attention.phoneSymbolName)
                .foregroundStyle(attention.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(fixture.thread.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(showsWorkspace ? "\(fixture.thread.workspaceKind.displayName) · \(attention.displayName)" : fixture.task.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IPhoneThreadDetail: View {
    let fixture: Phase0Fixture
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @Binding var approvalReceipt: String?
    @State private var composerText = ""
    @State private var localNotice: String?
    @State private var showsApproval = false

    private var approval: Approval? {
        fixture.approvals.first(where: { $0.status == .pending })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IPhoneThreadStatusHeader(
                    fixture: fixture,
                    isMacReachable: isMacReachable
                )

                if let approval {
                    Button {
                        showsApproval = true
                    } label: {
                        IPhoneApprovalCallout(approval: approval, isMacReachable: isMacReachable)
                    }
                    .buttonStyle(.plain)
                }

                if fixture.thread.workspaceKind == .coding {
                    NavigationLink {
                        IPhoneMobileDiffView()
                    } label: {
                        IPhoneCodingReviewSummary()
                    }
                    .buttonStyle(.plain)
                }

                if fixture.phoneAttention == .failed {
                    IPhoneFailureCallout(localNotice: $localNotice)
                }

                IPhoneConversationBubble(
                    author: "You",
                    icon: "person.fill",
                    text: fixture.phoneUserPrompt
                )
                IPhoneConversationBubble(
                    author: fixture.providerSession.provider,
                    icon: "sparkles",
                    text: fixture.phoneAgentSummary
                )

                if let approvalReceipt {
                    IPhoneReceiptRow(text: approvalReceipt)
                }

                if let localNotice {
                    IPhoneReceiptRow(text: localNotice)
                }
            }
            .padding(16)
            .padding(.bottom, 92)
        }
        .background(Nord.polarNight0)
        .navigationTitle(fixture.thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .iPhoneFixtureRefreshable()
        .safeAreaInset(edge: .bottom) {
            IPhoneComposer(
                text: $composerText,
                isMacReachable: isMacReachable,
                isRunning: fixture.phoneAttention == .running,
                sendOrQueue: sendOrQueue,
                interrupt: interrupt
            )
        }
        .sheet(isPresented: $showsApproval) {
            IPhoneApprovalSheet(
                fixture: fixture,
                isMacReachable: isMacReachable,
                approvalReceipt: $approvalReceipt
            )
        }
    }

    private func sendOrQueue() {
        let trimmedText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if isMacReachable {
            localNotice = "Local fixture send intent recorded. No provider received this message."
        } else {
            queuedCommands.append(
                PhoneQueuedCommand(
                    id: UUID(),
                    position: queuedCommands.count + 1,
                    threadTitle: fixture.thread.title,
                    body: trimmedText,
                    createdLabel: "Just now"
                )
            )
            localNotice = "Queued locally at position \(queuedCommands.count). It remains editable until reconciliation."
        }
        composerText = ""
    }

    private func interrupt() {
        localNotice = "Local fixture interrupt requested. No provider run was contacted or stopped."
    }
}

private struct IPhoneThreadStatusHeader: View {
    let fixture: Phase0Fixture
    let isMacReachable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(fixture.phoneAttention.displayName, systemImage: fixture.phoneAttention.phoneSymbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(fixture.phoneAttention.tint)
                Spacer()
                Text(isMacReachable ? "Mac reachable" : "Offline queue enabled")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isMacReachable ? Nord.auroraGreen : Nord.auroraOrange)
            }
            Text("\(fixture.thread.workspaceKind.displayName) · \(fixture.providerSession.provider)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Fixture only — provider, account, repository, calendar, and notification services are disconnected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneApprovalCallout: View {
    let approval: Approval
    let isMacReachable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval required", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(Nord.auroraYellow)
            Text(approval.consequence.capitalized)
                .font(.subheadline)
                .foregroundStyle(Nord.snowStorm0)
            Text(isMacReachable ? "Open the decision with its consequence and alternatives." : "Open the decision. A local fixture receipt is not an external calendar change.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Nord.auroraYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneCodingReviewSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Coding review", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nord.snowStorm0.opacity(0.45))
            }
            Text("3 changed files · 4 checks passed · provider completion awaits review")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Open syntax-highlighted mobile diff", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Nord.frost1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneFailureCallout: View {
    @Binding var localNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Provider run failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Nord.auroraRed)
            Text("No research conclusion was accepted. Preserve the failure evidence and continue on Mac when ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Defer investigation to Mac") {
                localNotice = "Local fixture handoff recorded. No provider retry was started."
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Nord.auroraRed.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneConversationBubble: View {
    let author: String
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Nord.polarNight3, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(author)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.frost1)
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct IPhoneComposer: View {
    @Binding var text: String
    let isMacReachable: Bool
    let isRunning: Bool
    let sendOrQueue: () -> Void
    let interrupt: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(isMacReachable ? "Reply" : "Queue a follow-up", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button(isMacReachable ? "Send" : "Queue", action: sendOrQueue)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isRunning {
                Button("Interrupt run", role: .destructive, action: interrupt)
                    .font(.caption.weight(.semibold))
            } else if !isMacReachable {
                Text("Queued commands are local fixture state and remain editable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct IPhoneQueueView: View {
    @Binding var isMacReachable: Bool
    @Binding var queuedCommands: [PhoneQueuedCommand]
    @State private var reconciliationNotice: String?

    var body: some View {
        List {
            Section {
                IPhoneReachabilityRow(
                    isMacReachable: isMacReachable,
                    queuedCount: queuedCommands.count
                )
            }
            .listRowBackground(Nord.polarNight1)

            Section("Ordered pending commands") {
                if queuedCommands.isEmpty {
                    Label("Nothing queued", systemImage: "checkmark.circle")
                        .foregroundStyle(Nord.frost1)
                    Text("This local fixture has no pending outbound command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(queuedCommands.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(queuedCommands[index].position)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Nord.frost1)
                                    .frame(width: 22, height: 22)
                                    .background(Nord.frost3.opacity(0.22), in: Circle())
                                Text(queuedCommands[index].threadTitle)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(queuedCommands[index].createdLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            TextField("Queued follow-up", text: $queuedCommands[index].body, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }
            }

            Section {
                Button(isMacReachable ? "Simulate Mac unavailable" : "Simulate Mac reconnect") {
                    isMacReachable.toggle()
                    reconciliationNotice = isMacReachable
                        ? "Fixture connectivity changed. Commands remain queued here; no dispatch occurred."
                        : "Fixture connectivity changed. New follow-ups will join this editable queue."
                }
            }

            if let reconciliationNotice {
                Section("Fixture state") {
                    IPhoneReceiptRow(text: reconciliationNotice)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Nord.polarNight0)
        .navigationTitle("Offline queue")
        .iPhoneFixtureRefreshable()
        .toolbar {
            EditButton()
        }
    }

    private func delete(at offsets: IndexSet) {
        queuedCommands.remove(atOffsets: offsets)
        normalizePositions()
    }

    private func move(from source: IndexSet, to destination: Int) {
        queuedCommands.move(fromOffsets: source, toOffset: destination)
        normalizePositions()
    }

    private func normalizePositions() {
        for index in queuedCommands.indices {
            queuedCommands[index].position = index + 1
        }
    }
}

private struct IPhoneApprovalSheet: View {
    let fixture: Phase0Fixture
    let isMacReachable: Bool
    @Binding var approvalReceipt: String?
    @Environment(\.dismiss) private var dismiss

    private var approval: Approval? {
        fixture.approvals.first(where: { $0.status == .pending })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Approval required", systemImage: "checkmark.shield.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Nord.auroraYellow)
                    Text(fixture.thread.title)
                        .font(.title3.weight(.semibold))

                    if let approval {
                        VStack(spacing: 0) {
                            IPhoneApprovalDetailRow("Target", value: approval.target.capitalized)
                            Divider()
                            IPhoneApprovalDetailRow("Consequence", value: approval.consequence.capitalized)
                            Divider()
                            IPhoneApprovalDetailRow("Data egress", value: approval.action.egressDescription)
                            Divider()
                            IPhoneApprovalDetailRow("Alternative", value: approval.action.alternativeDescription)
                            Divider()
                            IPhoneApprovalDetailRow("Freshness", value: "Current local fixture approval · expires in 15 minutes")
                        }
                        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Text(isMacReachable
                         ? "The Mac is reachable in this fixture, but no calendar change will be sent."
                         : "The Mac is unavailable. A decision is recorded locally for review; it is not an external calendar change.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        Button("Reject change", role: .destructive) {
                            approvalReceipt = "Local fixture rejection recorded. The event remains unchanged."
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("Approve change") {
                            approvalReceipt = isMacReachable
                                ? "Local fixture approval recorded. External reconciliation is still required."
                                : "Local fixture approval queued for reconciliation. No external change occurred."
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .background(Nord.polarNight0)
            .navigationTitle("Review decision")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct IPhoneApprovalDetailRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Nord.frost1)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

private struct IPhoneReceiptRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(Nord.frost1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct IPhoneNewDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projectName: String?
    @State private var selectedKind: String
    @State private var title = ""
    @State private var created = false

    init(projectName: String? = nil) {
        self.projectName = projectName
        _selectedKind = State(initialValue: projectName == nil ? "Conversation" : "Task")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let projectName {
                    Section("Project") {
                        Label(projectName, systemImage: "folder.fill")
                        Text("This local draft keeps the selected project context.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Start") {
                    Picker("Type", selection: $selectedKind) {
                        Text("Task").tag("Task")
                        Text("Conversation").tag("Conversation")
                        Text("Research").tag("Research")
                        Text("Calendar task").tag("Calendar task")
                        Text("Scheduled work").tag("Scheduled work")
                    }
                    TextField("What should this start?", text: $title)
                }
                Section("Local fixture boundary") {
                    Text("No provider, repository, calendar, account, schedule, or notification is created from this prototype.")
                }
                if created {
                    Section {
                        Label("Local \(selectedKind.lowercased()) draft created", systemImage: "checkmark.circle")
                            .foregroundStyle(Nord.auroraGreen)
                    }
                }
            }
            .navigationTitle(projectName == nil ? "New" : "New task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create local draft") {
                        created = true
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private extension Phase0Fixture {
    var phoneAttention: AttentionState {
        (try? makeProjection())?.attention ?? .none
    }

    var phoneUserPrompt: String {
        switch thread.workspaceKind {
        case .coding:
            "Please keep the selected project context separate and make the next step easy to review."
        case .research:
            "Compare the provider behavior and show the evidence boundary if the run cannot finish."
        case .knowledge:
            "Use only the selected knowledge context and tell me what remains unknown."
        case .email:
            "Prepare the draft, but do not contact anyone without an explicit decision."
        case .calendar:
            "Please preserve the existing attendees before changing the event time."
        }
    }

    var phoneAgentSummary: String {
        switch phoneAttention {
        case .needsResponse:
            "A scoped decision is ready. Review the target, consequence, data egress, and alternative before responding."
        case .needsReview:
            "The provider completed its work. Review the mobile diff, checks, and full evidence before you accept it."
        case .running:
            "The run is active. You can queue the next instruction or request an interruption without losing the thread."
        case .failed:
            "The run stopped with a visible failure. No result has been accepted and the raw evidence is retained for Mac review."
        case .queued:
            "The requested work is queued and has not started yet."
        case .interrupted:
            "The run was interrupted and partial state remains available for recovery."
        case .none:
            "There is no current intervention required."
        }
    }
}

private extension AttentionState {
    var phoneSymbolName: String {
        switch self {
        case .none: "checkmark.circle"
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .needsResponse: "checkmark.shield"
        case .needsReview: "doc.text.magnifyingglass"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        }
    }
}
#endif
