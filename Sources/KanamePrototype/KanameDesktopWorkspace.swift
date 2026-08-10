import KanameDesktop
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

private enum DesktopDestination: String, CaseIterable, Identifiable {
    case home
    case threads
    case inbox
    case projects
    case research
    case knowledge
    case email
    case calendar
    case automations
    case github
    case skills
    case devices
    case liveCodex
    case localCore
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .threads: "Threads"
        case .inbox: "Inbox"
        case .projects: "Projects"
        case .research: "Research"
        case .knowledge: "Obsidian"
        case .email: "Email"
        case .calendar: "Calendar"
        case .automations: "Automations"
        case .github: "GitHub"
        case .skills: "Skills & Tools"
        case .devices: "Devices & Remote"
        case .liveCodex: "Coding"
        case .localCore: "Local Core"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "rectangle.grid.2x2.fill"
        case .threads: "bubble.left.and.bubble.right.fill"
        case .inbox: "tray.full.fill"
        case .projects: "folder.fill"
        case .research: "text.magnifyingglass"
        case .knowledge: "diamond.inset.filled"
        case .email: "envelope.fill"
        case .calendar: "calendar"
        case .automations: "clock.arrow.2.circlepath"
        case .github: "point.3.connected.trianglepath.dotted"
        case .skills: "hammer.fill"
        case .devices: "iphone.and.arrow.forward"
        case .liveCodex: "chevron.left.forwardslash.chevron.right"
        case .localCore: "internaldrive.fill"
        case .settings: "gearshape.fill"
        }
    }

    var keepsThreadSelection: Bool {
        self == .home || self == .threads || self == .inbox
    }
}

private struct DesktopNavigationLocation: Equatable {
    let destination: DesktopDestination
    let selectedThreadID: String?
}

struct KanameDesktopWorkspace: View {
    @StateObject private var model = DesktopAppModel()
    @StateObject private var personalIntegrations = DesktopPersonalIntegrationViewModel()
    @State private var destination: DesktopDestination
    @State private var selectedThreadID: String?
    @State private var searchText = ""
    @State private var inboxFilter: DesktopAttention? = nil
    @State private var showsNewThread = false
    @State private var showsNewProject = false
    @State private var showsInspector = true
    @State private var showsSettings = false
    @State private var navigationHistory: [DesktopNavigationLocation] = []

    init() {
        let arguments = CommandLine.arguments
        let requestedDestination = arguments.firstIndex(of: "--desktop-destination")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
            ?? .home
        let requestedBackDestination = arguments.firstIndex(of: "--desktop-back-target")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
        _destination = State(initialValue: requestedDestination == .settings ? .home : requestedDestination)
        _showsSettings = State(initialValue: requestedDestination == .settings)
        _selectedThreadID = State(
            initialValue: [.home, .threads, .inbox].contains(requestedDestination)
                ? "thread-desktop-dogfood"
                : nil
        )
        _navigationHistory = State(
            initialValue: requestedBackDestination.map {
                [DesktopNavigationLocation(
                    destination: $0,
                    selectedThreadID: $0.keepsThreadSelection ? "thread-desktop-dogfood" : nil
                )]
            } ?? []
        )
    }

    var body: some View {
        navigationLayout
        .background(Nord.polarNight0)
        .background(MouseBackButtonHandler(action: goBack))
        .sheet(isPresented: $showsNewThread) {
            NewDesktopThreadSheet(model: model) { threadID in
                openThread(threadID)
            }
        }
        .sheet(isPresented: $showsNewProject) {
            NewDesktopProjectSheet(model: model)
        }
        .sheet(isPresented: $showsSettings) {
            DesktopSettingsView(model: model, integrations: personalIntegrations)
        }
        .alert(
            "Local workspace was not saved",
            isPresented: Binding(
                get: { model.persistenceError != nil },
                set: { if !$0 { model.clearPersistenceError() } }
            )
        ) {
            Button("Dismiss", role: .cancel) { model.clearPersistenceError() }
        } message: {
            Text(model.persistenceError ?? "The previous durable workspace remains intact.")
        }
    }

    @ViewBuilder
    private var navigationLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            workspaceColumns
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var workspaceColumns: some View {
        if showsInspector {
            HSplitView {
                centerColumn
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)

                inspectorColumn
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
            }
        } else {
            centerColumn
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            content
        }
        .toolbar { toolbar }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Text(destination.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            ControlGroup {
                Button {
                    showsNewThread = true
                } label: {
                    Label("New thread", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New thread")

                Menu {
                    Button("New project") { showsNewProject = true }
                    Divider()
                    Button("Start research") { navigate(to: .research) }
                    Button("Draft email") { navigate(to: .email) }
                    Button("Propose calendar event") { navigate(to: .calendar) }
                    Button("Create automation") { navigate(to: .automations) }
                    Divider()
                    Button("Open Devices & Remote") { navigate(to: .devices) }
                    Button("Open Coding") { navigate(to: .liveCodex) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More workspace actions")
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 16)
        .frame(height: 53)
        .background(Nord.polarNight0)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    KanameIdentityRow()
                        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
                }

                Section("Workspace") {
                    destinationButton(.home)
                    destinationButton(.threads, count: model.activeThreads.count)
                    destinationButton(
                        .inbox,
                        count: model.activeThreads.filter {
                            $0.attention == .needsResponse || $0.attention == .needsApproval || $0.unread
                        }.count
                    )
                }

                Section("Organize") {
                    destinationButton(.projects, count: model.snapshot.projects.count)
                    destinationButton(.research, count: model.snapshot.domains.research.count)
                    destinationButton(.knowledge, count: model.snapshot.domains.knowledgeSources.count)
                }

                Section("Services") {
                    destinationButton(.email, count: model.snapshot.domains.emailDrafts.count)
                    destinationButton(.calendar, count: model.snapshot.domains.calendarProposals.count)
                    destinationButton(.automations, count: model.snapshot.domains.automations.count)
                    destinationButton(.github, count: model.snapshot.domains.gitWorkspaces.count)
                }

                Section("Build") {
                    destinationButton(.skills, count: model.snapshot.domains.skills.filter(\.enabled).count)
                    destinationButton(.liveCodex)
                    destinationButton(.localCore)
                }

                Section("System") {
                    destinationButton(.devices)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nord.polarNight1)
            .listStyle(.sidebar)

            Divider()
            Button {
                showsSettings = true
            } label: {
                HStack {
                    Label("Settings", systemImage: DesktopDestination.settings.symbol)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(showsSettings ? Nord.polarNight2.opacity(0.72) : Color.clear)
        }
        .frame(minWidth: 230, idealWidth: 258, maxWidth: 300)
        .navigationTitle("Kaname")
    }

    private func destinationButton(_ item: DesktopDestination, count: Int? = nil) -> some View {
        Button {
            navigate(to: item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(destination == item ? Nord.frost1 : .secondary)
                Text(item.title)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(destination == item ? Nord.polarNight0 : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            destination == item ? Nord.frost1 : Nord.polarNight2,
                            in: Capsule()
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(destination == item ? .body.weight(.semibold) : .body)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch destination {
            case .home:
                DesktopHomeView(
                    model: model,
                    searchText: searchText,
                    openThread: openThread,
                    openDestination: navigate
                )
            case .threads:
                DesktopThreadsView(
                    model: model,
                    searchText: searchText,
                    selectedThreadID: threadSelection
                )
            case .inbox:
                DesktopInboxView(
                    model: model,
                    searchText: searchText,
                    filter: $inboxFilter,
                    selectedThreadID: threadSelection
                )
            case .projects:
                DesktopProjectsView(model: model, createProject: { showsNewProject = true }, openThread: openThread)
            case .research:
                DesktopResearchView(model: model, openThread: openThread)
            case .knowledge:
                DesktopKnowledgeView(model: model)
            case .email:
                DesktopEmailView(model: model, integrations: personalIntegrations)
            case .calendar:
                DesktopCalendarView(model: model, integrations: personalIntegrations)
            case .automations:
                DesktopAutomationsView(model: model)
            case .github:
                DesktopGitHubView(model: model, integrations: personalIntegrations)
            case .skills:
                DesktopSkillsView(model: model)
            case .devices:
                DesktopDevicesView(model: model)
            case .liveCodex:
                DesktopCodingView(model: model, integrations: personalIntegrations)
            case .localCore:
                LocalCoreWorkspace()
            case .settings:
                DesktopSettingsView(model: model, integrations: personalIntegrations)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var inspector: some View {
        if let thread = model.thread(id: selectedThreadID), [.home, .threads, .inbox].contains(destination) {
            DesktopThreadInspector(model: model, thread: thread)
        } else {
            DesktopContextInspector(destination: destination, model: model)
        }
    }

    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            DesktopInspectorSearchField(text: $searchText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Nord.polarNight1)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let backTitle {
            ToolbarItem(placement: .navigation) {
                Button {
                    _ = goBack()
                } label: {
                    Label("Back to \(backTitle)", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to \(backTitle)")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                toggleInspector()
            } label: {
                Label(
                    showsInspector ? "Hide Inspector" : "Show Inspector",
                    systemImage: "sidebar.right"
                )
            }
            .help(showsInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    private func openThread(_ threadID: String) {
        visit(DesktopNavigationLocation(destination: .threads, selectedThreadID: threadID))
        model.markRead(threadID: threadID)
    }

    private var currentLocation: DesktopNavigationLocation {
        DesktopNavigationLocation(destination: destination, selectedThreadID: selectedThreadID)
    }

    private var threadSelection: Binding<String?> {
        Binding(
            get: { selectedThreadID },
            set: { threadID in
                visit(DesktopNavigationLocation(destination: destination, selectedThreadID: threadID))
                if let threadID { model.markRead(threadID: threadID) }
            }
        )
    }

    private var backTitle: String? {
        guard let location = navigationHistory.last else { return nil }
        if location.destination == destination,
           let thread = model.thread(id: location.selectedThreadID) {
            return thread.title
        }
        return location.destination.title
    }

    private func navigate(to target: DesktopDestination) {
        visit(
            DesktopNavigationLocation(
                destination: target,
                selectedThreadID: target.keepsThreadSelection ? selectedThreadID : nil
            )
        )
    }

    private func visit(_ target: DesktopNavigationLocation) {
        let current = currentLocation
        guard target != current else { return }
        if navigationHistory.last != current {
            navigationHistory.append(current)
            if navigationHistory.count > 100 {
                navigationHistory.removeFirst(navigationHistory.count - 100)
            }
        }
        apply(target)
    }

    private func apply(_ target: DesktopNavigationLocation) {
        preservingWindowFrame {
            destination = target.destination
            selectedThreadID = target.selectedThreadID
        }
    }

    private func toggleInspector() {
        preservingWindowFrame {
            showsInspector.toggle()
        }
    }

    private func preservingWindowFrame(_ updates: () -> Void) {
#if os(macOS)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        let frame = window?.frame
#endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
#if os(macOS)
        guard let window, let frame, !window.styleMask.contains(.fullScreen) else { return }
        DispatchQueue.main.async {
            guard !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
            window.setFrame(frame, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return }
            window.setFrame(frame, display: true)
        }
#endif
    }

    @discardableResult
    private func goBack() -> Bool {
        while let target = navigationHistory.popLast() {
            guard target != currentLocation else { continue }
            apply(target)
            if let threadID = target.selectedThreadID {
                model.markRead(threadID: threadID)
            }
            return true
        }
        return false
    }
}

private struct KanameIdentityRow: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(
                        LinearGradient(
                            colors: [Nord.frost1, Nord.frost3],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("要")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Nord.polarNight0)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Kaname")
                    .font(.headline)
                Text("Local-first desktop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(Nord.auroraGreen)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Local workspace available")
        }
    }
}

private struct DesktopHomeView: View {
    @ObservedObject var model: DesktopAppModel
    let searchText: String
    let openThread: (String) -> Void
    let openDestination: (DesktopDestination) -> Void

    private var attentionThreads: [DesktopThread] {
        model.threads(matching: searchText).filter {
            $0.attention == .needsResponse || $0.attention == .needsApproval || $0.attention == .failed
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProductStatusPill()
                        Text("Command centre")
                            .font(.largeTitle.weight(.bold))
                        Text("Your local work, attention, evidence, and device health in one place.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesktopAuthorityCard(remote: model.snapshot.remote)
                        .frame(width: 320)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    MetricCard(
                        title: "Needs you",
                        value: "\(attentionThreads.count)",
                        detail: attentionThreads.isEmpty ? "Nothing urgent" : "Review attention queue",
                        symbol: "person.crop.circle.badge.exclamationmark",
                        tint: attentionThreads.isEmpty ? Nord.auroraGreen : Nord.auroraYellow
                    )
                    MetricCard(
                        title: "Active work",
                        value: "\(model.activeThreads.filter { $0.attention == .running || $0.attention == .queued }.count)",
                        detail: "Running or queued locally",
                        symbol: "bolt.fill",
                        tint: Nord.frost0
                    )
                    MetricCard(
                        title: "Projects",
                        value: "\(model.snapshot.projects.count)",
                        detail: "Deliberate context boundaries",
                        symbol: "folder.fill",
                        tint: Nord.frost2
                    )
                    MetricCard(
                        title: "Local drafts",
                        value: "\(model.snapshot.domains.emailDrafts.count + model.snapshot.domains.calendarProposals.count)",
                        detail: "Email and calendar proposals",
                        symbol: "doc.text.fill",
                        tint: Nord.auroraPurple
                    )
                    MetricCard(
                        title: "Research",
                        value: "\(model.snapshot.domains.research.count)",
                        detail: "Durable questions",
                        symbol: DesktopDestination.research.symbol,
                        tint: Nord.frost1
                    )
                    MetricCard(
                        title: "Automations",
                        value: "\(model.snapshot.domains.automations.count)",
                        detail: "Draft and paused rules",
                        symbol: DesktopDestination.automations.symbol,
                        tint: Nord.auroraPurple
                    )
                }

                SectionHeading(
                    title: "Needs attention",
                    detail: attentionThreads.isEmpty ? "You are caught up." : "Open the exact context before deciding."
                )

                if attentionThreads.isEmpty {
                    EmptyPanel(
                        symbol: "checkmark.circle.fill",
                        title: "Nothing needs a decision",
                        detail: "Running and queued work remains visible below."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(attentionThreads) { thread in
                            ThreadCard(thread: thread) { openThread(thread.id) }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Recent work", detail: "Durable local threads, newest first.")
                        ForEach(model.threads(matching: searchText).prefix(5)) { thread in
                            ThreadRow(thread: thread) { openThread(thread.id) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Start or continue", detail: "Domain-specific local workspaces.")
                        QuickActionCard(
                            title: "Coding",
                            detail: "Inspect providers, use an isolated worktree, and review evidence before acceptance.",
                            symbol: DesktopDestination.liveCodex.symbol,
                            tint: Nord.frost1
                        ) { openDestination(.liveCodex) }
                        QuickActionCard(
                            title: "Research",
                            detail: "Start from a question and explicit source boundary.",
                            symbol: DesktopDestination.research.symbol,
                            tint: Nord.frost0
                        ) { openDestination(.research) }
                        QuickActionCard(
                            title: "Calendar",
                            detail: "Draft a source-aware event proposal without changing a calendar.",
                            symbol: DesktopDestination.calendar.symbol,
                            tint: Nord.auroraPurple
                        ) { openDestination(.calendar) }
                        QuickActionCard(
                            title: "Automations",
                            detail: "Define a disabled schedule with safe missed-run policy.",
                            symbol: DesktopDestination.automations.symbol,
                            tint: Nord.auroraYellow
                        ) { openDestination(.automations) }
                    }
                    .frame(width: 360, alignment: .topLeading)
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopThreadsView: View {
    @ObservedObject var model: DesktopAppModel
    let searchText: String
    @Binding var selectedThreadID: String?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                SurfaceHeader(
                    title: "Threads",
                    detail: "Durable conversations and project continuity",
                    symbol: DesktopDestination.threads.symbol
                )
                List(selection: $selectedThreadID) {
                    ForEach(model.threads(matching: searchText)) { thread in
                        ThreadDirectoryLabel(thread: thread)
                            .tag(thread.id as String?)
                            .contextMenu {
                                Button("Mark complete") {
                                    model.setAttention(threadID: thread.id, attention: .completed)
                                }
                                Button("Archive") {
                                    model.setAttention(threadID: thread.id, attention: .archived)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 280, idealWidth: 350, maxWidth: 430)

            if let thread = model.thread(id: selectedThreadID) {
                DesktopThreadConversation(model: model, thread: thread)
                    .id(thread.id)
            } else {
                EmptyPanel(
                    symbol: "bubble.left.and.bubble.right",
                    title: "Select a thread",
                    detail: "Open a durable conversation, plan, and its current evidence."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopInboxView: View {
    @ObservedObject var model: DesktopAppModel
    let searchText: String
    @Binding var filter: DesktopAttention?
    @Binding var selectedThreadID: String?

    private var threads: [DesktopThread] {
        model.threads(matching: searchText, attention: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SurfaceHeader(
                title: "Inbox",
                detail: "The same threads, projected by attention",
                symbol: DesktopDestination.inbox.symbol
            ) {
                Picker("Attention filter", selection: $filter) {
                    Text("All active").tag(nil as DesktopAttention?)
                    ForEach([
                        DesktopAttention.needsResponse,
                        .needsApproval,
                        .running,
                        .queued,
                        .failed,
                        .completed,
                    ], id: \.self) { attention in
                        Text(attention.label).tag(attention as DesktopAttention?)
                    }
                }
                .frame(width: 180)
            }


            if !model.snapshot.operations.approvals.isEmpty {
                ApprovalQueueStrip(model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }

            if threads.isEmpty {
                EmptyPanel(
                    symbol: "tray",
                    title: "No matching inbox items",
                    detail: "Change the attention filter or create a new local thread."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedThreadID) {
                    ForEach(threads) { thread in
                        InboxThreadLabel(thread: thread)
                            .tag(thread.id as String?)
                            .swipeActions(edge: .trailing) {
                                Button("Complete") {
                                    model.setAttention(threadID: thread.id, attention: .completed)
                                }
                                .tint(Nord.auroraGreen)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopThreadConversation: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @State private var draft = ""
    @State private var panel: Panel = .conversation

    private enum Panel: String, CaseIterable, Identifiable {
        case conversation
        case plan
        case evidence
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.title)
                            .font(.title2.weight(.bold))
                        Text(thread.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    AttentionPill(attention: thread.attention)
                }
                Picker("Thread panel", selection: $panel) {
                    ForEach(Panel.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(22)

            Divider()

            switch panel {
            case .conversation:
                conversation
            case .plan:
                ThreadPlanView(items: thread.plan)
            case .evidence:
                ThreadEvidenceView(items: thread.evidence)
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if thread.messages.isEmpty {
                            EmptyPanel(
                                symbol: "text.bubble",
                                title: "Start the conversation",
                                detail: "Messages are saved locally until you deliberately choose an execution surface."
                            )
                        } else {
                            ForEach(thread.messages) { message in
                                DesktopMessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(22)
                }
                .onChange(of: thread.messages.count) { _ in
                    if let id = thread.messages.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a local message or next instruction", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save local message")
            }
            .padding(14)
            .background(Nord.polarNight0)
        }
    }

    private func send() {
        let body = draft
        draft = ""
        model.appendUserMessage(threadID: thread.id, body: body)
    }
}

private struct DesktopProjectsView: View {
    @ObservedObject var model: DesktopAppModel
    let createProject: () -> Void
    let openThread: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Projects",
                    detail: "Repository, instruction, skill, and knowledge boundaries",
                    symbol: DesktopDestination.projects.symbol
                ) {
                    Button("New project", systemImage: "folder.badge.plus", action: createProject)
                        .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                    ForEach(model.snapshot.projects) { project in
                        ProjectCard(
                            project: project,
                            threads: model.activeThreads.filter { $0.projectID == project.id },
                            openThread: openThread
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopResearchView: View {
    @ObservedObject var model: DesktopAppModel
    let openThread: (String) -> Void
    @State private var showsNewResearch = false
    @State private var sourceTarget: DesktopResearchRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Research",
                    detail: "Questions, source boundaries, citations, and reusable findings",
                    symbol: DesktopDestination.research.symbol
                ) {
                    Button("New research", systemImage: "plus.magnifyingglass") {
                        showsNewResearch = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                BoundaryCallout(
                    title: "Research starts with an explicit boundary",
                    detail: "Kaname keeps the question and sensitivity boundary local. A provider or remote search receives content only after that execution surface is deliberately selected."
                )

                if model.snapshot.domains.research.isEmpty {
                    EmptyPanel(
                        symbol: "text.magnifyingglass",
                        title: "No research work yet",
                        detail: "Start a durable research thread without attaching it to a coding project."
                    )
                    .frame(minHeight: 260)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(model.snapshot.domains.research.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { record in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(Nord.frost1)
                                    Spacer()
                                    RecordStatusPill(state: record.status)
                                }
                                Text(record.title)
                                    .font(.headline)
                                Text(record.question)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                Divider()
                                LabeledContent("Sources", value: "\(record.sourceCount)")
                                    .font(.caption)
                                if let latest = model.snapshot.operations.researchSources
                                    .filter({ $0.researchID == record.id })
                                    .sorted(by: { $0.retrievedAtUnixMillis > $1.retrievedAtUnixMillis })
                                    .first {
                                    Text(latest.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button("Add source", systemImage: "link.badge.plus") {
                                    sourceTarget = record
                                }
                                .buttonStyle(.bordered)
                                RelativeTime(unixMillis: record.updatedAtUnixMillis)
                            }
                            .panelStyle()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsNewResearch) {
            NewResearchSheet(model: model) { threadID in
                openThread(threadID)
            }
        }
        .sheet(item: $sourceTarget) { research in
            NewResearchSourceSheet(model: model, research: research)
        }
    }
}

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

@MainActor
private final class DesktopPersonalIntegrationViewModel: ObservableObject {
    @Published private(set) var googleAccounts: [ExistingCLIAccountSnapshot] = []
    @Published private(set) var googleCalendars: [PersonalCalendarSourceSnapshot] = []
    @Published private(set) var mailThreads: [PersonalMailThreadSnapshot] = []
    @Published private(set) var githubAccess: GitHubCLIAccessSnapshot?
    @Published private(set) var providerCapabilities: [ProviderCapabilitySnapshot] = []
    @Published private(set) var appleAccessState: AppleCalendarAccessState
    @Published private(set) var isRefreshingGoogle = false
    @Published private(set) var isRefreshingInbox = false
    @Published private(set) var isRefreshingGitHub = false
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var isRequestingAppleCalendar = false
    @Published private(set) var message: String?

    private let integrations = PersonalIntegrationService()
    private let appleCalendar = AppleCalendarIntegrationService()

    init() {
        appleAccessState = appleCalendar.accessState
    }

    func refreshGoogle(model: DesktopAppModel) {
        guard !isRefreshingGoogle else { return }
        isRefreshingGoogle = true
        message = nil
        _Concurrency.Task {
            do {
                let discovered = try await integrations.discoverGoogleAccounts()
                googleAccounts = discovered
                let gmailAccounts = discovered.map { accountRecord(for: $0, service: .gmail) }
                let calendarAccounts = discovered.map { accountRecord(for: $0, service: .googleCalendar) }
                model.replaceAccounts(
                    for: [.gmail, .googleCalendar],
                    with: gmailAccounts + calendarAccounts
                )

                let identities = discovered.map(\.identity)
                googleCalendars = try await integrations.listGoogleCalendars(accounts: identities)
                let googleSources = googleCalendars.map { calendar in
                    DesktopCalendarSourceRecord.connected(
                        id: stableID(prefix: "google-calendar", value: "\(calendar.accountIdentity)|\(calendar.externalIdentifier)"),
                        accountID: stableID(prefix: DesktopAccountRecord.Service.googleCalendar.rawValue, value: calendar.accountIdentity),
                        externalIdentifier: calendar.externalIdentifier,
                        provider: .google,
                        displayName: calendar.name,
                        ownerIdentity: calendar.accountIdentity,
                        accessLevel: calendar.role,
                        isPrimary: calendar.isPrimary,
                        isEnabled: true
                    )
                }
                let appleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .apple }
                model.replaceCalendarSources(appleSources + googleSources)
                message = "Refreshed \(discovered.count) Google account\(discovered.count == 1 ? "" : "s") and \(googleCalendars.count) calendar\(googleCalendars.count == 1 ? "" : "s")."
            } catch {
                message = error.localizedDescription
            }
            isRefreshingGoogle = false
        }
    }

    func refreshInbox(model: DesktopAppModel) {
        guard !isRefreshingInbox else { return }
        let identities = model.snapshot.domains.accounts
            .filter { $0.service == .gmail && $0.status == .ready }
            .map(\.identity)
        guard !identities.isEmpty else {
            message = "Refresh Google accounts before reading the inbox."
            return
        }
        isRefreshingInbox = true
        message = nil
        _Concurrency.Task {
            do {
                mailThreads = try await integrations.listGoogleInbox(accounts: identities)
                message = "Read \(mailThreads.count) inbox thread\(mailThreads.count == 1 ? "" : "s") across \(identities.count) account\(identities.count == 1 ? "" : "s")."
            } catch {
                message = error.localizedDescription
            }
            isRefreshingInbox = false
        }
    }

    func refreshGitHub(model: DesktopAppModel) {
        guard !isRefreshingGitHub else { return }
        isRefreshingGitHub = true
        message = nil
        _Concurrency.Task {
            do {
                let access = try await integrations.inspectGitHubAccess()
                githubAccess = access
                model.replaceAccounts(
                    for: [.github],
                    with: [DesktopAccountRecord(
                        id: stableID(prefix: DesktopAccountRecord.Service.github.rawValue, value: access.login),
                        service: .github,
                        displayName: access.displayName,
                        identity: access.login,
                        status: .ready,
                        scope: "Current gh CLI host and token scope"
                    )]
                )
                message = "GitHub CLI access is ready for @\(access.login)."
            } catch {
                message = error.localizedDescription
            }
            isRefreshingGitHub = false
        }
    }

    func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        message = nil
        _Concurrency.Task {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let definitions: [(String, ProviderDriverKind, String, String)] = [
                ("codexLocal", .codex, "Codex", "codex"),
                ("claudeLocal", .claudeAgent, "Claude", "claude"),
                ("opencodeLocal", .openCode, "OpenCode", "opencode"),
            ]
            let prober = ProviderCapabilityProber()
            var results: [ProviderCapabilitySnapshot] = []
            for definition in definitions {
                guard let identifier = ProviderInstanceID(rawValue: definition.0) else { continue }
                let instance = ProviderInstance(id: identifier, driver: definition.1, displayName: definition.2)
                results.append(await prober.probe(ProviderProbeConfiguration(
                    instance: instance,
                    executable: definition.3,
                    workingDirectory: directory
                )))
            }
            providerCapabilities = results
            let ready = results.filter { $0.state == .ready || $0.state == .degraded }.count
            message = "Refreshed \(results.count) native provider adapter\(results.count == 1 ? "" : "s"); \(ready) available."
            isRefreshingProviders = false
        }
    }

    func requestAppleCalendarAccess(model: DesktopAppModel) {
        guard !isRequestingAppleCalendar else { return }
        isRequestingAppleCalendar = true
        message = nil
        _Concurrency.Task {
            do {
                let calendars = try await appleCalendar.requestAccessAndListCalendars()
                appleAccessState = appleCalendar.accessState
                let sourceNames = Array(Set(calendars.map(\.sourceName))).sorted()
                let accounts = sourceNames.map { sourceName in
                    DesktopAccountRecord(
                        id: stableID(prefix: DesktopAccountRecord.Service.appleCalendar.rawValue, value: sourceName),
                        service: .appleCalendar,
                        displayName: sourceName,
                        identity: sourceName,
                        status: .ready,
                        scope: "Calendars selected in Kaname settings"
                    )
                }
                model.replaceAccounts(for: [.appleCalendar], with: accounts)
                let googleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .google }
                let appleSources = calendars.map { calendar in
                    DesktopCalendarSourceRecord.connected(
                        id: stableID(prefix: "apple-calendar", value: calendar.externalIdentifier),
                        accountID: stableID(prefix: DesktopAccountRecord.Service.appleCalendar.rawValue, value: calendar.sourceName),
                        externalIdentifier: calendar.externalIdentifier,
                        provider: .apple,
                        displayName: calendar.name,
                        ownerIdentity: calendar.sourceName,
                        accessLevel: calendar.allowsChanges ? "read and write" : "read only",
                        isPrimary: false,
                        isEnabled: true
                    )
                }
                model.replaceCalendarSources(googleSources + appleSources)
                message = calendars.isEmpty
                    ? "Apple Calendar access was not granted."
                    : "Loaded \(calendars.count) Apple calendar\(calendars.count == 1 ? "" : "s")."
            } catch {
                appleAccessState = appleCalendar.accessState
                message = error.localizedDescription
            }
            isRequestingAppleCalendar = false
        }
    }

    private func accountRecord(
        for account: ExistingCLIAccountSnapshot,
        service: DesktopAccountRecord.Service
    ) -> DesktopAccountRecord {
        DesktopAccountRecord(
            id: stableID(prefix: service.rawValue, value: account.identity),
            service: service,
            displayName: account.identity,
            identity: account.identity,
            status: .ready,
            scope: account.capabilities.isEmpty ? "Existing zele session" : account.capabilities.joined(separator: ", ")
        )
    }

    private func stableID(prefix: String, value: String) -> String {
        let encoded = Data(value.lowercased().utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(prefix)-\(encoded)"
    }
}

private struct DesktopKnowledgeView: View {
    @ObservedObject var model: DesktopAppModel
    @StateObject private var localReads = DesktopLocalReadViewModel()
    @State private var showsNewProposal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Obsidian & Knowledge",
                    detail: "Explicit private notes, repository knowledge, freshness, and conflicts",
                    symbol: DesktopDestination.knowledge.symbol
                ) {
                    ControlGroup {
                        Button("Refresh overview", systemImage: "arrow.clockwise") {
                            if let source = model.snapshot.domains.knowledgeSources.first(where: { $0.kind == .obsidian }) {
                                localReads.readObsidian(path: source.scope)
                            }
                        }
                        Button("Propose edit", systemImage: "doc.badge.plus") {
                            showsNewProposal = true
                        }
                    }
                    .controlGroupStyle(.navigation)
                }

                HStack(alignment: .top, spacing: 14) {
                    MetricCard(
                        title: "Knowledge sources",
                        value: "\(model.snapshot.domains.knowledgeSources.count)",
                        detail: "Scoped references",
                        symbol: "books.vertical.fill",
                        tint: Nord.frost1
                    )
                    MetricCard(
                        title: "Proposed edits",
                        value: "\(model.snapshot.operations.knowledgeProposals.filter { $0.state == .proposed }.count)",
                        detail: "Nothing writes silently",
                        symbol: "doc.badge.ellipsis",
                        tint: Nord.auroraYellow
                    )
                }

                SectionHeading(
                    title: "Connected knowledge",
                    detail: "The app stores paths and provenance, not another full copy of the vault or repository."
                )
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.domains.knowledgeSources.enumerated()), id: \.element.id) { index, source in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: source.kind.symbol)
                                .font(.title3)
                                .foregroundStyle(source.kind.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(source.name).font(.headline)
                                    RecordStatusPill(state: source.status)
                                }
                                Text(source.scope)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(source.lastReadAtUnixMillis == nil ? "Not read yet" : "Freshness recorded locally")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        if index < model.snapshot.domains.knowledgeSources.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 18)
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))

                if localReads.isReadingObsidian {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the scoped overview through Obsidian…")
                    }
                    .panelStyle()
                } else if let preview = localReads.obsidianPreview {
                    SectionHeading(
                        title: "Live overview preview",
                        detail: preview.wasTruncated ? "Bounded preview · additional content omitted" : "Read locally through Obsidian"
                    )
                    ScrollView(.horizontal) {
                        Text(preview.content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .panelStyle()
                }

                if let error = localReads.obsidianError {
                    BoundaryCallout(title: "Obsidian read unavailable", detail: error)
                }

                if !model.snapshot.operations.knowledgeProposals.isEmpty {
                    SectionHeading(
                        title: "Review queue",
                        detail: "Every proposal retains its target and base revision."
                    )
                    ForEach(model.snapshot.operations.knowledgeProposals) { proposal in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(proposal.title).font(.headline)
                                Spacer()
                                ActionStatePill(state: proposal.state)
                            }
                            Text(proposal.target)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(proposal.summary)
                                .font(.subheadline)
                            DisclosureGroup("Proposed content") {
                                Text(proposal.proposedContent)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                        .panelStyle()
                    }
                }

                BoundaryCallout(
                    title: "Reviewable knowledge changes",
                    detail: "Obsidian and Lode edits will appear as proposed diffs with source revision and conflict state before Kaname writes them."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsNewProposal) {
            NewKnowledgeProposalSheet(model: model)
        }
    }
}

private struct DesktopEmailView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @State private var showsComposer = false

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter { $0.service == .gmail }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Email",
                    detail: "One inbox across your selected Gmail accounts, with account-isolated drafts",
                    symbol: DesktopDestination.email.symbol
                ) {
                    ControlGroup {
                        Button("Refresh inbox", systemImage: "arrow.clockwise") {
                            integrations.refreshInbox(model: model)
                        }
                        .disabled(integrations.isRefreshingInbox || accounts.isEmpty)
                        Button("New draft", systemImage: "square.and.pencil") { showsComposer = true }
                    }
                    .controlGroupStyle(.navigation)
                }

                AccountStrip(accounts: accounts)

                if integrations.isRefreshingInbox {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading selected Gmail inboxes…")
                    }
                    .panelStyle()
                } else if !integrations.mailThreads.isEmpty {
                    SectionHeading(
                        title: "Unified inbox",
                        detail: "Each result retains its source account. No message content is committed to the repository."
                    )
                    VStack(spacing: 0) {
                        ForEach(Array(integrations.mailThreads.enumerated()), id: \.element.externalIdentifier) { index, thread in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: thread.flags.lowercased().contains("unread") ? "envelope.fill" : "envelope.open")
                                    .foregroundStyle(Nord.frost0)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(thread.sender).font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(thread.dateDescription).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(thread.subject).font(.subheadline)
                                    Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(thread.accountIdentity)
                                        .font(.caption2)
                                        .foregroundStyle(Nord.frost1)
                                }
                            }
                            .padding(.vertical, 12)
                            if index < integrations.mailThreads.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15))
                }

                SectionHeading(
                    title: "Local drafts",
                    detail: "Saving here cannot send mail or grant mailbox access."
                )
                if model.snapshot.domains.emailDrafts.isEmpty {
                    EmptyPanel(
                        symbol: "envelope.badge",
                        title: "No email drafts",
                        detail: "Draft locally now; select and authorize an exact account before any future send."
                    )
                    .frame(minHeight: 240)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.snapshot.domains.emailDrafts.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { draft in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "doc.text.fill")
                                    .font(.title2)
                                    .foregroundStyle(Nord.frost0)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(draft.subject.isEmpty ? "Untitled draft" : draft.subject)
                                            .font(.headline)
                                        RecordStatusPill(state: draft.status)
                                    }
                                    Text(draft.recipients.isEmpty ? "No recipients selected" : draft.recipients)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(draft.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                Spacer()
                            }
                            .panelStyle()
                        }
                    }
                }

                BoundaryCallout(
                    title: "Sending is a consequential action",
                    detail: "Every send will identify the exact account, recipients, attachments, resolved content, approval, and external reconciliation result."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsComposer) {
            NewEmailDraftSheet(model: model)
        }
    }
}

private struct DesktopCalendarView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @State private var showsProposal = false

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter {
            $0.service == .googleCalendar || $0.service == .appleCalendar
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Calendar",
                    detail: "Google and Apple calendars with pinned scheduling zones and local-time transparency",
                    symbol: DesktopDestination.calendar.symbol
                ) {
                    ControlGroup {
                        Button("Refresh Google", systemImage: "arrow.clockwise") {
                            integrations.refreshGoogle(model: model)
                        }
                        .disabled(integrations.isRefreshingGoogle)
                        Button("Propose event", systemImage: "calendar.badge.plus") { showsProposal = true }
                    }
                    .controlGroupStyle(.navigation)
                }

                AccountStrip(accounts: accounts)

                if !model.snapshot.domains.calendarSources.isEmpty {
                    SectionHeading(
                        title: "Visible calendars",
                        detail: "Enable every calendar you want Kaname to show. This selection remains private on this Mac."
                    )
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(model.snapshot.domains.calendarSources) { source in
                            HStack(spacing: 12) {
                                Image(systemName: source.provider == .apple ? "apple.logo" : "g.circle.fill")
                                    .foregroundStyle(source.isEnabled ? Nord.frost1 : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.displayName).font(.subheadline.weight(.semibold))
                                    Text("\(source.ownerIdentity) · \(source.accessLevel)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("Visible", isOn: Binding(
                                    get: { source.isEnabled },
                                    set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                                ))
                                .labelsHidden()
                            }
                            .panelStyle()
                        }
                    }
                }

                SectionHeading(
                    title: "Event proposals",
                    detail: "Proposals remain local until an exact calendar and consequence are approved."
                )
                if model.snapshot.domains.calendarProposals.isEmpty {
                    EmptyPanel(
                        symbol: "calendar.badge.clock",
                        title: "No calendar proposals",
                        detail: "Create a local event proposal with explicit time zone, duration, and recurrence."
                    )
                    .frame(minHeight: 240)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(model.snapshot.domains.calendarProposals.sorted { $0.startAtUnixMillis < $1.startAtUnixMillis }) { proposal in
                            let eventDate = Date(timeIntervalSince1970: Double(proposal.startAtUnixMillis) / 1_000)
                            let presentation = DesktopTimeZonePresenter.presentation(
                                for: eventDate,
                                anchoredTimeZoneIdentifier: proposal.timeZoneIdentifier
                            )
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Image(systemName: "calendar")
                                        .font(.title2)
                                        .foregroundStyle(Nord.auroraPurple)
                                    Spacer()
                                    RecordStatusPill(state: proposal.status)
                                }
                                Text(proposal.title).font(.headline)
                                Text(presentation?.anchored ?? eventDate.formatted())
                                    .font(.title3.weight(.semibold))
                                if presentation?.differsFromViewer == true {
                                    Text("Here: \(presentation?.viewerLocal ?? "") (\(presentation?.viewerTimeZoneIdentifier ?? ""))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Divider()
                                if let sourceID = proposal.calendarSourceID,
                                   let source = model.snapshot.domains.calendarSources.first(where: { $0.id == sourceID }) {
                                    LabeledContent("Calendar", value: "\(source.displayName) · \(source.ownerIdentity)")
                                }
                                LabeledContent("Duration", value: "\(proposal.durationMinutes) minutes")
                                LabeledContent("Pinned zone", value: proposal.timeZoneIdentifier)
                                LabeledContent("Recurrence", value: proposal.recurrence)
                            }
                            .font(.caption)
                            .panelStyle()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsProposal) {
            NewCalendarProposalSheet(model: model)
        }
    }
}

private struct DesktopAutomationsView: View {
    @ObservedObject var model: DesktopAppModel
    @State private var showsNewAutomation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Automations",
                    detail: "Inspectable schedules, dry runs, missed-run policy, and durable history",
                    symbol: DesktopDestination.automations.symbol
                ) {
                    Button("New automation", systemImage: "plus.circle") { showsNewAutomation = true }
                        .buttonStyle(.borderedProminent)
                }

                BoundaryCallout(
                    title: "Safe default: skip missed runs",
                    detail: "Kaname never surprise-runs a backlog. New rules stay as local drafts until tools, data, budget, notifications, and authority are reviewed."
                )

                if model.snapshot.domains.automations.isEmpty {
                    EmptyPanel(
                        symbol: "clock.badge.questionmark",
                        title: "No automations",
                        detail: "Describe a schedule and local action. It will remain disabled until its policy is complete."
                    )
                    .frame(minHeight: 260)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.snapshot.domains.automations) { rule in
                            let referenceDate = rule.nextRunAtUnixMillis.map {
                                Date(timeIntervalSince1970: Double($0) / 1_000)
                            } ?? Date(timeIntervalSince1970: Double(rule.createdAtUnixMillis ?? 0) / 1_000)
                            let presentation = DesktopTimeZonePresenter.presentation(
                                for: referenceDate,
                                anchoredTimeZoneIdentifier: rule.timeZoneIdentifier
                            )
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: rule.status == .paused ? "pause.circle.fill" : "clock.arrow.2.circlepath")
                                    .font(.title2)
                                    .foregroundStyle(rule.status == .paused ? Nord.auroraYellow : Nord.frost1)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(rule.name).font(.headline)
                                        RecordStatusPill(state: rule.status)
                                    }
                                    Text(rule.schedule)
                                        .font(.subheadline.weight(.medium))
                                    Text(rule.actionSummary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 14) {
                                        Label("Pinned: \(rule.timeZoneIdentifier)", systemImage: "globe")
                                        Label(rule.missedRunPolicy.label, systemImage: "forward.end")
                                        Label(rule.lastResult, systemImage: "list.bullet.clipboard")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if presentation?.differsFromViewer == true {
                                        Text("Viewer zone: \(presentation?.viewerTimeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 8) {
                                    Button("Dry run") {
                                        _ = model.recordAutomationDryRun(id: rule.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    Button(rule.status == .paused ? "Resume draft" : "Pause") {
                                        model.setAutomationPaused(id: rule.id, paused: rule.status != .paused)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .panelStyle()
                        }
                    }
                }

                if !model.snapshot.operations.automationRuns.isEmpty {
                    SectionHeading(title: "Run history", detail: "Dry runs and future scheduled executions share durable evidence.")
                    VStack(spacing: 0) {
                        ForEach(Array(model.snapshot.operations.automationRuns.reversed().enumerated()), id: \.element.id) { index, run in
                            HStack(spacing: 12) {
                                Image(systemName: run.state == .completed ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(run.state == .completed ? Nord.auroraGreen : Nord.frost1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.detail).font(.subheadline)
                                    RelativeTime(unixMillis: run.scheduledAtUnixMillis)
                                }
                                Spacer()
                                ActionStatePill(state: run.state)
                            }
                            .padding(.vertical, 12)
                            if index < model.snapshot.operations.automationRuns.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsNewAutomation) {
            NewAutomationSheet(model: model)
        }
    }
}

private struct DesktopGitHubView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @StateObject private var localReads = DesktopLocalReadViewModel()
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
                                    .foregroundStyle(Nord.frost0)
                                Spacer()
                                RecordStatusPill(state: workspace.status)
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
                            RecordStatusPill(state: inspection.isClean ? .ready : .needsReview)
                        }
                        LabeledContent("Branch", value: inspection.branch)
                        LabeledContent("HEAD", value: inspection.head)
                        LabeledContent("Changed paths", value: "\(inspection.changedPaths.count)")
                        if inspection.wasTruncated {
                            Text("The bounded Git response was truncated.")
                                .font(.caption)
                                .foregroundStyle(Nord.auroraYellow)
                        }
                    }
                    .font(.caption)
                    .panelStyle()
                }

                if let error = localReads.gitError {
                    BoundaryCallout(title: "Local Git read unavailable", detail: error)
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
                                    .foregroundStyle(Nord.frost1)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(layer.title).font(.headline)
                                    Text("\(layer.branch) → \(layer.baseBranch)")
                                        .font(.system(.caption, design: .monospaced))
                                    Text("\(layer.checkSummary) · \(layer.reviewSummary)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ActionStatePill(state: layer.state)
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
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsNewLayer) {
            NewGitStackLayerSheet(model: model)
        }
    }
}

private struct DesktopSkillsView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Skills & Tools",
                    detail: "Progressive disclosure, provenance, scope, permissions, and update review",
                    symbol: DesktopDestination.skills.symbol
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    ForEach(model.snapshot.domains.skills) { skill in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Image(systemName: skill.kind.symbol)
                                    .font(.title2)
                                    .foregroundStyle(skill.enabled ? Nord.frost1 : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name).font(.headline)
                                    Text(skill.kind.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { skill.enabled },
                                    set: { model.setSkillEnabled(id: skill.id, enabled: $0) }
                                ))
                                .labelsHidden()
                            }
                            Divider()
                            LabeledContent("Scope", value: skill.scope)
                            LabeledContent("Source", value: skill.source)
                            LabeledContent("Revision", value: skill.revision)
                            HStack {
                                Text("Trust")
                                Spacer()
                                RecordStatusPill(state: skill.status)
                            }
                        }
                        .font(.caption)
                        .panelStyle()
                    }
                }

                BoundaryCallout(
                    title: "Updates are reviewable",
                    detail: "Behavioral instructions and executables are pinned with source, revision, licence, requested capabilities, and a diff before installation or activation."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopCodingView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @State private var panel = Panel.overview
    @State private var showsNewComparison = false

    private enum Panel: String, CaseIterable, Identifiable {
        case overview
        case codex
        case claude
        case openCode

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overview: "Control plane"
            case .codex: "Codex run"
            case .claude: "Claude"
            case .openCode: "OpenCode"
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
            adapter: "Capability adapter",
            capabilities: "Install and version discovery · isolated authentication state"
        ),
        LocalProviderDescriptor(
            name: "OpenCode",
            executable: "opencode",
            adapter: "Capability adapter",
            capabilities: "Local server inventory · models · agents · degraded operation"
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
                .frame(maxWidth: 360)
                Spacer()
                if panel == .overview {
                    Text("Read-only inventory · no provider started")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Nord.polarNight1)

            Divider()

            switch panel {
            case .overview:
                overview
            case .codex:
                CodexLiveWorkspace()
            case .claude:
                NativeProviderDiscussionView(driver: .claude)
            case .openCode:
                NativeProviderDiscussionView(driver: .openCode)
            }
        }
        .background(Nord.polarNight0)
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
                        Button("Refresh sessions", systemImage: "arrow.clockwise") {
                            integrations.refreshProviders()
                        }
                        .disabled(integrations.isRefreshingProviders)
                        Button("Open Codex run", systemImage: "arrow.right.circle.fill") {
                            panel = .codex
                        }
                    }
                    .controlGroupStyle(.navigation)
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
                            RecordStatusPill(state: .needsReview)
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

                if !model.snapshot.operations.comparisons.isEmpty {
                    SectionHeading(
                        title: "Comparison drafts",
                        detail: "Each provider receives a separate run identity from the same frozen brief."
                    )
                    ForEach(model.snapshot.operations.comparisons) { comparison in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(comparison.title).font(.headline)
                                Spacer()
                                ActionStatePill(state: comparison.state)
                            }
                            Text(comparison.brief)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(model.snapshot.operations.providerRuns.filter { comparison.runIDs.contains($0.id) }) { run in
                                    Label(run.provider, systemImage: "cpu")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Nord.polarNight0, in: Capsule())
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
                                    .fill(index == 0 ? Nord.frost1 : Nord.polarNight2)
                                    .frame(width: 28, height: 28)
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(index == 0 ? Nord.polarNight0 : .secondary)
                            }
                            Text(step)
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        if index < 6 {
                            Rectangle()
                                .fill(Nord.polarNight3)
                                .frame(height: 1)
                                .offset(y: -11)
                        }
                    }
                }
                .padding(18)
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsNewComparison) {
            NewProviderComparisonSheet(model: model, availableProviders: providers.map(\.name))
        }
    }
}

private struct LocalProviderDescriptor: Identifiable {
    let name: String
    let executable: String
    let adapter: String
    let capabilities: String

    var id: String { executable }

    var executableURL: URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = environmentPath.split(separator: ":").map(String.init) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        ]
        return candidates.lazy
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private struct ProviderCapabilityCard: View {
    let provider: LocalProviderDescriptor
    let snapshot: ProviderCapabilitySnapshot?

    private var status: DesktopRecordState {
        guard let snapshot else { return provider.executableURL == nil ? .disconnected : .ready }
        switch snapshot.state {
        case .ready, .degraded: return .ready
        case .authenticationRequired: return .needsReview
        case .unavailable, .unsupported: return .disconnected
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(status == .ready ? Nord.frost1 : .secondary)
                Text(provider.name).font(.headline)
                Spacer()
                RecordStatusPill(state: status)
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

private struct DesktopDevicesView: View {
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Devices & Remote",
                    detail: "Encrypted reachability, recovery, and device authority",
                    symbol: DesktopDestination.devices.symbol
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    DeviceEndpointCard(
                        symbol: "desktopcomputer",
                        title: "This Mac",
                        subtitle: "Initial authority",
                        status: "Local workspace available",
                        tint: Nord.auroraGreen,
                        facts: [
                            ("Role", "Execution host and authority"),
                            ("Private state", "Local 0700 / 0600 storage"),
                            ("Keychain prompts", "Not used by qualification harness"),
                        ]
                    )
                    DeviceEndpointCard(
                        symbol: "iphone",
                        title: "iPhone companion",
                        subtitle: "Physical qualification deferred",
                        status: "Simulator path ready",
                        tint: Nord.auroraYellow,
                        facts: [
                            ("Connected phone", "Charging only · excluded"),
                            ("Simulator", "Enrollment and recovery passed"),
                            ("Real APNs", "Paid team still required"),
                        ]
                    )
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    RemoteStatusCard(
                        title: "Ciphertext relay",
                        status: model.snapshot.remote.relayStatus,
                        detail: "Authenticated envelope storage only. The hosted qualification database is clean.",
                        symbol: "network.badge.shield.half.filled",
                        tint: Nord.frost0
                    )
                    RemoteStatusCard(
                        title: "Notifications",
                        status: model.snapshot.remote.notificationStatus,
                        detail: "APNs is a wake and attention hint, never a durable queue or plaintext sync channel.",
                        symbol: "bell.badge.fill",
                        tint: Nord.auroraPurple
                    )
                    RemoteStatusCard(
                        title: "Reconciliation",
                        status: model.snapshot.remote.queueStatus,
                        detail: "Queued items remain editable until staged and terminal receipts remove pending state.",
                        symbol: "arrow.triangle.2.circlepath.circle.fill",
                        tint: Nord.frost2
                    )
                }

                SectionHeading(title: "Qualification timeline", detail: "Direct evidence and explicit not-run boundaries.")
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.remote.events.enumerated()), id: \.element.id) { index, event in
                        RemoteTimelineRow(event: event, isLast: index == model.snapshot.remote.events.count - 1)
                    }
                }
                .padding(.horizontal, 18)
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))

                BoundaryCallout(
                    title: "Live device actions remain off",
                    detail: "This desktop surface does not inspect, install on, launch, mirror, or configure the connected charging iPhone. Physical enrollment and APNs credential work remain separate, explicit live operations."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @State private var draft: DesktopPreferences

    init(model: DesktopAppModel, integrations: DesktopPersonalIntegrationViewModel) {
        self.model = model
        self.integrations = integrations
        _draft = State(initialValue: model.snapshot.preferences)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: "Settings",
                    detail: "Local presentation, privacy, and review defaults",
                    symbol: DesktopDestination.settings.symbol
                )

                SettingsSection(title: "Workspace", symbol: "macwindow") {
                    Toggle("Show technical details by default", isOn: $draft.showTechnicalDetails)
                    Toggle("Use compact thread rows", isOn: $draft.compactRows)
                    Toggle("Confirm before archiving", isOn: $draft.confirmBeforeArchiving)
                }

                SettingsSection(title: "Personal integrations", symbol: "person.crop.circle.badge.checkmark") {
                    Text("Kaname reuses sessions owned by zele, gh, Codex, Claude, and OpenCode. Tokens stay with those tools; account references and selections stay in Kaname's private Application Support data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    integrationRow(
                        title: "Gmail & Google Calendar",
                        detail: googleIntegrationDetail,
                        busy: integrations.isRefreshingGoogle,
                        action: "Refresh zele accounts"
                    ) {
                        integrations.refreshGoogle(model: model)
                    }
                    integrationRow(
                        title: "Apple Calendar",
                        detail: "Permission: \(appleCalendarAccessLabel)",
                        busy: integrations.isRequestingAppleCalendar,
                        action: integrations.appleAccessState == .notRequested ? "Request access" : "Refresh calendars"
                    ) {
                        integrations.requestAppleCalendarAccess(model: model)
                    }
                    integrationRow(
                        title: "GitHub",
                        detail: model.snapshot.domains.accounts.first(where: { $0.service == .github })
                            .map { "Current gh account: @\($0.identity)" } ?? "Uses the account and host available to gh today",
                        busy: integrations.isRefreshingGitHub,
                        action: "Refresh gh access"
                    ) {
                        integrations.refreshGitHub(model: model)
                    }
                    integrationRow(
                        title: "Coding providers",
                        detail: providerIntegrationDetail,
                        busy: integrations.isRefreshingProviders,
                        action: "Refresh local sessions"
                    ) {
                        integrations.refreshProviders()
                    }

                    if let message = integrations.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !model.snapshot.domains.calendarSources.isEmpty {
                    SettingsSection(title: "Calendar selection", symbol: "calendar.badge.checkmark") {
                        Text("These choices affect Kaname only; they do not hide or delete calendars in Google or Apple Calendar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.snapshot.domains.calendarSources) { source in
                            Toggle(isOn: Binding(
                                get: { source.isEnabled },
                                set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.displayName)
                                    Text("\(source.provider.label) · \(source.ownerIdentity)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                SettingsSection(title: "Scheduling", symbol: "clock.badge.checkmark") {
                    TextField("Default IANA time zone", text: $draft.defaultScheduleTimeZoneIdentifier)
                    HStack {
                        Button("Use current zone") {
                            draft.defaultScheduleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
                        }
                        Spacer()
                        Text("Viewer zone: \(TimeZone.autoupdatingCurrent.identifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Recurring schedules stay pinned to this zone's wall clock after travel, including daylight-saving changes. Kaname also shows the equivalent time in your current viewing zone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil {
                        Label("Enter a valid IANA identifier such as Asia/Tokyo.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Nord.auroraYellow)
                    }
                }

                SettingsSection(title: "Notification privacy", symbol: "hand.raised.fill") {
                    Picker("Preview content", selection: $draft.previewPrivacy) {
                        ForEach(DesktopPreferences.PreviewPrivacy.allCases, id: \.self) { privacy in
                            Text(privacy.label).tag(privacy)
                        }
                    }
                    Text("Safe summary never includes private task content. Hidden is the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Execution authority", symbol: "lock.shield.fill") {
                    Toggle("Safe mode (disable future write integrations)", isOn: $draft.safeMode)
                    LabeledContent("Default", value: "Local-only draft")
                    LabeledContent("Provider writes", value: "Exact approval required")
                    LabeledContent("External accounts", value: "Not connected")
                    Text("Changing display settings never grants provider, repository, account, device, or network authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Recovery & diagnostics", symbol: "lifepreserver.fill") {
                    Stepper(
                        "Keep audit metadata for \(draft.auditRetentionDays) days",
                        value: $draft.auditRetentionDays,
                        in: 7...365,
                        step: 7
                    )
                    Button("Copy redacted diagnostics", systemImage: "doc.on.doc") {
#if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.redactedDiagnostics(), forType: .string)
#endif
                    }
                    Text("Diagnostics include counts and health states only. They exclude conversation text, drafts, recipients, identities, note paths, repository paths, and credential material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Return to Kaname", systemImage: "arrow.left") { dismiss() }
                    Spacer()
                    Button("Revert") { draft = model.snapshot.preferences }
                    Button("Save settings") {
                        model.updatePreferences(draft)
                        dismiss()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .frame(minWidth: 700, idealWidth: 820, minHeight: 620, idealHeight: 720)
    }

    private var googleIntegrationDetail: String {
        let gmailCount = model.snapshot.domains.accounts.filter { $0.service == .gmail }.count
        let calendarCount = model.snapshot.domains.calendarSources.filter { $0.provider == .google }.count
        return gmailCount == 0
            ? "Uses every account already available to zele"
            : "\(gmailCount) Gmail account\(gmailCount == 1 ? "" : "s") · \(calendarCount) Google calendar\(calendarCount == 1 ? "" : "s")"
    }

    private var providerIntegrationDetail: String {
        guard !integrations.providerCapabilities.isEmpty else {
            return "Reuses the current Codex, Claude, and OpenCode installations"
        }
        let available = integrations.providerCapabilities.filter {
            $0.state == .ready || $0.state == .degraded
        }.count
        return "\(available) of \(integrations.providerCapabilities.count) native adapters available"
    }

    private var appleCalendarAccessLabel: String {
        switch integrations.appleAccessState {
        case .notRequested: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Write only"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

    @ViewBuilder
    private func integrationRow(
        title: String,
        detail: String,
        busy: Bool,
        action: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(action, action: perform)
                .disabled(busy)
        }
    }
}

private struct DesktopThreadInspector: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorTitle(title: "Thread context", symbol: "sidebar.right")
                VStack(alignment: .leading, spacing: 10) {
                    Text(thread.title)
                        .font(.headline)
                    AttentionPill(attention: thread.attention)
                    Divider()
                    InspectorFact(label: "Kind", value: thread.kind.label)
                    InspectorFact(label: "Provider", value: thread.provider)
                    InspectorFact(label: "Model", value: thread.model)
                    InspectorFact(
                        label: "Project",
                        value: model.project(id: thread.projectID)?.name ?? "Standalone"
                    )
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Plan")
                        .font(.headline)
                    if thread.plan.isEmpty {
                        Text("No plan recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(thread.plan) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.state.symbol)
                                    .foregroundStyle(item.state.tint)
                                Text(item.title)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .panelStyle()

                let artifacts = model.snapshot.operations.artifacts.filter { $0.threadID == thread.id }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Artifacts")
                        .font(.headline)
                    if artifacts.isEmpty {
                        Text("No artifacts attached.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(artifacts) { artifact in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(artifact.name, systemImage: artifact.kind.symbol)
                                    .font(.subheadline.weight(.semibold))
                                Text(artifact.localPath)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Thread actions")
                        .font(.headline)
                    Button("Mark complete") {
                        model.setAttention(threadID: thread.id, attention: .completed)
                    }
                    .disabled(thread.attention == .completed)
                    Button("Archive", role: .destructive) {
                        model.setAttention(threadID: thread.id, attention: .archived)
                    }
                }
                .panelStyle()
            }
            .padding(18)
        }
    }
}

private struct DesktopContextInspector: View {
    let destination: DesktopDestination
    @ObservedObject var model: DesktopAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorTitle(title: "Current context", symbol: destination.symbol)
                VStack(alignment: .leading, spacing: 10) {
                    Text(destination.title)
                        .font(.headline)
                    Text(destination.contextDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Local health")
                        .font(.headline)
                    InspectorStatus(label: "Workspace state", value: "Durable", tint: Nord.auroraGreen)
                    InspectorStatus(label: "External accounts", value: "Disconnected", tint: Nord.polarNight3)
                    InspectorStatus(label: "Mobile relay", value: "Clean", tint: Nord.frost0)
                    InspectorStatus(label: "Physical iPhone", value: "Excluded", tint: Nord.auroraYellow)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Safety boundary")
                        .font(.headline)
                    Text("Local drafts and navigation are available. Provider execution, workspace writes, devices, accounts, and external effects retain their own explicit gates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .panelStyle()
            }
            .padding(18)
        }
    }
}

private struct DesktopInspectorSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search Kaname", text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Nord.polarNight0.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Nord.polarNight3.opacity(0.72), lineWidth: 1)
        }
    }
}

private struct NewResearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let created: (String) -> Void
    @State private var title = ""
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New research")
                .font(.title2.weight(.bold))
            Text("Create a local research record and durable thread. No provider or search service starts from this form.")
                .foregroundStyle(.secondary)
            TextField("Short title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Question, decision, or desired output", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create research") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.createResearch(title: title, question: question) != nil,
              let threadID = model.createThread(title: title, kind: .research, projectID: nil) else { return }
        model.appendUserMessage(threadID: threadID, body: question)
        dismiss()
        created(threadID)
    }
}

private struct NewResearchSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let research: DesktopResearchRecord
    @State private var title = ""
    @State private var location = ""
    @State private var publisher = ""
    @State private var note = ""
    @State private var isPrimary = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add research source")
                .font(.title2.weight(.bold))
            Text(research.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Form {
                TextField("Source title", text: $title)
                TextField("URL or local reference", text: $location)
                TextField("Publisher or owner", text: $publisher)
                Toggle("Primary source", isOn: $isPrimary)
                TextField("Evidence note", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add source") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 560, height: 430)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.addResearchSource(
            researchID: research.id,
            title: title,
            location: location,
            publisher: publisher,
            isPrimary: isPrimary,
            note: note
        ) != nil else { return }
        dismiss()
    }
}

private struct NewKnowledgeProposalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var sourceID: String?
    @State private var title = ""
    @State private var target = ""
    @State private var summary = ""
    @State private var proposedContent = ""
    @State private var baseRevision = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Propose knowledge edit")
                .font(.title2.weight(.bold))
            Text("This stores a reviewable local proposal. It does not write to Obsidian, Lode, or a repository.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Knowledge source", selection: $sourceID) {
                    Text("Unlinked proposal").tag(nil as String?)
                    ForEach(model.snapshot.domains.knowledgeSources) { source in
                        Text(source.name).tag(source.id as String?)
                    }
                }
                TextField("Title", text: $title)
                TextField("Exact target path", text: $target)
                TextField("Summary", text: $summary)
                TextField("Base revision or digest", text: $baseRevision)
                TextEditor(text: $proposedContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 9))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save proposal") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !proposedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard model.createKnowledgeProposal(
            sourceID: sourceID,
            title: title,
            target: target,
            summary: summary,
            proposedContent: proposedContent,
            baseRevision: baseRevision
        ) != nil else { return }
        dismiss()
    }
}

private struct NewGitStackLayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var workspaceID: String?
    @State private var title = ""
    @State private var branch = ""
    @State private var baseBranch = "main"
    @State private var dependsOnLayerID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New local stack layer")
                .font(.title2.weight(.bold))
            Text("Model dependency and review state without creating a branch or pull request.")
                .foregroundStyle(.secondary)
            Form {
                Picker("Workspace", selection: $workspaceID) {
                    Text("Select workspace").tag(nil as String?)
                    ForEach(model.snapshot.domains.gitWorkspaces) { workspace in
                        Text(workspace.name).tag(workspace.id as String?)
                    }
                }
                TextField("Layer title", text: $title)
                TextField("Branch", text: $branch)
                TextField("Base branch", text: $baseBranch)
                Picker("Depends on", selection: $dependsOnLayerID) {
                    Text("No layer dependency").tag(nil as String?)
                    ForEach(model.snapshot.operations.gitStackLayers) { layer in
                        Text(layer.title).tag(layer.id as String?)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save layer") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .onAppear {
            workspaceID = workspaceID ?? model.snapshot.domains.gitWorkspaces.first?.id
        }
    }

    private var isValid: Bool {
        workspaceID != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let workspaceID,
              model.addGitStackLayer(
                workspaceID: workspaceID,
                title: title,
                branch: branch,
                baseBranch: baseBranch,
                dependsOnLayerID: dependsOnLayerID
              ) != nil else { return }
        dismiss()
    }
}

private struct NewProviderComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let availableProviders: [String]
    @State private var title = ""
    @State private var brief = ""
    @State private var selectedProviders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New provider comparison")
                .font(.title2.weight(.bold))
            Text("Freeze one local brief into separate provider run identities. This form does not start a provider.")
                .foregroundStyle(.secondary)
            TextField("Comparison title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Shared brief", text: $brief, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)
            VStack(alignment: .leading, spacing: 9) {
                Text("Providers").font(.headline)
                ForEach(availableProviders, id: \.self) { provider in
                    Toggle(provider, isOn: Binding(
                        get: { selectedProviders.contains(provider) },
                        set: { selected in
                            if selected { selectedProviders.insert(provider) }
                            else { selectedProviders.remove(provider) }
                        }
                    ))
                }
            }
            .panelStyle()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save comparison draft") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 580, height: 520)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedProviders.count >= 2
    }

    private func save() {
        guard model.createProviderComparison(
            title: title,
            brief: brief,
            providers: Array(selectedProviders)
        ) != nil else { return }
        dismiss()
    }
}

private struct NewEmailDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var selectedAccountID: String?
    @State private var recipients = ""
    @State private var subject = ""
    @State private var draftBody = ""

    init(model: DesktopAppModel) {
        self.model = model
        _selectedAccountID = State(initialValue: model.snapshot.domains.accounts.first {
            $0.service == .gmail && $0.status == .ready
        }?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New local email draft")
                .font(.title2.weight(.bold))
            Picker("Gmail account", selection: $selectedAccountID) {
                Text("No account selected").tag(nil as String?)
                ForEach(model.snapshot.domains.accounts.filter { $0.service == .gmail }) { account in
                    Text(account.identity).tag(account.id as String?)
                }
            }
            TextField("Recipients (optional while drafting)", text: $recipients)
                .textFieldStyle(.roundedBorder)
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draftBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Save draft only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save draft") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 500)
    }

    private func save() {
        guard model.saveEmailDraft(
            accountID: selectedAccountID,
            recipients: recipients,
            subject: subject,
            body: draftBody
        ) != nil else { return }
        dismiss()
    }
}

private struct NewCalendarProposalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var selectedCalendarSourceID: String?
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var durationMinutes = 30
    @State private var timeZoneIdentifier: String
    @State private var recurrence = "Does not repeat"

    init(model: DesktopAppModel) {
        self.model = model
        let sources = model.snapshot.domains.calendarSources.filter(\.isEnabled)
        _selectedCalendarSourceID = State(initialValue: sources.first?.id)
        _timeZoneIdentifier = State(initialValue: model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Propose calendar event")
                .font(.title2.weight(.bold))
            Text("This creates a local proposal. It does not request Calendar access or create an event.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title)
                Picker("Calendar", selection: $selectedCalendarSourceID) {
                    Text("Choose later").tag(nil as String?)
                    ForEach(model.snapshot.domains.calendarSources.filter(\.isEnabled)) { source in
                        Text("\(source.displayName) · \(source.ownerIdentity)").tag(source.id as String?)
                    }
                }
                DatePicker("Start", selection: $start)
                    .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent)
                Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 5...1_440, step: 5)
                TextField("IANA time zone", text: $timeZoneIdentifier)
                Text("The wall-clock time stays pinned to this zone after travel. Kaname shows the local equivalent elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Recurrence", selection: $recurrence) {
                    Text("Does not repeat").tag("Does not repeat")
                    Text("Daily").tag("Daily")
                    Text("Weekly").tag("Weekly")
                    Text("Monthly").tag("Monthly")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save proposal") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 540, height: 430)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
    }

    private func save() {
        let source = selectedCalendarSourceID.flatMap { selectedID in
            model.snapshot.domains.calendarSources.first { $0.id == selectedID }
        }
        guard model.createCalendarProposal(
            accountID: source?.accountID,
            calendarSourceID: source?.id,
            title: title,
            startAtUnixMillis: Int64(start.timeIntervalSince1970 * 1_000),
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence
        ) != nil else { return }
        dismiss()
    }
}

private struct NewAutomationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var name = ""
    @State private var schedule = "Every Monday at 09:00"
    @State private var timeZoneIdentifier: String
    @State private var actionSummary = ""
    @State private var missedRunPolicy = DesktopAutomationRule.MissedRunPolicy.skip

    init(model: DesktopAppModel) {
        self.model = model
        _timeZoneIdentifier = State(initialValue: model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New automation draft")
                .font(.title2.weight(.bold))
            Text("Define intent and timing now. The rule stays disabled until its exact tools, data, budget, notifications, and authority are reviewed.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Human schedule or cron expression", text: $schedule)
                TextField("IANA time zone", text: $timeZoneIdentifier)
                Text("Pinned wall-clock zone. Travel changes the displayed local equivalent, not when the rule runs in this zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What should happen?", text: $actionSummary, axis: .vertical)
                    .lineLimit(3...7)
                Picker("Missed run", selection: $missedRunPolicy) {
                    ForEach(DesktopAutomationRule.MissedRunPolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save disabled draft") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 580, height: 480)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !actionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
    }

    private func save() {
        guard model.createAutomation(
            name: name,
            schedule: schedule,
            timeZoneIdentifier: timeZoneIdentifier,
            actionSummary: actionSummary,
            missedRunPolicy: missedRunPolicy
        ) != nil else { return }
        dismiss()
    }
}

private struct NewDesktopThreadSheet: View {
    @ObservedObject var model: DesktopAppModel
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind: DesktopWorkKind = .coding
    @State private var projectID: String? = "project-kaname"

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    TextField("What should this thread be about?", text: $title)
                    Picker("Kind", selection: $kind) {
                        ForEach(DesktopWorkKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    Picker("Project", selection: $projectID) {
                        Text("Standalone").tag(nil as String?)
                        ForEach(model.snapshot.projects) { project in
                            Text(project.name).tag(project.id as String?)
                        }
                    }
                }
                Section("Authority") {
                    Label("Creates a local durable draft only", systemImage: "internaldrive")
                    Text("No provider, repository, account, device, or external service starts from this sheet.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
            .frame(width: 520, height: 340)
            .navigationTitle("New thread")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if let id = model.createThread(title: title, kind: kind, projectID: projectID) {
                            created(id)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct NewDesktopProjectSheet: View {
    @ObservedObject var model: DesktopAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var summary = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Local path (optional)", text: $path)
                        Button("Choose…", action: chooseDirectory)
                    }
                    TextField("Purpose", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Boundary") {
                    Text("Adding a project records local context only. Kaname will inspect instructions, Git state, and worktree policy before any provider run.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
            .frame(width: 540, height: 380)
            .navigationTitle("New project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if model.createProject(name: name, path: path, summary: summary) != nil {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func chooseDirectory() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose project"
        if panel.runModal() == .OK {
            path = panel.url?.standardizedFileURL.path ?? path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let selectedName = panel.url?.lastPathComponent {
                name = selectedName
            }
        }
#endif
    }
}

private struct AccountStrip: View {
    let accounts: [DesktopAccountRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts & scope")
                .font(.headline)
            ForEach(accounts) { account in
                HStack(spacing: 12) {
                    Image(systemName: account.service.symbol)
                        .foregroundStyle(account.status == .ready ? Nord.auroraGreen : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(account.identity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.scope)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    RecordStatusPill(state: account.status)
                }
            }
        }
        .panelStyle()
    }
}

private struct ApprovalQueueStrip: View {
    @ObservedObject var model: DesktopAppModel

    private var pending: [DesktopApprovalRecord] {
        model.snapshot.operations.approvals.filter { $0.state == .awaitingApproval }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Approval proposals", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                Spacer()
                Text("\(pending.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(pending) { approval in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(approval.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        RecordStatusPill(state: .needsReview)
                    }
                    Text(approval.exactTarget)
                        .font(.system(.caption, design: .monospaced))
                    Text(approval.consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(approval.reversible ? "Reversible" : "Not reversible", systemImage: approval.reversible ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                        if !approval.dataLeavingDevice.isEmpty {
                            Label(approval.dataLeavingDevice, systemImage: "arrow.up.right.square")
                        }
                        Spacer()
                        Button("Reject") { model.resolveApproval(id: approval.id, approved: false) }
                        Button("Record approval") { model.resolveApproval(id: approval.id, approved: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 10))
            }
            if pending.isEmpty {
                Text("No action is waiting for approval.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Recording a decision here never dispatches the proposed external action by itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .panelStyle()
    }
}

private struct RecordStatusPill: View {
    let state: DesktopRecordState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(state.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.18), in: Capsule())
    }
}

private struct ActionStatePill: View {
    let state: DesktopActionState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.18), in: Capsule())
    }
}

private struct ProductStatusPill: View {
    var body: some View {
        Label("Desktop dogfood · local-first", systemImage: "checkmark.shield.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Nord.frost0)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Nord.polarNight2, in: Capsule())
    }
}

private struct DesktopAuthorityCard: View {
    let remote: DesktopRemoteStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Local authority", systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                Text("Ready")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Nord.auroraGreen)
            }
            InspectorStatus(label: "Workspace", value: "Durable local state", tint: Nord.auroraGreen)
            InspectorStatus(label: "Remote", value: "Simulator qualified", tint: Nord.frost0)
            InspectorStatus(label: "Phone", value: "Deferred safely", tint: Nord.auroraYellow)
        }
        .padding(15)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Spacer()
                Text(value)
                    .font(.title2.weight(.bold))
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ThreadCard: View {
    let thread: DesktopThread
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    AttentionPill(attention: thread.attention)
                    Spacer()
                    Image(systemName: thread.kind.symbol)
                        .foregroundStyle(.secondary)
                }
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(thread.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Divider()
                HStack {
                    Text(thread.provider)
                    Spacer()
                    RelativeTime(unixMillis: thread.updatedAtUnixMillis)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct ThreadRow: View {
    let thread: DesktopThread
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: thread.kind.symbol)
                    .foregroundStyle(thread.attention.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(thread.title)
                            .font(.headline)
                            .lineLimit(1)
                        if thread.unread {
                            Circle().fill(Nord.frost1).frame(width: 7, height: 7)
                        }
                    }
                    Text(thread.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                AttentionPill(attention: thread.attention)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct ThreadDirectoryLabel: View {
    let thread: DesktopThread

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: thread.kind.symbol)
                .foregroundStyle(thread.attention.tint)
                .frame(width: 24)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    if thread.unread { Circle().fill(Nord.frost1).frame(width: 7, height: 7) }
                }
                Text(thread.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(thread.attention.label)
                    Text("·")
                    RelativeTime(unixMillis: thread.updatedAtUnixMillis)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct InboxThreadLabel: View {
    let thread: DesktopThread

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(thread.attention.tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.headline)
                Text(thread.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            AttentionPill(attention: thread.attention)
            RelativeTime(unixMillis: thread.updatedAtUnixMillis)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

private struct QuickActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(15)
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private struct ProjectCard: View {
    let project: DesktopProject
    let threads: [DesktopThread]
    let openThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Nord.frost2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title3.weight(.bold))
                    Text("\(threads.count) active thread\(threads.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(project.summary.isEmpty ? "No purpose recorded yet." : project.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let path = project.path {
                Label(path, systemImage: "externaldrive")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Divider()
            if threads.isEmpty {
                Text("No active work")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(threads.prefix(3)) { thread in
                    Button { openThread(thread.id) } label: {
                        HStack {
                            Circle().fill(thread.attention.tint).frame(width: 7, height: 7)
                            Text(thread.title).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct DeviceEndpointCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let status: String
    let tint: Color
    let facts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(tint)
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Divider()
            ForEach(facts, id: \.0) { fact in
                LabeledContent(fact.0, value: fact.1)
                    .font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct RemoteStatusCard: View {
    let title: String
    let status: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RemoteTimelineRow: View {
    let event: DesktopRemoteEvent
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Image(systemName: event.state.symbol)
                    .foregroundStyle(event.state.tint)
                    .background(Nord.polarNight1)
                if !isLast {
                    Rectangle()
                        .fill(Nord.polarNight3)
                        .frame(width: 1, height: 45)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title).font(.headline)
                    Spacer()
                    Text(event.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(event.state.tint)
                }
                Text(event.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 16 : 4)
        }
        .padding(.top, 16)
    }
}

struct BoundaryCallout: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(Nord.auroraYellow)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Nord.auroraYellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Nord.auroraYellow.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ThreadPlanView: View {
    let items: [DesktopPlanItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    EmptyPanel(symbol: "list.bullet.clipboard", title: "No plan yet", detail: "A provider plan remains separate from write approval.")
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(item.state.tint)
                                .frame(width: 25, height: 25)
                                .background(item.state.tint.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text(item.state.label).font(.caption).foregroundStyle(item.state.tint)
                            }
                            Spacer()
                        }
                        .padding(15)
                        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ThreadEvidenceView: View {
    let items: [DesktopEvidence]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if items.isEmpty {
                    EmptyPanel(symbol: "checkmark.seal", title: "No evidence yet", detail: "Provider completion does not count as accepted work.")
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.state.symbol)
                                .foregroundStyle(item.state.tint)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.headline)
                                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.state.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.state.tint)
                        }
                        .padding(15)
                        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DesktopMessageBubble: View {
    let message: DesktopMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 60) }
            if message.role != .user {
                Image(systemName: message.role == .assistant ? "sparkles" : "shield.lefthalf.filled")
                    .foregroundStyle(message.role == .assistant ? Nord.frost1 : Nord.auroraPurple)
                    .frame(width: 25)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.role.label)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    RelativeTime(unixMillis: message.createdAtUnixMillis)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(message.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(message.role.background, in: RoundedRectangle(cornerRadius: 15))
            if message.role != .user { Spacer(minLength: 42) }
        }
    }
}

struct SurfaceHeader<Actions: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let actions: Actions

    init(title: String, detail: String, symbol: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(Nord.frost1)
                .frame(width: 42, height: 42)
                .background(Nord.polarNight2, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(22)
    }
}

private extension SurfaceHeader where Actions == EmptyView {
    init(title: String, detail: String, symbol: String) {
        self.init(title: title, detail: detail, symbol: symbol) { EmptyView() }
    }
}

private struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(Nord.frost2)
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AttentionPill: View {
    let attention: DesktopAttention

    var body: some View {
        Text(attention.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(attention.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(attention.tint.opacity(0.12), in: Capsule())
    }
}

private struct RelativeTime: View {
    let unixMillis: Int64

    var body: some View {
        Text(Date(timeIntervalSince1970: TimeInterval(unixMillis) / 1_000), style: .relative)
    }
}

private struct InspectorTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title3.weight(.bold))
    }
}

private struct InspectorFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
}

private struct InspectorStatus: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .panelStyle()
    }
}

extension View {
    func panelStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Nord.polarNight2.opacity(0.58), in: RoundedRectangle(cornerRadius: 15))
    }
}

private extension DesktopDestination {
    var contextDetail: String {
        switch self {
        case .home: "Attention, active work, project boundaries, and system health."
        case .threads: "Conversation continuity over durable local records."
        case .inbox: "Rule-based attention projection over those same threads."
        case .projects: "Deliberate repository, instruction, skill, and knowledge boundaries."
        case .research: "Questions, source boundaries, citations, and reusable findings."
        case .knowledge: "Private Obsidian context and repository knowledge with visible provenance."
        case .email: "Account-isolated drafts and externally reconciled communication."
        case .calendar: "Source-aware event proposals with time zones and consequence review."
        case .automations: "Inspectable schedules, missed-run rules, and durable run history."
        case .github: "Local and remote repository state, checks, reviews, and stack relationships."
        case .skills: "Capability provenance, scope, permissions, compatibility, and updates."
        case .devices: "Encrypted reachability and recovery without silently widening authority."
        case .liveCodex: "Isolated worktree inspection, planning, explicit write approval, and evidence review."
        case .localCore: "Provider-free replay, failure, and recovery evidence from the durable authority."
        case .settings: "Presentation and privacy defaults that never grant external authority."
        }
    }
}

private extension DesktopRecordState {
    var tint: Color {
        switch self {
        case .ready: Nord.auroraGreen
        case .draft: Nord.frost1
        case .proposed: Nord.auroraPurple
        case .paused: Nord.auroraYellow
        case .disconnected: Nord.polarNight3
        case .needsReview: Nord.auroraOrange
        }
    }

    var foreground: Color {
        self == .disconnected ? .secondary : tint
    }
}

private extension DesktopActionState {
    var tint: Color {
        switch self {
        case .proposed, .awaitingApproval: Nord.auroraYellow
        case .approved, .running: Nord.frost1
        case .rejected, .failed: Nord.auroraRed
        case .completed, .reconciled: Nord.auroraGreen
        case .cancelled: Nord.polarNight3
        }
    }
}

private extension DesktopKnowledgeSource.Kind {
    var symbol: String {
        switch self {
        case .obsidian: "diamond.fill"
        case .lode: "shippingbox.fill"
        case .repository: "folder.fill.badge.gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .obsidian: Nord.auroraPurple
        case .lode: Nord.frost0
        case .repository: Nord.frost1
        }
    }
}

private extension DesktopSkillRecord.Kind {
    var symbol: String {
        switch self {
        case .skill: "wand.and.stars"
        case .tool: "hammer.fill"
        case .connector: "cable.connector"
        case .hook: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

private extension DesktopArtifactRecord.Kind {
    var symbol: String {
        switch self {
        case .file: "doc.fill"
        case .diff: "plus.forwardslash.minus"
        case .report: "doc.text.fill"
        case .image: "photo.fill"
        case .log: "list.bullet.rectangle.fill"
        }
    }
}

private extension DesktopAccountRecord.Service {
    var symbol: String {
        switch self {
        case .github: "point.3.connected.trianglepath.dotted"
        case .gmail: "envelope.fill"
        case .googleCalendar: "calendar.badge.clock"
        case .appleCalendar: "calendar"
        }
    }
}

private extension DesktopAttention {
    var tint: Color {
        switch self {
        case .needsResponse, .needsApproval: Nord.auroraYellow
        case .running: Nord.frost0
        case .queued: Nord.frost3
        case .completed: Nord.auroraGreen
        case .failed: Nord.auroraRed
        case .archived: Nord.polarNight3
        }
    }
}

private extension DesktopWorkKind {
    var symbol: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .research: "text.magnifyingglass"
        case .planning: "list.bullet.clipboard"
        case .personal: "person.fill"
        }
    }
}

private extension DesktopMessageRole {
    var label: String {
        switch self {
        case .user: "You"
        case .assistant: "Kaname"
        case .system: "Local state"
        }
    }

    var background: Color {
        switch self {
        case .user: Nord.frost3.opacity(0.24)
        case .assistant: Nord.polarNight1
        case .system: Nord.auroraPurple.opacity(0.12)
        }
    }
}

private extension DesktopPlanItem.State {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .complete: "Complete"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: Nord.polarNight3
        case .inProgress: Nord.frost1
        case .complete: Nord.auroraGreen
        }
    }
}

private extension DesktopEvidence.State {
    var label: String {
        switch self {
        case .passed: "Passed"
        case .pending: "Pending"
        case .notRun: "Not run"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.seal.fill"
        case .pending: "clock.fill"
        case .notRun: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed: Nord.auroraGreen
        case .pending: Nord.frost1
        case .notRun: Nord.auroraYellow
        case .failed: Nord.auroraRed
        }
    }
}

private extension DesktopRemoteEvent.State {
    var label: String {
        switch self {
        case .passed: "Passed"
        case .ready: "Ready"
        case .deferred: "Deferred"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .ready: "circle.dotted"
        case .deferred: "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed: Nord.auroraGreen
        case .ready: Nord.frost1
        case .deferred: Nord.auroraYellow
        }
    }
}
