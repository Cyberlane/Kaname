import KanameDesktop
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
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
    let selectedProjectID: String?
}

private struct DesktopUIRestoreState: Codable {
    var destination: String
    var selectedThreadID: String?
    var selectedProjectID: String?
}

private struct DesktopUIRestoreStore {
    let fileURL: URL

    func load() -> DesktopUIRestoreState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DesktopUIRestoreState.self, from: data)
    }

    func save(_ state: DesktopUIRestoreState) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Workspace persistence remains authoritative; selection restoration
            // is helpful UI continuity and must never prevent Kaname from opening.
        }
    }
}

private struct NewConversationRequest: Identifiable {
    let id = UUID()
    let projectID: String?
}

struct KanameDesktopWorkspace: View {
    private let uiRestoreStore: DesktopUIRestoreStore
    @StateObject private var model: DesktopAppModel
    @StateObject private var conversationRuntime: DesktopConversationRuntime
    @StateObject private var personalIntegrations: DesktopPersonalIntegrationViewModel
    @StateObject private var updates: DesktopUpdateViewModel
    @State private var destination: DesktopDestination
    @State private var selectedThreadID: String?
    @State private var selectedProjectID: String?
    @State private var searchText = ""
    @State private var inboxFilter: DesktopAttention? = nil
    @State private var newConversationRequest: NewConversationRequest?
    @State private var showsNewProject = false
    @State private var showsInspector = true
    @State private var showsSettings = false
    @State private var navigationHistory: [DesktopNavigationLocation] = []

    init() {
        let environment = KanameDesktopEnvironment.current
        let restoreStore = DesktopUIRestoreStore(fileURL: environment.desktopDirectory.appending(path: "ui-restore.json"))
        let restoredUI = restoreStore.load()
        uiRestoreStore = restoreStore
        let desktopModel = DesktopAppModel(store: FileDesktopStateStore(fileURL: environment.workspaceFileURL))
        _model = StateObject(wrappedValue: desktopModel)
        _conversationRuntime = StateObject(wrappedValue: DesktopConversationRuntime(model: desktopModel, environment: environment))
        _personalIntegrations = StateObject(wrappedValue: DesktopPersonalIntegrationViewModel(environment: environment))
        _updates = StateObject(wrappedValue: DesktopUpdateViewModel(environment: environment))
        let arguments = CommandLine.arguments
        let explicitDestination = arguments.firstIndex(of: "--desktop-destination")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
        let requestedDestination = explicitDestination
            ?? restoredUI.flatMap { DesktopDestination(rawValue: $0.destination) }
            ?? .home
        let requestedBackDestination = arguments.firstIndex(of: "--desktop-back-target")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
        let requestedProjectID = arguments.firstIndex(of: "--desktop-project-id")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        _destination = State(initialValue: requestedDestination == .settings ? .home : requestedDestination)
        _showsSettings = State(initialValue: requestedDestination == .settings)
        _selectedThreadID = State(
            initialValue: explicitDestination == nil
                ? restoredUI?.selectedThreadID
                : ([.home, .threads, .inbox].contains(requestedDestination) ? "thread-desktop-dogfood" : nil)
        )
        _selectedProjectID = State(initialValue: explicitDestination == nil
            ? restoredUI?.selectedProjectID
            : (requestedDestination == .projects ? requestedProjectID : nil))
        _navigationHistory = State(
            initialValue: requestedBackDestination.map {
                [DesktopNavigationLocation(
                    destination: $0,
                    selectedThreadID: $0.keepsThreadSelection ? "thread-desktop-dogfood" : nil,
                    selectedProjectID: nil
                )]
            } ?? []
        )
    }

    var body: some View {
        ZStack {
            navigationLayout
                .background(Nord.polarNight0)
                .allowsHitTesting(!showsSettings)
                .disabled(showsSettings)

            if showsSettings {
                DesktopSettingsModal(
                    model: model,
                    integrations: personalIntegrations,
                    updates: updates,
                    dismiss: { showsSettings = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(1)
            }
        }
        .sheet(item: $newConversationRequest) { request in
            NewDesktopThreadSheet(model: model, projectID: request.projectID) { threadID in
                openThread(threadID)
            }
        }
        .sheet(isPresented: $showsNewProject) {
            NewDesktopProjectSheet(model: model)
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
        .task {
            personalIntegrations.startMonitoring(model: model)
        }
        .onChange(of: destination) { _ in persistUIRestoreState() }
        .onChange(of: selectedThreadID) { _ in persistUIRestoreState() }
        .onChange(of: selectedProjectID) { _ in persistUIRestoreState() }
        .onAppear {
            DesktopBackCommandRouter.shared.install(handleBack)
        }
        .onDisappear {
            DesktopBackCommandRouter.shared.removeHandler()
        }
        .animation(.easeOut(duration: 0.16), value: showsSettings)
    }

    private func persistUIRestoreState() {
        uiRestoreStore.save(DesktopUIRestoreState(
            destination: destination.rawValue,
            selectedThreadID: selectedThreadID,
            selectedProjectID: selectedProjectID
        ))
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
            Text(workspaceTitle)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            ControlGroup {
                Button {
                    beginConversation(projectID: inheritedProjectID)
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation")

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
                    runtime: conversationRuntime,
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
                if let project = model.project(id: selectedProjectID) {
                    DesktopProjectOverview(
                        model: model,
                        project: project,
                        startConversation: { beginConversation(projectID: project.id) },
                        openThread: openThread
                    )
                } else {
                    DesktopProjectsView(
                        model: model,
                        createProject: { showsNewProject = true },
                        openProject: openProject,
                        startConversation: { beginConversation(projectID: $0) },
                        openThread: openThread
                    )
                }
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
                DesktopCodingView(
                    model: model,
                    integrations: personalIntegrations,
                    runtime: conversationRuntime,
                    openThread: openThread
                )
            case .localCore:
                LocalCoreWorkspace()
            case .settings:
                DesktopSettingsView(model: model, integrations: personalIntegrations, updates: updates)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var inspector: some View {
        if let project = model.project(id: selectedProjectID), destination == .projects {
            DesktopProjectInspector(model: model, project: project)
        } else if let thread = model.thread(id: selectedThreadID), [.home, .threads, .inbox].contains(destination) {
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
        visit(DesktopNavigationLocation(destination: .threads, selectedThreadID: threadID, selectedProjectID: nil))
        model.markRead(threadID: threadID)
    }

    private func openProject(_ projectID: String) {
        visit(DesktopNavigationLocation(destination: .projects, selectedThreadID: nil, selectedProjectID: projectID))
    }

    private var inheritedProjectID: String? {
        guard destination.keepsThreadSelection else { return nil }
        return model.thread(id: selectedThreadID)?.projectID
    }

    private func beginConversation(projectID: String?) {
        newConversationRequest = NewConversationRequest(projectID: projectID)
    }

    private var currentLocation: DesktopNavigationLocation {
        DesktopNavigationLocation(
            destination: destination,
            selectedThreadID: selectedThreadID,
            selectedProjectID: selectedProjectID
        )
    }

    private var threadSelection: Binding<String?> {
        Binding(
            get: { selectedThreadID },
            set: { threadID in
                visit(DesktopNavigationLocation(
                    destination: destination,
                    selectedThreadID: threadID,
                    selectedProjectID: nil
                ))
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
        if location.destination == .projects,
           let project = model.project(id: location.selectedProjectID) {
            return project.name
        }
        return location.destination.title
    }

    private var workspaceTitle: String {
        if destination == .projects, let project = model.project(id: selectedProjectID) {
            return project.name
        }
        return destination.title
    }

    private func navigate(to target: DesktopDestination) {
        visit(
            DesktopNavigationLocation(
                destination: target,
                selectedThreadID: target.keepsThreadSelection ? selectedThreadID : nil,
                selectedProjectID: nil
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
            selectedProjectID = target.selectedProjectID
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
    private func handleBack() -> Bool {
        if showsSettings {
            showsSettings = false
            return true
        }
        if newConversationRequest != nil {
            newConversationRequest = nil
            return true
        }
        if showsNewProject {
            showsNewProject = false
            return true
        }
        return goBack()
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
    @ObservedObject var runtime: DesktopConversationRuntime
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
                DesktopThreadConversation(model: model, runtime: runtime, thread: thread)
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
    @ObservedObject var runtime: DesktopConversationRuntime
    let thread: DesktopThread
    @State private var draft = ""
    @State private var questionAnswer = ""
    @State private var panel: Panel = .conversation
    @State private var showsRename = false
    @State private var renamedTitle = ""
    @State private var showsRuntimeSettings = false
    @State private var runtimeProvider = "Codex"
    @State private var runtimeModel = "Use provider default"
    @State private var runtimeReasoning = "xhigh"

    init(model: DesktopAppModel, runtime: DesktopConversationRuntime, thread: DesktopThread) {
        self.model = model
        self.runtime = runtime
        self.thread = thread
        _draft = State(initialValue: model.composerDraft(threadID: thread.id))
    }

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
                    if runtime.isRunning(threadID: thread.id) {
                        Button("Interrupt", systemImage: "stop.circle") {
                            runtime.interrupt(threadID: thread.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        renamedTitle = thread.title
                        showsRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename conversation")
                    Button {
                        runtimeProvider = thread.provider
                        runtimeModel = thread.model
                        runtimeReasoning = thread.reasoningEffort
                        showsRuntimeSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .disabled(runtime.isRunning(threadID: thread.id))
                    .accessibilityLabel("Conversation runtime settings")
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
        .sheet(isPresented: $showsRename) {
            DesktopRenameConversationSheet(
                title: $renamedTitle,
                cancel: { showsRename = false },
                save: {
                    if model.renameThread(id: thread.id, title: renamedTitle) { showsRename = false }
                }
            )
        }
        .sheet(isPresented: $showsRuntimeSettings) {
            DesktopConversationRuntimeSheet(
                provider: $runtimeProvider,
                model: $runtimeModel,
                reasoning: $runtimeReasoning,
                cancel: { showsRuntimeSettings = false },
                save: {
                    if model.updateThreadRuntime(
                        id: thread.id,
                        provider: runtimeProvider,
                        model: runtimeModel,
                        reasoningEffort: runtimeReasoning
                    ) { showsRuntimeSettings = false }
                }
            )
        }
    }

    private var timeline: [DesktopConversationTimelineItem] {
        let messages = thread.messages.map(DesktopConversationTimelineItem.message)
        let events = model.providerEvents(threadID: thread.id)
            .filter { $0.kind != .assistantText }
            .map(DesktopConversationTimelineItem.event)
        return (messages + events).sorted { $0.createdAtUnixMillis < $1.createdAtUnixMillis }
    }

    private var latestRecoverableRun: DesktopProviderRunRecord? {
        guard let latest = model.providerRuns(threadID: thread.id).last,
              latest.state == .failed || latest.state == .interrupted else { return nil }
        return latest
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if timeline.isEmpty {
                            EmptyPanel(
                                symbol: "text.bubble",
                                title: "Start the conversation",
                                detail: "Your first message is saved once, then sent through the project's provider and context boundary."
                            )
                        } else {
                            ForEach(timeline) { item in
                                switch item {
                                case let .message(message):
                                    DesktopMessageBubble(message: message)
                                        .id(item.id)
                                case let .event(event):
                                    DesktopProviderEventCard(
                                        event: event,
                                        questionAnswer: $questionAnswer,
                                        answer: {
                                            runtime.answerQuestion(
                                                threadID: thread.id,
                                                event: event,
                                                answer: questionAnswer
                                            )
                                            questionAnswer = ""
                                        }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                    }
                    .padding(22)
                }
                .onChange(of: timeline.count) { _ in
                    if let id = timeline.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            if let run = latestRecoverableRun,
               model.nextQueuedProviderRun(threadID: thread.id) == nil,
               !runtime.isRunning(threadID: thread.id) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(Nord.auroraOrange)
                    Text(run.errorSummary ?? "This turn stopped before completion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry turn") { runtime.retry(runID: run.id) }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(thread.provider)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(send)
                    .onChange(of: draft) { model.updateComposerDraft(threadID: thread.id, body: $0) }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(runtime.isRunning(threadID: thread.id) ? "Queue follow-up" : "Send message")
            }
            .padding(14)
            .background(Nord.polarNight0)
            HStack(spacing: 6) {
                Image(systemName: runtime.isRunning(threadID: thread.id) ? "hourglass" : "lock.shield")
                Text(runtime.isRunning(threadID: thread.id)
                    ? "\(thread.provider) is responding. New messages queue in order."
                    : "\(thread.provider) · \(thread.model) · \(thread.reasoningEffort) · Read-only, network off")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func send() {
        let body = draft
        if runtime.send(threadID: thread.id, body: body) {
            draft = ""
            model.updateComposerDraft(threadID: thread.id, body: "")
        }
    }
}

private enum DesktopConversationTimelineItem: Identifiable {
    case message(DesktopMessage)
    case event(DesktopProviderEventRecord)

    var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .event(event): "event-\(event.id)"
        }
    }

    var createdAtUnixMillis: Int64 {
        switch self {
        case let .message(message): message.createdAtUnixMillis
        case let .event(event): event.createdAtUnixMillis
        }
    }
}

private struct DesktopProviderEventCard: View {
    let event: DesktopProviderEventRecord
    @Binding var questionAnswer: String
    let answer: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.title).font(.caption.weight(.semibold))
                    Spacer()
                    RelativeTime(unixMillis: event.createdAtUnixMillis)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if event.kind == .question, event.approvalID != nil {
                    HStack {
                        TextField("Answer Codex", text: $questionAnswer)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(answer)
                        Button("Answer", action: answer)
                            .buttonStyle(.borderedProminent)
                            .disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if event.payloadWasTruncated {
                    Label("Raw payload exceeded the evidence limit", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Nord.auroraYellow)
                }
            }
            Spacer(minLength: 42)
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private var symbol: String {
        switch event.kind {
        case .status: "circle.dotted"
        case .reasoning: "list.bullet.clipboard"
        case .tool: "wrench.and.screwdriver"
        case .question: "questionmark.bubble"
        case .approval: "checkmark.shield"
        case .diff: "doc.badge.ellipsis"
        case .usage: "gauge.with.dots.needle.50percent"
        case .error: "exclamationmark.triangle"
        case .native: "waveform.path.ecg"
        case .assistantText: "sparkles"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .error: Nord.auroraRed
        case .question, .approval: Nord.auroraYellow
        case .diff: Nord.auroraPurple
        case .tool, .reasoning: Nord.frost0
        case .status, .usage, .native, .assistantText: Nord.frost1
        }
    }
}

private struct DesktopRenameConversationSheet: View {
    @Binding var title: String
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename conversation").font(.title2.weight(.bold))
            TextField("Conversation title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("A manual title is never replaced by later provider turns.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct DesktopConversationRuntimeSheet: View {
    @Binding var provider: String
    @Binding var model: String
    @Binding var reasoning: String
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Conversation runtime").font(.title2.weight(.bold))
            Text("These overrides apply to future turns in this conversation. They never expand tool, network, or write authority.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Form {
                Picker("Provider", selection: $provider) {
                    Text("Codex").tag("Codex")
                    Text("Claude").tag("Claude")
                    Text("OpenCode").tag("OpenCode")
                }
                TextField("Model", text: $model)
                Picker("Reasoning", selection: $reasoning) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Extra high").tag("xhigh")
                }
            }
            .formStyle(.grouped)
            HStack {
                Label("Standard conversation turns remain read-only with network off.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct DesktopProjectsView: View {
    @ObservedObject var model: DesktopAppModel
    let createProject: () -> Void
    let openProject: (String) -> Void
    let startConversation: (String) -> Void
    let openThread: (String) -> Void
    @State private var query = ""
    @State private var showsArchived = false

    private var projects: [DesktopProject] {
        model.projects(matching: query, includeArchived: showsArchived)
    }

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

                HStack(spacing: 12) {
                    Label {
                        TextField("Search projects", text: $query)
                            .textFieldStyle(.plain)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 11))

                    Picker("Project state", selection: $showsArchived) {
                        Text("Active").tag(false)
                        Text("Archived").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                if projects.isEmpty {
                    EmptyPanel(
                        symbol: showsArchived ? "archivebox" : "folder",
                        title: query.isEmpty ? (showsArchived ? "No archived projects" : "No active projects") : "No matching projects",
                        detail: query.isEmpty
                            ? "Projects keep repository, instruction, skill, and knowledge context deliberate."
                            : "Try a project name, purpose, path, or instruction reference."
                    )
                    .frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                        ForEach(projects) { project in
                            ProjectCard(
                                project: project,
                                threads: model.activeThreads.filter { $0.projectID == project.id },
                                openProject: { openProject(project.id) },
                                startConversation: { startConversation(project.id) },
                                openThread: openThread
                            )
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopProjectOverview: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject
    let startConversation: () -> Void
    let openThread: (String) -> Void
    @State private var showsEditor = false
    @State private var showsArchiveConfirmation = false

    private var threads: [DesktopThread] {
        model.snapshot.threads
            .filter { $0.projectID == project.id && $0.attention != .archived }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
    }

    private var threadIDs: Set<String> { Set(threads.map(\.id)) }

    private var runs: [DesktopProviderRunRecord] {
        model.snapshot.operations.providerRuns.filter { run in
            run.threadID.map(threadIDs.contains) == true
        }
    }

    private var artifacts: [DesktopArtifactRecord] {
        model.snapshot.operations.artifacts.filter { artifact in
            artifact.threadID.map(threadIDs.contains) == true
        }
    }

    private var workspaces: [DesktopGitWorkspace] {
        model.snapshot.domains.gitWorkspaces.filter { $0.projectID == project.id }
    }

    private var knowledgeSources: [DesktopKnowledgeSource] {
        let selected = Set(project.context.knowledgeSourceIDs)
        return model.snapshot.domains.knowledgeSources.filter { selected.contains($0.id) }
    }

    private var skills: [DesktopSkillRecord] {
        let selected = Set(project.context.skillIDs)
        return model.snapshot.domains.skills.filter { selected.contains($0.id) }
    }

    private var attentionCount: Int {
        threads.filter { $0.attention == .needsResponse || $0.attention == .needsApproval || $0.unread }.count
    }

    private var hasActiveRun: Bool {
        runs.contains { $0.state == .running || $0.state == .awaitingApproval }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SurfaceHeader(
                    title: project.name,
                    detail: project.summary.isEmpty ? "No purpose recorded yet." : project.summary,
                    symbol: "folder.fill"
                ) {
                    HStack(spacing: 10) {
                        Button("Edit context", systemImage: "slider.horizontal.3") { showsEditor = true }
                            .buttonStyle(.bordered)
                        if project.archivedAtUnixMillis == nil {
                            Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Restore project", systemImage: "arrow.uturn.backward") {
                                model.setProjectArchived(id: project.id, archived: false)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if project.archivedAtUnixMillis != nil {
                    BoundaryCallout(
                        title: "Archived project",
                        detail: "Its context remains inspectable and recoverable. Restore it before starting new work."
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ProjectMetric(title: "Conversations", value: "\(threads.count)", symbol: "bubble.left.and.bubble.right", tint: Nord.frost1)
                    ProjectMetric(title: "Needs you", value: "\(attentionCount)", symbol: "person.crop.circle.badge.exclamationmark", tint: attentionCount == 0 ? Nord.auroraGreen : Nord.auroraYellow)
                    ProjectMetric(title: "Provider runs", value: "\(runs.count)", symbol: "cpu", tint: Nord.frost2)
                    ProjectMetric(title: "Artifacts", value: "\(artifacts.count)", symbol: "doc.on.doc", tint: Nord.auroraPurple)
                }

                HStack(alignment: .top, spacing: 14) {
                    DesktopProjectSection(title: "Execution context", symbol: "scope") {
                        ProjectContextFact(label: "Default kind", value: project.context.defaultKind.label)
                        ProjectContextFact(label: "Provider", value: project.context.defaultProvider)
                        ProjectContextFact(label: "Model", value: project.context.defaultModel)
                        if let path = project.path {
                            ProjectContextFact(label: "Primary workspace", value: path, monospaced: true)
                        }
                        if workspaces.isEmpty && project.path == nil {
                            ProjectEmptyContext(text: "No repository or workspace linked")
                        } else {
                            ForEach(workspaces) { workspace in
                                ProjectSourceRow(
                                    symbol: "externaldrive.fill",
                                    title: workspace.name,
                                    detail: "\(workspace.branch) · \(workspace.remoteSummary)",
                                    status: workspace.status.label
                                )
                            }
                        }
                    }

                    DesktopProjectSection(title: "Instructions", symbol: "text.book.closed") {
                        if project.context.instructionReferences.isEmpty {
                            ProjectEmptyContext(text: "No instruction source linked")
                        } else {
                            ForEach(project.context.instructionReferences, id: \.self) { reference in
                                ProjectSourceRow(
                                    symbol: "doc.text",
                                    title: reference,
                                    detail: "Included deliberately",
                                    status: "Linked"
                                )
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    DesktopProjectSection(title: "Knowledge", symbol: "books.vertical.fill") {
                        if knowledgeSources.isEmpty {
                            ProjectEmptyContext(text: "No knowledge source linked")
                        } else {
                            ForEach(knowledgeSources) { source in
                                ProjectSourceRow(
                                    symbol: source.kind == .obsidian ? "diamond.fill" : "folder.fill",
                                    title: source.name,
                                    detail: source.scope,
                                    status: source.status.label
                                )
                            }
                        }
                    }

                    DesktopProjectSection(title: "Skills & tools", symbol: "hammer.fill") {
                        if skills.isEmpty {
                            ProjectEmptyContext(text: "No project skill linked")
                        } else {
                            ForEach(skills) { skill in
                                ProjectSourceRow(
                                    symbol: skill.kind == .hook ? "point.3.connected.trianglepath.dotted" : "hammer",
                                    title: skill.name,
                                    detail: skill.scope,
                                    status: skill.enabled ? "Enabled" : "Disabled"
                                )
                            }
                        }
                    }
                }

                DesktopProjectSection(title: "Recent conversations", symbol: "clock.arrow.circlepath") {
                    if threads.isEmpty {
                        ProjectEmptyContext(text: "No active conversation in this project")
                    } else {
                        ForEach(threads.prefix(8)) { thread in
                            Button { openThread(thread.id) } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(thread.attention.tint).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(thread.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(thread.kind.label).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if project.archivedAtUnixMillis == nil {
                    Divider()
                    Button("Archive project", systemImage: "archivebox") { showsArchiveConfirmation = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(hasActiveRun ? .secondary : Nord.auroraRed)
                        .disabled(hasActiveRun)
                        .help(hasActiveRun ? "Finish or interrupt active runs before archiving" : "Archive this project and its conversations")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsEditor) {
            DesktopProjectEditor(model: model, project: project)
        }
        .confirmationDialog(
            "Archive \(project.name)?",
            isPresented: $showsArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive project and conversations", role: .destructive) {
                model.setProjectArchived(id: project.id, archived: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is recoverable. Linked context remains local and inspectable.")
        }
    }
}

private struct DesktopProjectEditor: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var summary: String
    @State private var instructionText: String
    @State private var knowledgeSourceIDs: Set<String>
    @State private var skillIDs: Set<String>
    @State private var defaultKind: DesktopWorkKind
    @State private var defaultProvider: String
    @State private var defaultModel: String
    @State private var saveError: String?

    init(model: DesktopAppModel, project: DesktopProject) {
        self.model = model
        self.project = project
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path ?? "")
        _summary = State(initialValue: project.summary)
        _instructionText = State(initialValue: project.context.instructionReferences.joined(separator: "\n"))
        _knowledgeSourceIDs = State(initialValue: Set(project.context.knowledgeSourceIDs))
        _skillIDs = State(initialValue: Set(project.context.skillIDs))
        _defaultKind = State(initialValue: project.context.defaultKind)
        _defaultProvider = State(initialValue: project.context.defaultProvider)
        _defaultModel = State(initialValue: project.context.defaultModel)
    }

    private var instructions: [String] {
        instructionText.split(whereSeparator: \Character.isNewline).map(String.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Purpose", text: $summary, axis: .vertical).lineLimit(2...5)
                    TextField("Primary workspace path", text: $path)
                }

                Section("Conversation defaults") {
                    Picker("Kind", selection: $defaultKind) {
                        ForEach(DesktopWorkKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Provider", text: $defaultProvider)
                    TextField("Model", text: $defaultModel)
                    Text("Defaults remove setup friction; every run still shows its actual provider, model, context, and authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Instruction references") {
                    TextEditor(text: $instructionText)
                        .font(.body.monospaced())
                        .frame(minHeight: 90)
                    Text("One repository-relative or deliberately scoped reference per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Knowledge") {
                    if model.snapshot.domains.knowledgeSources.isEmpty {
                        Text("No knowledge sources are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.domains.knowledgeSources) { source in
                            Toggle(isOn: membership(source.id, in: $knowledgeSourceIDs)) {
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text(source.scope).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(source.name)
                            .accessibilityValue("\(source.kind.label), \(source.scope), \(source.status.label)")
                        }
                    }
                }

                Section("Skills & tools") {
                    if model.snapshot.domains.skills.isEmpty {
                        Text("No skills or tools are available.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.domains.skills) { skill in
                            Toggle(isOn: membership(skill.id, in: $skillIDs)) {
                                VStack(alignment: .leading) {
                                    Text(skill.name)
                                    Text("\(skill.kind.label) · \(skill.scope)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(skill.name)
                            .accessibilityValue("\(skill.kind.label), \(skill.scope), \(skill.enabled ? "enabled" : "disabled")")
                        }
                    }
                }

                Section("Review") {
                    LabeledContent("Instructions", value: "\(instructions.count)")
                    LabeledContent("Knowledge sources", value: "\(knowledgeSourceIDs.count)")
                    LabeledContent("Skills & tools", value: "\(skillIDs.count)")
                    Text("Saving replaces this project's context selection only. It does not start a provider, read a source, or grant write authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Nord.auroraRed)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 720, height: 720)
            .navigationTitle("Edit \(project.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save context", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func membership(_ id: String, in selection: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { enabled in
                if enabled { selection.wrappedValue.insert(id) }
                else { selection.wrappedValue.remove(id) }
            }
        )
    }

    private func save() {
        let context = DesktopProjectContext(
            instructionReferences: instructions,
            knowledgeSourceIDs: Array(knowledgeSourceIDs).sorted(),
            skillIDs: Array(skillIDs).sorted(),
            defaultKind: defaultKind,
            defaultProvider: defaultProvider,
            defaultModel: defaultModel
        )
        if model.updateProject(id: project.id, name: name, path: path, summary: summary, context: context) {
            dismiss()
        } else {
            saveError = "Review the project name, paths, and defaults before saving."
        }
    }
}

private struct DesktopProjectSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct ProjectMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.bold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ProjectContextFact: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct ProjectSourceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Nord.frost1).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(status).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

private struct ProjectEmptyContext: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
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
private final class DesktopUpdateViewModel: ObservableObject {
    let environment: KanameDesktopEnvironment
    @Published private(set) var receipt: KanameUpdateReceipt
    @Published private(set) var isBusy = false
    @Published private(set) var canRollback = false
    @Published private(set) var message: String?

    private let coordinator: KanameUpdateCoordinator
    private var helperProcess: Process?

    init(environment: KanameDesktopEnvironment = .current) {
        self.environment = environment
        coordinator = KanameUpdateCoordinator(environment: environment)
        receipt = KanameUpdateReceipt(
            status: .idle,
            detail: environment.channel == .stable
                ? "No update is staged."
                : "This candidate has its own state and cannot replace stable Kaname.",
            updatedAtUnixMillis: 0
        )
        _Concurrency.Task { await refresh() }
    }

    func chooseAndStage() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose a stable Kaname update"
        panel.prompt = "Verify and stage"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        message = "Verifying the signature and staging a private copy…"
        _Concurrency.Task {
            do {
                receipt = try await coordinator.stage(bundleURL: url)
                message = "Update ready. Your current Kaname remains active until you choose Switch and relaunch."
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
            await refreshRollbackAvailability()
        }
#endif
    }

    func switchAndRelaunch(model: DesktopAppModel) {
#if os(macOS)
        let hasActiveApproval = model.snapshot.operations.approvals.contains { $0.state == .awaitingApproval }
        isBusy = true
        _Concurrency.Task {
            do {
                let request = try await coordinator.switchRequest(
                    installedBundleURL: Bundle.main.bundleURL,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    composerCheckpointed: model.persistenceError == nil,
                    hasActiveApproval: hasActiveApproval
                )
                try launchHelper(request)
                message = "Switching after the current UI closes…"
                NSApplication.shared.terminate(nil)
            } catch {
                message = error.localizedDescription
                isBusy = false
            }
        }
#endif
    }

    func rollback() {
#if os(macOS)
        _Concurrency.Task {
            do {
                let request = try await coordinator.rollbackRequest(
                    installedBundleURL: Bundle.main.bundleURL,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                )
                try launchHelper(request)
                message = "Restoring the previous Kaname UI…"
                NSApplication.shared.terminate(nil)
            } catch {
                message = error.localizedDescription
            }
        }
#endif
    }

    private func launchHelper(_ request: KanameUpdateLaunchRequest) throws {
        let process = Process()
        process.executableURL = request.helperURL
        process.arguments = request.arguments
        try process.run()
        helperProcess = process
    }

    private func refresh() async {
        receipt = await coordinator.receipt()
        await refreshRollbackAvailability()
    }

    private func refreshRollbackAvailability() async {
        let backupURL = await coordinator.backupBundleURL
        canRollback = FileManager.default.fileExists(atPath: backupURL.path)
    }
}

@MainActor
private final class DesktopPersonalIntegrationViewModel: ObservableObject {
    @Published private(set) var googleAccounts: [NativeGoogleAccountSnapshot] = []
    @Published private(set) var googleCalendars: [PersonalCalendarSourceSnapshot] = []
    @Published private(set) var mailThreads: [PersonalMailThreadSnapshot] = []
    @Published private(set) var githubAccess: GitHubCLIAccessSnapshot?
    @Published private(set) var providerCapabilities: [ProviderCapabilitySnapshot] = []
    @Published private(set) var appleAccessState: AppleCalendarAccessState
    @Published private(set) var isRefreshingGoogle = false
    @Published private(set) var isConnectingGoogle = false
    @Published private(set) var hasGoogleClientConfiguration = false
    @Published private(set) var isRefreshingInbox = false
    @Published private(set) var isRefreshingGitHub = false
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var isRequestingAppleCalendar = false
    @Published private(set) var lastProviderRefreshAt: Date?
    @Published private(set) var lastIntegrationRefreshAt: Date?
    @Published private(set) var message: String?

    private let integrations = PersonalIntegrationService()
    private let googleIntegration: NativeGoogleIntegrationService
    private let appleCalendar = AppleCalendarIntegrationService()
    private let providerCache: ProviderCapabilityCacheStore

    init(environment: KanameDesktopEnvironment = .current) {
        googleIntegration = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService
        )
        providerCache = ProviderCapabilityCacheStore(directory: environment.connectivityDirectory)
        appleAccessState = appleCalendar.accessState
        _Concurrency.Task {
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            googleAccounts = (try? await googleIntegration.accounts()) ?? []
            if let cached = try? await providerCache.load() {
                providerCapabilities = cached.capabilities
                lastProviderRefreshAt = cached.checkedAt
            }
        }
    }

    private var monitoringTask: _Concurrency.Task<Void, Never>?

    func startMonitoring(model: DesktopAppModel) {
        guard monitoringTask == nil else { return }
        monitoringTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            googleAccounts = (try? await googleIntegration.accounts()) ?? []
            if let cached = try? await providerCache.load() {
                providerCapabilities = cached.capabilities
                lastProviderRefreshAt = cached.checkedAt
            }
            guard !CommandLine.arguments.contains("--snapshot") else { return }

            refreshProviders(announce: false)
            refreshGitHub(model: model, announce: false)
            if !googleAccounts.isEmpty { refreshGoogle(model: model, announce: false) }
            refreshAppleCalendarStatus(model: model, announce: false)

            var cycle = 0
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(300))
                guard !_Concurrency.Task.isCancelled else { return }
                cycle += 1
                refreshProviders(announce: false)
                if cycle.isMultiple(of: 3) {
                    refreshGitHub(model: model, announce: false)
                    if !googleAccounts.isEmpty { refreshGoogle(model: model, announce: false) }
                    refreshAppleCalendarStatus(model: model, announce: false)
                }
            }
        }
    }

    func refreshAllStatus(model: DesktopAppModel) {
        refreshProviders()
        refreshGitHub(model: model)
        if !googleAccounts.isEmpty { refreshGoogle(model: model) }
        refreshAppleCalendarStatus(model: model)
    }

    func refreshGoogle(model: DesktopAppModel, announce: Bool = true) {
        guard !isRefreshingGoogle else { return }
        isRefreshingGoogle = true
        if announce { message = nil }
        _Concurrency.Task {
            do {
                let discovered = try await googleIntegration.accounts()
                googleAccounts = discovered
                let gmailAccounts = discovered.map { accountRecord(for: $0, service: .gmail) }
                let calendarAccounts = discovered.map { accountRecord(for: $0, service: .googleCalendar) }
                model.replaceAccounts(
                    for: [.gmail, .googleCalendar],
                    with: gmailAccounts + calendarAccounts
                )

                var refreshedCalendars: [PersonalCalendarSourceSnapshot] = []
                var failedAccounts: [String] = []
                for account in discovered {
                    do {
                        refreshedCalendars.append(contentsOf: try await googleIntegration.listCalendars(
                            accountIDs: [account.id],
                            allowKeychainInteraction: announce
                        ))
                    } catch {
                        failedAccounts.append(account.identity)
                    }
                }
                googleCalendars = refreshedCalendars
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
                lastIntegrationRefreshAt = .now
                if announce {
                    message = failedAccounts.isEmpty
                        ? "Refreshed \(discovered.count) Google account\(discovered.count == 1 ? "" : "s") and \(googleCalendars.count) calendar\(googleCalendars.count == 1 ? "" : "s")."
                        : "Refreshed \(discovered.count - failedAccounts.count) of \(discovered.count) Google accounts. Reconnect: \(failedAccounts.joined(separator: ", "))."
                }
            } catch {
                if announce { message = error.localizedDescription }
            }
            isRefreshingGoogle = false
        }
    }

    func connectGoogleAccount(model: DesktopAppModel) {
        guard !isConnectingGoogle else { return }
        isConnectingGoogle = true
        message = nil
        _Concurrency.Task {
            do {
#if os(macOS)
                let account = try await googleIntegration.connectAccount()
                message = "Connected \(account.identity). Refreshing its calendars…"
                isConnectingGoogle = false
                refreshGoogle(model: model)
#else
                message = "Google account connection is available in the desktop app."
                isConnectingGoogle = false
#endif
            } catch {
                message = error.localizedDescription
                isConnectingGoogle = false
            }
        }
    }

    func disconnectGoogleAccount(id: String, model: DesktopAppModel) {
        message = nil
        _Concurrency.Task {
            do {
                try await googleIntegration.disconnect(accountID: id)
                googleAccounts = try await googleIntegration.accounts()
                googleCalendars.removeAll { calendar in
                    !googleAccounts.contains { $0.identity == calendar.accountIdentity }
                }
                let gmailAccounts = googleAccounts.map { accountRecord(for: $0, service: .gmail) }
                let calendarAccounts = googleAccounts.map { accountRecord(for: $0, service: .googleCalendar) }
                model.replaceAccounts(for: [.gmail, .googleCalendar], with: gmailAccounts + calendarAccounts)
                let appleSources = model.snapshot.domains.calendarSources.filter { $0.provider == .apple }
                let googleSources = model.snapshot.domains.calendarSources.filter { source in
                    source.provider == .google && googleAccounts.contains { $0.identity == source.ownerIdentity }
                }
                model.replaceCalendarSources(appleSources + googleSources)
                message = "Google account disconnected from Kaname."
            } catch {
                message = error.localizedDescription
            }
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
            var refreshedThreads: [PersonalMailThreadSnapshot] = []
            var failedAccounts: [String] = []
            for account in googleAccounts where identities.contains(account.identity) {
                do {
                    refreshedThreads.append(contentsOf: try await googleIntegration.listInbox(accountIDs: [account.id]))
                } catch {
                    failedAccounts.append(account.identity)
                }
            }
            mailThreads = refreshedThreads
            message = failedAccounts.isEmpty
                ? "Read \(mailThreads.count) inbox thread\(mailThreads.count == 1 ? "" : "s") across \(identities.count) account\(identities.count == 1 ? "" : "s")."
                : "Read \(mailThreads.count) inbox threads; reconnect \(failedAccounts.joined(separator: ", "))."
            isRefreshingInbox = false
        }
    }

    func refreshGitHub(model: DesktopAppModel, announce: Bool = true) {
        guard !isRefreshingGitHub else { return }
        isRefreshingGitHub = true
        if announce { message = nil }
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
                lastIntegrationRefreshAt = .now
                if announce { message = "GitHub CLI access is ready for @\(access.login)." }
            } catch {
                if announce { message = error.localizedDescription }
            }
            isRefreshingGitHub = false
        }
    }

    func refreshProviders(announce: Bool = true) {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        if announce { message = nil }
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
            let checkedAt = results.map(\.checkedAt).max() ?? .now
            lastProviderRefreshAt = checkedAt
            try? await providerCache.save(ProviderCapabilityCacheSnapshot(
                capabilities: results,
                checkedAt: checkedAt
            ))
            let ready = results.filter { $0.state == .ready || $0.state == .degraded }.count
            if announce {
                message = "Refreshed \(results.count) native provider adapter\(results.count == 1 ? "" : "s"); \(ready) available."
            }
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
                applyAppleCalendars(calendars, model: model)
                lastIntegrationRefreshAt = .now
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

    func refreshAppleCalendarStatus(model: DesktopAppModel, announce: Bool = true) {
        appleAccessState = appleCalendar.accessState
        guard appleAccessState == .ready else { return }
        let calendars = appleCalendar.listCalendarsIfAuthorized()
        applyAppleCalendars(calendars, model: model)
        lastIntegrationRefreshAt = .now
        if announce {
            message = "Refreshed \(calendars.count) authorized Apple calendar\(calendars.count == 1 ? "" : "s")."
        }
    }

    private func applyAppleCalendars(
        _ calendars: [AppleCalendarSourceSnapshot],
        model: DesktopAppModel
    ) {
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
    }

    private func accountRecord(
        for account: NativeGoogleAccountSnapshot,
        service: DesktopAccountRecord.Service
    ) -> DesktopAccountRecord {
        DesktopAccountRecord(
            id: stableID(prefix: service.rawValue, value: account.identity),
            service: service,
            displayName: account.displayName,
            identity: account.identity,
            status: .ready,
            scope: account.capabilities.joined(separator: ", ")
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
                                ActionStatePill(state: pullRequest.state)
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
        .background(Nord.polarNight0)
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
                Text("Awaiting approval").font(.caption).foregroundStyle(Nord.auroraYellow)
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
                Text("Merge awaiting approval").foregroundStyle(Nord.auroraYellow)
            default:
                Button("Request merge approval") {
                    githubControl.requestMergeApproval(model: model, pullRequest: pullRequest)
                }
                .buttonStyle(.bordered)
            }
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
    @ObservedObject var runtime: DesktopConversationRuntime
    let openThread: (String) -> Void
    @StateObject private var control = DesktopCodingControlViewModel()
    @State private var panel = Panel.overview
    @State private var showsNewComparison = false
    @State private var showsNewWorktree = false
    @State private var commitMessages: [String: String] = [:]

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
            .background(Nord.polarNight1)

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
                        Button("New worktree", systemImage: "arrow.triangle.branch") {
                            showsNewWorktree = true
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
        .sheet(isPresented: $showsNewWorktree) {
            NewManagedWorktreeSheet(model: model)
        }
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
                                    .foregroundStyle(Nord.auroraYellow)
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
            Text("Awaiting approval").foregroundStyle(Nord.auroraYellow)
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
            Text("Awaiting Inbox approval").foregroundStyle(Nord.auroraYellow)
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
            Text("Cleanup awaiting approval").foregroundStyle(Nord.auroraYellow)
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
                        HStack { Text(comparison.title).font(.headline); Spacer(); ActionStatePill(state: comparison.state) }
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
                        HStack { Text(gate.kind.label).font(.headline); Text(gate.command).font(.system(.caption, design: .monospaced)); Spacer(); ActionStatePill(state: gate.state) }
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

private struct DesktopSettingsModal: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            DesktopSettingsView(model: model, integrations: integrations, updates: updates, dismiss: dismiss)
                .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Nord.polarNight3, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { }
                .padding(24)
                .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: dismiss)
    }
}

private struct DesktopSettingsView: View {
    @Environment(\.dismiss) private var environmentDismiss
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @State private var draft: DesktopPreferences
    private let explicitDismiss: (() -> Void)?

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        dismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        explicitDismiss = dismiss
        _draft = State(initialValue: model.snapshot.preferences)
    }

    var body: some View {
        DesktopSettingsShell(
            model: model,
            integrations: integrations,
            updates: updates,
            draft: $draft,
            dismiss: { explicitDismiss?() ?? environmentDismiss() }
        )
        .onChange(of: draft) { updated in
            var persisted = updated
            if TimeZone(identifier: updated.defaultScheduleTimeZoneIdentifier) == nil {
                persisted.defaultScheduleTimeZoneIdentifier = model.snapshot.preferences.defaultScheduleTimeZoneIdentifier
            }
            model.updatePreferences(persisted)
        }
    }

}

private struct DesktopSettingsShell: View {
    private enum Category: String, CaseIterable, Identifiable {
        case general, integrations, providers, updates, calendars, scheduling, privacy, diagnostics
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: "General"
            case .integrations: "Integrations"
            case .providers: "Coding providers"
            case .updates: "Updates"
            case .calendars: "Calendars"
            case .scheduling: "Scheduling"
            case .privacy: "Privacy & Safety"
            case .diagnostics: "Diagnostics"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .integrations: "link"
            case .providers: "chevron.left.forwardslash.chevron.right"
            case .updates: "arrow.triangle.2.circlepath.circle.fill"
            case .calendars: "calendar"
            case .scheduling: "clock.fill"
            case .privacy: "lock.shield.fill"
            case .diagnostics: "lifepreserver.fill"
            }
        }
    }

    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @Binding var draft: DesktopPreferences
    let dismiss: () -> Void
    @State private var category: Category = .general

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        draft: Binding<DesktopPreferences>,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        _draft = draft
        self.dismiss = dismiss
        let arguments = CommandLine.arguments
        let requested = arguments.firstIndex(of: "--desktop-settings-category")
            .flatMap { arguments.indices.contains($0 + 1) ? Category(rawValue: arguments[$0 + 1]) : nil }
        _category = State(initialValue: requested ?? .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryRail
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.label).font(.title2.weight(.bold))
                            Text(pageDetail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        categoryPage
                        if let message = integrations.message {
                            Label(message, systemImage: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Nord.polarNight2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .background(Nord.polarNight0)
        .frame(minWidth: 820, idealWidth: 940, minHeight: 640, idealHeight: 740)
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Settings", systemImage: "gearshape.fill")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ForEach(Category.allCases) { item in
                Button { category = item } label: {
                    Label(item.label, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            category == item ? Nord.frost2.opacity(0.22) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(category == item ? Nord.snowStorm0 : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Return to Kaname", systemImage: "arrow.left", action: dismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .frame(width: 205)
        .background(Nord.polarNight1)
    }

    private var footer: some View {
        HStack {
            Label(
                TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                    ? "The time zone will save when it is valid; other changes are saved."
                    : "Changes save automatically.",
                systemImage: TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(
                TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil
                    ? Nord.auroraYellow
                    : Color.secondary.opacity(0.65)
            )
            Spacer()
            Button("Refresh all status", systemImage: "arrow.clockwise") {
                integrations.refreshAllStatus(model: model)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var pageDetail: String {
        switch category {
        case .general: "Workspace presentation and review defaults"
        case .integrations: "Personal services, account health, and explicit authorization"
        case .providers: "Local coding agents available to Kaname"
        case .updates: "Verified switching, health checks, and rollback"
        case .calendars: "Choose which connected calendars Kaname may show"
        case .scheduling: "Stable wall-clock behavior when you travel"
        case .privacy: "Notification content and execution authority"
        case .diagnostics: "Retention and privacy-safe support information"
        }
    }

    @ViewBuilder private var categoryPage: some View {
        switch category {
        case .general: generalPage
        case .integrations: integrationsPage
        case .providers: providersPage
        case .updates: updatesPage
        case .calendars: calendarsPage
        case .scheduling: schedulingPage
        case .privacy: privacyPage
        case .diagnostics: diagnosticsPage
        }
    }

    private var generalPage: some View {
        SettingsSection(title: "Workspace", symbol: "macwindow") {
            Toggle("Show technical details by default", isOn: $draft.showTechnicalDetails)
            Toggle("Use compact thread rows", isOn: $draft.compactRows)
            Toggle("Confirm before archiving", isOn: $draft.confirmBeforeArchiving)
        }
    }

    private var integrationsPage: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Connection state refreshes automatically every 15 minutes.", systemImage: "clock.arrow.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let checkedAt = integrations.lastIntegrationRefreshAt {
                    Text(checkedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                }
            }
            SettingsIntegrationCard(
                title: "Google",
                detail: googleDetail,
                symbol: "g.circle.fill",
                tint: .blue,
                connected: !integrations.googleAccounts.isEmpty,
                busy: integrations.isRefreshingGoogle || integrations.isConnectingGoogle
            ) {
                Button(
                    integrations.googleAccounts.isEmpty ? "Connect Google" : "Add account",
                    systemImage: "person.badge.plus"
                ) {
                    integrations.connectGoogleAccount(model: model)
                }
                .disabled(!integrations.hasGoogleClientConfiguration)
                if !integrations.googleAccounts.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { integrations.refreshGoogle(model: model) }
                }
            } details: {
                if integrations.googleAccounts.isEmpty {
                    Text(integrations.hasGoogleClientConfiguration
                        ? "Connect Google opens the system browser, asks for read-only Gmail and Calendar permission, and returns directly to Kaname."
                        : "Google is not registered in this build yet. Its private OAuth client registration belongs in Kaname's build configuration, not in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(integrations.googleAccounts) { account in
                        HStack {
                            Circle().fill(Nord.auroraGreen).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName).font(.subheadline.weight(.semibold))
                                Text(account.identity).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") { integrations.disconnectGoogleAccount(id: account.id, model: model) }
                                .buttonStyle(.borderless).foregroundStyle(Nord.auroraRed)
                        }
                    }
                }
            }
            SettingsIntegrationCard(
                title: "Apple Calendar",
                detail: "Permission: \(appleAccessLabel)",
                symbol: "calendar.circle.fill",
                tint: .red,
                connected: integrations.appleAccessState == .ready,
                busy: integrations.isRequestingAppleCalendar
            ) {
                Button(integrations.appleAccessState == .notRequested ? "Request access" : "Refresh") {
                    if integrations.appleAccessState == .notRequested {
                        integrations.requestAppleCalendarAccess(model: model)
                    } else {
                        integrations.refreshAppleCalendarStatus(model: model)
                    }
                }
            } details: {
                Text("Uses macOS EventKit and the calendar accounts already configured on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsIntegrationCard(
                title: "GitHub",
                detail: integrations.githubAccess.map { "Connected as @\($0.login)" } ?? "Uses your current gh CLI session",
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .purple,
                connected: integrations.githubAccess != nil,
                busy: integrations.isRefreshingGitHub
            ) {
                Button("Refresh gh access", systemImage: "arrow.clockwise") { integrations.refreshGitHub(model: model) }
            } details: {
                Text("Kaname asks gh for the current host and account; it never copies the gh token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var providersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Each adapter uses its installed CLI and existing sign-in.").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("Cached immediately · refreshes every 5 minutes")
                        if let checkedAt = integrations.lastProviderRefreshAt {
                            Text("·")
                            Text(checkedAt, style: .relative)
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if integrations.isRefreshingProviders { ProgressView().controlSize(.small) }
                Button("Refresh now", systemImage: "arrow.clockwise") { integrations.refreshProviders() }
                    .disabled(integrations.isRefreshingProviders)
            }
            ForEach(providerDescriptors) { provider in
                SettingsProviderRow(
                    provider: provider,
                    snapshot: integrations.providerCapabilities.first { $0.instance.driver == provider.driver }
                )
            }
        }
    }

    private var calendarsPage: some View {
        SettingsSection(title: "Visible in Kaname", symbol: "calendar.badge.checkmark") {
            Text("These choices affect Kaname only; they never hide or delete calendars at the provider.")
                .font(.caption).foregroundStyle(.secondary)
            if model.snapshot.domains.calendarSources.isEmpty {
                Label("Connect Google or Apple Calendar from Integrations first.", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.domains.calendarSources) { source in
                Toggle(isOn: Binding(
                    get: { source.isEnabled },
                    set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            Text("\(source.provider.label) · \(source.ownerIdentity)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: source.provider == .google ? "g.circle.fill" : "apple.logo")
                            .foregroundStyle(source.provider == .google ? .blue : .red)
                    }
                }
            }
        }
    }

    private var updatesPage: some View {
        VStack(spacing: 14) {
            SettingsSection(title: "Update continuity", symbol: "arrow.triangle.2.circlepath.circle.fill") {
                LabeledContent("Channel", value: updates.environment.displayName)
                LabeledContent("State", value: updates.receipt.status.rawValue.capitalized)
                if let version = updates.receipt.version {
                    LabeledContent("Ready", value: "\(version) (\(updates.receipt.build ?? "—"))")
                }
                Text(updates.receipt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if updates.environment.channel == .stable {
                    HStack {
                        Button("Choose verified update…", systemImage: "shippingbox") { updates.chooseAndStage() }
                            .disabled(updates.isBusy)
                        Button("Switch and relaunch", systemImage: "arrow.clockwise") {
                            updates.switchAndRelaunch(model: model)
                        }
                        .disabled(updates.isBusy || updates.receipt.status != .staged)
                        Button("Rollback", systemImage: "arrow.uturn.backward") { updates.rollback() }
                            .disabled(updates.isBusy || !updates.canRollback)
                    }
                } else {
                    Label("Candidate state is isolated. Qualify here, then stage a stable-identity build from stable Kaname.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(Nord.frost1)
                }
                if let message = updates.message {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsSection(title: "Switch safety", symbol: "checkmark.shield.fill") {
                Label("Composer drafts and the current selection are checkpointed locally before a switch.", systemImage: "square.and.arrow.down")
                Label("An active approval blocks switching until you resolve it.", systemImage: "hand.raised.fill")
                Label("A missed health deadline automatically restores the previous bundle.", systemImage: "lifepreserver.fill")
            }
        }
    }

    private var schedulingPage: some View {
        SettingsSection(title: "Default schedule zone", symbol: "clock.badge.checkmark") {
            TextField("IANA time zone", text: $draft.defaultScheduleTimeZoneIdentifier)
            HStack {
                Button("Use current zone") { draft.defaultScheduleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier }
                Spacer()
                Text("Viewer: \(TimeZone.autoupdatingCurrent.identifier)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Recurring schedules stay pinned to this zone's wall clock. Kaname also shows the equivalent in your current viewing zone.")
                .font(.caption).foregroundStyle(.secondary)
            if TimeZone(identifier: draft.defaultScheduleTimeZoneIdentifier) == nil {
                Label("Enter a valid IANA identifier such as Asia/Tokyo.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow)
            }
        }
    }

    private var privacyPage: some View {
        VStack(spacing: 14) {
            SettingsSection(title: "Notification privacy", symbol: "hand.raised.fill") {
                Picker("Preview content", selection: $draft.previewPrivacy) {
                    ForEach(DesktopPreferences.PreviewPrivacy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Safe summary never includes private task content. Hidden is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "Execution authority", symbol: "lock.shield.fill") {
                Toggle("Safe mode (disable future write integrations)", isOn: $draft.safeMode)
                LabeledContent("Default", value: "Local-only draft")
                LabeledContent("Provider writes", value: "Exact approval required")
                LabeledContent("External accounts", value: readyAccountSummary)
            }
        }
    }

    private var diagnosticsPage: some View {
        SettingsSection(title: "Recovery & diagnostics", symbol: "lifepreserver.fill") {
            Stepper("Keep audit metadata for \(draft.auditRetentionDays) days", value: $draft.auditRetentionDays, in: 7...365, step: 7)
            Button("Copy redacted diagnostics", systemImage: "doc.on.doc") {
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.redactedDiagnostics(), forType: .string)
#endif
            }
            Text("Diagnostics include counts and health only. They exclude content, identities, paths, and credentials.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providerDescriptors: [SettingsProviderDescriptor] {
        [
            .init(name: "Codex", driver: .codex, symbol: "terminal.fill", tint: Nord.frost1, detail: "OpenAI coding sessions, models, and skills"),
            .init(name: "Claude", driver: .claudeAgent, symbol: "sparkles", tint: .orange, detail: "Claude Code sessions and models"),
            .init(name: "OpenCode", driver: .openCode, symbol: "chevron.left.forwardslash.chevron.right", tint: .purple, detail: "OpenCode sessions and upstream providers"),
        ]
    }

    private var googleDetail: String {
        let count = integrations.googleAccounts.count
        let calendars = model.snapshot.domains.calendarSources.filter { $0.provider == .google }.count
        if count == 0 { return integrations.hasGoogleClientConfiguration ? "Ready to add an account" : "Unavailable in this build" }
        return "\(count) account\(count == 1 ? "" : "s") · \(calendars) calendar\(calendars == 1 ? "" : "s")"
    }

    private var readyAccountSummary: String {
        let count = model.snapshot.domains.accounts.filter { $0.status == .ready }.count
        return count == 0 ? "Not connected" : "\(count) ready"
    }

    private var appleAccessLabel: String {
        switch integrations.appleAccessState {
        case .notRequested: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Write only"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

}

private struct SettingsProviderDescriptor: Identifiable {
    let name: String
    let driver: ProviderDriverKind
    let symbol: String
    let tint: Color
    let detail: String
    var id: String { driver.rawValue }
}

private struct SettingsProviderRow: View {
    let provider: SettingsProviderDescriptor
    let snapshot: ProviderCapabilitySnapshot?

    private var connected: Bool { snapshot?.state == .ready || snapshot?.state == .degraded }
    private var needsAttention: Bool { snapshot?.state == .authenticationRequired }
    private var summary: String {
        guard let snapshot else { return "Not checked" }
        let version = snapshot.version.map { "v\($0) · " } ?? ""
        switch snapshot.state {
        case .ready: return "\(version)Authenticated"
        case .degraded: return "\(version)Available with limited capabilities"
        case .authenticationRequired: return "\(version)Sign in with the provider CLI"
        case .unavailable: return "Executable not found"
        case .unsupported: return "Installed version is unsupported"
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(provider.detail).font(.caption).foregroundStyle(.secondary)
                if let snapshot {
                    LabeledContent("Authentication", value: snapshot.authentication.rawValue.capitalized)
                    LabeledContent("Models", value: snapshot.models.isEmpty ? "Reported on first session" : "\(snapshot.models.count) available")
                    LabeledContent("Skills", value: snapshot.skills.isEmpty ? "None reported" : "\(snapshot.skills.count) available")
                    if let detail = snapshot.detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(provider.tint.opacity(0.18)).frame(width: 38, height: 38)
                    Image(systemName: provider.symbol).foregroundStyle(provider.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(connected ? Nord.auroraGreen : needsAttention ? Nord.auroraYellow : .secondary).frame(width: 8, height: 8)
            }
        }
        .panelStyle()
    }
}

private struct SettingsIntegrationCard<Actions: View, Details: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let connected: Bool
    let busy: Bool
    let actions: Actions
    let details: Details

    init(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        connected: Bool,
        busy: Bool,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder details: () -> Details
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.connected = connected
        self.busy = busy
        self.actions = actions()
        self.details = details()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { details }.padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.18)).frame(width: 42, height: 42)
                    Image(systemName: symbol).font(.title3).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(connected ? Nord.auroraGreen : .secondary).frame(width: 7, height: 7)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                HStack(spacing: 7) { actions }.buttonStyle(.bordered).disabled(busy)
            }
        }
        .panelStyle()
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

private struct DesktopProjectInspector: View {
    @ObservedObject var model: DesktopAppModel
    let project: DesktopProject

    private var projectThreads: [DesktopThread] {
        model.snapshot.threads.filter { $0.projectID == project.id }
    }

    private var lastFreshness: Int64? {
        let selected = Set(project.context.knowledgeSourceIDs)
        return model.snapshot.domains.knowledgeSources
            .filter { selected.contains($0.id) }
            .compactMap(\.lastReadAtUnixMillis)
            .max()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorTitle(title: "Project context", symbol: "folder.fill")

                VStack(alignment: .leading, spacing: 10) {
                    Text(project.name).font(.headline)
                    Text(project.summary.isEmpty ? "No purpose recorded." : project.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Divider()
                    InspectorFact(label: "Default kind", value: project.context.defaultKind.label)
                    InspectorFact(label: "Provider", value: project.context.defaultProvider)
                    InspectorFact(label: "Model", value: project.context.defaultModel)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Included context").font(.headline)
                    InspectorStatus(label: "Instructions", value: "\(project.context.instructionReferences.count)", tint: Nord.frost1)
                    InspectorStatus(label: "Knowledge", value: "\(project.context.knowledgeSourceIDs.count)", tint: Nord.frost2)
                    InspectorStatus(label: "Skills & tools", value: "\(project.context.skillIDs.count)", tint: Nord.auroraPurple)
                    InspectorStatus(label: "Conversations", value: "\(projectThreads.count)", tint: Nord.auroraGreen)
                    if let lastFreshness {
                        HStack {
                            Text("Last source read").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            RelativeTime(unixMillis: lastFreshness).font(.caption)
                        }
                    }
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Boundary").font(.headline)
                    Text("Only the sources selected here may enter a new project conversation by default. A conversation still shows its exact runtime context and asks separately for consequential authority.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

private struct NewManagedWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @State private var projectID: String?
    @State private var threadID: String?
    @State private var branch = "kaname/work"
    @State private var baseRevision = "HEAD"

    private let environment = KanameDesktopEnvironment.current

    init(model: DesktopAppModel) {
        self.model = model
        let project = model.snapshot.projects.first { $0.archivedAtUnixMillis == nil && $0.path != nil }
        _projectID = State(initialValue: project?.id)
        _threadID = State(initialValue: project.flatMap { project in
            model.snapshot.threads.first { $0.projectID == project.id && $0.kind == .coding }?.id
        })
    }

    private var projects: [DesktopProject] {
        model.snapshot.projects.filter { $0.archivedAtUnixMillis == nil && $0.path != nil }
    }

    private var threads: [DesktopThread] {
        guard let projectID else { return [] }
        return model.snapshot.threads.filter { $0.projectID == projectID && $0.kind == .coding }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New isolated worktree").font(.title2.weight(.bold))
            Text("Choose the conversation that will own the work. Kaname derives a private destination and asks for exact approval before touching Git.")
                .foregroundStyle(.secondary)
            worktreeFields
            targetPreview
            BoundaryCallout(
                title: "Authority stays narrow",
                detail: "Saving creates a local proposal only. Creation and later cleanup each require a separate approval in Inbox; cleanup refuses a dirty worktree."
            )
            Spacer()
            footer
        }
        .padding(24)
        .frame(width: 640, height: 560)
    }

    private var worktreeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectPicker
            threadPicker
            TextField("Branch", text: $branch).textFieldStyle(.roundedBorder)
            TextField("Base revision", text: $baseRevision).textFieldStyle(.roundedBorder)
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: $projectID) {
            Text("Choose a project").tag(String?.none)
            ForEach(projects) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .onChange(of: projectID) { selected in
            threadID = model.snapshot.threads.first { $0.projectID == selected && $0.kind == .coding }?.id
        }
    }

    private var threadPicker: some View {
        Picker("Coding conversation", selection: $threadID) {
            Text("Choose a conversation").tag(String?.none)
            ForEach(threads) { thread in
                Text(thread.title).tag(Optional(thread.id))
            }
        }
    }

    @ViewBuilder
    private var targetPreview: some View {
        if let target = proposedTarget {
            LabeledContent("Managed destination") {
                Text(target.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .panelStyle()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
            Button("Save proposal") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(proposedTarget == nil)
        }
    }

    private var proposedTarget: URL? {
        guard let projectID, let threadID,
              let project = model.project(id: projectID),
              !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !baseRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let slug = "\(project.name)-\(branch)"
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let digest = String(threadID.prefix(8))
        return environment.worktreeDirectory.appending(path: "\(slug.prefix(80))-\(digest)", directoryHint: .isDirectory)
    }

    private func save() {
        guard let projectID, let threadID,
              let root = model.workspaceURL(threadID: threadID),
              let target = proposedTarget,
              model.proposeWorktree(
                projectID: projectID,
                threadID: threadID,
                rootWorkspacePath: root.path,
                worktreePath: target.path,
                branch: branch,
                baseRevision: baseRevision
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
    let projectID: String?
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DesktopWorkKind = .coding

    init(model: DesktopAppModel, projectID: String?, created: @escaping (String) -> Void) {
        self.model = model
        self.projectID = projectID
        self.created = created
        _kind = State(initialValue: model.project(id: projectID)?.context.defaultKind ?? .coding)
    }

    private var project: DesktopProject? {
        model.project(id: projectID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Context") {
                    LabeledContent {
                        Text(project?.name ?? "Standalone")
                            .fontWeight(.medium)
                    } label: {
                        Label(
                            project == nil ? "Conversation" : "Project",
                            systemImage: project == nil ? "bubble.left" : "folder.fill"
                        )
                    }
                    Text(
                        project == nil
                            ? "Start without attaching a project. You can connect deliberate context later."
                            : "This conversation stays attached to the selected project."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach(DesktopWorkKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(kind.startDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Label("No subject required", systemImage: "sparkles")
                    Text("Kaname opens a blank conversation and names it automatically from your first message.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
            .frame(width: 540, height: 390)
            .navigationTitle("New conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start conversation") {
                        let id = model.createConversation(kind: kind, projectID: projectID)
                        created(id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
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
    let openProject: () -> Void
    let startConversation: () -> Void
    let openThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button(action: openProject) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Nord.frost2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.title3.weight(.bold))
                            Text("\(threads.count) active thread\(threads.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open project overview")
                Spacer()
                Button(action: startConversation) {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(Nord.polarNight2, in: Circle())
                }
                .buttonStyle(.plain)
                .help("New conversation in \(project.name)")
                .accessibilityLabel("New conversation in \(project.name)")
            }
            Button(action: openProject) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.summary.isEmpty ? "No purpose recorded yet." : project.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let path = project.path {
                        Label(path, systemImage: "externaldrive")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Label("\(project.context.knowledgeSourceIDs.count)", systemImage: "books.vertical")
                        Label("\(project.context.skillIDs.count)", systemImage: "hammer")
                        Label(project.context.defaultProvider, systemImage: "cpu")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(project.name) project overview")
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
        case .interrupted: Nord.auroraOrange
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

    var startDetail: String {
        switch self {
        case .coding: "Discuss, plan, implement, and review work for a repository or workspace."
        case .research: "Investigate a question with explicit source and sensitivity boundaries."
        case .planning: "Shape a decision or implementation plan before granting write authority."
        case .personal: "Start non-coding work while keeping unrelated contexts separate."
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
