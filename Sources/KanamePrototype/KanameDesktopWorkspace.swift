import KanameDesktop
import KanamePrototypeUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

private enum DesktopDestination: String, CaseIterable, Identifiable {
    case home
    case threads
    case inbox
    case projects
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
        case .devices: "Devices & Remote"
        case .liveCodex: "Codex Workspace"
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
    @State private var destination: DesktopDestination
    @State private var selectedThreadID: String?
    @State private var searchText = ""
    @State private var inboxFilter: DesktopAttention? = nil
    @State private var showsNewThread = false
    @State private var showsNewProject = false
    @State private var navigationHistory: [DesktopNavigationLocation] = []

    init() {
        let arguments = CommandLine.arguments
        let requestedDestination = arguments.firstIndex(of: "--desktop-destination")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
            ?? .home
        let requestedBackDestination = arguments.firstIndex(of: "--desktop-back-target")
            .flatMap { arguments.indices.contains($0 + 1) ? DesktopDestination(rawValue: arguments[$0 + 1]) : nil }
        _destination = State(initialValue: requestedDestination)
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
        NavigationSplitView {
            sidebar
        } content: {
            content
                .navigationTitle(destination.title)
                .toolbar { toolbar }
        } detail: {
            inspectorColumn
        }
        .navigationSplitViewStyle(.balanced)
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
                    destinationButton(.devices)
                }

                Section("Build") {
                    destinationButton(.liveCodex)
                    destinationButton(.localCore)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Nord.polarNight1)
            .listStyle(.sidebar)

            Divider()
            Button {
                navigate(to: .settings)
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
            .background(destination == .settings ? Nord.polarNight2.opacity(0.72) : Color.clear)
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
            case .devices:
                DesktopDevicesView(model: model)
            case .liveCodex:
                CodexLiveWorkspace()
            case .localCore:
                LocalCoreWorkspace()
            case .settings:
                DesktopSettingsView(model: model)
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
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
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
            ControlGroup {
                Button {
                    showsNewThread = true
                } label: {
                    Label("New thread", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu {
                    Button("New project") { showsNewProject = true }
                    Divider()
                    Button("Open Devices & Remote") { navigate(to: .devices) }
                    Button("Open Codex Workspace") { navigate(to: .liveCodex) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            .controlGroupStyle(.navigation)
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
        destination = target.destination
        selectedThreadID = target.selectedThreadID
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
                        title: "Remote loop",
                        value: "Ready",
                        detail: "Simulator-qualified",
                        symbol: "lock.shield.fill",
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
                        SectionHeading(title: "Continue building", detail: "Validated development surfaces.")
                        QuickActionCard(
                            title: "Codex Workspace",
                            detail: "Inspect an isolated worktree, request a plan, approve exact scope, and review evidence.",
                            symbol: DesktopDestination.liveCodex.symbol,
                            tint: Nord.frost1
                        ) { openDestination(.liveCodex) }
                        QuickActionCard(
                            title: "Devices & Remote",
                            detail: "Review encrypted relay, recovery, privacy, and deferred live gates.",
                            symbol: DesktopDestination.devices.symbol,
                            tint: Nord.auroraPurple
                        ) { openDestination(.devices) }
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
    @ObservedObject var model: DesktopAppModel
    @State private var draft: DesktopPreferences

    init(model: DesktopAppModel) {
        self.model = model
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
                    LabeledContent("Default", value: "Local-only draft")
                    LabeledContent("Provider writes", value: "Exact approval required")
                    LabeledContent("External accounts", value: "Not connected")
                    Text("Changing display settings never grants provider, repository, account, device, or network authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Revert") { draft = model.snapshot.preferences }
                    Button("Save settings") { model.updatePreferences(draft) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .background(Nord.polarNight0)
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

private struct BoundaryCallout: View {
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

private struct SurfaceHeader<Actions: View>: View {
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

private extension View {
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
        case .devices: "Encrypted reachability and recovery without silently widening authority."
        case .liveCodex: "Isolated worktree inspection, planning, explicit write approval, and evidence review."
        case .localCore: "Provider-free replay, failure, and recovery evidence from the durable authority."
        case .settings: "Presentation and privacy defaults that never grant external authority."
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
