import KanameDesktop
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

extension Notification.Name {
    static let kanamePresentGlobalSearch = Notification.Name("com.cyberlane.kaname.desktop.command.global-search")
    static let kanameBeginConversation = Notification.Name("com.cyberlane.kaname.desktop.command.new-conversation")
    static let kanamePresentSettings = Notification.Name("com.cyberlane.kaname.desktop.command.settings")
    static let kanameImportFiles = Notification.Name("com.cyberlane.kaname.desktop.command.import-files")
    static let kanameExportCurrent = Notification.Name("com.cyberlane.kaname.desktop.command.export-current")
    static let kanameNavigate = Notification.Name("com.cyberlane.kaname.desktop.command.navigate")
    static let kanameToggleInspector = Notification.Name("com.cyberlane.kaname.desktop.command.toggle-inspector")
    static let kanameFocusComposer = Notification.Name("com.cyberlane.kaname.desktop.command.focus-composer")
    static let kanameGoBack = Notification.Name("com.cyberlane.kaname.desktop.command.go-back")
    static let kanamePresentDiagnostics = Notification.Name("com.cyberlane.kaname.desktop.command.diagnostics")
    static let kanameDesktopReady = Notification.Name("com.cyberlane.kaname.desktop.lifecycle.ready")
    static let kanameInterruptCurrent = Notification.Name("com.cyberlane.kaname.desktop.command.interrupt-current")
    static let kanameRetryCurrent = Notification.Name("com.cyberlane.kaname.desktop.command.retry-current")
}

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

private struct DesktopSearchNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let target: DesktopGlobalSearchNavigationTarget
    let title: String
}

private struct DesktopSearchFallbackNotice: Equatable {
    let destination: DesktopDestination
    let title: String
    let detail: String
}

private enum DesktopCommandCenterAction: Identifiable, Equatable {
    case newConversation(projectID: String?, projectName: String?)
    case configureConversation(projectID: String?, projectName: String?)
    case newProject
    case open(DesktopDestination)

    var id: String {
        switch self {
        case let .newConversation(projectID, _): "new-conversation:\(projectID ?? "standalone")"
        case let .configureConversation(projectID, _): "configure-conversation:\(projectID ?? "standalone")"
        case .newProject: "new-project"
        case let .open(destination): "open:\(destination.rawValue)"
        }
    }

    var title: String {
        switch self {
        case let .newConversation(_, projectName):
            projectName.map { "New conversation in \($0)" } ?? "New standalone conversation"
        case let .configureConversation(_, projectName):
            projectName.map { "Configure conversation in \($0)…" } ?? "Configure standalone conversation…"
        case .newProject: "Add project"
        case let .open(destination): "Open \(destination.title)"
        }
    }

    var detail: String {
        switch self {
        case .newConversation:
            "Open or reuse a local draft and focus the composer"
        case .configureConversation:
            "Choose kind, provider, model, thinking, and authority before opening"
        case .newProject:
            "Local folder, GitHub repository, Git URL, or folderless context"
        case let .open(destination):
            "Go to the \(destination.title) workspace"
        }
    }

    var symbol: String {
        switch self {
        case .newConversation: "square.and.pencil"
        case .configureConversation: "slider.horizontal.3"
        case .newProject: "folder.badge.plus"
        case let .open(destination): destination.symbol
        }
    }
}

private struct DesktopUIRestoreState: Codable {
    var destination: String
    var selectedThreadID: String?
    var selectedProjectID: String?
    var showsInspector: Bool?
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

private final class VolatileDesktopStateStore: DesktopStateStoring {
    private var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

private struct NewConversationRequest: Identifiable {
    let id = UUID()
    let projectID: String?
}

private struct DesktopQALargeTextKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var desktopQALargeText: Bool {
        get { self[DesktopQALargeTextKey.self] }
        set { self[DesktopQALargeTextKey.self] = newValue }
    }
}

struct KanameDesktopWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sizeCategory) private var sizeCategory
    private let uiRestoreStore: DesktopUIRestoreStore
    private let initialGlobalSearchQuery: String
    private let usesQALargeText: Bool
    @StateObject private var model: DesktopAppModel
    @StateObject private var conversationRuntime: DesktopConversationRuntime
    @StateObject private var automationScheduler: DesktopAutomationSchedulerViewModel
    @StateObject private var personalIntegrations: DesktopPersonalIntegrationViewModel
    @StateObject private var updates: DesktopUpdateViewModel
    @StateObject private var automaticBackup: DesktopAutomaticBackupViewModel
    @StateObject private var portableTransfer = DesktopPortableTransferViewModel()
    @State private var destination: DesktopDestination
    @State private var selectedThreadID: String?
    @State private var selectedProjectID: String?
    @State private var searchText = ""
    @State private var inboxFilter: DesktopAttention? = nil
    @State private var newConversationRequest: NewConversationRequest?
    @State private var showsNewProject = false
    @State private var showsInspector = true
    @State private var showsThreadDirectory = true
    @State private var showsSettings = false
    @State private var showsGlobalSearch = false
    @State private var showsDiagnostics = false
    @State private var developmentForkFailure: String?
    @State private var navigationHistory: [DesktopNavigationLocation] = []
    @State private var pendingCreatedThreadID: String?
    @State private var composerFocusRequest: DesktopComposerFocusRequest?
    @State private var selectedThreadRunID: String?
    @State private var selectedConversationAnchorID: String?
    @State private var workspaceAnnouncement = ""
    @State private var searchNavigationRequest: DesktopSearchNavigationRequest?
    @State private var searchFallbackNotice: DesktopSearchFallbackNotice?
    @State private var dismissedUpdateIdentity: String?
    @State private var showsUpdateInstallConfirmation = false
#if os(macOS)
    @State private var searchPreviousResponder: NSResponder?
    @State private var modalPreviousResponder: NSResponder?
    @State private var importPreviousResponder: NSResponder?
    @State private var diagnosticsPreviousResponder: NSResponder?
    @State private var navigationPreviousResponders: [NSResponder?] = []
#endif

    init() {
        let environment = KanameDesktopEnvironment.current
        let desktopStore: any DesktopStateStoring
        let forkFailure: String?
        do {
            _ = try DesktopDevelopmentDataFork.prepareIfNeeded(environment: environment)
            desktopStore = FileDesktopStateStore(fileURL: environment.workspaceFileURL)
            forkFailure = nil
        } catch {
            desktopStore = VolatileDesktopStateStore()
            forkFailure = error.localizedDescription
        }
        let restoreStore = DesktopUIRestoreStore(fileURL: environment.desktopDirectory.appending(path: "ui-restore.json"))
        let restoredUI = forkFailure == nil ? restoreStore.load() : nil
        uiRestoreStore = restoreStore
        let desktopModel = DesktopAppModel(store: desktopStore)
        let arguments = CommandLine.arguments
        if arguments.contains("--desktop-plan-review-fixture") {
            desktopModel.replaceProviderPlan(
                threadID: "thread-desktop-dogfood",
                steps: [
                    ("Audit the current Plan surface, workflow boundary, and related status patterns.", "pending"),
                    ("Replace the repeated cards with one bounded, readable implementation outline.", "pending"),
                    ("Add clear request-changes and approval actions without granting implicit write authority.", "pending"),
                    ("Verify long-step wrapping, compact layout, accessibility semantics, and existing workflow behavior.", "pending"),
                ],
                explanation: "A focused Plan review fixture with explicit authority and responsive actions."
            )
            desktopModel.finalizeCodingPlanForApproval(threadID: "thread-desktop-dogfood")
        }
        let runtime = DesktopConversationRuntime(model: desktopModel, environment: environment)
        _developmentForkFailure = State(initialValue: forkFailure)
        _model = StateObject(wrappedValue: desktopModel)
        _conversationRuntime = StateObject(wrappedValue: runtime)
        _automationScheduler = StateObject(wrappedValue: DesktopAutomationSchedulerViewModel(model: desktopModel, runtime: runtime, environment: environment))
        _personalIntegrations = StateObject(wrappedValue: DesktopPersonalIntegrationViewModel(environment: environment))
        _updates = StateObject(wrappedValue: DesktopUpdateViewModel(environment: environment))
        _automaticBackup = StateObject(wrappedValue: DesktopAutomaticBackupViewModel(environment: environment))
        if let fixtureIndex = arguments.firstIndex(of: "--desktop-workflow-fixture"),
           arguments.indices.contains(fixtureIndex + 1) {
            seedSyntheticWorkflowFixture(model: desktopModel, manifestPath: arguments[fixtureIndex + 1])
        }
        usesQALargeText = arguments.contains("--desktop-large-text")
        initialGlobalSearchQuery = arguments.firstIndex(of: "--desktop-search-query")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? ""
        _showsGlobalSearch = State(initialValue: arguments.contains("--desktop-global-search"))
        _showsDiagnostics = State(initialValue: arguments.contains("--desktop-diagnostics"))
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
        let startsWithContextualInspector = requestedDestination == .threads
            || (requestedDestination == .projects && (requestedProjectID ?? restoredUI?.selectedProjectID) != nil)
        _showsInspector = State(initialValue: startsWithContextualInspector
            ? (restoredUI?.showsInspector ?? true)
            : false)
        _newConversationRequest = State(initialValue: arguments.contains("--desktop-new-conversation")
            ? NewConversationRequest(projectID: requestedProjectID)
            : nil)
        _showsNewProject = State(initialValue: arguments.contains("--desktop-new-project"))
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
#if os(macOS)
        _navigationPreviousResponders = State(initialValue: requestedBackDestination == nil ? [] : [nil])
#endif
    }

    @ViewBuilder
    private var workspaceStack: some View {
        navigationLayout
            .background(Nord.polarNight0)
            .dropDestination(for: URL.self) { urls, _ in
                prepareImport(urls: urls)
            }
    }

    @ViewBuilder
    private var modalPresentationLayer: some View {
        ZStack {
            if showsSettings {
                DesktopSettingsModal(
                    model: model,
                    integrations: personalIntegrations,
                    updates: updates,
                    automaticBackup: automaticBackup,
                    dismiss: { dismissSettings(restoringFocus: true) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(1)
            }

            if showsGlobalSearch {
                DesktopModalBackdrop(dismiss: { dismissGlobalSearch(restoringFocus: true) }) {
                    DesktopGlobalSearchPalette(
                        snapshot: model.snapshot,
                        currentProjectID: inheritedProjectID ?? selectedProjectID,
                        initialQuery: initialGlobalSearchQuery,
                        dismiss: { dismissGlobalSearch(restoringFocus: true) },
                        open: openSearchResult,
                        perform: performCommandCenterAction
                    )
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(2)
            }

            if showsNewProject {
                DesktopModalBackdrop(dismiss: { dismissNewProject(restoringFocus: true) }) {
                    DesktopProjectCreationPalette(
                        model: model,
                        dismiss: { dismissNewProject(restoringFocus: true) },
                        created: finishProjectCreation
                    )
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(3)
            }

            if !workspaceAnnouncement.isEmpty {
                Text(workspaceAnnouncement)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityLabel(workspaceAnnouncement)
            }

            if model.isRecoveryReadOnly {
                DesktopRecoveryCenter(
                    model: model,
                    inspectDiagnostics: presentDiagnostics
                )
                .zIndex(10)
            }

            if let developmentForkFailure {
                ZStack {
                    Nord.polarNight0.ignoresSafeArea()
                    ContentUnavailableView {
                        Label("Development data fork stopped safely", systemImage: "lock.shield.fill")
                            .foregroundStyle(Nord.auroraYellow)
                    } description: {
                        Text(developmentForkFailure)
                        Text("The Stable workspace was not modified. Quit Development, resolve the reported condition, then relaunch it through the Dev launcher.")
                            .foregroundStyle(Nord.frost1)
                    }
                    .frame(maxWidth: 620)
                }
                .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presentedWorkspace: some View {
        workspaceStack
        .sheet(item: $newConversationRequest, onDismiss: finishNewConversationPresentation) { request in
            NewDesktopThreadSheet(
                model: model,
                projectID: request.projectID,
                capabilities: personalIntegrations.providerCapabilities
            ) { threadID in
                pendingCreatedThreadID = threadID
            }
            .environment(\.desktopQALargeText, usesQALargeText)
        }
        .sheet(item: $portableTransfer.importReview, onDismiss: finishImportPresentation) { _ in
            DesktopImportReviewSheet(transfer: portableTransfer, model: model)
        }
        .sheet(isPresented: $showsDiagnostics, onDismiss: restoreDiagnosticsFocus) {
            DesktopDiagnosticsInspector(
                report: model.redactedSupportBundle(),
                dismiss: { showsDiagnostics = false }
            )
        }
        .alert(
            "Local workspace was not saved",
            isPresented: Binding(
                get: { !model.isRecoveryReadOnly && model.persistenceError != nil },
                set: { if !$0 { model.clearPersistenceError() } }
            )
        ) {
            Button("Dismiss", role: .cancel) { model.clearPersistenceError() }
        } message: {
            Text(model.persistenceError ?? "The previous durable workspace remains intact.")
        }
        .alert(
            "Local file transfer",
            isPresented: Binding(
                get: { portableTransfer.message != nil },
                set: { if !$0 { portableTransfer.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { portableTransfer.message = nil }
        } message: {
            Text(portableTransfer.message ?? "The local file action finished.")
        }
        .alert(
            updateInstallConfirmationTitle,
            isPresented: $showsUpdateInstallConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Install and relaunch") { updates.switchAndRelaunch(model: model) }
        } message: {
            Text("Kaname will checkpoint the current UI, install the verified staged build, and relaunch. An active approval or a workspace persistence error blocks the switch, and a failed health check automatically restores the previous app.")
        }
    }

    private var lifecycleWorkspace: some View {
        presentedWorkspace
        .task {
            guard developmentForkFailure == nil, !model.isRecoveryReadOnly else { return }
            personalIntegrations.startMonitoring(model: model)
            automaticBackup.start(model: model)
            await _Concurrency.Task<Never, Never>.yield()
            NotificationCenter.default.post(name: .kanameDesktopReady, object: nil)
            updates.startAutomaticChecks()
        }
        .onChange(of: model.isRecoveryReadOnly) { isReadOnly in
            if isReadOnly {
                dismissNonRecoveryPresentations()
                return
            }
            guard developmentForkFailure == nil else { return }
            personalIntegrations.startMonitoring(model: model)
            automaticBackup.start(model: model)
            NotificationCenter.default.post(name: .kanameDesktopReady, object: nil)
            updates.startAutomaticChecks()
        }
        .onChange(of: destination) { _ in persistUIRestoreState() }
        .onChange(of: selectedThreadID) { _ in persistUIRestoreState() }
        .onChange(of: selectedProjectID) { _ in persistUIRestoreState() }
        .onChange(of: showsInspector) { _ in persistUIRestoreState() }
    }

    private var primaryCommandWorkspace: some View {
        lifecycleWorkspace
        .onReceive(NotificationCenter.default.publisher(for: .kanamePresentGlobalSearch)) { _ in
            presentGlobalSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameBeginConversation)) { _ in
            guard acceptsNonRecoveryCommands,
                  !showsSettings, newConversationRequest == nil, !showsNewProject else { return }
            if showsGlobalSearch { dismissGlobalSearch(restoringFocus: false) }
            beginConversation(projectID: inheritedProjectID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanamePresentSettings)) { _ in
            guard acceptsNonRecoveryCommands,
                  newConversationRequest == nil, !showsNewProject else { return }
            if showsGlobalSearch { dismissGlobalSearch(restoringFocus: false) }
            presentSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameImportFiles)) { notification in
            guard acceptsNonRecoveryCommands,
                  !showsSettings, !showsGlobalSearch,
                  newConversationRequest == nil, !showsNewProject else { return }
            captureImportFocus()
            if let urls = notification.object as? [URL] {
                if !portableTransfer.prepareImport(urls: urls, threadID: selectedThreadID) {
                    restoreImportFocus()
                }
            } else {
                if !portableTransfer.chooseImport(threadID: selectedThreadID) {
                    restoreImportFocus()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameExportCurrent)) { _ in
            guard acceptsNonRecoveryCommands,
                  !showsSettings, !showsGlobalSearch,
                  newConversationRequest == nil, !showsNewProject else { return }
            portableTransfer.export(
                thread: model.thread(id: selectedThreadID),
                project: model.project(id: selectedProjectID),
                model: model
            )
        }
    }

    var body: some View {
        primaryCommandWorkspace
        .overlay {
            modalPresentationLayer
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameNavigate)) { notification in
            guard acceptsNonRecoveryCommands,
                  let rawDestination = notification.object as? String,
                  let target = DesktopDestination(rawValue: rawDestination),
                  target != .settings,
                  newConversationRequest == nil,
                  !showsNewProject else { return }
            if showsGlobalSearch { dismissGlobalSearch(restoringFocus: false) }
            if showsSettings { dismissSettings(restoringFocus: false) }
            navigate(to: target)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameToggleInspector)) { _ in
            guard acceptsNonRecoveryCommands,
                  !showsSettings, !showsGlobalSearch,
                  newConversationRequest == nil, !showsNewProject else { return }
            toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameFocusComposer)) { _ in
            guard acceptsNonRecoveryCommands else { return }
            focusCurrentComposer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameGoBack)) { _ in
            _ = handleBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanamePresentDiagnostics)) { _ in
            presentDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameInterruptCurrent)) { _ in
            guard acceptsNonRecoveryCommands else { return }
            interruptCurrentConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanameRetryCurrent)) { _ in
            guard acceptsNonRecoveryCommands else { return }
            retryCurrentConversation()
        }
        .onAppear {
            DesktopBackCommandRouter.shared.install(handleBack)
        }
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updates.checkForUpdates(manual: false)
        }
#endif
        .onDisappear {
            DesktopBackCommandRouter.shared.removeHandler()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsSettings)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsGlobalSearch)
        .environment(
            \.sizeCategory,
            usesQALargeText ? .accessibilityExtraExtraExtraLarge : sizeCategory
        )
        .environment(\.desktopQALargeText, usesQALargeText)
    }

    private func persistUIRestoreState() {
        uiRestoreStore.save(DesktopUIRestoreState(
            destination: destination.rawValue,
            selectedThreadID: selectedThreadID,
            selectedProjectID: selectedProjectID,
            showsInspector: showsInspector
        ))
    }

    private var updateInstallConfirmationTitle: String {
        let version = updates.receipt.version ?? "the staged update"
        let build = updates.receipt.build.map { " (\($0))" } ?? ""
        return "Install Kaname \(version)\(build)?"
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
        GeometryReader { geometry in
            if showsInspector && geometry.size.width >= 980 {
                HSplitView {
                    centerColumn
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                    inspectorColumn
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 380)
                }
            } else {
                centerColumn
            }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if let notice = searchFallbackNotice, notice.destination == destination {
                searchFallbackBanner(notice)
                Divider()
            }
            content
        }
        .toolbar { toolbar }
    }

    private func searchFallbackBanner(_ notice: DesktopSearchFallbackNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Nord.frost1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Opened the closest local view for “\(notice.title)”")
                    .font(.subheadline.weight(.semibold))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Dismiss search navigation notice", systemImage: "xmark") {
                searchFallbackNotice = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Nord.polarNight1)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Text(workspaceTitle)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            ControlGroup {
                if destination == .threads {
                    Button {
                        showsThreadDirectory.toggle()
                    } label: {
                        Label(
                            showsThreadDirectory ? "Hide thread directory" : "Show thread directory",
                            systemImage: "sidebar.left"
                        )
                    }
                    .help(showsThreadDirectory ? "Hide thread directory" : "Show thread directory")
                }
                Button {
                    presentGlobalSearch()
                } label: {
                    Label("Open Command Center", systemImage: "command")
                }
                .help("Open Command Center (Command-K)")

                Button {
                    beginConversation(projectID: inheritedProjectID)
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .help("New conversation")

                Menu {
                    Button("New project") { presentNewProject() }
                    Button("Configure new conversation…") {
                        beginConfiguredConversation(projectID: inheritedProjectID)
                    }
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
            if let notice = updates.sidebarNotice,
               KanameUpdateNoticeProjection.isVisible(
                   notice,
                   dismissedIdentity: dismissedUpdateIdentity
               ) {
                DesktopUpdateNotificationPill(
                    notice: notice,
                    releaseNotes: updates.availableUpdate?.releaseNotes,
                    failureMessage: notice.phase == .retry ? updates.message : nil,
                    primaryAction: {
                        switch notice.phase {
                        case .available, .retry:
                            updates.verifyAndStageAvailable()
                        case .readyToInstall:
                            showsUpdateInstallConfirmation = true
                        case .preparing:
                            break
                        }
                    },
                    dismiss: notice.isDismissible ? {
                        dismissedUpdateIdentity = notice.identity
                    } : nil
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider()
            }
            Button("Settings", systemImage: DesktopDestination.settings.symbol, action: presentSettings)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
        .accessibilityAddTraits(destination == item ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch destination {
            case .home:
                DesktopHomeView(
                    model: model,
                    searchText: searchText,
                    openThread: { openThread($0) },
                    openDestination: navigate,
                    startConversation: { beginConversation(projectID: inheritedProjectID) }
                )
            case .threads:
                DesktopThreadsView(
                    model: model,
                    runtime: conversationRuntime,
                    capabilities: personalIntegrations.providerCapabilities,
                    searchText: searchText,
                    selectedThreadID: threadSelection,
                    selectedRunID: $selectedThreadRunID,
                    conversationAnchorID: $selectedConversationAnchorID,
                    composerFocusRequest: composerFocusRequest,
                    showsDirectory: $showsThreadDirectory
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
                        openThread: { openThread($0) }
                    )
                } else {
                    DesktopProjectsView(
                        model: model,
                        createProject: { presentNewProject() },
                        openProject: openProject,
                        startConversation: { beginConversation(projectID: $0) },
                        openThread: { openThread($0) }
                    )
                }
            case .research:
                DesktopResearchView(model: model, openThread: { openThread($0) })
            case .knowledge:
                DesktopKnowledgeView(
                    model: model,
                    searchRequest: searchNavigationRequest
                )
            case .email:
                DesktopEmailView(
                    model: model,
                    integrations: personalIntegrations,
                    allowsAutomaticInitialRead: searchNavigationRequest?.target.kind != .emailThread,
                    openAutomations: { navigate(to: .automations) }
                )
            case .calendar:
                DesktopCalendarView(model: model, integrations: personalIntegrations)
            case .automations:
                DesktopAutomationsView(
                    model: model,
                    scheduler: automationScheduler,
                    integrations: personalIntegrations
                )
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
                    openThread: { openThread($0) },
                    startConversation: { beginConversation(projectID: $0) }
                )
            case .localCore:
                LocalCoreWorkspace()
            case .settings:
                DesktopSettingsView(
                    model: model,
                    integrations: personalIntegrations,
                    updates: updates,
                    automaticBackup: automaticBackup
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var inspector: some View {
        if let project = model.project(id: selectedProjectID), destination == .projects {
            DesktopProjectInspector(model: model, project: project)
        } else if let thread = model.thread(id: selectedThreadID), [.home, .threads, .inbox].contains(destination) {
            DesktopThreadInspector(
                model: model,
                thread: thread,
                selectedRunID: $selectedThreadRunID,
                conversationAnchorID: $selectedConversationAnchorID
            )
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

    private func openThread(_ threadID: String, restoringComposerFocus: Bool = false) {
        guard acceptsNonRecoveryCommands else { return }
        if selectedThreadID != threadID {
            selectedThreadRunID = nil
            selectedConversationAnchorID = nil
        }
        visit(DesktopNavigationLocation(destination: .threads, selectedThreadID: threadID, selectedProjectID: nil))
        model.markRead(threadID: threadID)
        if restoringComposerFocus {
            requestComposerFocus(threadID: threadID)
        }
    }

    private func openProject(_ projectID: String) {
        guard acceptsNonRecoveryCommands else { return }
        visit(DesktopNavigationLocation(destination: .projects, selectedThreadID: nil, selectedProjectID: projectID))
    }

    private var inheritedProjectID: String? {
        guard destination.keepsThreadSelection else { return nil }
        return model.thread(id: selectedThreadID)?.projectID
    }

    private var acceptsNonRecoveryCommands: Bool {
        !model.isRecoveryReadOnly
            && !showsDiagnostics
            && portableTransfer.importReview == nil
    }

    private func beginConversation(projectID: String?) {
        guard acceptsNonRecoveryCommands else { return }
        let project = model.project(id: projectID)
        let kind = project?.context.defaultKind ?? .coding
        let provider = project?.context.defaultProvider ?? "Codex"
        let runtimeModel = ConversationRuntimeCatalog.selectedModel(
            provider: provider,
            requested: project?.context.defaultModel ?? "Use provider default",
            capabilities: personalIntegrations.providerCapabilities
        )
        let reasoning = ConversationRuntimeCatalog.selectedReasoning(
            provider: provider,
            model: runtimeModel,
            capabilities: personalIntegrations.providerCapabilities
        )
        let threadID = model.createOrReuseConversationDraft(
            kind: kind,
            projectID: projectID,
            provider: provider,
            model: runtimeModel,
            reasoningEffort: reasoning
        )
        openThread(threadID, restoringComposerFocus: true)
        announce("Draft ready in \(project?.name ?? "standalone context").")
    }

    private func beginConfiguredConversation(projectID: String?) {
        guard acceptsNonRecoveryCommands else { return }
        captureModalFocus()
        newConversationRequest = NewConversationRequest(projectID: projectID)
    }

    private func performCommandCenterAction(_ action: DesktopCommandCenterAction) {
        dismissGlobalSearch(restoringFocus: false)
        switch action {
        case let .newConversation(projectID, _):
            beginConversation(projectID: projectID)
        case let .configureConversation(projectID, _):
            beginConfiguredConversation(projectID: projectID)
        case .newProject:
            presentNewProject()
        case let .open(destination):
            navigateFromSearch(to: destination)
        }
    }

    private func presentNewProject() {
        guard acceptsNonRecoveryCommands else { return }
        captureModalFocus()
        showsNewProject = true
    }

    private func dismissNewProject(restoringFocus: Bool) {
        showsNewProject = false
        if restoringFocus { restoreModalFocus() }
    }

    private func finishProjectCreation(_ projectID: String) {
        showsNewProject = false
#if os(macOS)
        modalPreviousResponder = nil
#endif
        openProject(projectID)
    }

    private func presentSettings() {
        guard acceptsNonRecoveryCommands, !showsSettings else { return }
        captureModalFocus()
        showsSettings = true
    }

    private func dismissSettings(restoringFocus: Bool) {
        showsSettings = false
        if restoringFocus {
            restoreModalFocus()
        } else {
#if os(macOS)
            modalPreviousResponder = nil
#endif
        }
    }

    private func finishNewConversationPresentation() {
        if let threadID = pendingCreatedThreadID {
            pendingCreatedThreadID = nil
#if os(macOS)
            modalPreviousResponder = nil
#endif
            openThread(threadID, restoringComposerFocus: true)
            return
        }
        restoreModalFocus()
    }

    private func focusCurrentComposer() {
        guard acceptsNonRecoveryCommands else { return }
        guard destination == .threads,
              let threadID = selectedThreadID,
              model.thread(id: threadID) != nil else {
            announce("Open a conversation before focusing the message composer.")
            return
        }
        if showsGlobalSearch { dismissGlobalSearch(restoringFocus: false) }
        if showsSettings { dismissSettings(restoringFocus: false) }
        requestComposerFocus(threadID: threadID)
    }

    private func requestComposerFocus(threadID: String) {
        guard let request = DesktopComposerFocusRequest.next(
            after: composerFocusRequest,
            threadID: threadID
        ) else { return }
        composerFocusRequest = request
        announce("Message composer focused for \(model.thread(id: threadID)?.title ?? "conversation").")
    }

    private func announce(_ message: String) {
        workspaceAnnouncement = ""
        DispatchQueue.main.async {
            workspaceAnnouncement = message
            postDesktopAccessibilityAnnouncement(message)
        }
    }

    private func interruptCurrentConversation() {
        guard let threadID = selectedThreadID, conversationRuntime.isRunning(threadID: threadID) else {
            announce("There is no active conversation run to interrupt.")
            return
        }
        conversationRuntime.interrupt(threadID: threadID)
        announce("Interrupt requested for the current conversation.")
    }

    private func retryCurrentConversation() {
        guard let threadID = selectedThreadID,
              !conversationRuntime.isRunning(threadID: threadID),
              model.nextQueuedProviderRun(threadID: threadID) == nil,
              let run = model.providerRuns(threadID: threadID).last,
              run.state == .failed || run.state == .interrupted else {
            announce("There is no failed or interrupted turn to retry.")
            return
        }
        conversationRuntime.retry(runID: run.id)
        announce("Retry queued for the current conversation.")
    }

    private func presentGlobalSearch() {
        guard acceptsNonRecoveryCommands else { return }
        if showsGlobalSearch {
            dismissGlobalSearch(restoringFocus: true)
            return
        }
        guard newConversationRequest == nil, !showsNewProject else { return }
        if showsSettings { dismissSettings(restoringFocus: false) }
#if os(macOS)
        searchPreviousResponder = currentDesktopResponder()
#endif
        showsGlobalSearch = true
    }

    private func dismissGlobalSearch(restoringFocus: Bool) {
        showsGlobalSearch = false
#if os(macOS)
        let responder = searchPreviousResponder
        searchPreviousResponder = nil
        guard restoringFocus else { return }
        restoreDesktopResponder(responder)
#endif
    }

    private func openSearchResult(_ result: DesktopGlobalSearchResult) {
        dismissGlobalSearch(restoringFocus: false)
        searchFallbackNotice = nil
        switch DesktopGlobalSearchNavigationResolver.resolve(result.navigationTarget, in: model.snapshot) {
        case let .conversation(threadID), let .scopedConversation(threadID):
            searchNavigationRequest = nil
            openThread(threadID)
        case let .project(projectID):
            searchNavigationRequest = nil
            openProject(projectID)
        case let .knowledgeDocument(path):
            searchNavigationRequest = DesktopSearchNavigationRequest(
                target: .init(kind: .knowledgeDocument, itemID: path, scopeID: result.navigationTarget.scopeID),
                title: result.document.title
            )
            navigateFromSearch(to: .knowledge)
            announce("Opened \(result.document.title) in the local knowledge workspace.")
        case let .destinationFallback(target):
            presentSearchFallback(result: result, target: target)
        }
    }

    private func presentSearchFallback(
        result: DesktopGlobalSearchResult,
        target: DesktopGlobalSearchNavigationTarget
    ) {
        let fallback = searchFallbackDestination(for: target.kind)
        searchNavigationRequest = DesktopSearchNavigationRequest(target: target, title: result.document.title)
        searchFallbackNotice = DesktopSearchFallbackNotice(
            destination: fallback.destination,
            title: result.document.title,
            detail: fallback.detail
        )
        navigateFromSearch(to: fallback.destination)
        announce("Opened the closest local \(fallback.destination.title) view for \(result.document.title). \(fallback.detail)")
    }

    private func searchFallbackDestination(
        for kind: DesktopGlobalSearchNavigationTarget.Kind
    ) -> (destination: DesktopDestination, detail: String) {
        let localOnly = "This workspace has no exact selection contract for that saved item, so Kaname preserved the typed target without guessing or performing another read."
        switch kind {
        case .conversation: return (.threads, localOnly)
        case .project: return (.projects, localOnly)
        case .research: return (.research, localOnly)
        case .knowledgeDocument: return (.knowledge, localOnly)
        case .emailThread:
            return (.email, "Kaname did not contact Gmail. Use the explicit search or refresh control when you want to load the exact account-scoped thread.")
        case .calendarEvent: return (.calendar, localOnly)
        case .automation: return (.automations, localOnly)
        case .githubWork: return (.github, localOnly)
        case .skill: return (.skills, localOnly)
        case .approval: return (.inbox, localOnly)
        case .artifact: return (.home, localOnly)
        }
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
        guard acceptsNonRecoveryCommands else { return }
        searchNavigationRequest = nil
        searchFallbackNotice = nil
        visit(
            DesktopNavigationLocation(
                destination: target,
                selectedThreadID: target.keepsThreadSelection ? selectedThreadID : nil,
                selectedProjectID: nil
            )
        )
    }

    private func navigateFromSearch(to target: DesktopDestination) {
        guard acceptsNonRecoveryCommands else { return }
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
#if os(macOS)
            navigationPreviousResponders.append(currentDesktopResponder())
#endif
            if navigationHistory.count > 100 {
                let overflow = navigationHistory.count - 100
                navigationHistory.removeFirst(overflow)
#if os(macOS)
                navigationPreviousResponders.removeFirst(min(overflow, navigationPreviousResponders.count))
#endif
            }
        }
        apply(target)
    }

    private func apply(_ target: DesktopNavigationLocation) {
        let destinationChanged = target.destination != destination
        let entersThread = target.destination == .threads
            && target.selectedThreadID != nil
            && (destination != .threads || selectedThreadID == nil)
        let entersProject = target.destination == .projects
            && target.selectedProjectID != nil
            && (destination != .projects || selectedProjectID == nil)
        preservingWindowFrame {
            destination = target.destination
            selectedThreadID = target.selectedThreadID
            selectedProjectID = target.selectedProjectID
            if destinationChanged {
                showsInspector = target.destination == .threads && target.selectedThreadID != nil
                    || target.destination == .projects && target.selectedProjectID != nil
            } else if entersThread || entersProject {
                showsInspector = true
            }
        }
    }

    private func toggleInspector() {
        guard acceptsNonRecoveryCommands else { return }
#if os(macOS)
        let previousResponder = currentDesktopResponder()
#endif
        preservingWindowFrame {
            showsInspector.toggle()
        }
#if os(macOS)
        restoreDesktopResponder(previousResponder)
#endif
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
        if showsDiagnostics {
            showsDiagnostics = false
            return true
        }
        if portableTransfer.importReview != nil {
            portableTransfer.importReview = nil
            return true
        }
        if showsGlobalSearch {
            dismissGlobalSearch(restoringFocus: true)
            return true
        }
        if showsSettings {
            dismissSettings(restoringFocus: true)
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
        guard !model.isRecoveryReadOnly else { return false }
        searchNavigationRequest = nil
        searchFallbackNotice = nil
        return goBack()
    }

    @discardableResult
    private func goBack() -> Bool {
        while let target = navigationHistory.popLast() {
#if os(macOS)
            let previousResponder = navigationPreviousResponders.popLast() ?? nil
#endif
            guard target != currentLocation else { continue }
            apply(target)
            if let threadID = target.selectedThreadID {
                model.markRead(threadID: threadID)
            }
#if os(macOS)
            restoreDesktopResponder(previousResponder)
#endif
            return true
        }
        return false
    }

    private func captureModalFocus() {
#if os(macOS)
        if modalPreviousResponder == nil {
            modalPreviousResponder = currentDesktopResponder()
        }
#endif
    }

    private func restoreModalFocus() {
#if os(macOS)
        let responder = modalPreviousResponder
        modalPreviousResponder = nil
        restoreDesktopResponder(responder)
#endif
    }

    private func prepareImport(urls: [URL]) -> Bool {
        guard acceptsNonRecoveryCommands else { return false }
        captureImportFocus()
        let prepared = portableTransfer.prepareImport(urls: urls, threadID: selectedThreadID)
        if !prepared { restoreImportFocus() }
        return prepared
    }

    private func finishImportPresentation() {
        portableTransfer.importReview = nil
        restoreImportFocus()
    }

    private func presentDiagnostics() {
        guard !showsDiagnostics,
              portableTransfer.importReview == nil,
              newConversationRequest == nil,
              !showsNewProject,
              !showsGlobalSearch else { return }
#if os(macOS)
        diagnosticsPreviousResponder = currentDesktopResponder()
#endif
        showsDiagnostics = true
    }

    private func dismissNonRecoveryPresentations() {
        showsGlobalSearch = false
        showsSettings = false
        newConversationRequest = nil
        showsNewProject = false
        portableTransfer.importReview = nil
        searchNavigationRequest = nil
        searchFallbackNotice = nil
#if os(macOS)
        searchPreviousResponder = nil
        modalPreviousResponder = nil
        importPreviousResponder = nil
#endif
    }

    private func captureImportFocus() {
#if os(macOS)
        importPreviousResponder = currentDesktopResponder()
#endif
    }

    private func restoreImportFocus() {
#if os(macOS)
        let responder = importPreviousResponder
        importPreviousResponder = nil
        restoreDesktopResponder(responder)
#endif
    }

    private func restoreDiagnosticsFocus() {
#if os(macOS)
        let responder = diagnosticsPreviousResponder
        diagnosticsPreviousResponder = nil
        restoreDesktopResponder(responder)
#endif
    }
}

private struct DesktopModalBackdrop<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: Content

    init(dismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.dismiss = dismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            content.padding(24)
        }
    }
}

#if os(macOS)
@MainActor
private func currentDesktopResponder() -> NSResponder? {
    (NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow)?.firstResponder
}

@MainActor
private func restoreDesktopResponder(_ responder: NSResponder?) {
    DispatchQueue.main.async {
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        guard let responder, window?.makeFirstResponder(responder) == true else {
            window?.makeFirstResponder(nil)
            return
        }
    }
}

@MainActor
private func postDesktopAccessibilityAnnouncement(_ message: String) {
    guard !message.isEmpty,
          let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
    NSAccessibility.post(
        element: window,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
    )
}
#endif

private enum DesktopGlobalSearchScheduledSource: Sendable {
    case cached(DesktopGlobalSearchLocalCorpus)
    case snapshot(DesktopAppSnapshot)
}

private struct DesktopGlobalSearchScheduledRequest: Sendable {
    let generation: UInt64
    let query: DesktopGlobalSearchQuery
    let source: DesktopGlobalSearchScheduledSource
}

private struct DesktopGlobalSearchScheduledOutput: Sendable {
    let corpus: DesktopGlobalSearchLocalCorpus
    let sections: [DesktopGlobalSearchSection]
}

private struct DesktopGlobalSearchPalette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: DesktopAppSnapshot
    let currentProjectID: String?
    let dismiss: () -> Void
    let open: (DesktopGlobalSearchResult) -> Void
    let perform: (DesktopCommandCenterAction) -> Void
    @State private var query = ""
    @State private var selection = DesktopGlobalSearchSelectionState()
    @State private var sections: [DesktopGlobalSearchSection] = []
    @State private var cachedCorpus: DesktopGlobalSearchLocalCorpus?
    @State private var generationGate = DesktopGlobalSearchGenerationGate()
    @State private var scheduledRequest: DesktopGlobalSearchScheduledRequest?
    @State private var isSearching = false
    @State private var selectedCommandIndex = 0
    @FocusState private var queryFocused: Bool

    init(
        snapshot: DesktopAppSnapshot,
        currentProjectID: String?,
        initialQuery: String = "",
        dismiss: @escaping () -> Void,
        open: @escaping (DesktopGlobalSearchResult) -> Void,
        perform: @escaping (DesktopCommandCenterAction) -> Void
    ) {
        self.snapshot = snapshot
        self.currentProjectID = currentProjectID
        self.dismiss = dismiss
        self.open = open
        self.perform = perform
        _query = State(initialValue: initialQuery)
    }

    private var resultCount: Int {
        sections.reduce(0) { $0 + $1.results.count }
    }

    private var commandQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(">") else { return "" }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var showsCommands: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix(">")
    }

    private var commandActions: [DesktopCommandCenterAction] {
        let activeProjects = snapshot.projects
            .filter { $0.archivedAtUnixMillis == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let currentProject = activeProjects.first { $0.id == currentProjectID }
        var actions: [DesktopCommandCenterAction] = []
        if let currentProject {
            actions.append(.newConversation(projectID: currentProject.id, projectName: currentProject.name))
        }
        actions.append(.newConversation(projectID: nil, projectName: nil))
        if query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") {
            actions.append(contentsOf: activeProjects
                .filter { $0.id != currentProjectID }
                .map { .newConversation(projectID: $0.id, projectName: $0.name) })
        }
        actions.append(.configureConversation(projectID: currentProject?.id, projectName: currentProject?.name))
        actions.append(.newProject)
        actions.append(contentsOf: [
            .open(.inbox), .open(.projects), .open(.research), .open(.liveCodex),
            .open(.github), .open(.knowledge), .open(.calendar), .open(.automations),
            .open(.skills), .open(.devices),
        ])
        guard !commandQuery.isEmpty else { return Array(actions.prefix(8)) }
        return actions.filter {
            $0.title.lowercased().contains(commandQuery)
                || $0.detail.lowercased().contains(commandQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Nord.frost1)
                TextField("Search Kaname or type > for actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($queryFocused)
                    .onSubmit { openSelection() }
                    .accessibilityLabel("Search Kaname")
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating local search results")
                }
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Button("Close search", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Close search (Escape)")
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)

            Divider()

            Group {
                if showsCommands {
                    commandPrompt
                } else if sections.isEmpty && isSearching {
                    ProgressView("Searching the local snapshot…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sections.isEmpty {
                    EmptyPanel(
                        symbol: "magnifyingglass",
                        title: "No local results",
                        detail: "Try a title, project, account, status, or source name. Kaname will not contact a provider to broaden the search."
                    )
                    .padding(24)
                } else {
                    searchResults
                        .opacity(isSearching ? 0.62 : 1)
                        .allowsHitTesting(!isSearching)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 14) {
                Label("Local actions and snapshots", systemImage: "lock.shield")
                    .foregroundStyle(Nord.auroraGreen)
                Text("No providers, accounts, credentials, or vaults are contacted")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("↑↓ Select   ↩ Open   esc Close")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
        }
        .frame(maxWidth: 720, maxHeight: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Nord.polarNight3, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
        .onAppear {
            scheduleSearch()
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: query) { _ in
            selectedCommandIndex = 0
            scheduleSearch()
        }
        .onChange(of: snapshot.lastSavedAtUnixMillis) { _ in
            cachedCorpus = nil
            scheduleSearch()
        }
        .task(id: generationGate.latestGeneration) {
            await runScheduledSearch(scheduledRequest)
        }
        .onDisappear {
            generationGate.cancel()
            scheduledRequest = nil
            isSearching = false
        }
        .onMoveCommand { direction in
            guard !isSearching else { return }
            switch direction {
            case .up: moveSelection(.previous)
            case .down: moveSelection(.next)
            default: break
            }
        }
        .background {
#if os(macOS)
            DesktopPaletteKeyMonitor { direction in
                guard !isSearching else { return }
                moveSelection(direction)
            }
            .frame(width: 0, height: 0)
#endif
        }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search Kaname")
    }

    private func scheduleSearch() {
        let generation = generationGate.schedule()
        if showsCommands {
            sections = []
            selection.reconcile(with: [])
            scheduledRequest = nil
            isSearching = false
            return
        }
        let searchQuery = DesktopGlobalSearchQuery(query)
        guard !searchQuery.isEmpty else {
            sections = []
            selection.reconcile(with: [])
            scheduledRequest = nil
            isSearching = false
            return
        }
        isSearching = true
        scheduledRequest = DesktopGlobalSearchScheduledRequest(
            generation: generation,
            query: searchQuery,
            source: cachedCorpus.map(DesktopGlobalSearchScheduledSource.cached)
                ?? .snapshot(snapshot)
        )
    }

    private func runScheduledSearch(_ request: DesktopGlobalSearchScheduledRequest?) async {
        guard let request else { return }
        do {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !_Concurrency.Task<Never, Never>.isCancelled else { return }

        let worker = _Concurrency.Task<DesktopGlobalSearchScheduledOutput?, Never>.detached(priority: .userInitiated) {
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            let corpus: DesktopGlobalSearchLocalCorpus
            switch request.source {
            case let .cached(value):
                corpus = value
            case let .snapshot(value):
                corpus = DesktopGlobalSearchLocalIndex.corpus(from: value)
            }
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            let sections = DesktopGlobalSearch.search(query: request.query, in: corpus)
            guard !_Concurrency.Task<Never, Never>.isCancelled else { return nil }
            return DesktopGlobalSearchScheduledOutput(corpus: corpus, sections: sections)
        }
        let output = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !_Concurrency.Task<Never, Never>.isCancelled,
              let output,
              generationGate.accepts(request.generation),
              scheduledRequest?.generation == request.generation else { return }
        cachedCorpus = output.corpus
        sections = output.sections
        isSearching = false
        selection.reconcile(with: output.sections)
    }

    private var commandPrompt: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Suggested actions" : "Actions", systemImage: "command")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Type > to find every command")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)

                    if commandActions.isEmpty {
                        EmptyPanel(
                            symbol: "command",
                            title: "No matching actions",
                            detail: "Try a project, destination, or workflow name. Remove > to search saved content."
                        )
                        .frame(minHeight: 220)
                    } else {
                        ForEach(Array(commandActions.enumerated()), id: \.element.id) { index, action in
                            commandRow(action, isSelected: index == selectedCommandIndex)
                                .id(action.id)
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: selectedCommandIndex) { index in
                guard commandActions.indices.contains(index) else { return }
                if reduceMotion {
                    proxy.scrollTo(commandActions[index].id, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(commandActions[index].id, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("\(commandActions.count) Command Center actions")
    }

    private func commandRow(_ action: DesktopCommandCenterAction, isSelected: Bool) -> some View {
        Button { perform(action) } label: {
            CommandCenterSelectableLabel(
                symbol: action.symbol,
                title: action.title,
                detail: action.detail,
                provenance: nil,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var searchResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(section.title, systemImage: symbol(for: section.domain))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(section.results.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)

                            ForEach(section.results) { result in
                                resultRow(result)
                                    .id(result.selectionID)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: selection.selectedResultID) { selectedID in
                guard let selectedID else { return }
                if reduceMotion {
                    proxy.scrollTo(selectedID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("\(resultCount) search results")
        .onChange(of: resultCount) { count in
            postDesktopAccessibilityAnnouncement("\(count) local search results")
        }
    }

    private func resultRow(_ result: DesktopGlobalSearchResult) -> some View {
        let isSelected = selection.selectedResultID == result.selectionID
        return Button {
            open(result)
        } label: {
            CommandCenterSelectableLabel(
                symbol: symbol(for: result.domain),
                title: result.document.title,
                detail: result.document.summary,
                provenance: provenanceText(result.provenance),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .disabled(isSearching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.domain.label), \(result.document.title), \(provenanceText(result.provenance))")
        .accessibilityHint("Open this result")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openSelection() {
        guard !isSearching else { return }
        if showsCommands {
            guard commandActions.indices.contains(selectedCommandIndex) else { return }
            perform(commandActions[selectedCommandIndex])
            return
        }
        guard let result = selection.result(in: sections) ?? sections.first?.results.first else { return }
        open(result)
    }

    private func moveSelection(_ direction: DesktopGlobalSearchSelectionDirection) {
        guard showsCommands else {
            selection.move(direction, in: sections)
            return
        }
        guard !commandActions.isEmpty else {
            selectedCommandIndex = 0
            return
        }
        switch direction {
        case .previous:
            selectedCommandIndex = selectedCommandIndex == 0
                ? commandActions.count - 1
                : selectedCommandIndex - 1
        case .next:
            selectedCommandIndex = selectedCommandIndex + 1 == commandActions.count
                ? 0
                : selectedCommandIndex + 1
        }
    }

    private func provenanceText(_ provenance: DesktopGlobalSearchProvenance) -> String {
        [
            provenance.sourceLabel,
            provenance.projectLabel,
            provenance.accountLabel,
            provenance.scopeLabel,
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { labels, label in
            if !labels.contains(label) { labels.append(label) }
        }
        .joined(separator: " · ")
    }

    private func symbol(for domain: DesktopGlobalSearchDomain) -> String {
        switch domain {
        case .conversations: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .research: "text.magnifyingglass"
        case .knowledge: "diamond"
        case .email: "envelope"
        case .calendar: "calendar"
        case .automations: "clock.arrow.2.circlepath"
        case .github: "point.3.connected.trianglepath.dotted"
        case .skills: "hammer"
        case .approvals: "checkmark.shield"
        case .artifacts: "doc"
        }
    }
}

private struct CommandCenterSelectableLabel: View {
    let symbol: String
    let title: String
    let detail: String
    let provenance: String?
    let isSelected: Bool

    var body: some View {
        Label {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? Nord.polarNight0 : .primary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Nord.polarNight1 : .secondary)
                            .lineLimit(1)
                    }
                    if let provenance {
                        Text(provenance)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Nord.polarNight2 : Nord.frost1)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Nord.polarNight1)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(isSelected ? Nord.polarNight0 : Nord.frost1)
                .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(isSelected ? Nord.frost1 : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

#if os(macOS)
struct DesktopLocalKeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var handle: (NSEvent) -> Bool
        private var monitor: Any?

        init(handle: @escaping (NSEvent) -> Bool) {
            self.handle = handle
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

struct DesktopPaletteKeyMonitor: View {
    let move: (DesktopGlobalSearchSelectionDirection) -> Void

    var body: some View {
        DesktopLocalKeyMonitor { event in
            let commandModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard commandModifiers.isEmpty else { return false }
            switch event.keyCode {
            case 125:
                move(.next)
                return true
            case 126:
                move(.previous)
                return true
            default:
                return false
            }
        }
    }
}
#endif

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
    let startConversation: () -> Void

    private var attentionThreads: [DesktopThread] {
        model.threads(matching: searchText).filter {
            $0.attention == .needsResponse || $0.attention == .needsApproval || $0.attention == .failed
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProductStatusPill()
                        Text("Command centre")
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text("Your local work, attention, evidence, and device health in one place.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .layoutPriority(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button("New conversation", systemImage: "square.and.pencil", action: startConversation)
                            .buttonStyle(.borderedProminent)
                        DesktopAuthorityCard(remote: model.snapshot.remote)
                            .frame(width: 286)
                    }
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
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
    }
}

private struct DesktopThreadsView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var runtime: DesktopConversationRuntime
    let capabilities: [ProviderCapabilitySnapshot]
    let searchText: String
    @Binding var selectedThreadID: String?
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    let composerFocusRequest: DesktopComposerFocusRequest?
    @Binding var showsDirectory: Bool

    var body: some View {
        HSplitView {
            if showsDirectory {
                VStack(alignment: .leading, spacing: 0) {
                    SurfaceHeader(
                        title: "Threads",
                        detail: "Durable conversations and project continuity",
                        symbol: DesktopDestination.threads.symbol
                    )
                    List(selection: $selectedThreadID) {
                        let matching = model.threads(matching: searchText)
                        let active = matching.filter { $0.attention != .completed }
                        let completed = matching.filter { $0.attention == .completed }
                        Section("Active") {
                            ForEach(active) { thread in threadDirectoryRow(thread) }
                        }
                        if !completed.isEmpty {
                            Section("Completed") {
                                ForEach(completed) { thread in threadDirectoryRow(thread) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 310)
            }

            if let thread = model.thread(id: selectedThreadID) {
                DesktopThreadConversation(
                    model: model,
                    runtime: runtime,
                    capabilities: capabilities,
                    thread: thread,
                    selectedRunID: $selectedRunID,
                    conversationAnchorID: $conversationAnchorID,
                    composerFocusRequest: composerFocusRequest
                )
                    .id(thread.id)
                    .frame(minWidth: 340)
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
        .onChange(of: selectedThreadID) { _ in
            selectedRunID = nil
            conversationAnchorID = nil
        }
    }

    private func threadDirectoryRow(_ thread: DesktopThread) -> some View {
        ThreadDirectoryLabel(
            thread: thread,
            runs: model.providerRuns(threadID: thread.id)
        )
        .tag(thread.id as String?)
        .contextMenu {
            Button(thread.attention == .completed ? "Mark active" : "Mark complete") {
                model.setAttention(
                    threadID: thread.id,
                    attention: thread.attention == .completed ? .needsResponse : .completed
                )
            }
            Button("Archive") {
                model.setAttention(threadID: thread.id, attention: .archived)
            }
        }
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

private enum DesktopConversationRuntimeSheetFocus {
    case full
    case model
}

private struct DesktopThreadConversation: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var runtime: DesktopConversationRuntime
    let capabilities: [ProviderCapabilitySnapshot]
    let thread: DesktopThread
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    let composerFocusRequest: DesktopComposerFocusRequest?
    @State private var draft = ""
    @State private var composerSelection: TextSelection?
    @State private var composerCursorOffset: Int?
    @State private var composerHasSelection = false
    @State private var composerCommandSelection = DesktopComposerCommandSelectionState()
    @State private var composerCommandMenuDismissed = false
    @State private var composerCommandKeyboardScrollRevision: UInt = 0
    @State private var attachments: [ConversationImageAttachment] = []
    @State private var attachmentError: String?
    @State private var isImportingAttachments = false
    @State private var questionAnswer = ""
    @State private var panel: Panel = .conversation
    @State private var showsRename = false
    @State private var renamedTitle = ""
    @State private var showsRuntimeSettings = false
    @State private var runtimeSheetFocus = DesktopConversationRuntimeSheetFocus.full
    @State private var runtimeProvider = "Codex"
    @State private var runtimeModel = "Use provider default"
    @State private var runtimeReasoning = "xhigh"
    @State private var runtimeMode: ConversationRuntimeMode = .approvalRequired
    @State private var runtimeNetworkAccess = false
    @State private var narrativeRowLimit = DesktopConversationNarrativePresentation.defaultMaximumRows
    @State private var conversationSearch = ""
    @State private var followsLatest = true
    @State private var hasNewNarrativeContent = false
    @FocusState private var composerFocused: Bool
#if os(macOS)
    @State private var sheetPreviousResponder: NSResponder?
    @State private var pasteMonitor: Any?
#endif

    init(
        model: DesktopAppModel,
        runtime: DesktopConversationRuntime,
        capabilities: [ProviderCapabilitySnapshot],
        thread: DesktopThread,
        selectedRunID: Binding<String?>,
        conversationAnchorID: Binding<String?>,
        composerFocusRequest: DesktopComposerFocusRequest?
    ) {
        self.model = model
        self.runtime = runtime
        self.capabilities = capabilities
        self.thread = thread
        _selectedRunID = selectedRunID
        _conversationAnchorID = conversationAnchorID
        self.composerFocusRequest = composerFocusRequest
        _draft = State(initialValue: model.composerDraft(threadID: thread.id))
        _attachments = State(initialValue: model.composerAttachments(threadID: thread.id))
        let requestedPanel = CommandLine.arguments.firstIndex(of: "--desktop-thread-panel")
            .flatMap { index in
                CommandLine.arguments.indices.contains(index + 1)
                    ? Panel(rawValue: CommandLine.arguments[index + 1])
                    : nil
            }
            ?? .conversation
        _panel = State(initialValue: thread.kind == .coding || requestedPanel != .knowledge
            ? requestedPanel
            : .conversation)
    }

    private enum Panel: String, CaseIterable, Identifiable {
        case conversation
        case plan
        case changes
        case evidence
        case knowledge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .conversation: "Chat"
            case .plan: "Plan"
            case .changes: "Changes"
            case .evidence: "Evidence"
            case .knowledge: "Knowledge"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            threadHeader

            Divider()

            switch panel {
            case .conversation:
                conversation
            case .changes:
                DesktopThreadChangesView(model: model, thread: thread)
            case .plan:
                ThreadPlanView(
                    items: thread.plan,
                    phase: runtime.codingStage(threadID: thread.id).planPhase(hasSavedPlan: !thread.plan.isEmpty),
                    provider: thread.provider,
                    requestChanges: requestPlanChanges,
                    approvePlan: approvePlanAndImplement
                )
            case .evidence:
                ThreadEvidenceView(items: thread.evidence)
            case .knowledge:
                DesktopCodingKnowledgeLaneView(
                    model: model,
                    thread: thread
                )
                .id(thread.id)
            }
        }
        .sheet(isPresented: $showsRename, onDismiss: restoreSheetFocus) {
            DesktopRenameConversationSheet(
                title: $renamedTitle,
                cancel: { showsRename = false },
                save: {
                    if model.renameThread(id: thread.id, title: renamedTitle) { showsRename = false }
                }
            )
        }
        .sheet(isPresented: $showsRuntimeSettings, onDismiss: restoreSheetFocus) {
            DesktopConversationRuntimeSheet(
                provider: $runtimeProvider,
                model: $runtimeModel,
                reasoning: $runtimeReasoning,
                runtimeMode: $runtimeMode,
                networkAccess: $runtimeNetworkAccess,
                capabilities: capabilities,
                stagedCoding: thread.kind == .coding,
                initialFocus: runtimeSheetFocus,
                cancel: { showsRuntimeSettings = false },
                save: {
                    if model.updateThreadRuntime(
                        id: thread.id,
                        provider: runtimeProvider,
                        model: runtimeModel,
                        reasoningEffort: runtimeReasoning,
                        runtimeMode: runtimeMode,
                        networkAccess: runtimeNetworkAccess
                    ) { showsRuntimeSettings = false }
                }
            )
        }
        .onAppear {
            applyComposerFocusRequest()
            if thread.kind == .coding, runtime.codingStage(threadID: thread.id) == .knowledgeReview {
                panel = .knowledge
            }
#if os(macOS)
            installImagePasteMonitor()
#endif
        }
        .onDisappear {
#if os(macOS)
            removeImagePasteMonitor()
#endif
        }
        .onChange(of: composerFocusRequest) { _ in applyComposerFocusRequest() }
        .onChange(of: composerFocused) { isFocused in
            if isFocused {
                composerCommandMenuDismissed = false
                reconcileComposerCommandSelection()
            }
        }
        .onChange(of: thread.id) { _ in
            if thread.kind != .coding { panel = .conversation }
            narrativeRowLimit = DesktopConversationNarrativePresentation.defaultMaximumRows
            conversationSearch = ""
            selectedRunID = nil
            conversationAnchorID = nil
            followsLatest = true
            hasNewNarrativeContent = false
            draft = model.composerDraft(threadID: thread.id)
            composerSelection = nil
            composerCursorOffset = nil
            composerHasSelection = false
            composerCommandSelection = DesktopComposerCommandSelectionState()
            composerCommandMenuDismissed = false
            attachments = model.composerAttachments(threadID: thread.id)
            attachmentError = nil
        }
        .onChange(of: thread.plan.count) { count in
            if count > 0 { panel = .plan }
        }
        .onChange(of: thread.evidence.count) { count in
            if count > 0 { panel = .evidence }
        }
        .onChange(of: runtime.codingStage(threadID: thread.id)) { stage in
            if thread.kind == .coding, stage == .knowledgeReview {
                panel = .knowledge
            }
        }
    }

    private var threadHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.title).font(.title2.weight(.bold))
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
                    captureSheetFocus()
                    renamedTitle = thread.title
                    showsRename = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename conversation")
                AttentionPill(attention: thread.attention)
            }
            if thread.kind == .coding { codingWorkflowBanner }
            Picker("Thread panel", selection: $panel) {
                ForEach(availablePanels) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(22)
    }

    private var codingWorkflowBanner: some View {
        let stage = runtime.codingStage(threadID: thread.id)
        return DesktopCodingWorkflowBanner(
            stage: stage,
            provider: thread.provider,
            evidencePassed: !thread.evidence.isEmpty && thread.evidence.allSatisfy { $0.state == .passed },
            error: runtime.codingWorkflowErrors[thread.id],
            isCondensed: panel == .plan && stage == .planReview,
            showsPlanReviewAction: panel != .plan,
            approvePlan: approvePlanAndImplement,
            beginReview: {
                panel = .changes
                runtime.beginImplementationReview(threadID: thread.id)
            },
            recheckEvidence: {
                panel = .evidence
                runtime.recheckImplementation(threadID: thread.id)
            },
            accept: { runtime.reviewImplementation(threadID: thread.id, accepted: true) },
            reject: { runtime.reviewImplementation(threadID: thread.id, accepted: false) },
            reviewKnowledge: { panel = .knowledge }
        )
    }

    private func requestPlanChanges() {
        panel = .conversation
        DispatchQueue.main.async { composerFocused = true }
        postDesktopAccessibilityAnnouncement("Chat opened. Describe the changes you want in the plan.")
    }

    private func approvePlanAndImplement() {
        panel = .plan
        runtime.approvePlanAndImplement(threadID: thread.id)
    }

    private var narrativePage: DesktopConversationNarrativePage {
        DesktopConversationNarrativePresentation.page(
            messages: thread.messages,
            runs: model.providerRuns(threadID: thread.id),
            events: model.providerEvents(threadID: thread.id),
            maximumRows: narrativeRowLimit,
            searchText: conversationSearch
        )
    }

    private var narrative: [DesktopConversationNarrativeRow] { narrativePage.rows }

    private var narrativeActivityCount: Int {
        thread.messages.reduce(0) { $0 + $1.body.utf8.count + 1 }
            + model.providerRuns(threadID: thread.id).count
            + model.providerRuns(threadID: thread.id).lazy.filter { $0.completedAtUnixMillis != nil }.count
            + model.providerEvents(threadID: thread.id).lazy.filter(\.kind.isNarrativeCritical).count
    }

    private var latestRecoverableRun: DesktopProviderRunRecord? {
        guard let latest = model.providerRuns(threadID: thread.id).last,
              latest.purpose != .codingImplementation,
              latest.state == .failed || latest.state == .interrupted else { return nil }
        return latest
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find conversation or activity", text: $conversationSearch)
                    .textFieldStyle(.plain)
                if !conversationSearch.isEmpty {
                    Text("\(narrative.count) result\(narrative.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        conversationSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear conversation search")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Nord.polarNight1)

            Divider()

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if narrative.isEmpty {
                                EmptyPanel(
                                    symbol: conversationSearch.isEmpty ? "text.bubble" : "magnifyingglass",
                                    title: conversationSearch.isEmpty ? "Start the conversation" : "Nothing matches",
                                    detail: conversationSearch.isEmpty
                                        ? "Your first message is saved once, then sent through the project's provider and context boundary."
                                        : "Search includes messages and the full recorded activity behind every run."
                                )
                            } else {
                                if narrativePage.hiddenOlderRowCount > 0 {
                                    Button("Show \(min(120, narrativePage.hiddenOlderRowCount)) older conversation items") {
                                        narrativeRowLimit += 120
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHint("Loads earlier conversation rows without expanding raw provider activity")
                                }
                                ForEach(narrative) { item in
                                    switch item {
                                    case let .message(message):
                                        DesktopMessageBubble(message: message, threadID: thread.id)
                                            .id(item.id)
                                    case let .criticalEvent(event):
                                        DesktopProviderEventCard(
                                            event: event,
                                            questionAnswer: $questionAnswer,
                                            answer: { answerQuestion(event) }
                                        )
                                        .id(item.id)
                                    case let .runSummary(summary):
                                        DesktopConversationRunCapsule(
                                            summary: summary,
                                            inspect: {
                                                selectedRunID = summary.id
                                            }
                                        )
                                        .id(item.id)
                                    }
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("narrative-bottom")
                                .onAppear {
                                    followsLatest = true
                                    hasNewNarrativeContent = false
                                }
                                .onDisappear { followsLatest = false }
                        }
                        .padding(22)
                    }

                    if hasNewNarrativeContent {
                        Button {
                            proxy.scrollTo("narrative-bottom", anchor: .bottom)
                            followsLatest = true
                            hasNewNarrativeContent = false
                        } label: {
                            Label("New response", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(16)
                        .shadow(radius: 8)
                    }
                }
                .onChange(of: narrativeActivityCount) { _ in
                    if followsLatest {
                        proxy.scrollTo("narrative-bottom", anchor: .bottom)
                    } else {
                        hasNewNarrativeContent = true
                    }
                }
                .onChange(of: conversationSearch) { _ in
                    if followsLatest { proxy.scrollTo("narrative-bottom", anchor: .bottom) }
                }
                .onChange(of: conversationAnchorID) { anchorID in
                    guard let anchorID else { return }
                    panel = .conversation
                    proxy.scrollTo("message-\(anchorID)", anchor: .center)
                    followsLatest = false
                    hasNewNarrativeContent = false
                    conversationAnchorID = nil
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("narrative-bottom", anchor: .bottom)
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
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                DesktopComposerImageThumbnail(
                                    threadID: thread.id,
                                    attachment: attachment,
                                    remove: { removeAttachment(attachment) }
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                    }
                    .frame(height: 74)
                }

                if let attachmentError {
                    Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Nord.auroraRed)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let commandQuery = composerCommandQuery {
                    DesktopComposerCommandDrawer(
                        query: commandQuery.fragment,
                        commands: filteredComposerCommands,
                        selectedCommandID: selectedComposerCommand?.id,
                        keyboardScrollRevision: composerCommandKeyboardScrollRevision,
                        select: selectComposerCommand,
                        activate: activateComposerCommand
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }

                TextField(
                    "Message \(thread.provider)",
                    text: $draft,
                    selection: $composerSelection,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .lineLimit(DesktopComposerPresentation.minimumLines...DesktopComposerPresentation.maximumLines)
                    .padding(.horizontal, 12)
                    .padding(.top, 11)
                    .padding(.bottom, 8)
                    .focused($composerFocused)
                    .disabled(!canSendMessage)
                    .onSubmit(submitComposer)
                    .onChange(of: draft) { body in
                        composerCommandMenuDismissed = false
                        composerCursorOffset = min(composerCursorOffset ?? body.count, body.count)
                        model.updateComposerDraft(threadID: thread.id, body: body)
                    }
                    .onChange(of: composerSelection) { _ in
                        composerCommandMenuDismissed = false
                        updateComposerSelectionState()
                        reconcileComposerCommandSelection()
                    }
                    .accessibilityLabel("Message composer for \(thread.title)")

                GeometryReader { geometry in
                    composerAccessoryRow(compact: geometry.size.width < 360)
                }
                .frame(height: 25)
                .padding(.leading, 7)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Nord.polarNight3.opacity(0.55), lineWidth: 1)
            }
#if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                importImageURLs(urls)
            }
            .background {
                DesktopLocalKeyMonitor(handle: handleComposerCommandKey)
                    .frame(width: 0, height: 0)
            }
#endif
            .padding(14)
            .background(Nord.polarNight0)
            .onChange(of: runtime.isRunning(threadID: thread.id)) { isRunning in
                postDesktopAccessibilityAnnouncement(
                    isRunning ? "\(thread.provider) is responding" : "\(thread.provider) finished responding"
                )
            }
        }
    }

    private func applyComposerFocusRequest() {
        guard composerFocusRequest?.threadID == thread.id else { return }
        panel = .conversation
        DispatchQueue.main.async { composerFocused = true }
    }

    private func captureSheetFocus() {
#if os(macOS)
        sheetPreviousResponder = currentDesktopResponder()
#endif
    }

    private func restoreSheetFocus() {
#if os(macOS)
        let responder = sheetPreviousResponder
        sheetPreviousResponder = nil
        restoreDesktopResponder(responder)
#endif
    }

    private var runtimeSettingsLocked: Bool {
        runtime.isRunning(threadID: thread.id)
            || runtime.codingWorkflowBusyThreadIDs.contains(thread.id)
    }

    private var composerCommands: [DesktopComposerCommand] {
        DesktopComposerCommands.catalog { command in
            guard runtimeSettingsLocked, command == .model || command == .runtime else { return nil }
            return "Runtime settings are locked while work is active."
        }
    }

    private var composerCommandQuery: DesktopComposerCommandQuery? {
        guard composerFocused, !composerCommandMenuDismissed else { return nil }
        return DesktopComposerCommands.query(
            in: draft,
            cursorOffset: composerCursorOffset ?? draft.count,
            hasSelection: composerHasSelection
        )
    }

    private var filteredComposerCommands: [DesktopComposerCommand] {
        guard let composerCommandQuery else { return [] }
        return DesktopComposerCommands.matching(composerCommandQuery, in: composerCommands)
    }

    private var selectedComposerCommand: DesktopComposerCommand? {
        composerCommandSelection.command(in: filteredComposerCommands) ?? filteredComposerCommands.first
    }

    private func updateComposerSelectionState() {
        guard let composerSelection else {
            composerCursorOffset = draft.count
            composerHasSelection = false
            return
        }
        switch composerSelection.indices {
        case let .selection(range):
            composerCursorOffset = draft.distance(from: draft.startIndex, to: range.lowerBound)
            composerHasSelection = !range.isEmpty
        case .multiSelection:
            composerCursorOffset = nil
            composerHasSelection = true
        @unknown default:
            composerCursorOffset = nil
            composerHasSelection = true
        }
    }

    private func reconcileComposerCommandSelection() {
        composerCommandSelection.reconcile(with: filteredComposerCommands)
    }

    private func selectComposerCommand(_ commandID: DesktopComposerCommandID) {
        composerCommandSelection = DesktopComposerCommandSelectionState(selectedCommandID: commandID)
    }

#if os(macOS)
    private func handleComposerCommandKey(_ event: NSEvent) -> Bool {
        guard composerCommandQuery != nil else { return false }
        let commandModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard commandModifiers.isEmpty else { return false }
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText() {
            return false
        }

        switch event.keyCode {
        case 125:
            return moveComposerCommandSelection(.next)
        case 126:
            return moveComposerCommandSelection(.previous)
        case 48:
            return activateSelectedComposerCommand()
        case 53:
            composerCommandMenuDismissed = true
            composerCommandSelection = DesktopComposerCommandSelectionState()
            postDesktopAccessibilityAnnouncement("Command menu dismissed")
            return true
        default:
            return false
        }
    }
#endif

    private func moveComposerCommandSelection(
        _ direction: DesktopComposerCommandSelectionDirection
    ) -> Bool {
        guard !filteredComposerCommands.isEmpty else { return false }
        composerCommandSelection.reconcile(with: filteredComposerCommands)
        composerCommandSelection.move(direction, in: filteredComposerCommands)
        composerCommandKeyboardScrollRevision &+= 1
        announceSelectedComposerCommand()
        return true
    }

    private func announceSelectedComposerCommand() {
        guard let selectedComposerCommand else { return }
        let state = selectedComposerCommand.disabledReason.map { "Unavailable. \($0)" } ?? "Selected"
        postDesktopAccessibilityAnnouncement("\(selectedComposerCommand.invocation), \(state)")
    }

    private func submitComposer() {
        guard !activateSelectedComposerCommand() else { return }
        sendMessage()
    }

    @discardableResult
    private func activateSelectedComposerCommand() -> Bool {
        guard let composerCommandQuery else { return false }
        let resolution = DesktopComposerCommands.resolveSubmission(
            text: draft,
            query: composerCommandQuery,
            selectedCommandID: selectedComposerCommand?.id,
            commands: composerCommands
        )
        switch resolution {
        case let .local(command, edit):
            applyComposerCommandEdit(edit)
            performComposerCommand(command)
            return true
        case let .disabled(_, reason):
            postDesktopAccessibilityAnnouncement(reason)
            return true
        case .message:
            return false
        }
    }

    private func activateComposerCommand(_ commandID: DesktopComposerCommandID) {
        selectComposerCommand(commandID)
        guard let composerCommandQuery else { return }
        let resolution = DesktopComposerCommands.resolveSubmission(
            text: draft,
            query: composerCommandQuery,
            selectedCommandID: commandID,
            commands: composerCommands
        )
        switch resolution {
        case let .local(command, edit):
            applyComposerCommandEdit(edit)
            performComposerCommand(command)
        case let .disabled(_, reason):
            postDesktopAccessibilityAnnouncement(reason)
        case .message:
            break
        }
    }

    private func applyComposerCommandEdit(_ edit: DesktopComposerCommandEdit) {
        draft = edit.text
        let insertionOffset = min(edit.insertionOffset, draft.count)
        let insertionPoint = draft.index(draft.startIndex, offsetBy: insertionOffset)
        composerSelection = TextSelection(insertionPoint: insertionPoint)
        composerCursorOffset = insertionOffset
        composerHasSelection = false
        composerCommandSelection = DesktopComposerCommandSelectionState()
        model.updateComposerDraft(threadID: thread.id, body: draft)
    }

    private func performComposerCommand(_ command: DesktopComposerCommandID) {
        switch command {
        case .model:
            openRuntimeSettings(focus: .model)
        case .runtime:
            openRuntimeSettings(focus: .full)
        case .chat:
            panel = .conversation
            DispatchQueue.main.async { composerFocused = true }
        case .diff:
            panel = .changes
        case .plan:
            panel = .plan
        case .checks:
            panel = .evidence
        case .rename:
            captureSheetFocus()
            renamedTitle = thread.title
            showsRename = true
        }
        postDesktopAccessibilityAnnouncement("\(command.title) opened")
    }

    private func openRuntimeSettings(focus: DesktopConversationRuntimeSheetFocus = .full) {
        captureSheetFocus()
        runtimeSheetFocus = focus
        runtimeProvider = thread.provider
        runtimeModel = thread.model
        runtimeReasoning = thread.reasoningEffort
        runtimeMode = thread.runtimeMode
        runtimeNetworkAccess = thread.networkAccess
        showsRuntimeSettings = true
    }

    private func updateRuntime(
        provider: String,
        runtimeModel: String,
        reasoning: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) {
        _ = model.updateThreadRuntime(
            id: thread.id,
            provider: provider,
            model: runtimeModel,
            reasoningEffort: reasoning,
            runtimeMode: runtimeMode,
            networkAccess: networkAccess
        )
    }

    private func composerAccessoryRow(compact: Bool) -> some View {
        HStack(spacing: 4) {
#if os(macOS)
            Button(action: chooseImages) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(
                !imageAttachmentsSupported
                    || isImportingAttachments
                    || attachments.count >= ConversationImageAttachment.maximumCountPerMessage
            )
            .help(
                imageAttachmentsSupported
                    ? "Attach images, or paste with Command-V"
                    : "Choose Codex, Claude, or OpenCode to attach images"
            )
            .accessibilityLabel("Attach images")
#endif

            DesktopComposerRuntimeControls(
                thread: thread,
                capabilities: capabilities,
                isLocked: runtimeSettingsLocked,
                compact: compact,
                editDetails: { openRuntimeSettings() },
                update: updateRuntime
            )

            Spacer(minLength: 8)

            if isImportingAttachments {
                ProgressView()
                    .controlSize(.small)
                    .help("Preparing image attachments")
                    .accessibilityLabel("Preparing image attachments")
            }

            if runtime.isRunning(threadID: thread.id) {
                ProgressView()
                    .controlSize(.small)
                    .help("\(thread.provider) is responding. New messages queue in order.")
                    .accessibilityLabel("\(thread.provider) is responding; new messages queue in order")
            }

            Button(action: submitComposer) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        !hasSendableContent
                            ? Color.secondary
                            : Nord.frost1
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessage || !hasSendableContent || isImportingAttachments)
            .accessibilityLabel(composerSubmissionAccessibilityLabel)
        }
    }

    private var canSendMessage: Bool {
        guard thread.kind == .coding else { return true }
        return ![.planning, .preparing, .implementing, .implementationReview, .evidenceReview, .knowledgeReview].contains(
            runtime.codingStage(threadID: thread.id)
        )
    }

    private var availablePanels: [Panel] {
        thread.kind == .coding ? Array(Panel.allCases) : Panel.allCases.filter { $0 != .knowledge }
    }

    private var hasSendableContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var imageAttachmentsSupported: Bool {
        DesktopConversationRuntime.supportsImageAttachments(provider: thread.provider)
    }

    private var composerSubmissionAccessibilityLabel: String {
        if let selectedComposerCommand {
            return selectedComposerCommand.disabledReason == nil
                ? "Run \(selectedComposerCommand.invocation) command"
                : "\(selectedComposerCommand.invocation) command unavailable"
        }
        return runtime.isRunning(threadID: thread.id) ? "Queue follow-up" : "Send message"
    }

    private func sendMessage() {
        let body = draft
        if canSendMessage,
           hasSendableContent,
           runtime.send(threadID: thread.id, body: body, attachments: attachments) {
            draft = ""
            attachments = []
            attachmentError = nil
            model.clearComposerDraft(threadID: thread.id)
        }
    }

    private func answerQuestion(_ event: DesktopProviderEventRecord) {
        runtime.answerQuestion(
            threadID: thread.id,
            event: event,
            answer: questionAnswer
        )
        questionAnswer = ""
    }

    private var attachmentStore: KanameConversationAttachmentStore {
        KanameConversationAttachmentStore(
            rootDirectory: KanameDesktopEnvironment.current.applicationSupportRoot
                .appending(path: "ConversationService", directoryHint: .isDirectory)
        )
    }

    private func removeAttachment(_ attachment: ConversationImageAttachment) {
        try? attachmentStore.remove(threadID: thread.id, attachment: attachment)
        _ = model.removeComposerAttachment(threadID: thread.id, attachmentID: attachment.id)
        attachments = model.composerAttachments(threadID: thread.id)
        attachmentError = nil
    }

#if os(macOS)
    private func chooseImages() {
        guard imageAttachmentsSupported, !isImportingAttachments else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach images"
        panel.message = "Images are copied into Kaname's private conversation storage and sent only with this message."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        _ = importImageURLs(panel.urls)
    }

    @discardableResult
    private func importImageURLs(_ urls: [URL]) -> Bool {
        guard imageAttachmentsSupported, !isImportingAttachments else { return false }
        let remaining = ConversationImageAttachment.maximumCountPerMessage - attachments.count
        let candidates = Array(urls.filter(Self.isImageURL).prefix(max(0, remaining)))
        guard !candidates.isEmpty else {
            attachmentError = remaining == 0 ? "A message can contain up to eight images." : "Choose a readable image file."
            return false
        }
        beginImageImport(candidates.map { ($0, nil, $0.lastPathComponent) })
        return true
    }

    private func importClipboardImage(_ data: Data, filename: String) {
        beginImageImport([(nil, data, filename)])
    }

    private func beginImageImport(_ inputs: [(URL?, Data?, String)]) {
        guard !inputs.isEmpty else { return }
        isImportingAttachments = true
        attachmentError = nil
        let store = attachmentStore
        let threadID = thread.id
        _Concurrency.Task {
            let results = await _Concurrency.Task.detached(priority: .userInitiated) {
                inputs.map { url, suppliedData, filename -> (ConversationImageAttachment?, String?) in
                    let accessed = url?.startAccessingSecurityScopedResource() ?? false
                    defer { if accessed { url?.stopAccessingSecurityScopedResource() } }
                    do {
                        let data: Data
                        if let suppliedData {
                            data = suppliedData
                        } else if let url {
                            data = try Data(contentsOf: url, options: .mappedIfSafe)
                        } else {
                            throw KanameConversationAttachmentError.invalidImage
                        }
                        return (try store.importImage(data: data, suggestedFilename: filename, threadID: threadID), nil)
                    } catch {
                        return (nil, error.localizedDescription)
                    }
                }
            }.value
            for result in results {
                if let attachment = result.0 {
                    if !model.addComposerAttachment(threadID: threadID, attachment: attachment) {
                        try? store.remove(threadID: threadID, attachment: attachment)
                        attachmentError = "Kaname could not save that attachment in the draft."
                    }
                } else if let error = result.1 {
                    attachmentError = error
                }
            }
            attachments = model.composerAttachments(threadID: threadID)
            isImportingAttachments = false
        }
    }

    private func installImagePasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard composerFocused,
                  modifiers.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return handleImagePasteboard() ? nil : event
        }
    }

    private func removeImagePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    private func handleImagePasteboard() -> Bool {
        guard imageAttachmentsSupported, !isImportingAttachments else { return false }
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(Self.isImageURL)
        if !urls.isEmpty { return importImageURLs(urls) }
        guard let image = NSImage(pasteboard: pasteboard), let data = image.tiffRepresentation else { return false }
        importClipboardImage(data, filename: "Pasted image.png")
        return true
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
#endif

}

private struct DesktopComposerCommandDrawer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let query: String
    let commands: [DesktopComposerCommand]
    let selectedCommandID: DesktopComposerCommandID?
    let keyboardScrollRevision: UInt
    let select: (DesktopComposerCommandID) -> Void
    let activate: (DesktopComposerCommandID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Commands", systemImage: "command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.frost1)
                Spacer()
                Text("\(commands.count) match\(commands.count == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)

            if commands.isEmpty {
                Text("No local command matches /\(query). Press Return to send this as ordinary chat text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(commands) { command in
                                commandRow(command)
                                    .id(command.id)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 5)
                    }
                    .onChange(of: keyboardScrollRevision) { _, _ in
                        guard let selectedCommandID,
                              commands.contains(where: { $0.id == selectedCommandID }) else { return }
                        if reduceMotion {
                            proxy.scrollTo(selectedCommandID, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(selectedCommandID, anchor: .center)
                            }
                        }
                    }
                }
                .frame(maxHeight: 238)
            }
        }
        .background(Nord.polarNight2.opacity(0.98), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Nord.polarNight3, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer commands")
        .accessibilityValue("\(commands.count) available")
    }

    private func commandRow(_ command: DesktopComposerCommand) -> some View {
        let isSelected = command.id == selectedCommandID
        return Button {
            activate(command.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: command.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(command.isEnabled ? Nord.frost1 : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(Text(command.invocation).font(.system(.callout, design: .monospaced).weight(.semibold))) "
                            + "\(Text(command.title).font(.callout.weight(.medium)))"
                    )
                    Text(command.disabledReason ?? command.detail)
                        .font(.caption)
                        .foregroundStyle(command.isEnabled ? Color.secondary : Nord.auroraYellow)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Nord.polarNight1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                isSelected ? Nord.frost1.opacity(command.isEnabled ? 1 : 0.62) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(isSelected ? Nord.polarNight0 : Color.primary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            if hovering { select(command.id) }
        }
        .accessibilityLabel("\(command.invocation), \(command.title)")
        .accessibilityValue(
            "\(isSelected ? "Selected. " : "")\(command.disabledReason ?? command.detail)"
        )
        .accessibilityHint(command.isEnabled ? "Press Return or Tab to run locally" : "Unavailable")
    }
}

private struct DesktopThreadChangesView: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @StateObject private var changes = DesktopThreadChangesViewModel()

    private var worktree: DesktopWorktreeRecord? {
        model.snapshot.operations.worktrees
            .filter { $0.threadID == thread.id && $0.state != .removed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    var body: some View {
        Group {
            if let worktree {
                changesWorkspace(worktree)
                    .onAppear { changes.load(worktree: worktree) }
                    .onChange(of: worktree.updatedAtUnixMillis) { _ in
                        changes.load(worktree: worktree, force: true)
                    }
            } else {
                EmptyPanel(
                    symbol: "doc.text.magnifyingglass",
                    title: "No code changes for this thread",
                    detail: "When an approved coding run creates an isolated worktree, its files and per-file patches appear here instead of filling the conversation."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Nord.polarNight0)
    }

    private func changesWorkspace(_ worktree: DesktopWorktreeRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("\(changes.snapshot?.changedFiles.count ?? worktree.changedFileCount) changed", systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                Text(worktree.branch)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(worktree.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(worktree.state == .failed ? Nord.auroraRed : Nord.frost1)
                Button {
                    changes.load(worktree: worktree, force: true)
                } label: {
                    Label("Refresh diff", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(changes.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Nord.polarNight1)

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter files", text: $changes.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(11)
                    Divider()

                    if changes.filteredPaths.isEmpty {
                        Text(changes.isLoading ? "Reading worktree…" : "Working tree is clean")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(changes.filteredPaths, id: \.self) { path in
                            Button {
                                changes.select(path: path, worktree: worktree)
                            } label: {
                                Label(path, systemImage: "doc.text")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Nord.frost1)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                changes.selectedPath == path
                                    ? Nord.frost1.opacity(0.12)
                                    : Color.clear
                            )
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

                diffPane
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(changes.selectedPath ?? "Select a file")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if changes.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Nord.polarNight1)

            Divider()

            if let message = changes.message {
                EmptyPanel(symbol: "exclamationmark.triangle", title: "Diff unavailable", detail: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changes.patch.isEmpty {
                Text(changes.isLoading ? "Loading patch…" : "No textual patch for this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(changes.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            DesktopUnifiedDiffLine(text: String(line))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesktopUnifiedDiffLine: View {
    let text: String

    private var tint: Color {
        if text.hasPrefix("+") && !text.hasPrefix("+++") { return Nord.auroraGreen }
        if text.hasPrefix("-") && !text.hasPrefix("---") { return Nord.auroraRed }
        if text.hasPrefix("@@") { return Nord.frost1 }
        return .clear
    }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(text.hasPrefix("@@") ? Nord.frost1 : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.13))
    }
}

private struct DesktopCodingWorkflowBanner: View {
    let stage: DesktopCodingWorkflowStage
    let provider: String
    let evidencePassed: Bool
    let error: String?
    let isCondensed: Bool
    let showsPlanReviewAction: Bool
    let approvePlan: () -> Void
    let beginReview: () -> Void
    let recheckEvidence: () -> Void
    let accept: () -> Void
    let reject: () -> Void
    let reviewKnowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isCondensed {
                Label("\(progressLabel) · \(title)", systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .help(Self.workflowPath)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(Self.workflowPath).lineLimit(1)
                    Text(progressLabel).lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .help(Self.workflowPath)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        statusContent
                        actions
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        statusContent
                        HStack(spacing: 7) { actions }
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Nord.auroraRed)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private static let workflowPath = "Discuss → Plan → Approve → Implement → Review changes → Review evidence (Accept) → Update knowledge"

    private var progressLabel: String {
        switch stage {
        case .discuss: "Stage 1 of 7 · Discuss"
        case .planning: "Stage 2 of 7 · Plan"
        case .planReview: "Stage 3 of 7 · Approve"
        case .preparing, .implementing: "Stage 4 of 7 · Implement"
        case .implementationReview: "Stage 5 of 7 · Review changes"
        case .evidenceReview: "Stage 6 of 7 · Review evidence"
        case .knowledgeReview: "Stage 7 of 7 · Knowledge update"
        case .completed: "Complete · Knowledge reconciled or waived"
        case .rejected: "Stopped · Rejected"
        case .failed: "Stopped safely · no accepted result"
        }
    }

    @ViewBuilder private var actions: some View {
        switch stage {
        case .planReview:
            if showsPlanReviewAction {
                Button("Approve plan & implement", action: approvePlan)
                    .buttonStyle(.borderedProminent)
                    .disabled(provider.caseInsensitiveCompare("Codex") != .orderedSame)
                    .help(provider.caseInsensitiveCompare("Codex") == .orderedSame
                        ? "Create an isolated worktree and authorize one network-denied implementation turn"
                        : "Choose Codex to use Kaname's signed isolated implementation flow")
            }
        case .implementationReview:
            Button("Review changes & run checks", systemImage: "checkmark.shield", action: beginReview)
                .buttonStyle(.borderedProminent)
        case .evidenceReview:
            Button("Re-run checks", systemImage: "arrow.clockwise", action: recheckEvidence).buttonStyle(.bordered)
            Button("Reject", role: .destructive, action: reject).buttonStyle(.bordered)
            Button("Accept", action: accept)
                .buttonStyle(.borderedProminent)
                .disabled(!evidencePassed)
                .help(evidencePassed ? "Record local acceptance" : "All independent evidence must pass before acceptance")
        case .knowledgeReview:
            Button("Review knowledge", systemImage: "books.vertical", action: reviewKnowledge)
                .buttonStyle(.borderedProminent)
        case .completed, .discuss, .planning, .preparing, .implementing, .rejected, .failed:
            EmptyView()
        }
    }

    private var title: String {
        switch stage {
        case .discuss: "Discuss the task"
        case .planning: "Planning read-only"
        case .planReview: "Plan needs your approval"
        case .preparing: "Preparing the next guarded stage"
        case .implementing: "Implementing in an isolated worktree"
        case .implementationReview: "Review changes before checks"
        case .evidenceReview: "Evidence needs your review"
        case .knowledgeReview: "Accepted · knowledge update pending"
        case .completed: "Completed"
        case .rejected: "Rejected; isolated changes retained"
        case .failed: "Stopped safely"
        }
    }

    private var detail: String {
        switch stage {
        case .discuss: "Your next message starts a read-only planning turn. It cannot write code."
        case .planning: "No write authority or network access is available. The structured plan will appear in the Plan tab."
        case .planReview: "Review or revise the plan. Implementation cannot start until you press the approval button."
        case .preparing: "Kaname is creating or checking the isolated worktree and signed evidence boundary."
        case .implementing: "One approved, network-denied turn may write only inside the linked worktree."
        case .implementationReview: "Review the isolated changes and run independent checks before evidence acceptance."
        case .evidenceReview: "Provider completion is not acceptance. Inspect the diff and verification evidence, then accept or reject."
        case .knowledgeReview: "The code is accepted locally. Review the proposed knowledge edit or provide a reason for no durable update."
        case .completed: "The knowledge update was reconciled or explicitly waived. Nothing was pushed, published, or merged."
        case .rejected: "The changes remain isolated and recoverable. Send revision guidance to request a fresh plan."
        case .failed: "No result was accepted. Inspect the error, then send a revised request or retry the planning turn."
        }
    }

    private var symbol: String {
        switch stage {
        case .failed, .rejected: "exclamationmark.shield.fill"
        case .planning, .preparing, .implementing: "hourglass"
        case .planReview, .implementationReview, .evidenceReview, .knowledgeReview: "person.crop.circle.badge.questionmark"
        case .completed: "checkmark.seal.fill"
        case .discuss: "text.bubble"
        }
    }

    private var tint: Color {
        switch stage {
        case .failed, .rejected: Nord.auroraRed
        case .planReview, .evidenceReview: Nord.auroraYellow
        case .implementationReview, .knowledgeReview: Nord.auroraYellow
        case .planning, .preparing, .implementing: Nord.frost1
        case .completed: Nord.auroraGreen
        case .discuss: Nord.frost0
        }
    }
}

private struct DesktopConversationRunCapsule: View {
    let summary: DesktopConversationRunSummary
    let inspect: () -> Void

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 11) {
            GridRow {
                Image(systemName: summary.run.state.accessibilitySymbol)
                    .foregroundStyle(summary.run.state.tint)
                    .frame(width: 24)
                DesktopConversationRunCapsuleDetails(summary: summary, inspect: inspect)
            }
        }
        .padding(12)
        .background(summary.run.state.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(summary.run.state.tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(summary.run.provider) run \(summary.run.state.label). \(summary.conciseActivityLabel)")
    }
}

private struct DesktopConversationRunCapsuleDetails: View {
    let summary: DesktopConversationRunSummary
    let inspect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            capsuleHeader
            capsuleSummary
            capsuleLatestActivity
            capsuleActionLayout
        }
    }

    private var runLabel: String {
        let state = summary.run.state == .running
            ? "Working"
            : "Run \(summary.run.state.label.lowercased())"
        return "\(state) · \(summary.run.provider)"
    }

    private var capsuleHeader: some View {
        LabeledContent(runLabel) {
            RelativeTime(unixMillis: summary.presentationTimeUnixMillis)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold))
    }

    private var capsuleSummary: some View {
        Text(summary.conciseActivityLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder private var capsuleLatestActivity: some View {
        if let latest = summary.latestActivity,
           !latest.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(latest.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var capsuleActionLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { capsuleActions }
            VStack(alignment: .leading, spacing: 6) { capsuleActions }
        }
    }

    @ViewBuilder private var capsuleActions: some View {
        Button("Open activity", systemImage: "list.bullet.rectangle", action: inspect)
            .buttonStyle(.bordered)
            .controlSize(.small)
        if summary.payloadWasTruncated {
            Label("Evidence payload capped", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(Nord.auroraYellow)
        }
    }
}

private struct DesktopProviderEventGroupCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: DesktopProviderEventGroup
    @Binding var isExpanded: Bool
    @Binding var questionAnswer: String
    let answer: (DesktopProviderEventRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpansion) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: group.kind.timelineSymbol)
                        .foregroundStyle(group.kind.timelineTint)
                        .frame(width: 25)
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent {
                            RelativeTime(unixMillis: group.latestCreatedAtUnixMillis)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } label: {
                            Text(group.summaryTitle)
                                .font(.caption.weight(.semibold))
                        }
                        if !group.latestSummary.isEmpty {
                            Text(group.latestSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if group.containsTruncatedPayload {
                            Label("Some raw payloads exceeded the evidence limit", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(Nord.auroraYellow)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
                        .frame(width: 14, height: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(group.accessibilityLabel(isExpanded: isExpanded))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse event group" : "Expand event group")
            .accessibilityIdentifier("provider-event-group-\(group.id)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.events) { event in
                        DesktopProviderEventCard(
                            event: event,
                            questionAnswer: $questionAnswer,
                            answer: { answer(event) }
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(12)
        .background(group.kind.timelineTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct DesktopProviderEventCard: View {
    let event: DesktopProviderEventRecord
    @Binding var questionAnswer: String
    let answer: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack {
                Image(systemName: event.kind.timelineSymbol)
                    .foregroundStyle(event.kind.timelineTint)
                Spacer(minLength: 0)
            }
            .frame(width: 25)
            .accessibilityHidden(true)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(event.kind.timelineTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title). \(event.detail)")
    }
}

private extension DesktopProviderEventKind {
    var timelineSymbol: String {
        switch self {
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

    var timelineTint: Color {
        switch self {
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
        .desktopAdaptiveSheet(idealWidth: 440)
    }
}

private struct DesktopConversationRuntimeSheet: View {
    @Binding var provider: String
    @Binding var model: String
    @Binding var reasoning: String
    @Binding var runtimeMode: ConversationRuntimeMode
    @Binding var networkAccess: Bool
    let capabilities: [ProviderCapabilitySnapshot]
    let stagedCoding: Bool
    let initialFocus: DesktopConversationRuntimeSheetFocus
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runtimeHeading
            runtimeForm
            runtimeActions
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 520)
    }

    private var runtimeHeading: some View {
        Group {
            Label("Conversation runtime", systemImage: "slider.horizontal.3")
                .font(.title2.weight(.bold))
            Text(stagedCoding
                ? "Provider, model, and thinking apply to future turns. Coding authority is staged separately: read-only plan first, then one explicitly approved isolated implementation."
                : "These settings apply to future turns in this conversation. Change them whenever no turn is running.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeForm: some View {
        Form {
            ConversationRuntimeEditor(
                provider: $provider,
                model: $model,
                reasoning: $reasoning,
                runtimeMode: $runtimeMode,
                networkAccess: $networkAccess,
                capabilities: capabilities,
                stagedCoding: stagedCoding,
                initialFocus: initialFocus
            )
        }
        .formStyle(.grouped)
    }

    private var runtimeActions: some View {
        HStack {
            Label(
                stagedCoding
                    ? "Plan first · read-only · network disabled · explicit isolated implementation approval"
                    : ConversationRuntimeCatalog.boundarySummary(
                        provider: provider,
                        runtimeMode: runtimeMode,
                        networkAccess: networkAccess
                    ),
                systemImage: stagedCoding ? "checkmark.shield.fill" : (runtimeMode == .fullAccess ? "exclamationmark.shield" : "lock.shield")
            )
                .font(.caption)
                .foregroundStyle(!stagedCoding && runtimeMode == .fullAccess ? Nord.auroraYellow : .secondary)
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private enum ConversationRuntimeCatalog {
    static let providers = ["Codex", "Claude", "OpenCode"]

    static func snapshot(
        for provider: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> ProviderCapabilitySnapshot? {
        let driver: ProviderDriverKind? = switch provider.lowercased() {
        case "codex": .codex
        case "claude": .claudeAgent
        case "opencode", "open code": .openCode
        default: nil
        }
        return capabilities.first { $0.instance.driver == driver }
    }

    static func models(
        for provider: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> [ProviderModel] {
        snapshot(for: provider, capabilities: capabilities)?.models ?? []
    }

    static func selectedModel(
        provider: String,
        requested: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> String {
        guard requested == "Use provider default" else { return requested }
        let models = models(for: provider, capabilities: capabilities)
        return models.first(where: \.isDefault)?.id ?? models.first?.id ?? requested
    }

    static func reasoningEfforts(
        provider: String,
        model: String,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> [String] {
        if let advertised = models(for: provider, capabilities: capabilities)
            .first(where: { $0.id == model })?.supportedReasoningEfforts,
           !advertised.isEmpty {
            return advertised
        }
        switch provider.lowercased() {
        case "codex": return ["minimal", "low", "medium", "high", "xhigh"]
        case "claude": return ["low", "medium", "high", "xhigh", "max"]
        default: return ["minimal", "low", "medium", "high", "max"]
        }
    }

    static func selectedReasoning(
        provider: String,
        model: String,
        current: String? = nil,
        capabilities: [ProviderCapabilitySnapshot]
    ) -> String {
        if let advertised = models(for: provider, capabilities: capabilities).first(where: { $0.id == model }),
           let effort = advertised.defaultReasoningEffort {
            return effort
        }
        let choices = reasoningEfforts(provider: provider, model: model, capabilities: capabilities)
        if let current, choices.contains(current) { return current }
        return choices.contains("medium") ? "medium" : choices.first ?? "medium"
    }

    static func managesNetwork(_ provider: String) -> Bool {
        provider.caseInsensitiveCompare("Codex") == .orderedSame
    }

    static func boundarySummary(
        provider: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> String {
        if runtimeMode == .fullAccess {
            return "Full local access, no approval prompts, network on"
        }
        let network = managesNetwork(provider)
            ? (networkAccess ? "network on" : "network off")
            : "network follows \(provider)"
        return "\(runtimeMode.label), \(network)"
    }
}

private extension ConversationRuntimeMode {
    var label: String {
        switch self {
        case .approvalRequired: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .approvalRequired: "Read-only by default; stop for broader actions."
        case .autoAcceptEdits: "Allow workspace edits; ask before other escalation."
        case .auto: "Allow routine work and review risky escalation automatically."
        case .fullAccess: "Allow commands, files, and network without prompts."
        }
    }
}

private struct DesktopComposerRuntimeControls: View {
    let thread: DesktopThread
    let capabilities: [ProviderCapabilitySnapshot]
    let isLocked: Bool
    let compact: Bool
    let editDetails: () -> Void
    let update: (String, String, String, ConversationRuntimeMode, Bool) -> Void

    private var advertisedModels: [ProviderModel] {
        ConversationRuntimeCatalog.models(for: thread.provider, capabilities: capabilities)
    }

    private var modelTitle: String {
        if thread.model == "Use provider default" { return "Provider default" }
        return advertisedModels.first(where: { $0.id == thread.model })?.displayName ?? thread.model
    }

    private var thinkingTitle: String {
        thread.reasoningEffort == "xhigh" ? "Extra high" : thread.reasoningEffort.capitalized
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { thread.provider },
            set: { provider in
                let selectedModel = ConversationRuntimeCatalog.selectedModel(
                    provider: provider,
                    requested: "Use provider default",
                    capabilities: capabilities
                )
                let reasoning = ConversationRuntimeCatalog.selectedReasoning(
                    provider: provider,
                    model: selectedModel,
                    capabilities: capabilities
                )
                update(
                    provider,
                    selectedModel,
                    reasoning,
                    thread.runtimeMode,
                    ConversationRuntimeCatalog.managesNetwork(provider) ? thread.networkAccess : false
                )
            }
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { thread.model },
            set: { selectedModel in
                update(
                    thread.provider,
                    selectedModel,
                    ConversationRuntimeCatalog.selectedReasoning(
                        provider: thread.provider,
                        model: selectedModel,
                        current: thread.reasoningEffort,
                        capabilities: capabilities
                    ),
                    thread.runtimeMode,
                    thread.networkAccess
                )
            }
        )
    }

    private var reasoningSelection: Binding<String> {
        Binding(
            get: { thread.reasoningEffort },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    $0,
                    thread.runtimeMode,
                    thread.networkAccess
                )
            }
        )
    }

    private var authoritySelection: Binding<ConversationRuntimeMode> {
        Binding(
            get: { thread.runtimeMode },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    thread.reasoningEffort,
                    $0,
                    $0 == .fullAccess ? true : thread.networkAccess
                )
            }
        )
    }

    private var networkSelection: Binding<Bool> {
        Binding(
            get: { thread.runtimeMode == .fullAccess ? true : thread.networkAccess },
            set: {
                update(
                    thread.provider,
                    thread.model,
                    thread.reasoningEffort,
                    thread.runtimeMode,
                    $0
                )
            }
        )
    }

    var body: some View {
        controlRow(compact: compact)
            .controlSize(.small)
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: 3) {
            providerAndModelMenu(compact: compact)
            thinkingMenu(compact: compact)
            authorityMenu(compact: compact)
        }
    }

    private func providerAndModelMenu(compact: Bool) -> some View {
        runtimeMenu(
            title: "\(thread.provider) · \(modelTitle)",
            systemImage: "cpu",
            compact: compact,
            maximumWidth: 220,
            accessibilityLabel: "Provider and model, \(thread.provider), \(modelTitle)",
            unlockedHelp: "Choose provider and model"
        ) {
            Section("Provider") {
                Picker("Provider", selection: providerSelection) {
                    ForEach(ConversationRuntimeCatalog.providers, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }
            }
            Section("Model") {
                Picker("Model", selection: modelSelection) {
                    Text("Use provider default").tag("Use provider default")
                    ForEach(advertisedModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    if thread.model != "Use provider default",
                       !advertisedModels.contains(where: { $0.id == thread.model }) {
                        Text("\(thread.model) (custom)").tag(thread.model)
                    }
                }
            }
            Button("Custom model or provider…", systemImage: "slider.horizontal.3", action: editDetails)
        }
    }

    private func thinkingMenu(compact: Bool) -> some View {
        runtimeMenu(
            title: thinkingTitle,
            systemImage: "brain.head.profile",
            compact: compact,
            accessibilityLabel: "Thinking, \(thinkingTitle)",
            unlockedHelp: "Choose thinking level"
        ) {
            Picker("Thinking", selection: reasoningSelection) {
                ForEach(
                    ConversationRuntimeCatalog.reasoningEfforts(
                        provider: thread.provider,
                        model: thread.model,
                        capabilities: capabilities
                    ),
                    id: \.self
                ) { effort in
                    Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                }
                let choices = ConversationRuntimeCatalog.reasoningEfforts(
                    provider: thread.provider,
                    model: thread.model,
                    capabilities: capabilities
                )
                if !choices.contains(thread.reasoningEffort) {
                    Text("\(thinkingTitle) (custom)").tag(thread.reasoningEffort)
                }
            }
            Divider()
            Button("Custom thinking or variant…", systemImage: "slider.horizontal.3", action: editDetails)
        }
    }

    private func runtimeMenu<Content: View>(
        title: String,
        systemImage: String,
        compact: Bool,
        maximumWidth: CGFloat? = nil,
        accessibilityLabel: String,
        unlockedHelp: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            ComposerRuntimeControlLabel(
                title: title,
                systemImage: systemImage,
                compact: compact
            )
            .frame(maxWidth: compact ? nil : maximumWidth, alignment: .leading)
        }
        .disabled(isLocked)
        .accessibilityLabel(accessibilityLabel)
        .help(isLocked ? "Runtime controls unlock when the current turn finishes." : unlockedHelp)
    }

    private func authorityMenu(compact: Bool) -> some View {
        Group {
            if thread.kind == .coding {
                Menu {
                    Text("Coding always starts with a read-only, network-disabled plan.")
                    Text("Your explicit plan approval grants one network-disabled turn inside a new isolated worktree.")
                    Divider()
                    Button("Runtime details…", systemImage: "info.circle", action: editDetails)
                } label: {
                    ComposerRuntimeControlLabel(
                        title: "Plan first",
                        systemImage: "checkmark.shield.fill",
                        compact: compact
                    )
                }
                .accessibilityLabel("Access, plan first with explicit isolated implementation approval")
                .help("Read-only plan first; isolated implementation only after explicit approval")
            } else {
                Menu {
                    Picker("Access", selection: authoritySelection) {
                        ForEach(ConversationRuntimeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Divider()
                    if ConversationRuntimeCatalog.managesNetwork(thread.provider) {
                        Toggle("Network access", isOn: networkSelection)
                            .disabled(thread.runtimeMode == .fullAccess)
                        if thread.runtimeMode == .fullAccess {
                            Text("Network is required by Full access")
                        }
                    } else {
                        Text("Network controlled by \(thread.provider)")
                    }
                    Divider()
                    Button("Runtime details…", systemImage: "info.circle", action: editDetails)
                } label: {
                    ComposerRuntimeControlLabel(
                        title: thread.runtimeMode.label,
                        systemImage: thread.runtimeMode == .fullAccess
                            ? "exclamationmark.shield.fill"
                            : "checkmark.shield",
                        compact: compact
                    )
                    .foregroundStyle(thread.runtimeMode == .fullAccess ? Nord.auroraYellow : .secondary)
                }
                .accessibilityLabel(
                    "Access, \(ConversationRuntimeCatalog.boundarySummary(provider: thread.provider, runtimeMode: thread.runtimeMode, networkAccess: thread.networkAccess))"
                )
                .help(ConversationRuntimeCatalog.boundarySummary(
                    provider: thread.provider,
                    runtimeMode: thread.runtimeMode,
                    networkAccess: thread.networkAccess
                ))
            }
        }
        .disabled(isLocked)
    }
}

private struct ComposerRuntimeControlLabel: View {
    let title: String
    let systemImage: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            if !compact {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 7 : 8)
        .frame(height: 25)
        .background(Nord.polarNight2.opacity(0.72), in: Capsule())
        .contentShape(Capsule())
    }
}

private struct ConversationRuntimeEditor: View {
    private static let customChoice = "__kaname_custom_choice__"
    private enum Field: Hashable { case model }

    @Binding var provider: String
    @Binding var model: String
    @Binding var reasoning: String
    @Binding var runtimeMode: ConversationRuntimeMode
    @Binding var networkAccess: Bool
    let capabilities: [ProviderCapabilitySnapshot]
    let stagedCoding: Bool
    let initialFocus: DesktopConversationRuntimeSheetFocus
    @FocusState private var focusedField: Field?

    private var advertisedModels: [ProviderModel] {
        ConversationRuntimeCatalog.models(for: provider, capabilities: capabilities)
    }

    private var reasoningChoices: [String] {
        ConversationRuntimeCatalog.reasoningEfforts(
            provider: provider,
            model: model,
            capabilities: capabilities
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                model == "Use provider default" || advertisedModels.contains(where: { $0.id == model })
                    ? model
                    : Self.customChoice
            },
            set: { model = $0 == Self.customChoice ? "" : $0 }
        )
    }

    private var reasoningSelection: Binding<String> {
        Binding(
            get: { reasoningChoices.contains(reasoning) ? reasoning : Self.customChoice },
            set: { reasoning = $0 == Self.customChoice ? "" : $0 }
        )
    }

    private var usesCustomModel: Bool {
        model != "Use provider default" && !advertisedModels.contains(where: { $0.id == model })
    }

    private var usesCustomReasoning: Bool {
        !reasoningChoices.contains(reasoning)
    }

    var body: some View {
        Section("Provider & model") {
            Picker("Provider", selection: $provider) {
                ForEach(ConversationRuntimeCatalog.providers, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            if let snapshot = ConversationRuntimeCatalog.snapshot(for: provider, capabilities: capabilities) {
                LabeledContent("Status", value: snapshot.state == .ready ? "Ready" : snapshot.state.rawValue.capitalized)
            }
            Picker("Model", selection: modelSelection) {
                Text("Use provider default").tag("Use provider default")
                ForEach(advertisedModels, id: \.id) { option in
                    Text(option.displayName).tag(option.id)
                }
                Text("Custom…").tag(Self.customChoice)
            }
            .focused($focusedField, equals: .model)
            if usesCustomModel {
                TextField("Custom model ID", text: $model)
            }
            Picker("Thinking", selection: reasoningSelection) {
                ForEach(reasoningChoices, id: \.self) { effort in
                    Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                }
                Text("Custom…").tag(Self.customChoice)
            }
            if usesCustomReasoning {
                TextField("Custom thinking / variant ID", text: $reasoning)
            }
            Text("Lists come from the provider when available. Choose Custom to enter another model or thinking identifier supported by that provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Authority") {
            if stagedCoding {
                LabeledContent("Planning", value: "Read-only · network disabled")
                LabeledContent("Implementation", value: "Explicit approval · isolated worktree · network disabled")
                Text("Coding authority is not a free-running runtime preference. Kaname stops after the plan and again after evidence collection so you can make each decision deliberately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Permission mode", selection: $runtimeMode) {
                    ForEach(ConversationRuntimeMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(runtimeMode.detail)
                    .font(.caption)
                    .foregroundStyle(runtimeMode == .fullAccess ? Nord.auroraYellow : .secondary)
                if ConversationRuntimeCatalog.managesNetwork(provider) {
                    Toggle("Allow network access", isOn: $networkAccess)
                        .disabled(runtimeMode == .fullAccess)
                    if runtimeMode == .fullAccess {
                        Text("Codex full access is unsandboxed, so network access is necessarily on.")
                            .font(.caption)
                            .foregroundStyle(Nord.auroraYellow)
                    }
                } else {
                    LabeledContent("Network", value: "Provider controlled")
                    Text("\(provider) does not expose a separate enforceable network switch through Kaname's current adapter. Its native permission mode remains authoritative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: provider) { newProvider in
            model = ConversationRuntimeCatalog.selectedModel(
                provider: newProvider,
                requested: "Use provider default",
                capabilities: capabilities
            )
            reasoning = ConversationRuntimeCatalog.selectedReasoning(
                provider: newProvider,
                model: model,
                capabilities: capabilities
            )
            if !ConversationRuntimeCatalog.managesNetwork(newProvider) { networkAccess = false }
        }
        .onChange(of: model) { newModel in
            reasoning = ConversationRuntimeCatalog.selectedReasoning(
                provider: provider,
                model: newModel,
                current: reasoning,
                capabilities: capabilities
            )
        }
        .onChange(of: runtimeMode) { newMode in
            if newMode == .fullAccess { networkAccess = true }
        }
        .onAppear {
            guard initialFocus == .model else { return }
            DispatchQueue.main.async { focusedField = .model }
        }
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
            .desktopAdaptiveSheet(idealWidth: 720, idealHeight: 720)
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

private struct DesktopUpdateNotificationPill: View {
    let notice: KanameUpdateNotice
    let releaseNotes: String?
    let failureMessage: String?
    let primaryAction: () -> Void
    let dismiss: (() -> Void)?

    private var title: String {
        switch notice.phase {
        case .available: "Update available"
        case .retry: "Retry update"
        case .preparing: "Preparing update…"
        case .readyToInstall: "Restart to update"
        }
    }

    private var symbol: String {
        switch notice.phase {
        case .available, .retry: "arrow.down.circle.fill"
        case .preparing: "arrow.triangle.2.circlepath"
        case .readyToInstall: "arrow.clockwise.circle.fill"
        }
    }

    private var helpText: String {
        var parts = ["Kaname \(notice.version) (\(notice.build))."]
        if let failureMessage, !failureMessage.isEmpty {
            parts.append(failureMessage)
        } else if let releaseNotes, !releaseNotes.isEmpty {
            parts.append(String(releaseNotes.prefix(600)))
        }
        return parts.joined(separator: " ")
    }

    private var accessibilityAction: String {
        switch notice.phase {
        case .available: "Download update."
        case .retry: "Retry preparing update."
        case .preparing: "Verification and private staging are in progress."
        case .readyToInstall: "Install and relaunch."
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: primaryAction) {
                HStack(spacing: 9) {
                    if notice.phase == .preparing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: symbol)
                            .frame(width: 16)
                    }
                    (
                        Text(title).font(.caption.weight(.semibold))
                            + Text("\nKaname \(notice.version) (\(notice.build))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                    )
                    .lineLimit(2)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(notice.phase == .preparing)
            .help(helpText)
            .accessibilityLabel("Kaname \(notice.version) build \(notice.build). \(accessibilityAction)")

            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Dismiss until next launch")
                .accessibilityLabel("Dismiss update until next launch")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(Nord.snowStorm0)
        .background(Nord.frost1.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Nord.frost1.opacity(0.38), lineWidth: 1)
        }
    }
}

@MainActor
private final class DesktopUpdateViewModel: ObservableObject {
    let environment: KanameDesktopEnvironment
    @Published private(set) var receipt: KanameUpdateReceipt
    @Published private(set) var discoveryStatus: KanameUpdateDiscoveryStatus = .notChecked
    @Published private(set) var availableUpdate: KanameAvailableUpdate?
    @Published private(set) var discoveryPreferences = KanameUpdateDiscoveryPreferences()
    @Published private(set) var isBusy = false
    @Published private(set) var isChecking = false
    @Published private(set) var canRollback = false
    @Published private(set) var message: String?

    private let coordinator: KanameUpdateCoordinator
    private let catalog: KanameLocalDogfoodUpdateCatalog
    private let preferenceStore: KanameUpdateDiscoveryPreferencesStore
    private var helperProcess: Process?
    private var automaticCheckTask: _Concurrency.Task<Void, Never>?
    private var hasLoadedDiscoveryPreferences = false
    private var workspaceIsReady = false
    private static let deferIntervalMillis: Int64 = 24 * 60 * 60 * 1_000

    init(environment: KanameDesktopEnvironment = .current) {
        self.environment = environment
        coordinator = KanameUpdateCoordinator(environment: environment)
        catalog = KanameLocalDogfoodUpdateCatalog(environment: environment)
        preferenceStore = KanameUpdateDiscoveryPreferencesStore(environment: environment)
        receipt = KanameUpdateReceipt(
            status: .idle,
            detail: environment.channel == .stable
                ? "No update is staged."
                : "This candidate has its own state and cannot replace stable Kaname.",
            updatedAtUnixMillis: 0
        )
        _Concurrency.Task { await refresh() }
    }

    deinit {
        automaticCheckTask?.cancel()
    }

    var currentVersionLabel: String {
        let versionValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        let buildValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        let version = (versionValue as? String) ?? "Unknown"
        let build = (buildValue as? String) ?? "—"
        return "\(version) (\(build))"
    }

    var sidebarNotice: KanameUpdateNotice? {
        KanameUpdateNoticeProjection.notice(
            channel: environment.channel,
            discoveryStatus: discoveryStatus,
            availableUpdate: availableUpdate,
            receipt: receipt
        )
    }

    func startAutomaticChecks() {
        workspaceIsReady = true
        beginAutomaticChecksIfReady()
    }

    func checkForUpdates(manual: Bool) {
        checkForUpdates(manual: manual, ignoresAutomaticInterval: false)
    }

    private func checkForUpdates(manual: Bool, ignoresAutomaticInterval: Bool) {
        guard environment.channel == .stable, !isChecking, !isBusy else { return }
        guard receipt.status != .staged, receipt.status != .switching else { return }
        guard manual || hasLoadedDiscoveryPreferences else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        if !manual {
            guard discoveryPreferences.automaticChecksEnabled else { return }
            if !ignoresAutomaticInterval,
               !KanameUpdateAutomaticCheckPolicy.permitsCheck(
                   lastAttemptAtUnixMillis: discoveryPreferences.lastAttemptAtUnixMillis,
                   nowUnixMillis: now
               ) {
                return
            }
        }
        isChecking = true
        discoveryStatus = .checking
        message = manual ? "Checking the private local dogfood catalog…" : nil
        _Concurrency.Task {
            var preferences = await preferenceStore.load()
            preferences.lastAttemptAtUnixMillis = now
            preferences.lastSourceIdentifier = KanameLocalDogfoodUpdateCatalog.sourceIdentifier
            do {
                let update = try await catalog.latestUpdate()
                preferences.lastSuccessAtUnixMillis = now
                availableUpdate = update
                if let update, preferences.skippedIdentity == update.identity {
                    discoveryStatus = .skipped
                    message = "Build \(update.build) is skipped on this Mac."
                } else if let update,
                          !manual,
                          preferences.deferredIdentity == update.identity,
                          (preferences.deferredUntilUnixMillis ?? 0) > now {
                    discoveryStatus = .deferred
                    message = "Build \(update.build) is deferred for 24 hours."
                } else if let update {
                    discoveryStatus = .available
                    message = "Kaname \(update.version) (\(update.build)) is available from \(update.sourceLabel)."
                } else {
                    discoveryStatus = .upToDate
                    message = manual ? "This Kaname build is up to date." : nil
                }
                try await preferenceStore.save(preferences)
            } catch {
                discoveryStatus = .failed
                message = error.localizedDescription
                try? await preferenceStore.save(preferences)
            }
            discoveryPreferences = preferences
            isChecking = false
        }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        var preferences = discoveryPreferences
        preferences.automaticChecksEnabled = enabled
        discoveryPreferences = preferences
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
        if enabled {
            checkForUpdates(manual: false, ignoresAutomaticInterval: true)
        }
    }

    func deferAvailableUpdate() {
        guard let update = availableUpdate else { return }
        var preferences = discoveryPreferences
        preferences.deferredIdentity = update.identity
        preferences.deferredUntilUnixMillis = Int64(Date().timeIntervalSince1970 * 1_000) + Self.deferIntervalMillis
        discoveryPreferences = preferences
        discoveryStatus = .deferred
        message = "Build \(update.build) is deferred for 24 hours."
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func reviewAvailableUpdate() {
        var preferences = discoveryPreferences
        preferences.deferredIdentity = nil
        preferences.deferredUntilUnixMillis = nil
        applyAvailableState(preferences)
    }

    func skipAvailableUpdate() {
        guard let update = availableUpdate else { return }
        var preferences = discoveryPreferences
        preferences.skippedIdentity = update.identity
        preferences.deferredIdentity = nil
        preferences.deferredUntilUnixMillis = nil
        discoveryPreferences = preferences
        discoveryStatus = .skipped
        message = "Build \(update.build) is skipped on this Mac."
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func unskipAvailableUpdate() {
        var preferences = discoveryPreferences
        preferences.skippedIdentity = nil
        applyAvailableState(preferences)
    }

    private func applyAvailableState(_ preferences: KanameUpdateDiscoveryPreferences) {
        discoveryPreferences = preferences
        discoveryStatus = availableUpdate == nil ? .upToDate : .available
        message = availableUpdate.map { "Kaname \($0.version) (\($0.build)) is available from \($0.sourceLabel)." }
        _Concurrency.Task { try? await preferenceStore.save(preferences) }
    }

    func verifyAndStageAvailable() {
        guard let update = availableUpdate, !isBusy else { return }
        isBusy = true
        discoveryStatus = .verifying
        message = "Rechecking the digest and same-signer trust before staging…"
        _Concurrency.Task {
            do {
                let artifactURL = try await catalog.verifiedArtifactURL(for: update)
                receipt = try await coordinator.stage(bundleURL: artifactURL)
                discoveryStatus = .staged
                message = "Update downloaded and verified. Your current Kaname remains active until you choose Install and relaunch."
            } catch {
                discoveryStatus = .failed
                message = error.localizedDescription
            }
            isBusy = false
            await refreshRollbackAvailability()
        }
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

    func rollback(model: DesktopAppModel) {
#if os(macOS)
        guard !isBusy else { return }
        let hasActiveApproval = model.snapshot.operations.approvals.contains { $0.state == .awaitingApproval }
        isBusy = true
        _Concurrency.Task {
            do {
                let request = try await coordinator.rollbackRequest(
                    installedBundleURL: Bundle.main.bundleURL,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    composerCheckpointed: model.persistenceError == nil,
                    hasActiveApproval: hasActiveApproval
                )
                try launchHelper(request)
                message = "Restoring the previous Kaname UI…"
                NSApplication.shared.terminate(nil)
            } catch {
                message = error.localizedDescription
                isBusy = false
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
        discoveryPreferences = await preferenceStore.load()
        hasLoadedDiscoveryPreferences = true
        await refreshRollbackAvailability()
        beginAutomaticChecksIfReady()
    }

    private func beginAutomaticChecksIfReady() {
        guard environment.channel == .stable,
              workspaceIsReady,
              hasLoadedDiscoveryPreferences,
              automaticCheckTask == nil else { return }
        automaticCheckTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(
                for: .seconds(KanameUpdateAutomaticCheckPolicy.startupDelaySeconds)
            )
            guard !_Concurrency.Task.isCancelled else { return }
            self?.checkForUpdates(manual: false, ignoresAutomaticInterval: true)
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(
                    for: .seconds(KanameUpdateAutomaticCheckPolicy.intervalSeconds)
                )
                guard !_Concurrency.Task.isCancelled else { return }
                self?.checkForUpdates(manual: false, ignoresAutomaticInterval: false)
            }
        }
    }

    private func refreshRollbackAvailability() async {
        let backupURL = await coordinator.backupBundleURL
        canRollback = FileManager.default.fileExists(atPath: backupURL.path)
    }
}

@MainActor
final class DesktopPersonalIntegrationViewModel: ObservableObject {
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
    @Published private(set) var googleAccountLoadFailure: String?
    @Published private(set) var message: String?

    private let integrations = PersonalIntegrationService()
    private let googleIntegration: NativeGoogleIntegrationService
    private let appleCalendar = AppleCalendarIntegrationService()
    private let providerCache: ProviderCapabilityCacheStore
    private let workflowMailMonitor: DesktopMailViewModel

    init(environment: KanameDesktopEnvironment = .current) {
        googleIntegration = NativeGoogleIntegrationService(
            rootDirectory: environment.googleDirectory,
            keychainService: environment.googleKeychainService,
            accessMode: environment.googleIntegrationAccessMode
        )
        providerCache = ProviderCapabilityCacheStore(directory: environment.connectivityDirectory)
        workflowMailMonitor = DesktopMailViewModel(environment: environment)
        appleAccessState = appleCalendar.accessState
        do {
            googleAccounts = try NativeGoogleIntegrationService.savedAccounts(
                rootDirectory: environment.googleDirectory
            )
            googleAccountLoadFailure = nil
        } catch {
            googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
        }
        _Concurrency.Task {
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            if let cached = try? await providerCache.load() {
                providerCapabilities = cached.capabilities
                lastProviderRefreshAt = cached.checkedAt
            }
        }
    }

    private var monitoringTask: _Concurrency.Task<Void, Never>?

    func startMonitoring(model: DesktopAppModel) {
        guard monitoringTask == nil else { return }
        workflowMailMonitor.startWorkflowMonitoring(model: model)
        monitoringTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            hasGoogleClientConfiguration = await googleIntegration.hasClientConfiguration
            await reloadSavedGoogleAccounts(announce: false)
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

    func retrySavedGoogleAccounts(model: DesktopAppModel) {
        _Concurrency.Task {
            await reloadSavedGoogleAccounts(announce: true)
            guard !googleAccounts.isEmpty else { return }
            refreshGoogle(model: model)
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
                googleAccountLoadFailure = nil
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
                        accessLevel: discovered.first(where: { $0.identity == calendar.accountIdentity })?.supportsCalendarEventWrites == true
                            ? calendar.role
                            : "\(calendar.role) · reconnect for event changes",
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
                googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
                if announce { message = googleAccountLoadFailure }
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
                googleAccountLoadFailure = nil
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

    private func reloadSavedGoogleAccounts(announce: Bool) async {
        do {
            googleAccounts = try await googleIntegration.accounts()
            googleAccountLoadFailure = nil
        } catch {
            googleAccountLoadFailure = Self.savedGoogleAccountLoadFailure(error)
            if announce { message = googleAccountLoadFailure }
        }
    }

    private static func savedGoogleAccountLoadFailure(_ error: Error) -> String {
        "Kaname could not load its saved Google account index. The saved connections were not removed. Retry loading them before reconnecting any account. (\(error.localizedDescription))"
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

private struct DesktopCodingKnowledgeLaneView: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    @StateObject private var knowledge = DesktopKnowledgeViewModel()
    @State private var targetScopeID: String?
    @State private var targetPath = ""
    @State private var waiverReason = ""

    private var lane: DesktopCodingKnowledgeLane? {
        model.codingKnowledgeLane(threadID: thread.id)
    }

    private var writableScopes: [DesktopVaultScopeRecord] {
        model.snapshot.operations.vaultScopes.filter { $0.canWrite }
    }

    private var selectedScope: DesktopVaultScopeRecord? {
        writableScopes.first { $0.id == targetScopeID }
    }

    private var activeWrite: DesktopKnowledgeWriteRecord? {
        (knowledge.activeWriteID ?? lane?.writeID).flatMap { id in
            model.snapshot.operations.knowledgeWrites.first { $0.id == id }
        }
    }

    private var knowledgeReadyForDisposition: Bool {
        guard lane?.disposition != .reconciled, lane?.disposition != .waived else { return false }
        let workflowReady = model.codingWorkflow(threadID: thread.id)?.state == .updatingKnowledge
        let acceptedWorktree = lane?.acceptedWorktreeID.flatMap { acceptedWorktreeID in
            model.snapshot.operations.worktrees.first {
                $0.id == acceptedWorktreeID && $0.threadID == thread.id
            }
        }?.state == .accepted
        return workflowReady && acceptedWorktree
    }

    private var activeProposal: DesktopKnowledgeProposal? {
        activeWrite.flatMap { write in
            model.snapshot.operations.knowledgeProposals.first { $0.id == write.proposalID }
        }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeWrite?.approvalID.flatMap { id in
            model.snapshot.operations.approvals.first { $0.id == id }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if knowledge.isBusy {
                    ProgressView("Working with local knowledge…")
                }
                if let message = knowledge.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lane {
                    knowledgeCollectionSection(
                        title: "Consulted",
                        emptyMessage: "No consulted sources were recorded.",
                        items: lane.consultedSources,
                        accessibilityLabel: "Consulted coding knowledge sources"
                    ) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title).font(.subheadline.weight(.semibold))
                            Text(source.path).font(.caption).textSelection(.enabled)
                            Text("Digest " + source.digest + " · " + source.provenance)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    knowledgeCollectionSection(
                        title: "Candidates",
                        emptyMessage: "No candidates were recorded. An empty list does not waive the durable update.",
                        items: lane.candidates,
                        accessibilityLabel: "Coding knowledge candidates"
                    ) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(candidate.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(candidate.category.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Nord.frost1)
                            }
                            Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                            if let digest = candidate.evidenceDigest {
                                Text("Evidence digest: " + digest)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    proposalSection(lane)
                    statusSection(lane)
                } else {
                    EmptyPanel(
                        symbol: "books.vertical",
                        title: "Knowledge lane unavailable",
                        detail: "This coding result has no durable knowledge lane to review."
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .onAppear {
            if targetScopeID == nil { targetScopeID = writableScopes.first?.id }
            knowledge.resumeCodingProposal(model: model, threadID: thread.id)
        }
        .onChange(of: thread.id) { _ in
            targetScopeID = writableScopes.first?.id
            targetPath = ""
            waiverReason = ""
        }
    }

    private func knowledgeCollectionSection<Item: Identifiable, Row: View>(
        title: String,
        emptyMessage: String,
        items: [Item],
        accessibilityLabel: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func proposalSection(_ lane: DesktopCodingKnowledgeLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed edit").font(.headline)
            if let activeWrite {
                LabeledContent("Target", value: activeWrite.targetPath)
                LabeledContent("Proposal", value: activeWrite.proposalID)
                LabeledContent("Write", value: activeWrite.id)
                LabeledContent("State", value: activeWrite.state.label)
                LabeledContent("Base digest", value: activeWrite.baseDigest)
                LabeledContent("Proposed digest", value: activeWrite.proposedDigest)
                if let activeProposal {
                    Text(activeProposal.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let diff = knowledge.diff {
                    ScrollView(.horizontal) {
                        Text(diff.unifiedDiff)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                } else if !activeWrite.unifiedDiff.isEmpty {
                    ScrollView(.horizontal) {
                        Text(activeWrite.unifiedDiff)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                }
                HStack {
                    if activeApproval == nil, knowledgeReadyForDisposition {
                        Button("Request write approval", systemImage: "checkmark.shield") {
                            knowledge.requestApproval(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if activeApproval?.state == .approved, knowledgeReadyForDisposition {
                        Button("Apply approved edit", systemImage: "square.and.arrow.down") {
                            knowledge.applyApprovedDraft(model: model)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if activeApproval != nil {
                        Label("Write approval: " + (activeApproval?.state.label ?? "Unknown"), systemImage: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if activeWrite.state == .failed || lane.disposition == .conflict
                        || activeApproval?.state == .rejected || activeApproval?.state == .cancelled {
                        Button("Revise from current note", systemImage: "arrow.triangle.2.circlepath") {
                            let previousPath = activeWrite.targetPath
                            guard model.beginCodingKnowledgeRevision(threadID: thread.id) else { return }
                            targetPath = previousPath
                            targetScopeID = writableScopes.first(where: {
                                previousPath == $0.path || previousPath.hasPrefix($0.path + "/")
                            })?.id
                            knowledge.resumeCodingProposal(model: model, threadID: thread.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if let document = knowledge.document {
                Text("Exact note: " + document.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Current digest: " + document.digest)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextEditor(text: $knowledge.draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 230, maxHeight: 360)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Editable proposed knowledge note")
                    .disabled(!knowledgeReadyForDisposition)
                HStack {
                    Button("Review exact diff", systemImage: "doc.text.magnifyingglass") {
                        knowledge.reviewDraft(model: model, codingThreadID: thread.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!knowledgeReadyForDisposition || knowledge.isBusy)
                    Button("Reset draft", systemImage: "arrow.uturn.backward") { knowledge.resetDraft() }
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !knowledgeReadyForDisposition {
                        Text("The accepted implementation must enter the knowledge review lane before a durable note proposal can be created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Writable scope", selection: $targetScopeID) {
                        Text("Choose a writable scope").tag(String?.none)
                        ForEach(writableScopes) { scope in
                            Text(scope.path).tag(Optional(scope.id))
                        }
                    }
                    .labelsHidden()
                    if writableScopes.isEmpty {
                        Text("Add a writable Obsidian scope in Knowledge before proposing an edit.")
                            .font(.caption)
                            .foregroundStyle(Nord.auroraYellow)
                    }
                    TextField("Vault-relative Markdown note path", text: $targetPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Vault-relative target note path")
                    Text("The exact note must already exist inside the selected writable scope. No write occurs during inspection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Inspect & seed editable draft", systemImage: "doc.text.magnifyingglass") {
                        knowledge.prepareCodingDraft(
                            model: model,
                            threadID: thread.id,
                            path: targetPath,
                            scopePath: selectedScope?.path ?? "",
                            candidates: lane.candidates
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!knowledgeReadyForDisposition || knowledge.isBusy || selectedScope == nil || targetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed coding knowledge edit")
    }

    private func statusSection(_ lane: DesktopCodingKnowledgeLane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conflicts/status").font(.headline)
            LabeledContent("Disposition", value: lane.disposition.label)
            if let acceptedWorktreeID = lane.acceptedWorktreeID {
                LabeledContent("Accepted worktree", value: acceptedWorktreeID)
            }
            if let reason = lane.dispositionReason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let activeWrite, let currentDigest = activeWrite.currentDigest {
                LabeledContent("Current digest", value: currentDigest)
            }
            if let document = model.snapshot.operations.knowledgeDocuments.first(where: {
                $0.path == activeWrite?.targetPath
            }) {
                LabeledContent("Persisted digest", value: document.digest)
                if let conflictDigest = document.conflictDigest {
                    LabeledContent("Conflict digest", value: conflictDigest)
                }
            }
            if lane.disposition == .reconciled || lane.disposition == .waived {
                Label(
                    lane.disposition == .reconciled ? "Durable update reconciled" : "No durable update recorded with an explicit reason",
                    systemImage: "checkmark.seal"
                )
                .foregroundStyle(Nord.auroraGreen)
            } else {
                Divider()
                Text("No durable update").font(.subheadline.weight(.semibold))
                TextField("Reason required", text: $waiverReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Reason for no durable knowledge update")
                Button("Record no durable update", systemImage: "arrow.uturn.left") {
                    let reason = waiverReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reason.isEmpty else { return }
                    if model.waiveCodingKnowledge(threadID: thread.id, reason: reason) {
                        waiverReason = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!knowledgeReadyForDisposition || waiverReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("This records an explicit reason and completes the knowledge lane without writing a note")
            }
        }
        .panelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coding knowledge conflicts and status")
    }
}

private struct DesktopKnowledgeView: View {
    @ObservedObject var model: DesktopAppModel
    let searchRequest: DesktopSearchNavigationRequest?
    @StateObject private var knowledge = DesktopKnowledgeViewModel()
    @State private var selectedScopeID: String?
    @State private var selectedPath: String?
    @State private var searchText = ""
    @State private var editing = false
    @State private var showsScopeSheet = false

    private var selectedScope: DesktopVaultScopeRecord? {
        model.snapshot.operations.vaultScopes.first { $0.id == selectedScopeID }
    }

    private var activeWrite: DesktopKnowledgeWriteRecord? {
        knowledge.activeWriteID.flatMap { id in model.snapshot.operations.knowledgeWrites.first { $0.id == id } }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeWrite?.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Obsidian & Knowledge",
                detail: "Native notes with explicit scope, provenance, freshness, and conflict-safe writes",
                symbol: DesktopDestination.knowledge.symbol
            ) {
                ControlGroup {
                    Button("Add scope", systemImage: "folder.badge.plus") { showsScopeSheet = true }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        if let selectedPath { knowledge.inspect(model: model, path: selectedPath) }
                    }
                    .disabled(selectedPath == nil || knowledge.isBusy)
                }
                .controlGroupStyle(.navigation)
            }
            .padding(24)

            Divider()

            HSplitView {
                knowledgeSidebar
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                noteWorkspace
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Nord.polarNight0)
        .onAppear {
            knowledge.seedDefaultScope(model: model)
            if !applySearchRequest() {
                if selectedScopeID == nil { selectedScopeID = model.snapshot.operations.vaultScopes.first?.id }
                if selectedPath == nil, let path = selectedScope?.path, path.hasSuffix(".md") {
                    selectedPath = path
                    knowledge.inspect(model: model, path: path)
                }
            }
        }
        .onChange(of: searchRequest?.id) { _ in
            _ = applySearchRequest()
        }
        .sheet(isPresented: $showsScopeSheet) {
            NewVaultScopeSheet(model: model) { id in
                selectedScopeID = id
            }
        }
    }

    @discardableResult
    private func applySearchRequest() -> Bool {
        guard let searchRequest,
              searchRequest.target.kind == .knowledgeDocument,
              model.snapshot.operations.knowledgeDocuments.contains(where: {
                  $0.path == searchRequest.target.itemID
              }) else { return false }
        let path = searchRequest.target.itemID
        if let scope = model.snapshot.operations.vaultScopes
            .filter({ path == $0.path || path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            selectedScopeID = scope.id
        }
        selectedPath = path
        knowledge.inspect(model: model, path: path)
        return true
    }

    private var knowledgeSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Vault scope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let selectedScope {
                    Label(selectedScope.canWrite ? "Read & write" : "Read only", systemImage: selectedScope.canWrite ? "pencil.and.outline" : "eye")
                        .font(.caption2)
                        .foregroundStyle(selectedScope.canWrite ? Nord.auroraYellow : Nord.frost1)
                }
            }
            Picker("Vault scope", selection: $selectedScopeID) {
                Text("Choose a scope").tag(String?.none)
                ForEach(model.snapshot.operations.vaultScopes) { scope in
                    Text(scope.path).tag(Optional(scope.id))
                }
            }
            .labelsHidden()
            .onChange(of: selectedScopeID) { _ in
                knowledge.clearSearch()
                if let path = selectedScope?.path, path.hasSuffix(".md") {
                    selectedPath = path
                    knowledge.inspect(model: model, path: path)
                }
            }

            HStack(spacing: 8) {
                TextField("Search this scope", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search", systemImage: "magnifyingglass") { runSearch() }
                    .labelStyle(.iconOnly)
                    .disabled(selectedScope == nil || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if knowledge.searchResults.isEmpty {
                Text(selectedScope?.path.hasSuffix(".md") == true
                     ? "This is an exact-note scope. Add a folder scope to search neighboring notes."
                     : "Search results stay inside the selected scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(knowledge.searchResults) { result in
                            Button {
                                selectedPath = result.path
                                knowledge.inspect(model: model, path: result.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: result.path).deletingPathExtension().lastPathComponent)
                                        .font(.subheadline.weight(.semibold))
                                    Text(result.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    if !result.context.isEmpty {
                                        Text(result.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(selectedPath == result.path ? Nord.polarNight2 : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            DisclosureGroup("Context sources") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.snapshot.domains.knowledgeSources) { source in
                        HStack(alignment: .top) {
                            Image(systemName: source.kind.symbol).foregroundStyle(source.kind.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(.caption.weight(.semibold))
                                Text("\(source.kind.label) · \(source.scope)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    if !model.snapshot.domains.knowledgeSources.contains(where: { $0.kind == .lode }) {
                        Text("Lode is not connected; no Lode content is silently assumed current.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }

            if !model.snapshot.operations.capabilityUpdates.isEmpty {
                DisclosureGroup("Capability updates") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.snapshot.operations.capabilityUpdates) { update in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(update.source).font(.caption.weight(.semibold))
                                Text("\(update.previousRevision) → \(update.proposedRevision)").font(.caption2)
                                Text(update.changeSummary).font(.caption2).foregroundStyle(.secondary)
                                if update.state == .proposed {
                                    HStack {
                                        Button("Accept") { model.reviewCapabilityUpdate(id: update.id, accepted: true) }
                                        Button("Reject") { model.reviewCapabilityUpdate(id: update.id, accepted: false) }
                                    }
                                    .controlSize(.small)
                                } else { ActionStatePill(state: update.state) }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Spacer(minLength: 8)
            if let selectedScope {
                Button("Remove scope", systemImage: "minus.circle", role: .destructive) {
                    model.removeVaultScope(id: selectedScope.id)
                    selectedScopeID = model.snapshot.operations.vaultScopes.first?.id
                }
                .font(.caption)
            }
        }
        .padding(18)
        .background(Nord.polarNight1)
    }

    @ViewBuilder
    private var noteWorkspace: some View {
        if knowledge.isBusy, knowledge.document == nil {
            VStack(spacing: 12) { ProgressView(); Text("Reading selected note…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = knowledge.document {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: document.path).deletingPathExtension().lastPathComponent)
                                .font(.title2.weight(.bold))
                            Text(document.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Picker("Mode", selection: $editing) {
                            Text("Read").tag(false)
                            Text("Edit").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    if editing {
                        TextEditor(text: $knowledge.draft)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 440)
                            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Markdown editor for \(document.path)")
                    } else {
                        NativeObsidianMarkdown(content: knowledge.draft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
                    }

                    knowledgeMetadata(document: document)

                    if editing {
                        HStack {
                            Button("Review changes", systemImage: "doc.text.magnifyingglass") {
                                knowledge.reviewDraft(model: model)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(knowledge.isBusy || selectedScope?.canWrite != true)
                            Button("Reset draft", systemImage: "arrow.uturn.backward") { knowledge.resetDraft() }
                            Spacer()
                            if selectedScope?.canWrite != true {
                                Label("This scope is read only", systemImage: "lock.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let diff = knowledge.diff {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(diff.summary, systemImage: "plusminus")
                                    .font(.headline)
                                Spacer()
                                if let activeWrite { ActionStatePill(state: activeWrite.state) }
                            }
                            ScrollView(.horizontal) {
                                Text(diff.unifiedDiff).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            HStack {
                                if activeApproval == nil {
                                    Button("Request write approval", systemImage: "checkmark.shield") {
                                        knowledge.requestApproval(model: model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if activeApproval?.state == .approved {
                                    Button("Apply approved edit", systemImage: "square.and.arrow.down") {
                                        knowledge.applyApprovedDraft(model: model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Label(activeApproval?.state == .rejected ? "Write rejected" : "Waiting in Inbox", systemImage: "tray.full")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .panelStyle()
                    }

                    if let message = knowledge.message {
                        BoundaryCallout(
                            title: activeWrite?.state == .failed ? "Conflict or write failure" : "Knowledge status",
                            detail: message
                        )
                    }
                }
                .padding(24)
            }
        } else {
            EmptyPanel(
                symbol: "note.text",
                title: "Choose a scoped note",
                detail: "Kaname reads only the vault paths you add. Folder scopes enable search; write access is a separate choice."
            )
            .padding(24)
        }
    }

    private func knowledgeMetadata(document: ObsidianDocumentSnapshot) -> some View {
        let record = model.snapshot.operations.knowledgeDocuments.first { $0.path == document.path }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Revision \(document.digest.prefix(12))", systemImage: "checkmark.seal")
                Spacer()
                if let record { RelativeTime(unixMillis: record.lastReadAtUnixMillis) }
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Use as").font(.caption.weight(.semibold))
                Picker("Project context role", selection: Binding(
                    get: { record?.role },
                    set: { model.classifyKnowledgeDocument(path: document.path, projectID: "project-kaname", role: $0) }
                )) {
                    Text("Unclassified").tag(DesktopKnowledgeDocumentRecord.Role?.none)
                    ForEach(DesktopKnowledgeDocumentRecord.Role.allCases, id: \.self) { role in
                        Text(role.label).tag(Optional(role))
                    }
                }
                .labelsHidden()
                Spacer()
                Text(record?.provenance ?? "Local Obsidian vault").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Context & provenance") {
                VStack(alignment: .leading, spacing: 9) {
                    MetadataTokens(title: "Properties", values: document.properties.map { "\($0.key): \($0.value)" }.sorted())
                    MetadataTokens(title: "Wikilinks", values: document.wikilinks)
                    MetadataTokens(title: "Backlinks", values: document.backlinks)
                    MetadataTokens(title: "Attachments", values: document.attachments)
                    MetadataTokens(title: "Attributed sources", values: record?.sourceURLs ?? [])
                }
                .padding(.top, 8)
            }
        }
        .panelStyle()
    }

    private func runSearch() {
        guard let selectedScope else { return }
        knowledge.search(model: model, query: searchText, scope: selectedScope)
    }
}

private struct NativeObsidianMarkdown: View {
    let content: String

    private var bodyLines: [String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return lines }
        return Array(lines.suffix(from: lines.index(after: closing)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(bodyLines.enumerated()), id: \.offset) { _, line in
                rendered(line)
            }
        }
    }

    @ViewBuilder
    private func rendered(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 5)
        } else if trimmed.hasPrefix("#") {
            let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
            Text(inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 7 : 3)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Nord.frost1)
                Text(inline(String(trimmed.dropFirst(2))))
            }
        } else if trimmed.hasPrefix("> [!") {
            Label(calloutText(trimmed), systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Nord.frost1)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Nord.polarNight2, in: RoundedRectangle(cornerRadius: 9))
        } else if trimmed.hasPrefix(">") {
            Text(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                .italic()
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Nord.frost1).frame(width: 3) }
        } else {
            Text(inline(trimmed)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ value: String) -> AttributedString {
        let readable = readableWikilinks(in: value)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: readable, options: options)) ?? AttributedString(readable)
    }

    private func readableWikilinks(in value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\]|#]+)(?:[|#]([^\]]+))?\]\]"#) else {
            return value
        }
        var result = value
        let sourceRange = NSRange(value.startIndex..., in: value)
        for match in expression.matches(in: value, range: sourceRange).reversed() {
            guard let whole = Range(match.range(at: 0), in: result),
                  let targetRange = Range(match.range(at: 1), in: value) else { continue }
            let alias = match.range(at: 2).location == NSNotFound
                ? nil
                : Range(match.range(at: 2), in: value).map { String(value[$0]) }
            result.replaceSubrange(whole, with: alias ?? String(value[targetRange]))
        }
        return result
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .headline
        }
    }

    private func calloutText(_ line: String) -> String {
        guard let close = line.firstIndex(of: "]") else { return line }
        let title = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Note" : title
    }
}

private struct MetadataTokens: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text(values.isEmpty ? "None" : values.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

private struct NewVaultScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let onCreate: (String) -> Void
    @State private var path = ""
    @State private var canWrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Obsidian scope").font(.title2.weight(.bold))
            Text("Choose a vault-relative note or folder. Kaname never expands this boundary automatically.")
                .foregroundStyle(.secondary)
            TextField("Projects/Example or Projects/Example/Overview.md", text: $path)
                .textFieldStyle(.roundedBorder)
            Toggle("Allow proposing writes inside this scope", isOn: $canWrite)
            if canWrite {
                Label("Every write still needs an exact diff approval and current-revision check.", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(Nord.auroraYellow)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add scope") {
                    if let id = model.addVaultScope(path: path, sourceID: nil, canWrite: canWrite) {
                        onCreate(id)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 520)
    }
}

@MainActor
private func seedSyntheticWorkflowFixture(model: DesktopAppModel, manifestPath: String) {
    guard model.workflowDefinitions.isEmpty,
          let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else { return }
    let capabilities: Set<String> = [
        "kaname.context.compile", "kaname.model.structured", "kaname.artifact.register",
        "kaname.validation.run", "kaname.email.read", "kaname.email.draft", "kaname.email.send"
    ]
    guard let manifest = try? DesktopWorkflowPackageCodec.decode(data, registeredCapabilityIDs: capabilities),
    (try? model.installWorkflowPackage(
        manifestData: data, registeredCapabilityIDs: capabilities, enable: false
    )) != nil,
    model.setWorkflowEnabled(id: manifest.id, enabled: true),
    let workID = model.createWorkflowWorkItem(
        workflowID: manifest.id,
        title: "Northstar case review",
        goal: "Resolve a fictional case with traceable decisions and evidence."
    ),
    let firstEvent = model.observeWorkflowExternalEvent(
        source: "gmail", accountID: "fixture-account", conversationID: "fixture-thread-a",
        messageID: "fixture-message-1", cursor: "fixture-history-1", payloadDigest: "fixture-payload-1",
        deduplicationKey: "fixture:message-1"
    ) else { return }
    _ = model.bindWorkflowConversation(
        workItemID: workID, source: "gmail", accountID: "fixture-account",
        conversationID: "fixture-thread-a", relationship: .primary,
        reason: "Exact fictional document identifier", confidence: 1, requiresReview: false,
        firstMessageID: "fixture-message-1", latestMessageID: "fixture-message-2"
    )
    guard let firstEpisode = model.createWorkflowEpisode(
        workItemID: workID, sourceEventID: firstEvent, sourceMessageID: "fixture-message-1",
        intent: .request, summary: "Prepare the first structured proposal for the fictional case.",
        deltaSummary: "Initial request"
    ),
    let oldFact = model.recordWorkflowFact(
        workItemID: workID, episodeID: firstEpisode, key: "Case status", value: "Draft",
        state: .verified, sourceReferenceIDs: ["fixture-message-1"], verifiedBy: "Synthetic validator"
    ),
    let correctionEvent = model.observeWorkflowExternalEvent(
        source: "gmail", accountID: "fixture-account", conversationID: "fixture-thread-a",
        messageID: "fixture-message-2", cursor: "fixture-history-2", payloadDigest: "fixture-payload-2",
        deduplicationKey: "fixture:message-2"
    ),
    let correctionEpisode = model.createWorkflowEpisode(
        workItemID: workID, sourceEventID: correctionEvent, sourceMessageID: "fixture-message-2",
        intent: .correction, summary: "Move the case to review and replace the earlier draft status.",
        deltaSummary: "Case status changed from Draft to Needs review"
    ) else { return }
    _ = model.recordWorkflowFact(
        workItemID: workID, episodeID: correctionEpisode, key: "Case status", value: "Needs review",
        state: .verified, sourceReferenceIDs: ["fixture-message-2"], verifiedBy: "Synthetic validator",
        supersedesFactID: oldFact
    )
    _ = model.recordWorkflowFact(
        workItemID: workID, episodeID: correctionEpisode, key: "Review note",
        value: "Include a concise summary of the changed fields.",
        state: .proposed, sourceReferenceIDs: ["fixture-message-2"], verifiedBy: nil
    )
    guard let contextID = model.compileWorkflowContext(
        workItemID: workID, episodeID: correctionEpisode,
        request: "Prepare the corrected fictional case proposal.",
        references: [
            DesktopWorkflowContextReference.reference(
                id: "fixture-message-2", kind: "email-message", label: "Latest correction",
                sourceID: "fixture-message-2", digest: "fixture-payload-2", included: true,
                reason: "Latest active instruction", estimatedTokens: 180
            ),
            DesktopWorkflowContextReference.reference(
                id: "fixture-message-1", kind: "email-message", label: "Superseded request",
                sourceID: "fixture-message-1", digest: "fixture-payload-1", included: false,
                reason: "Superseded by the latest correction", estimatedTokens: 160
            )
        ],
        negativeConstraints: ["Do not use the superseded Draft status"]
    ),
    let runID = model.queueWorkflowRun(
        workItemID: workID, episodeID: correctionEpisode, contextSnapshotID: contextID
    ) else { return }
    _ = model.recordWorkflowValidation(
        workItemID: workID, episodeID: correctionEpisode, runID: runID,
        validatorID: "fixture.case-contract", validatorRevision: "1", targetID: "fixture-case-output",
        severity: .blocking, outcome: .passed, summary: "Required identifiers and status fields passed."
    )
}

private struct DesktopEmailView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    let allowsAutomaticInitialRead: Bool
    let openAutomations: () -> Void
    @StateObject private var mail = DesktopMailViewModel()
    @State private var showsComposer = false
    @State private var section = MailSection.inbox
    @State private var selectedAccountID: String?
    @State private var pendingMutation: GmailThreadMutation?
    @State private var pendingOutboundDraftID: String?
    @State private var pendingOutboundSend = false
    @State private var showsRuleSheet = false
    @State private var replySeed: MailReplySeed?
    @State private var workflowFilter = CommandLine.arguments.contains("--desktop-workflow-fixture") ? MailWorkflowFilter.active : .needsAttention
    @State private var workflowCollection = CommandLine.arguments.contains("--desktop-workflow-definitions") ? MailWorkflowCollection.definitions : .work
    @State private var selectedWorkflowWorkItemID: String?
    @State private var workflowImportMessage: String?
    @State private var capabilityImportMessage: String?
    @State private var manualRunDefinition: DesktopWorkflowDefinitionRecord?
    @State private var installationToConfigure: DesktopWorkflowInstallationRecord?
    @State private var workflowStudioDraftID: String?
    @State private var connectorToConfigure: DesktopWorkflowConnectorInstallationRecord?

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter { $0.service == .gmail }
    }

    private var googleAccounts: [NativeGoogleAccountSnapshot] {
        if let selectedAccountID { return integrations.googleAccounts.filter { $0.id == selectedAccountID } }
        return integrations.googleAccounts
    }

    private var activeAction: DesktopMailActionRecord? {
        mail.activeActionID.flatMap { id in model.snapshot.operations.mailActions.first { $0.id == id } }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeAction?.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
    }

    var body: some View {
        emailWorkspace
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsComposer) {
            NewEmailDraftSheet(model: model)
        }
        .sheet(isPresented: $showsRuleSheet) {
            NewMailRuleSheet(model: model, mail: mail, accounts: integrations.googleAccounts)
        }
        .sheet(item: $replySeed) { seed in
            NewEmailDraftSheet(
                model: model,
                accountID: seed.accountID,
                recipients: seed.recipients,
                subject: seed.subject,
                body: ""
            )
        }
        .sheet(item: $manualRunDefinition) { definition in
            WorkflowManualRunSheet(
                definition: definition,
                revision: model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
            ) { title, request, input in
                mail.runWorkflowManually(
                    model: model, workflowID: definition.id,
                    title: title, request: request, input: input
                )
            }
        }
        .sheet(item: $installationToConfigure) { installation in
            WorkflowInstallationSetupSheet(
                model: model,
                installation: installation,
                accounts: integrations.googleAccounts
            )
        }
        .sheet(isPresented: Binding(
            get: { workflowStudioDraftID != nil },
            set: { if !$0 { workflowStudioDraftID = nil } }
        )) {
            if let draftID = workflowStudioDraftID {
                WorkflowStudioSheet(model: model, draftID: draftID) { workflowID in
                    workflowImportMessage = "Published \(workflowID) disabled. Review bindings and authority before enabling it."
                    workflowCollection = .definitions
                }
            }
        }
        .sheet(item: $connectorToConfigure) { connector in
            WorkflowConnectorBindingSheet(model: model, connector: connector)
        }
        .onAppear {
            loadInitialMailDataIfNeeded()
        }
        .onChange(of: integrations.googleAccounts) {
            loadInitialMailDataIfNeeded()
        }
    }

    private func loadInitialMailDataIfNeeded() {
        let accounts = googleAccounts
        mail.loadLabels(accounts: accounts)
        guard allowsAutomaticInitialRead,
              mail.threads.isEmpty,
              !mail.isBusy,
              !accounts.isEmpty else { return }
        mail.search(accounts: accounts, model: model)
    }

    private var emailWorkspace: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Email",
                detail: "Account-isolated Gmail search, complete threads, local drafts, and reconciled actions",
                symbol: DesktopDestination.email.symbol
            )
            .padding(24)

            HStack {
                Text("View").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $section) {
                    ForEach(MailSection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Text("Account").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $selectedAccountID) {
                    Text("All accounts").tag(String?.none)
                    ForEach(integrations.googleAccounts) { Text($0.identity).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                Menu {
                    Button("New local draft", systemImage: "square.and.pencil") { showsComposer = true }
                    Button("Refresh current search", systemImage: "arrow.clockwise") {
                        mail.search(accounts: googleAccounts, model: model)
                    }
                    .disabled(mail.isBusy || googleAccounts.isEmpty)
                    Divider()
                    Button("Open Automations", systemImage: DesktopDestination.automations.symbol) {
                        openAutomations()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Email actions")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()

            switch section {
            case .inbox: inboxWorkspace
            case .drafts: draftsWorkspace
            }
        }
        .onChange(of: selectedAccountID) { _, accountID in
            accountScopeChanged(to: accountID)
        }
    }

    private var inboxWorkspace: some View {
        HSplitView {
            mailThreadList.frame(minWidth: 300, idealWidth: 370, maxWidth: 460)

            threadDetail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mailThreadList: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Gmail search (for example: in:inbox is:unread)", text: $mail.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { mail.search(accounts: googleAccounts, model: model) }
                Button("Run", systemImage: "magnifyingglass") { mail.search(accounts: googleAccounts, model: model) }
                    .labelStyle(.iconOnly)
            }
            .padding([.horizontal, .top], 16)

            if !googleAccounts.isEmpty {
                mailLabelBrowser
            }

            if let loadFailure = integrations.googleAccountLoadFailure,
               integrations.googleAccounts.isEmpty {
                VStack(spacing: 12) {
                    EmptyPanel(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "Saved Gmail accounts unavailable",
                        detail: loadFailure
                    )
                    Button("Retry saved accounts", systemImage: "arrow.clockwise") {
                        integrations.retrySavedGoogleAccounts(model: model)
                    }
                    .disabled(integrations.isRefreshingGoogle)
                }
                .padding(16)
            } else if integrations.googleAccounts.isEmpty {
                EmptyPanel(
                    symbol: "person.crop.circle.badge.plus",
                    title: "No Gmail account connected",
                    detail: "Connect Google from Settings before searching Gmail."
                )
                .padding(16)
            } else if mail.isBusy, mail.threads.isEmpty {
                ProgressView("Reading Gmail…").frame(maxHeight: .infinity)
            } else if mail.threads.isEmpty {
                EmptyPanel(
                    symbol: "tray",
                    title: "No matching threads",
                    detail: "Search one or all connected accounts. Every result keeps its source account."
                )
                .padding(16)
            } else {
                List(selection: mailThreadSelection) {
                    ForEach(mail.threads, id: \.stableID) { thread in
                        MailThreadRow(thread: thread)
                            .tag(thread.stableID)
                            .onTapGesture {
                                pendingMutation = mail.select(thread, model: model)
                            }
                    }
                }
                if mail.hasNextPage {
                    Button("Load next page") { mail.search(accounts: googleAccounts, model: model, loadMore: true) }
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var mailLabelBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Folders & labels", systemImage: "tray.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let selection = mail.selectedLabel {
                    Text(selection.label.name)
                        .font(.caption)
                        .foregroundStyle(Nord.frost1)
                        .lineLimit(1)
                    Button {
                        mail.clearLabelSelection()
                        mail.search(accounts: googleAccounts, model: model)
                    } label: {
                        Label("Clear \(selection.label.name)", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Clear folder or label filter")
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(googleAccounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.identity)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Nord.frost1)
                                .lineLimit(1)
                            if mail.labelLoadingAccountIDs.contains(account.id), mail.labels[account.id] == nil {
                                ProgressView("Loading folders…").controlSize(.small)
                            } else if let error = mail.labelErrors[account.id] {
                                LabeledContent {
                                    Button("Retry") { mail.loadLabels(accounts: [account], force: true) }
                                        .controlSize(.small)
                                } label: {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } else {
                                mailLabelGroup(
                                    title: "Folders",
                                    labels: labels(for: account, type: "system"),
                                    account: account
                                )
                                mailLabelGroup(
                                    title: "Labels",
                                    labels: labels(for: account, type: "user"),
                                    account: account
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func mailLabelGroup(
        title: String,
        labels: [GmailLabelSnapshot],
        account: NativeGoogleAccountSnapshot
    ) -> some View {
        if !labels.isEmpty {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 5)], alignment: .leading, spacing: 5) {
                ForEach(labels) { label in
                    let isSelected = mail.selectedLabel?.accountID == account.id
                        && mail.selectedLabel?.label.id == label.id
                    Button {
                        selectedAccountID = account.id
                        mail.setAccountScope(account.id)
                        mail.selectLabel(accountID: account.id, label: label)
                        mail.search(accounts: [account], model: model)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: labelSymbol(label.id))
                            Text(label.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected ? Nord.frost1.opacity(0.28) : Nord.polarNight2,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func labels(for account: NativeGoogleAccountSnapshot, type: String) -> [GmailLabelSnapshot] {
        (mail.labels[account.id] ?? [])
            .filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
            .sorted { left, right in
                if type == "system" {
                    let order = ["INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "ALL_MAIL", "SPAM", "TRASH"]
                    let leftIndex = order.firstIndex(of: left.id) ?? order.count
                    let rightIndex = order.firstIndex(of: right.id) ?? order.count
                    if leftIndex != rightIndex { return leftIndex < rightIndex }
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func labelSymbol(_ id: String) -> String {
        let systemLabelSymbols = [
            "INBOX": "tray",
            "STARRED": "star",
            "IMPORTANT": "exclamationmark.circle",
            "SENT": "paperplane",
            "DRAFT": "doc",
            "SPAM": "exclamationmark.shield",
            "TRASH": "trash",
        ]
        return systemLabelSymbols[id] ?? "tag"
    }

    private func accountScopeChanged(to accountID: String?) {
        mail.setAccountScope(accountID)
        let scopedAccounts = accountID.map { id in
            integrations.googleAccounts.filter { $0.id == id }
        } ?? integrations.googleAccounts
        mail.loadLabels(accounts: scopedAccounts)
        if allowsAutomaticInitialRead, !scopedAccounts.isEmpty {
            mail.search(accounts: scopedAccounts, model: model)
        }
    }

    private var mailThreadSelection: Binding<String?> {
        Binding(
            get: { mail.selectedThread?.stableID },
            set: { stableID in
                guard let stableID, let thread = mail.threads.first(where: { $0.stableID == stableID }) else { return }
                pendingMutation = mail.select(thread, model: model)
            }
        )
    }

    @ViewBuilder
    private var threadDetail: some View {
        if let thread = mail.selectedThread {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(thread.messages.last?.subject ?? "(No subject)").font(.title2.weight(.bold))
                            Text(thread.accountIdentity).font(.caption).foregroundStyle(Nord.frost1)
                            Text("\(thread.messages.count) message(s) · \(thread.labels.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ControlGroup {
                            Button("Refresh", systemImage: "arrow.clockwise") { mail.refreshSelected(model: model) }
                            Button("Summarize", systemImage: "text.quote") { mail.summarize(thread) }
                            Button("Draft reply", systemImage: "arrowshape.turn.up.left") {
                                replySeed = replySeed(for: thread)
                            }
                            Button("Archive", systemImage: "archivebox") {
                                pendingMutation = .archive
                                mail.proposeThreadMutation(
                                    model: model,
                                    thread: thread,
                                    mutation: .archive,
                                    preview: "Remove Inbox from this thread in \(thread.accountIdentity).",
                                    kind: .archive
                                )
                            }
                            Button("Trash", systemImage: "trash") {
                                pendingMutation = .trash
                                mail.proposeThreadMutation(
                                    model: model,
                                    thread: thread,
                                    mutation: .trash,
                                    preview: "Move this thread to Gmail Trash in \(thread.accountIdentity).",
                                    kind: .trash
                                )
                            }
                            Menu("Label", systemImage: "tag") {
                                ForEach(mail.labels[thread.accountID] ?? []) { label in
                                    Button(label.name) {
                                        let alreadyApplied = thread.labels.contains(label.id)
                                        let mutation = GmailThreadMutation.applyLabels(
                                            add: alreadyApplied ? [] : [label.id],
                                            remove: alreadyApplied ? [label.id] : []
                                        )
                                        pendingMutation = mutation
                                        mail.proposeThreadMutation(
                                            model: model,
                                            thread: thread,
                                            mutation: mutation,
                                            preview: "\(alreadyApplied ? "Remove" : "Add") label \(label.name) \(alreadyApplied ? "from" : "to") this thread in \(thread.accountIdentity).",
                                            kind: .labels
                                        )
                                    }
                                }
                            }
                        }
                        .controlGroupStyle(.navigation)
                    }

                    if let summary = mail.localSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Private on-device summary", systemImage: "lock.shield")
                                .font(.headline)
                            Text(summary).textSelection(.enabled)
                        }
                        .panelStyle()
                    }

                    workflowAssociations(thread: thread)

                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(message.sender).font(.headline)
                                Spacer()
                                Text(message.dateDescription).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("To: \(message.recipients)").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            MailReaderBody(message: message)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !message.attachments.isEmpty {
                                HStack {
                                    ForEach(message.attachments) { attachment in
                                        Button(attachment.filename, systemImage: "paperclip") {
                                            mail.saveAttachment(accountID: thread.accountID, attachment: attachment)
                                        }
                                        .help("Download \(attachment.size) bytes, then choose where to save")
                                    }
                                }
                            }
                        }
                        .panelStyle()
                    }

                    actionReview
                    mailStatus
                }
                .padding(20)
            }
        } else {
            EmptyPanel(symbol: "envelope.open", title: "Choose a thread", detail: "Read the complete account-scoped conversation, attachments, labels, and action history here.")
                .padding(24)
        }
    }

    private var draftsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BoundaryCallout(
                    title: "Local until you decide",
                    detail: "Creating a Gmail draft and sending are separate exact actions. Send is never covered by a standing rule."
                )
                if model.snapshot.domains.emailDrafts.isEmpty {
                    EmptyPanel(symbol: "doc.badge.plus", title: "No local drafts", detail: "Compose locally without touching Gmail, then preview a remote draft or send.")
                }
                ForEach(model.snapshot.domains.emailDrafts.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { draft in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(draft.subject.isEmpty ? "Untitled draft" : draft.subject).font(.headline); Spacer(); RecordStatusPill(state: draft.status) }
                        LabeledContent("Recipients", value: draft.recipients.isEmpty ? "None" : draft.recipients)
                        Text(draft.body).foregroundStyle(.secondary).lineLimit(6)
                        if let account = googleAccount(for: draft) {
                            Text("From \(account.identity)").font(.caption).foregroundStyle(Nord.frost1)
                            HStack {
                                Button("Review Gmail draft") {
                                    pendingOutboundDraftID = draft.id
                                    pendingOutboundSend = false
                                    mail.proposeOutbound(model: model, draft: draft, account: account, send: false)
                                }
                                Button("Review send") {
                                    pendingOutboundDraftID = draft.id
                                    pendingOutboundSend = true
                                    mail.proposeOutbound(model: model, draft: draft, account: account, send: true)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(draft.recipients.isEmpty || draft.body.isEmpty)
                            }
                        } else {
                            Label("Choose or reconnect the draft account before any Gmail action.", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.caption).foregroundStyle(Nord.auroraYellow)
                        }
                    }
                    .panelStyle()
                }
                actionReview
                mailStatus
            }
            .padding(24)
        }
    }

    private var workflowsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workflow operations").font(.headline)
                        Text("Manual checks and package operations stay visible under Automations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check triggers", systemImage: "arrow.triangle.2.circlepath") {
                        mail.checkWorkflowTriggers(model: model)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.workflowTriggerBindings().contains(where: { $0.enabled && $0.trigger == .email }))
                }
                BoundaryCallout(
                    title: "Generic workflows, private behavior",
                    detail: "Kaname supplies durable work, context, checks, approvals, effects, and observability. Installed packages supply domain behavior; email content can never broaden their authority."
                )
                workflowOperationalSummary
                Picker("Workflow collection", selection: $workflowCollection) {
                    ForEach(MailWorkflowCollection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                switch workflowCollection {
                case .work: workflowWorkList
                case .definitions: workflowDefinitionList
                case .simpleRules: simpleRuleList
                }
                if let workflowImportMessage { BoundaryCallout(title: "Workflow package", detail: workflowImportMessage) }
                mailStatus
            }
            .padding(24)
        }
    }

    private var workflowOperationalSummary: some View {
        let health = model.workflowTriggerHealth
        let actionRequired = health.filter { $0.state == .actionRequired }.count
        let degraded = health.filter { $0.state == .degraded }.count
        let waiting = model.snapshot.operations.workflows.waitSubscriptions.filter { $0.state == .active }.count
        let operational = model.activeWorkflowOperationalStatuses
        let operationalAction = operational.filter { $0.level == .actionRequired }.count
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(health.filter { $0.state != .healthy && $0.state != .paused }) { record in
                    LabeledContent(record.errorSummary ?? record.state.label) {
                        Text(record.state.label).foregroundStyle(record.state == .actionRequired ? Nord.auroraYellow : .secondary)
                    }
                }
                ForEach(mail.workflowComponentIssues, id: \.self) { issue in
                    Label(issue, systemImage: "puzzlepiece.extension.fill")
                        .font(.caption).foregroundStyle(Nord.auroraYellow)
                }
                ForEach(operational) { record in
                    Label(record.summary, systemImage: record.level == .actionRequired ? "exclamationmark.shield.fill" : "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(record.level == .actionRequired ? Nord.auroraYellow : .secondary)
                }
                if health.isEmpty && mail.workflowComponentIssues.isEmpty && operational.isEmpty {
                    Text("Health appears after the first enabled trigger check. Manual-only workflows stay quiet here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 14) {
                Label(actionRequired == 0 ? "No trigger action required" : "\(actionRequired) action required",
                      systemImage: actionRequired == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(actionRequired == 0 ? Nord.auroraGreen : Nord.auroraYellow)
                if degraded > 0 { Text("\(degraded) retrying").foregroundStyle(.secondary) }
                if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(Nord.frost0) }
                if operationalAction > 0 { Text("\(operationalAction) operation alert\(operationalAction == 1 ? "" : "s")").foregroundStyle(Nord.auroraYellow) }
                Spacer()
                Text("Details").font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Nord.polarNight1.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var workflowWorkList: some View {
        Picker("Work state", selection: $workflowFilter) {
            ForEach(MailWorkflowFilter.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 520)

        let items = filteredWorkflowItems
        if items.isEmpty {
            EmptyPanel(
                symbol: workflowFilter.symbol,
                title: workflowFilter.emptyTitle,
                detail: "Work appears here only after a generic workflow is installed and an event is deliberately associated. Ordinary email remains uncluttered."
            )
        } else {
            ForEach(items) { item in
                WorkflowWorkItemCard(
                    model: model,
                    item: item,
                    expanded: selectedWorkflowWorkItemID == item.id,
                    requestEffectApproval: { mail.requestWorkflowEffectApproval(model: model, effect: $0) },
                    executeEffect: { mail.executeWorkflowEffect(model: model, effect: $0) },
                    completeHumanReview: { mail.completeWorkflowHumanReview(model: model, runID: $0, stepID: $1) },
                    toggleExpanded: {
                        selectedWorkflowWorkItemID = selectedWorkflowWorkItemID == item.id ? nil : item.id
                    }
                )
                .onAppear {
                    if selectedWorkflowWorkItemID == nil,
                       CommandLine.arguments.contains("--desktop-workflow-fixture") {
                        selectedWorkflowWorkItemID = item.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workflowDefinitionList: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if !model.snapshot.operations.workflows.connectorInstallations.isEmpty {
                    Text("Trusted connectors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.connectorInstallations) { connector in
                        WorkflowConnectorInstallationRow(
                            model: model, connector: connector,
                            onConfigure: { connectorToConfigure = connector }
                        )
                    }
                }
                if !model.snapshot.operations.workflows.rendererInstallations.isEmpty {
                    Text("Renderers and recalculation adapters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.rendererInstallations) { renderer in
                        WorkflowRendererInstallationRow(model: model, renderer: renderer)
                    }
                }
                if !model.snapshot.operations.workflows.subflows.isEmpty {
                    Text("Reusable subflows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.subflows) { subflow in
                        LabeledContent("\(subflow.name) · \(subflow.version)") {
                            Text("\(subflow.steps.count) stages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(model.workflowCapabilityInstallations) { capability in
                    WorkflowCapabilityInstallationRow(
                        model: model,
                        capability: capability,
                        onTest: testWorkflowCapability
                    )
                }
                HStack {
                    Text("External capabilities run locally without network access and remain disabled until their schema test passes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Install capability…", systemImage: "puzzlepiece.extension") { installWorkflowCapability() }
                }
                if let capabilityImportMessage {
                    Label(capabilityImportMessage, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let recentQualifications = model.snapshot.operations.workflows.qualificationRuns.suffix(12)
                if !recentQualifications.isEmpty {
                    DisclosureGroup("Recent qualification · \(recentQualifications.count)") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(recentQualifications.reversed()) { run in
                                WorkflowQualificationSummaryRow(run: run)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(
                "Component library · \(model.workflowCapabilityInstallations.count + model.snapshot.operations.workflows.connectorInstallations.count + model.snapshot.operations.workflows.rendererInstallations.count + model.snapshot.operations.workflows.subflows.count) installed",
                systemImage: "puzzlepiece.extension"
            )
        }

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Installed definitions").font(.headline)
                Text("Every revision is immutable; broadened authority remains disabled until reviewed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Create workflow", systemImage: "plus") {
                workflowStudioDraftID = model.createWorkflowStudioDraft(
                    name: "Untitled workflow", summary: "A reusable workflow created in Kaname."
                )
            }
            Button("Install package…", systemImage: "shippingbox") { installWorkflowPackage() }
                .buttonStyle(.borderedProminent)
        }
        if model.workflowDefinitions.isEmpty {
            EmptyPanel(
                symbol: "shippingbox",
                title: "No workflow packages installed",
                detail: "Create an outline in Workflow Studio or install a reviewed package. Definitions never embed credentials or silently inherit connector authority."
            )
        } else {
            ForEach(model.workflowDefinitions) { definition in
                WorkflowDefinitionCard(
                    model: model,
                    definition: definition,
                    googleAccounts: integrations.googleAccounts,
                    runManually: { manualRunDefinition = definition },
                    configureInstallation: { installationToConfigure = $0 },
                    processExistingMatches: { mail.processExistingWorkflowMatches(model: model, binding: $0) }
                )
            }
        }
    }

    @ViewBuilder
    private var simpleRuleList: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Simple rules").font(.headline)
                Text("Narrow Gmail rules remain workflow definitions managed from Automations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New simple rule", systemImage: "plus") { showsRuleSheet = true }
                .buttonStyle(.borderedProminent)
                .disabled(integrations.googleAccounts.isEmpty)
        }
        BoundaryCallout(
            title: "Visible, narrow standing authority",
            detail: "Simple rules bind one Gmail account, one saved query, and one reversible action. Trash and send always require an exact approval."
        )
        if model.snapshot.operations.mailStandingRules.isEmpty {
            EmptyPanel(symbol: "checklist", title: "No simple rules", detail: "Save a narrow archive rule from a tested Gmail query. Rules remain visible and pausable.")
        }
        ForEach(model.snapshot.operations.mailStandingRules) { rule in
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: rule.enabled ? "checkmark.shield.fill" : "pause.circle")
                    .foregroundStyle(rule.enabled ? Nord.auroraGreen : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name).font(.headline)
                    Text(rule.accountIdentity).font(.caption).foregroundStyle(Nord.frost1)
                    Text(rule.query).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(rule.action.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.setMailStandingRuleEnabled(id: rule.id, enabled: $0) }
                ))
                Button("Run now") { mail.runStandingRule(model: model, rule: rule) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rule.enabled || mail.isBusy)
            }
            .panelStyle()
        }
    }

    private var filteredWorkflowItems: [DesktopWorkflowWorkItemRecord] {
        model.workflowWorkItems.filter { item in
            switch workflowFilter {
            case .needsAttention: item.state.needsAttention
            case .active: !item.state.needsAttention && !item.state.isHistorical
            case .history: item.state.isHistorical
            }
        }
    }

    @ViewBuilder
    private func workflowAssociations(thread: GmailThreadDetailSnapshot) -> some View {
        let items = model.workflowWorkItems(accountID: thread.accountID, conversationID: thread.id)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Text(items.count, format: .number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } label: {
                    Label("Associated automation", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(Nord.frost1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.state.label).font(.caption2).foregroundStyle(Nord.frost0)
                        }
                        Spacer()
                        Button("Open in Automations") { openAutomations() }
                            .buttonStyle(.bordered)
                    }
                    .panelStyle()
                }
            }
        }
    }

    private func installWorkflowPackage() {
        do {
            if let message = try DesktopWorkflowTransferUI.installPackage(model: model) {
                workflowImportMessage = message
                workflowCollection = .definitions
            }
        } catch {
            workflowImportMessage = "Installation failed safely: \(error.localizedDescription)"
        }
    }

    private func installWorkflowCapability() {
        guard let store = model.workflowCapabilityStore() else {
            capabilityImportMessage = "Capability storage is unavailable in this workspace."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Install Kaname capability"
        panel.message = "Choose a .kanamecapability directory. Kaname verifies its manifest, executable digest, schemas, paths, and trust receipt before copying it privately."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let inspected = try store.inspectPackage(
                at: url,
                installedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            let alert = NSAlert()
            let permissionSummary = inspected.0.permissions.permissions.map(\.label).joined(separator: ", ")
            alert.messageText = "Install \(inspected.0.name) \(inspected.0.version)?"
            alert.informativeText = "\(inspected.0.summary)\n\nTrust: \(inspected.0.trust.label)\nRuntime: \(inspected.0.runtime.label)\nPermissions: \(permissionSummary.isEmpty ? "Local computation only" : permissionSummary)\n\nThe capability will remain disabled until its local schema test passes."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install disabled")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let receipt = try store.installPackage(
                at: url,
                installedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            guard model.registerWorkflowCapabilityInstallation(receipt) else {
                capabilityImportMessage = "The capability bytes were installed, but Kaname could not commit its receipt."
                return
            }
            let directory = store.installationDirectory(
                capabilityID: receipt.capabilityID, version: receipt.version
            )
            var adapters: [String] = []
            if let connector = try? DesktopWorkflowProcessConnector.loadPackageManifest(from: directory),
               model.registerWorkflowConnector(package: connector, capability: receipt) {
                adapters.append("trusted connector")
            }
            if let renderer = try? DesktopWorkflowRendererAdapter.loadManifest(from: directory),
               model.registerWorkflowRenderer(package: renderer, capability: receipt) {
                adapters.append("renderer")
            }
            let adapterDetail = adapters.isEmpty ? "" : " Registered as " + adapters.joined(separator: " and ") + "."
            capabilityImportMessage = "Installed \(receipt.name) \(receipt.version) disabled.\(adapterDetail) Run its artifact fixture suite before enabling it."
        } catch {
            capabilityImportMessage = "Capability installation failed safely: \(error.localizedDescription)"
        }
    }

    private func testWorkflowCapability(_ capability: DesktopWorkflowCapabilityInstallationRecord) {
        guard let store = model.workflowCapabilityStore() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose capability qualification suite"
        panel.message = "Choose a fixture directory containing qualification.json plus its declared inputs, artifacts, state, context, expected outputs, and negative cases."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runs = try DesktopWorkflowCapabilityQualifier().run(
                suiteURL: url, installation: capability, capabilityStore: store,
                scratchRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("KanameWorkflowCapabilityTests", isDirectory: true)
            )
            let passed = !runs.isEmpty && runs.allSatisfy { $0.outcome == .passed }
            runs.forEach { _ = model.recordWorkflowQualification($0) }
            _ = model.recordWorkflowCapabilityTest(id: capability.id, passed: passed)
            let failedAssertions = runs.flatMap(\.assertions).filter { !$0.passed }.count
            capabilityImportMessage = passed
                ? "Qualification passed \(runs.count) fixture\(runs.count == 1 ? "" : "s"). Review bindings and enable \(capability.name) when ready."
                : "Qualification failed with \(failedAssertions) assertion\(failedAssertions == 1 ? "" : "s"); the component remains disabled."
        } catch {
            _ = model.recordWorkflowCapabilityTest(id: capability.id, passed: false)
            capabilityImportMessage = "Test failed; the capability remains disabled: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var actionReview: some View {
        if let action = activeAction {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label("Action preview", systemImage: "checkmark.shield").font(.headline); Spacer(); ActionStatePill(state: action.state) }
                Text(action.preview)
                Text(action.exactTarget).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if let draftID = pendingOutboundDraftID,
                   let draft = model.snapshot.domains.emailDrafts.first(where: { $0.id == draftID }) {
                    DisclosureGroup("Resolved message body") { Text(draft.body).textSelection(.enabled).padding(.top, 6) }
                }
                HStack {
                    if action.standingRuleID != nil {
                        Button("Run under standing rule") { executeActive(action: action) }.buttonStyle(.borderedProminent)
                    } else if activeApproval == nil {
                        Button("Request approval") { mail.requestActiveApproval(model: model) }.buttonStyle(.borderedProminent)
                    } else if activeApproval?.state == .approved {
                        Button(action.kind == .send ? "Send approved message" : "Apply approved action") { executeActive(action: action) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Label(activeApproval?.state == .rejected ? "Rejected" : "Waiting in Inbox", systemImage: "tray.full")
                    }
                }
            }
            .panelStyle()
        }
    }

    @ViewBuilder
    private var mailStatus: some View {
        if !mail.failedAccounts.isEmpty {
            BoundaryCallout(title: "Partial Gmail refresh", detail: "Other accounts remain usable. Reconnect: \(mail.failedAccounts.joined(separator: ", ")).")
        }
        if let message = mail.message { BoundaryCallout(title: "Mail status", detail: message) }
    }

    private func executeActive(action: DesktopMailActionRecord) {
        if let mutation = pendingMutation {
            mail.executeActiveThreadMutation(model: model, mutation: mutation)
        } else if let draftID = pendingOutboundDraftID,
                  let draft = model.snapshot.domains.emailDrafts.first(where: { $0.id == draftID }) {
            mail.executeOutbound(model: model, draft: draft, send: pendingOutboundSend)
        }
    }

    private func googleAccount(for draft: DesktopEmailDraft) -> NativeGoogleAccountSnapshot? {
        guard let localID = draft.accountID,
              let identity = accounts.first(where: { $0.id == localID })?.identity else { return nil }
        return integrations.googleAccounts.first { $0.identity == identity }
    }

    private func replySeed(for thread: GmailThreadDetailSnapshot) -> MailReplySeed? {
        guard let message = thread.messages.last,
              let localAccountID = accounts.first(where: { $0.identity == thread.accountIdentity })?.id else { return nil }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        return MailReplySeed(accountID: localAccountID, recipients: message.sender, subject: subject)
    }
}

private enum MailSection: String, CaseIterable {
    case inbox
    case drafts

    var label: String { rawValue.capitalized }
}

private enum MailWorkflowCollection: String, CaseIterable {
    case work
    case definitions
    case simpleRules

    var label: String {
        switch self {
        case .work: "Work"
        case .definitions: "Definitions"
        case .simpleRules: "Simple rules"
        }
    }
}

private enum MailWorkflowFilter: String, CaseIterable {
    case needsAttention
    case active
    case history

    var label: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .active: "Active"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .needsAttention: "checkmark.circle"
        case .active: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }

    var emptyTitle: String {
        switch self {
        case .needsAttention: "Nothing needs attention"
        case .active: "No active workflow work"
        case .history: "No workflow history"
        }
    }
}

private struct MailReplySeed: Identifiable {
    let id = UUID()
    let accountID: String
    let recipients: String
    let subject: String
}

private struct MailThreadRow: View {
    let thread: GmailThreadDetailSnapshot

    var body: some View {
        let last = thread.messages.last
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(last?.sender ?? "Unknown sender").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if thread.labels.contains("UNREAD") { Circle().fill(Nord.frost0).frame(width: 7, height: 7) }
            }
            Text(subject(last)).font(.subheadline).lineLimit(1)
            Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(thread.accountIdentity).font(.caption2).foregroundStyle(Nord.frost1)
        }
        .padding(.vertical, 5)
    }

    private func subject(_ message: GmailMessageSnapshot?) -> String {
        guard let subject = message?.subject, !subject.isEmpty else { return "(No subject)" }
        return subject
    }
}

private struct MailReaderBody: View {
    let message: GmailMessageSnapshot
    @State private var presentation: Presentation = .formatted
    @State private var loadsRemoteImagesDirectly = false

    private enum Presentation: String, CaseIterable, Identifiable {
        case formatted = "Formatted"
        case plainText = "Plain text"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = message.bodyDisplayNotice, !notice.isEmpty {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sanitizedHTML = message.sanitizedHTML, !sanitizedHTML.isEmpty {
                HStack(spacing: 10) {
                    Picker("Message view", selection: $presentation) {
                        ForEach(Presentation.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()

                    Spacer()

                    Label(
                        loadsRemoteImagesDirectly ? "Direct images" : "Safe HTML",
                        systemImage: loadsRemoteImagesDirectly
                            ? "exclamationmark.shield.fill"
                            : "shield.lefthalf.filled"
                    )
                        .font(.caption2)
                        .foregroundStyle(loadsRemoteImagesDirectly ? Nord.auroraYellow : .secondary)
                        .help(loadsRemoteImagesDirectly
                            ? directImageHelp
                            : "Scripts, forms, remote images, and other remote content are blocked.")
                }

                remoteImageControls

                switch presentation {
                case .formatted:
                    MailHTMLMessageView(
                        html: loadsRemoteImagesDirectly
                            ? (message.directRemoteImagesHTML ?? sanitizedHTML)
                            : sanitizedHTML,
                        loadsRemoteImagesDirectly: loadsRemoteImagesDirectly
                    )
                case .plainText:
                    plainText
                }
            } else {
                plainText
            }
        }
        .onChange(of: message.id) { _, _ in
            loadsRemoteImagesDirectly = false
        }
    }

    @ViewBuilder
    private var remoteImageControls: some View {
        if message.embeddedImageCount > 0 {
            Label(
                "\(message.embeddedImageCount) embedded image\(message.embeddedImageCount == 1 ? "" : "s") loaded locally",
                systemImage: "photo.on.rectangle.angled"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("These images came from this email's validated MIME attachments. Kaname did not contact the sender to display them.")
        }

        if message.remoteImageCount > 0, message.directRemoteImagesHTML != nil {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Toggle(directImageToggleTitle, isOn: $loadsRemoteImagesDirectly)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Label("Privacy relay · Coming soon", systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("A privacy relay is planned but is not configured. Direct image loading is not private.")
                }

                Label(
                    remoteImageStatusText,
                    systemImage: loadsRemoteImagesDirectly ? "exclamationmark.triangle.fill" : "eye.slash"
                )
                .font(.caption2)
                .foregroundStyle(loadsRemoteImagesDirectly ? Nord.auroraYellow : .secondary)
            }
        }
    }

    private var directImageToggleTitle: String {
        guard message.insecureRemoteImageCount > 0 else {
            return "Load remote images directly"
        }
        return message.insecureRemoteImageCount == message.remoteImageCount
            ? "Try images over HTTPS"
            : "Load remote images (HTTPS only)"
    }

    private var directImageHelp: String {
        let base = "Remote images are loading directly from their senders. Scripts, forms, and other remote content remain blocked."
        guard message.insecureRemoteImageCount > 0 else { return base }
        return "\(base) Kaname rewrote insecure HTTP image URLs to HTTPS and never requested them over plaintext HTTP."
    }

    private var remoteImageStatusText: String {
        let remoteCount = message.remoteImageCount
        let insecureCount = message.insecureRemoteImageCount
        if loadsRemoteImagesDirectly {
            let warning = "The sender may observe this request, your network address, and when this message was opened."
            guard insecureCount > 0 else { return warning }
            return "\(warning) Kaname rewrote \(imageCount(insecureCount)) from HTTP to HTTPS."
        }
        guard insecureCount > 0 else {
            return "\(remoteCount) remote image\(remoteCount == 1 ? " is" : "s are") blocked to prevent tracking."
        }
        if insecureCount == remoteCount {
            return "\(imageCount(insecureCount)) \(insecureCount == 1 ? "uses" : "use") insecure HTTP and \(insecureCount == 1 ? "is" : "are") blocked. Loading will try HTTPS instead."
        }
        return "\(remoteCount) remote images are blocked to prevent tracking. Of those, \(imageCount(insecureCount)) \(insecureCount == 1 ? "uses" : "use") insecure HTTP and will be tried over HTTPS."
    }

    private func imageCount(_ count: Int) -> String {
        "\(count) image\(count == 1 ? "" : "s")"
    }

    private var plainText: some View {
        Text(message.body.isEmpty ? "No readable text body." : message.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkflowWorkItemCard: View {
    @ObservedObject var model: DesktopAppModel
    let item: DesktopWorkflowWorkItemRecord
    let expanded: Bool
    let requestEffectApproval: (DesktopWorkflowEffectRecord) -> Void
    let executeEffect: (DesktopWorkflowEffectRecord) -> Void
    let completeHumanReview: (String, String) -> Void
    let toggleExpanded: () -> Void
    @State private var standingGrantPreview: DesktopWorkflowEffectPreviewRecord? = nil

    private var definition: DesktopWorkflowDefinitionRecord? {
        model.snapshot.operations.workflows.definitions.first { $0.id == item.workflowID }
    }

    private var episodes: [DesktopWorkflowEpisodeRecord] {
        model.workflowEpisodes(workItemID: item.id)
    }

    private var currentEpisode: DesktopWorkflowEpisodeRecord? {
        item.currentEpisodeID.flatMap { id in episodes.first { $0.id == id } }
    }

    private var runs: [DesktopWorkflowRunRecord] {
        model.snapshot.operations.workflows.runs.filter { $0.workItemID == item.id }
            .sorted { ($0.startedAtUnixMillis ?? 0, $0.id) < ($1.startedAtUnixMillis ?? 0, $1.id) }
    }

    private var activeFacts: [DesktopWorkflowFactRecord] {
        let itemFacts = model.workflowFacts(workItemID: item.id).filter { $0.state == .verified }
        let accountIDs = Set(model.snapshot.operations.workflows.conversationBindings.filter {
            $0.workItemID == item.id && $0.relationship != .detached
        }.map(\.accountID))
        let installationFacts = model.workflowKnowledge(workflowID: item.workflowID).filter {
            $0.state == .verified && ($0.scope == .installation
                || ($0.scope == .accountBinding && $0.scopeID.map(accountIDs.contains) == true))
        }
        return Array(Dictionary(uniqueKeysWithValues: (itemFacts + installationFacts).map { ($0.id, $0) }).values)
            .sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
    }

    private var proposedKnowledge: [DesktopWorkflowFactRecord] {
        model.workflowFacts(workItemID: item.id).filter { $0.state == .proposed }
    }

    private var inactiveFacts: [DesktopWorkflowFactRecord] {
        model.workflowFacts(workItemID: item.id, includeInactive: true).filter {
            $0.state == .rejected || $0.state == .superseded || $0.state == .expired
        }
    }

    private var artifactRoles: [DesktopWorkflowArtifactRoleRecord] {
        model.workflowArtifactRoles(workItemID: item.id, includeInactive: true)
    }

    private var artifactRoleNames: [String] {
        Array(Set(artifactRoles.map(\.role))).sorted()
    }

    private var stateRecords: [DesktopWorkflowStateRecord] {
        model.workflowStateRecords(workflowID: item.workflowID)
    }

    private var pendingEffects: [DesktopWorkflowEffectRecord] {
        model.snapshot.operations.workflows.effects.filter {
            $0.workItemID == item.id && ![.reconciled, .cancelled].contains($0.state)
        }
    }

    private var pendingStructuredReviews: [DesktopWorkflowReviewRequestRecord] {
        model.pendingWorkflowReviews.filter { $0.workItemID == item.id }
    }

    private var activeWaits: [DesktopWorkflowWaitSubscriptionRecord] {
        model.activeWorkflowWaits.filter { $0.workItemID == item.id }
    }

    private var authorityGrants: [DesktopWorkflowAuthorityGrantRecord] {
        model.snapshot.operations.workflows.authorityGrants.filter { $0.workflowID == item.workflowID }
            .sorted { ($0.state.rawValue, $0.effectKind, $0.id) < ($1.state.rawValue, $1.effectKind, $1.id) }
    }

    private var datasetDefinitions: [DesktopWorkflowDatasetDefinition] {
        guard let revisionID = definition?.currentRevisionID else { return [] }
        return model.snapshot.operations.workflows.revisions.first { $0.id == revisionID }?.datasetDefinitions ?? []
    }

    private var executionReceipts: [DesktopWorkflowExecutionReceiptRecord] {
        let runIDs = Set(model.snapshot.operations.workflows.runs.filter { $0.workItemID == item.id }.map(\.id))
        return model.snapshot.operations.workflows.executionReceipts.filter { runIDs.contains($0.runID) }
            .sorted { ($0.createdAtUnixMillis, $0.id) > ($1.createdAtUnixMillis, $1.id) }
    }

    private var waitingHumanReviews: [(runID: String, step: DesktopWorkflowStepDefinition)] {
        model.snapshot.operations.workflows.runs.compactMap { run in
            guard run.workItemID == item.id, run.state == .waiting,
                  let revision = model.snapshot.operations.workflows.revisions.first(where: { $0.id == run.workflowRevisionID }),
                  let step = revision.steps.first(where: { $0.id == run.currentStepID && $0.kind == .humanReview }),
                  !pendingStructuredReviews.contains(where: { $0.runID == run.id && $0.stepID == step.id }) else {
                return nil
            }
            return (run.id, step)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleExpanded) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: definition?.icon ?? "point.3.connected.trianglepath.dotted")
                        .font(.title3)
                        .foregroundStyle(item.state.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(definition?.name ?? item.workflowID)
                            .font(.caption).foregroundStyle(Nord.frost1)
                        Text(item.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        WorkflowStatePill(state: item.state)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), \(item.state.label)")
            .accessibilityHint(expanded ? "Collapse workflow details" : "Show workflow details")

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Goal", value: item.goal)
                    if let currentEpisode {
                        LabeledContent("Current episode", value: "\(currentEpisode.ordinal) · \(currentEpisode.intent.label)")
                        Text(currentEpisode.deltaSummary.isEmpty ? currentEpisode.summary : currentEpisode.deltaSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    WorkflowMetricsRow(metrics: [
                        WorkflowMetricValue(label: "Episodes", value: "\(episodes.count)", tint: Nord.frost1),
                        WorkflowMetricValue(label: "Verified", value: "\(activeFacts.count)", tint: Nord.auroraGreen),
                        WorkflowMetricValue(
                            label: proposedKnowledge.isEmpty ? "Artifacts" : "To review",
                            value: "\(proposedKnowledge.isEmpty ? artifactRoles.count : proposedKnowledge.count)",
                            tint: proposedKnowledge.isEmpty ? Nord.frost1 : Nord.auroraYellow
                        )
                    ])
                    if !episodes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Episode history").font(.subheadline.weight(.semibold))
                            ForEach(episodes.suffix(12)) { episode in
                                WorkflowEpisodeRow(model: model, episode: episode)
                            }
                        }
                    }
                    if !runs.isEmpty {
                        DisclosureGroup("Run graph and history · \(runs.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(runs.suffix(8)) { run in
                                    WorkflowRunGraphProjectionView(model: model, run: run)
                                }
                                if runs.count >= 2 {
                                    WorkflowRunComparisonView(
                                        comparisons: model.compareWorkflowRuns(
                                            leftRunID: runs[runs.count - 2].id,
                                            rightRunID: runs[runs.count - 1].id
                                        )
                                    )
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !activeFacts.isEmpty {
                        DisclosureGroup("Current truth") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(activeFacts) { fact in
                                    LabeledContent {
                                        Text(fact.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    } label: {
                                        Label(fact.key, systemImage: fact.state == .verified ? "checkmark.seal.fill" : "questionmark.circle")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(fact.state == .verified ? Nord.auroraGreen : Nord.auroraYellow)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !proposedKnowledge.isEmpty {
                        WorkflowKnowledgeReviewSection(facts: proposedKnowledge) { id, accepted in
                            _ = model.reviewWorkflowKnowledge(
                                id: id, accepted: accepted, reviewer: "Kaname user"
                            )
                        }
                    }
                    if !pendingStructuredReviews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Decisions").font(.subheadline.weight(.semibold))
                            ForEach(pendingStructuredReviews) { request in
                                WorkflowStructuredReviewRow(request: request) { actionID, value in
                                    model.resolveWorkflowReview(
                                        id: request.id, actionID: actionID, value: value, reviewer: "Kaname user"
                                    )
                                }
                            }
                        }
                    }
                    if !artifactRoles.isEmpty {
                        DisclosureGroup("Artifacts · \(artifactRoles.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(artifactRoleNames, id: \.self) { role in
                                    Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(artifactRoles.filter { $0.role == role }.sorted {
                                        ($0.active ? 0 : 1, -$0.createdAtUnixMillis, $0.id)
                                            < ($1.active ? 0 : 1, -$1.createdAtUnixMillis, $1.id)
                                    }) { artifact in
                                        WorkflowArtifactRoleRow(
                                            artifact: artifact,
                                            byteCount: artifactByteCount(artifact),
                                            validationSummary: artifactValidationSummary(artifact),
                                            preview: { previewArtifacts([artifact]) },
                                            exportCopy: { exportArtifact(artifact) },
                                            compareWithCurrent: artifact.active ? nil : {
                                                let current = artifactRoles.first { $0.role == artifact.role && $0.active }
                                                previewArtifacts([artifact, current].compactMap { $0 })
                                            },
                                            makeCurrent: artifact.active ? nil : {
                                                _ = model.setWorkflowArtifactRoleCurrent(id: artifact.id)
                                            },
                                            promote: {
                                                _ = model.promoteWorkflowContent(
                                                    workflowID: item.workflowID,
                                                    artifactDigest: artifact.artifactDigest,
                                                    reason: "Explicitly promoted from workflow artifact role \(artifact.role)."
                                                )
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !artifactRoles.isEmpty {
                        let usage = (try? model.workflowStorage(workflowID: item.workflowID)?.artifactUsageBytes()) ?? 0
                        let receipts = model.snapshot.operations.workflows.purgeReceipts.filter { $0.workflowID == item.workflowID }
                        HStack {
                            Text("Private content: \(ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .file)) · \(receipts.count) purge receipt\(receipts.count == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Preview purge…", action: reviewPurge)
                                .disabled(!item.state.isHistorical)
                                .help(item.state.isHistorical ? "Review eligible bytes and retained reasons" : "Content remains protected until work settles")
                        }
                    }
                    if !stateRecords.isEmpty {
                        DisclosureGroup("Operational state · \(stateRecords.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(stateRecords) { record in
                                    WorkflowStateRecordRow(record: record)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !datasetDefinitions.isEmpty {
                        DisclosureGroup("Datasets · \(datasetDefinitions.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(datasetDefinitions) { dataset in
                                    let count = model.snapshot.operations.workflows.datasetRows.filter {
                                        $0.workflowID == item.workflowID && $0.datasetID == dataset.id
                                    }.count
                                    WorkflowDatasetSummaryRow(definition: dataset, rowCount: count)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !executionReceipts.isEmpty {
                        DisclosureGroup("Execution evidence · \(executionReceipts.count)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(executionReceipts) { receipt in
                                    VStack(alignment: .leading, spacing: 4) {
                                        LabeledContent {
                                            Text("\(receipt.elapsedMilliseconds) ms")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        } label: {
                                            Label(receipt.capabilityID, systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.semibold))
                                        }
                                        Text("Input \(receipt.inputDigest.prefix(12)) · Output \(receipt.outputDigest?.prefix(12) ?? "none")")
                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        if !receipt.standardOutput.isEmpty || !receipt.standardError.isEmpty {
                                            DisclosureGroup("Privacy-filtered logs") {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    if !receipt.standardOutput.isEmpty {
                                                        Text(receipt.standardOutput).textSelection(.enabled)
                                                    }
                                                    if !receipt.standardError.isEmpty {
                                                        Text(receipt.standardError).foregroundStyle(Nord.auroraYellow).textSelection(.enabled)
                                                    }
                                                }
                                                .font(.caption2.monospaced()).padding(.top, 4)
                                            }
                                            .font(.caption2)
                                        }
                                    }
                                    .padding(9)
                                    .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !activeWaits.isEmpty {
                        DisclosureGroup("Waiting subscriptions · \(activeWaits.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(activeWaits) { WorkflowWaitRow(wait: $0) }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !authorityGrants.isEmpty {
                        DisclosureGroup("Standing authority · \(authorityGrants.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(authorityGrants) { grant in
                                    WorkflowAuthorityGrantRow(
                                        grant: grant,
                                        events: model.snapshot.operations.workflows.authorityEvents.filter { $0.grantID == grant.id }
                                            .sorted { $0.recordedAtUnixMillis < $1.recordedAtUnixMillis }
                                    ) { requestedState in
                                        _ = model.setWorkflowAuthorityGrantState(id: grant.id, state: requestedState)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !inactiveFacts.isEmpty {
                        DisclosureGroup("Superseded or rejected facts") {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(inactiveFacts) { fact in
                                    LabeledContent(fact.key, value: fact.value)
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    if !pendingEffects.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("External effects").font(.subheadline.weight(.semibold))
                            ForEach(pendingEffects) { effect in
                                let preview = model.snapshot.operations.workflows.effectPreviews.first { $0.effectID == effect.id }
                                let approval = effect.approvalID.flatMap { id in
                                    model.snapshot.operations.approvals.first { $0.id == id }
                                }
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: effect.kind == "gmail-send" ? "paperplane.fill" : "bolt.horizontal.circle")
                                        .foregroundStyle(Nord.auroraYellow)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preview?.title ?? effect.kind)
                                            .font(.caption.weight(.semibold))
                                        if let summary = preview?.summary {
                                            Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Text(effect.exactTarget).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(2).textSelection(.enabled)
                                        if let preview {
                                            Text("\(preview.itemCount) item\(preview.itemCount == 1 ? "" : "s") · \(preview.reversible ? "reversible" : "not reversible")")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if effect.approvalID == nil && preview?.authorityGrantID == nil {
                                        VStack(alignment: .trailing, spacing: 5) {
                                            Button("Request approval") { requestEffectApproval(effect) }
                                            if let preview {
                                                Button("Standing grant…") { standingGrantPreview = preview }
                                                    .font(.caption)
                                            }
                                        }
                                    } else if effect.state == .outcomeUnknown {
                                        if preview != nil {
                                            Button("Reconcile result") { executeEffect(effect) }
                                                .buttonStyle(.borderedProminent)
                                                .help("Re-read every frozen target without repeating the action")
                                        } else {
                                            Text("Outcome unknown").font(.caption).foregroundStyle(Nord.auroraRed)
                                        }
                                    } else if effect.state == .executing {
                                        ProgressView().controlSize(.small).accessibilityLabel("Applying email effect")
                                    } else if approval?.state == .approved || preview?.authorityGrantID != nil {
                                        Button(effect.kind == "gmail-send" ? "Send" : "Apply exact action") { executeEffect(effect) }
                                            .buttonStyle(.borderedProminent)
                                    } else {
                                        Text("Waiting in Inbox").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    ForEach(waitingHumanReviews, id: \.runID) { review in
                        WorkflowHumanReviewRow(
                            runID: review.runID,
                            stepID: review.step.id,
                            stepName: review.step.name,
                            onContinue: completeHumanReview
                        )
                    }
                    if !item.state.isHistorical {
                        HStack {
                            Spacer()
                            Button("Close operationally") { _ = model.closeWorkflowWorkItem(id: item.id, accepted: false) }
                            Button("Record acceptance") { _ = model.closeWorkflowWorkItem(id: item.id, accepted: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .panelStyle()
        .sheet(item: $standingGrantPreview) { preview in
            WorkflowStandingGrantBuilderSheet(model: model, preview: preview)
        }
    }

    private func artifactURL(_ artifact: DesktopWorkflowArtifactRoleRecord) -> URL? {
        try? model.workflowStorage(workflowID: item.workflowID)?.artifactPresentationURL(
            sha256: artifact.artifactDigest, filename: artifact.filename
        )
    }

    private func artifactByteCount(_ artifact: DesktopWorkflowArtifactRoleRecord) -> Int? {
        try? model.workflowStorage(workflowID: item.workflowID)?.artifactRecords()
            .first { $0.sha256 == artifact.artifactDigest }?.byteCount
    }

    private func artifactValidationSummary(_ artifact: DesktopWorkflowArtifactRoleRecord) -> String {
        let reportValidationIDs = Set(model.snapshot.operations.workflows.validatorReports.compactMap {
            $0.subjectDigest == artifact.artifactDigest ? $0.validationID : nil
        })
        let validations = model.snapshot.operations.workflows.validations.filter {
            $0.targetID == artifact.artifactDigest || reportValidationIDs.contains($0.id)
        }
        guard !validations.isEmpty else { return "not validated" }
        return validations.allSatisfy { $0.outcome == .passed } ? "validated" : "validation attention"
    }

    private func previewArtifacts(_ artifacts: [DesktopWorkflowArtifactRoleRecord]) {
        let urls = artifacts.compactMap(artifactURL)
        guard !urls.isEmpty else { return }
        WorkflowArtifactPreviewController.shared.present(urls)
    }

    private func exportArtifact(_ artifact: DesktopWorkflowArtifactRoleRecord) {
        guard let data = try? model.workflowStorage(workflowID: item.workflowID)?.artifactData(
            sha256: artifact.artifactDigest
        ) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.message = "Export a verified copy. Kaname keeps the immutable workflow artifact in private storage."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func reviewPurge() {
        guard let storage = model.workflowStorage(workflowID: item.workflowID),
              let plan = model.previewWorkflowPurge(workflowID: item.workflowID, mode: .manual) else { return }
        let alert = NSAlert()
        alert.messageText = "Purge eligible private workflow content?"
        alert.informativeText = "Eligible: \(plan.eligibleDigests.count) artifact(s), \(ByteCountFormatter.string(fromByteCount: Int64(plan.eligibleBytes), countStyle: .file))\nRetained: \(plan.retained.count) artifact(s)\n\nPromoted artifacts and unresolved-effect evidence remain. A sanitized receipt records counts and reasons, never deleted content."
        alert.alertStyle = .warning
        if plan.eligibleDigests.isEmpty {
            alert.addButton(withTitle: "Done")
            _ = alert.runModal()
            return
        }
        alert.addButton(withTitle: "Purge eligible content")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if try model.executeWorkflowPurge(plan, storage: storage) == nil {
                _ = model.recordWorkflowOperationalStatus(
                    workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                    level: .actionRequired, summary: "The purge plan changed before execution; review it again."
                )
            } else {
                _ = model.recordWorkflowOperationalStatus(
                    workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                    level: .actionRequired, summary: "The latest retention operation completed.", active: false
                )
            }
        } catch {
            _ = model.recordWorkflowOperationalStatus(
                workflowID: item.workflowID, relatedID: item.workflowID, kind: .retentionFailure,
                level: .actionRequired, summary: "Retention cleanup failed safely: \(error.localizedDescription)"
            )
        }
    }
}

private struct WorkflowRunGraphProjectionView: View {
    @ObservedObject var model: DesktopAppModel
    let run: DesktopWorkflowRunRecord

    private var nodes: [DesktopWorkflowRunNodeProjection] { model.workflowRunProjection(runID: run.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(run.retryMode.label, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(run.state.label).font(.caption2).foregroundStyle(.secondary)
                Button("Reprocess current revision") {
                    _ = model.queueWorkflowDebugRun(priorRunID: run.id, action: .reprocessCurrentRevision)
                }
                .font(.caption2)
                .disabled(![.completed, .failed, .cancelled].contains(run.state))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(nodes) { node in
                        let step = revision?.steps.first { $0.id == node.stepID }
                        let attempts = model.snapshot.operations.workflows.stepAttempts.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }.sorted { $0.attempt < $1.attempt }
                        let transition = model.snapshot.operations.workflows.transitionRecords.last {
                            $0.runID == run.id && $0.fromStepID == node.stepID
                        }
                        let effects = model.snapshot.operations.workflows.effects.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }
                        let batchItems = model.snapshot.operations.workflows.batchItems.filter {
                            $0.runID == run.id && $0.stepID == node.stepID
                        }.sorted { $0.ordinal < $1.ordinal }
                        let eligibility = step.map {
                            DesktopWorkflowRunProjection.debugEligibility(
                                step: $0, projection: node,
                                hasUnknownEffect: effects.contains { $0.state == .outcomeUnknown }
                            )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Label(node.stepID, systemImage: symbol(node.state))
                                .font(.caption.weight(.semibold))
                            Text(node.state.label).font(.caption2)
                            if let elapsed = node.elapsedMilliseconds {
                                Text("\(elapsed) ms · attempt \(node.attempt)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if node.totalItems > 0 {
                                Text("Batch \(node.completedItems)/\(node.totalItems) · \(node.failedItems) failed · \(node.unknownItems) unknown")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(node.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            DisclosureGroup("Inspect step") {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let step {
                                        Text("\(step.kind.label) · \(step.capabilityID ?? "host structural step")")
                                        Text("Retry limit \(step.retryLimit) · \(step.isIdempotent ? "idempotent" : "not idempotent")")
                                    }
                                    ForEach(attempts) { attempt in
                                        Text("Attempt \(attempt.attempt) · \(attempt.state.label) · input \(attempt.inputDigest.prefix(10)) · output \(attempt.outputDigest?.prefix(10) ?? "none")")
                                    }
                                    if let transition {
                                        Text("Branch \(transition.outcome.rawValue) → \(transition.toStepID ?? "terminal")")
                                    }
                                    if !effects.isEmpty {
                                        Text("Effects: \(effects.map { $0.state.rawValue }.joined(separator: ", "))")
                                    }
                                    if !batchItems.isEmpty {
                                        ForEach(batchItems) { item in
                                            Text("Item \(item.ordinal + 1) · \(item.state.rawValue) · attempt \(item.attempt)")
                                        }
                                        let failedIDs = Set(batchItems.filter { $0.state == .failed }.map(\.id))
                                        let unknownItems = batchItems.filter { $0.state == .unknown }
                                        HStack {
                                            Button("Retry failed items") {
                                                _ = model.retryFailedWorkflowBatchItems(ids: failedIDs)
                                            }
                                            .disabled(failedIDs.isEmpty)
                                            Button("Reconcile unknown…") {
                                                reconcileUnknownBatchAsFailed(unknownItems)
                                            }
                                            .disabled(unknownItems.isEmpty)
                                        }
                                    }
                                    HStack {
                                        Button("Retry step") {
                                            _ = model.queueWorkflowDebugRun(
                                                priorRunID: run.id, action: .retryFailedStep, stepID: node.stepID
                                            )
                                        }
                                        .disabled(eligibility?.allowed.contains(.retryFailedStep) != true)
                                        Button("Restart after") {
                                            _ = model.queueWorkflowDebugRun(
                                                priorRunID: run.id, action: .restartFromCheckpoint, stepID: node.stepID
                                            )
                                        }
                                        .disabled(eligibility?.allowed.contains(.restartFromCheckpoint) != true)
                                    }
                                    if node.state == .outcomeUnknown {
                                        Label("Reconcile this effect in Effects before retrying.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                            .foregroundStyle(Nord.auroraRed)
                                    }
                                }
                                .font(.caption2)
                                .padding(.top, 4)
                            }
                        }
                        .padding(9)
                        .frame(width: 250, alignment: .leading)
                        .background(tint(node.state).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint(node.state), lineWidth: 1))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(node.stepID), \(node.state.label). \(node.detail)")
                    }
                }
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    private var revision: DesktopWorkflowRevisionRecord? {
        model.snapshot.operations.workflows.revisions.first { $0.id == run.workflowRevisionID }
    }

    private func reconcileUnknownBatchAsFailed(_ items: [DesktopWorkflowBatchItemRecord]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Record verified failure for unknown batch items?"
        alert.informativeText = "Use this only after checking the external system and confirming these \(items.count) item(s) did not succeed. They can then be retried explicitly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Record verified failure")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in items {
            _ = model.reconcileUnknownWorkflowBatchItem(
                id: item.id, outcomeKnown: true, succeeded: false,
                detail: "Operator verified that the interrupted item did not succeed externally."
            )
        }
    }

    private func symbol(_ state: DesktopWorkflowRunNodeState) -> String {
        switch state {
        case .notRun: "circle"
        case .queued: "list.number"
        case .running: "progress.indicator"
        case .waiting: "clock.badge"
        case .needsReview: "person.crop.circle.badge.exclamationmark"
        case .retrying: "arrow.clockwise.circle"
        case .succeeded: "checkmark.circle.fill"
        case .skipped: "forward.end.circle"
        case .failed: "xmark.octagon.fill"
        case .outcomeUnknown: "exclamationmark.arrow.triangle.2.circlepath"
        case .cancelled: "stop.circle"
        }
    }

    private func tint(_ state: DesktopWorkflowRunNodeState) -> Color {
        switch state {
        case .succeeded: Nord.auroraGreen
        case .failed, .outcomeUnknown: Nord.auroraRed
        case .waiting, .retrying: Nord.auroraYellow
        case .needsReview: Nord.auroraPurple
        case .running, .queued: Nord.frost1
        default: .secondary
        }
    }
}

private struct WorkflowRunComparisonView: View {
    let comparisons: [DesktopWorkflowRunStepComparison]

    var body: some View {
        DisclosureGroup("Compare latest two runs") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comparisons) { comparison in
                    HStack {
                        Text(comparison.stepID).font(.caption.weight(.semibold)).frame(width: 160, alignment: .leading)
                        Text(comparison.leftState.label).font(.caption2)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(comparison.rightState.label).font(.caption2)
                        Spacer()
                        if comparison.inputChanged { Label("Input", systemImage: "arrow.triangle.2.circlepath").font(.caption2) }
                        if comparison.outputChanged { Label("Output", systemImage: "arrow.triangle.2.circlepath").font(.caption2) }
                        if comparison.branchChanged { Label("Branch", systemImage: "arrow.triangle.branch").font(.caption2) }
                        if let delta = comparison.durationDeltaMilliseconds {
                            Text("\(delta >= 0 ? "+" : "")\(delta) ms").font(.caption2.monospacedDigit())
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
    }
}

private struct WorkflowEpisodeRow: View {
    @ObservedObject var model: DesktopAppModel
    let episode: DesktopWorkflowEpisodeRecord

    private var runs: [DesktopWorkflowRunRecord] { model.workflowRuns(episodeID: episode.id) }
    private var validations: [DesktopWorkflowValidationRecord] { model.workflowValidations(episodeID: episode.id) }
    private var reports: [DesktopWorkflowValidatorReportRecord] {
        let validationIDs = Set(validations.map(\.id))
        return model.snapshot.operations.workflows.validatorReports.filter { validationIDs.contains($0.validationID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent {
                Text(episode.state.label).font(.caption2).foregroundStyle(.secondary)
            } label: {
                Label(
                    "Episode \(episode.ordinal) · \(episode.intent.label)",
                    systemImage: episode.state == .superseded ? "arrow.uturn.forward.circle" : "circle.inset.filled"
                )
                .font(.caption.weight(.semibold)).foregroundStyle(episode.state.tint)
            }
            Text(episode.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            WorkflowEpisodeMetrics(runs: runs, validations: validations)
            if episode.state == .superseded {
                Text("Superseded by a later episode; retained as evidence and excluded from current truth by default.")
                    .font(.caption2).foregroundStyle(Nord.auroraYellow)
            }
            if !validations.isEmpty {
                WorkflowValidationEvidence(validations: validations, reports: reports)
            }
        }
        .padding(10)
        .background(Nord.polarNight1.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WorkflowEpisodeMetrics: View {
    let runs: [DesktopWorkflowRunRecord]
    let validations: [DesktopWorkflowValidationRecord]

    var body: some View {
        HStack(spacing: 12) {
            Label("\(runs.count) run\(runs.count == 1 ? "" : "s")", systemImage: "waveform.path.ecg")
            Label("\(validations.filter { $0.outcome == .passed }.count) passed", systemImage: "checkmark.circle")
            let blocking = validations.filter { $0.severity == .blocking && $0.outcome != .passed }.count
            if blocking > 0 {
                Label("\(blocking) blocking", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Nord.auroraYellow)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct WorkflowValidationEvidence: View {
    let validations: [DesktopWorkflowValidationRecord]
    let reports: [DesktopWorkflowValidatorReportRecord]

    var body: some View {
        DisclosureGroup("Validation evidence · \(validations.count)") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(validations) { validation in
                    let matchingReports = reports.filter { $0.validationID == validation.id }
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent {
                            Text(validation.outcome.label)
                                .foregroundStyle(validation.outcome == .passed ? Nord.auroraGreen : Nord.auroraYellow)
                        } label: {
                            Text(validation.validatorID).fontWeight(.semibold)
                        }
                        Text(validation.summary).foregroundStyle(.secondary)
                        ForEach(matchingReports) { report in
                            Text("Validator \(report.validatorVersion) · subject \(report.subjectDigest.prefix(12))")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            ForEach(report.findings) { finding in
                                Label(finding.summary, systemImage: finding.severity == .blocking
                                    ? "exclamationmark.triangle.fill" : "info.circle")
                                Text(finding.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.caption2)
    }
}

private struct WorkflowDefinitionCard: View {
    @ObservedObject var model: DesktopAppModel
    let definition: DesktopWorkflowDefinitionRecord
    let googleAccounts: [NativeGoogleAccountSnapshot]
    let runManually: () -> Void
    let configureInstallation: (DesktopWorkflowInstallationRecord) -> Void
    let processExistingMatches: (DesktopWorkflowTriggerBindingRecord) -> Void
    @State private var selectedAccountID = ""
    @State private var emailFilter = ""
    @State private var transferMessage: String?
    @State private var ownershipFilter = ""
    @State private var ownershipMode = DesktopWorkflowOwnershipMode.protected
    @State private var scheduleTime = Date()
    @State private var scheduleZone = TimeZone.current.identifier
    @State private var missedRunPolicy = DesktopAutomationRule.MissedRunPolicy.skip
    @State private var selectedCalendarSourceID = ""

    private var emailTriggerBindings: [DesktopWorkflowTriggerBindingRecord] {
        model.workflowTriggerBindings(workflowID: definition.id).filter { $0.trigger == .email }
    }

    private var calendarTriggerBindings: [DesktopWorkflowTriggerBindingRecord] {
        model.workflowTriggerBindings(workflowID: definition.id).filter { $0.trigger == .calendar }
    }

    private var googleCalendarSources: [DesktopCalendarSourceRecord] {
        model.snapshot.domains.calendarSources.filter { source in
            source.provider == .google && source.isEnabled
                && googleAccounts.contains { $0.identity == source.ownerIdentity }
        }
    }

    private var googleAccountPicker: some View {
        Picker("Account", selection: $selectedAccountID) {
            Text("Choose account").tag("")
            ForEach(googleAccounts) { account in Text(account.identity).tag(account.id) }
        }
        .frame(maxWidth: 220)
    }

    private var revision: DesktopWorkflowRevisionRecord? {
        model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
    }

    private var catalogFixtureSuite: DesktopWorkflowFixtureSuite? {
        DesktopWorkflowStarterCatalog.fixtureSuites.first { $0.workflowID == definition.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkflowDefinitionHeader(model: model, definition: definition)
            HStack(spacing: 8) {
                if definition.triggerKinds.contains(.manual) {
                    Button("Run…", systemImage: "play.fill", action: runManually)
                        .buttonStyle(.borderedProminent)
                        .disabled(!definition.enabled)
                }
                Button("Export package…", systemImage: "shippingbox.and.arrow.backward") {
                    do {
                        transferMessage = try DesktopWorkflowTransferUI.exportPackage(model: model, definition: definition)
                    } catch {
                        transferMessage = error.localizedDescription
                    }
                }
                Button("Export installation…", systemImage: "lock.doc") {
                    do {
                        transferMessage = try DesktopWorkflowTransferUI.exportInstallation(model: model, definition: definition)
                    } catch {
                        transferMessage = error.localizedDescription
                    }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            if let transferMessage {
                Label(transferMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let revision {
                let readiness = model.workflowMigrationReadiness(workflowID: definition.id)
                WorkflowMetricsRow(metrics: [
                    WorkflowMetricValue(label: "Revision", value: revision.version, tint: Nord.frost0),
                    WorkflowMetricValue(label: "Steps", value: "\(revision.steps.count)", tint: Nord.frost1),
                    WorkflowMetricValue(label: "Permissions", value: "\(revision.permissions.permissions.count)", tint: Nord.auroraYellow)
                ])
                if revision.schemaVersion == 3 {
                    DisclosureGroup("Installations · \(model.workflowInstallations(workflowID: definition.id).count)") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.workflowInstallations(workflowID: definition.id)) { installation in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: installation.readinessIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(installation.readinessIssues.isEmpty ? Nord.auroraGreen : Nord.auroraYellow)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(installation.name).font(.caption.weight(.semibold))
                                        Text(installation.readinessIssues.isEmpty
                                            ? "Configuration and bindings are ready; authority remains separate."
                                            : installation.readinessIssues.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Spacer()
                                    Button("Configure…") { configureInstallation(installation) }
                                    Toggle("Enabled", isOn: Binding(
                                        get: { installation.enabled },
                                        set: { _ = model.setWorkflowInstallationEnabled(id: installation.id, enabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .disabled(!installation.readinessIssues.isEmpty && !installation.enabled)
                                }
                            }
                            Button("Add another installation") {
                                do {
                                    let id = try model.createWorkflowInstallation(
                                        workflowID: definition.id,
                                        name: "\(definition.name) \(model.workflowInstallations(workflowID: definition.id).count + 1)"
                                    )
                                    if let created = model.snapshot.operations.workflows.installations.first(where: { $0.id == id }) {
                                        configureInstallation(created)
                                    }
                                } catch { transferMessage = error.localizedDescription }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(readiness.checks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: readinessSymbol(check.state))
                                    .foregroundStyle(readinessTint(check.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.title).font(.caption.weight(.semibold))
                                    Text(check.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Label("Host readiness", systemImage: readiness.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(readiness.isReady ? Nord.auroraGreen : Nord.auroraYellow)
                        Spacer()
                        Text(readiness.isReady ? "Ready to configure" : "\(readiness.blockedCount) blocked")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Stages and permission receipt") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(revision.steps) { step in
                            HStack {
                                Image(systemName: step.kind.symbol).foregroundStyle(Nord.frost1).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.name).font(.caption.weight(.semibold))
                                    Text(step.kind.label + (step.capabilityID.map { " · \($0)" } ?? ""))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    let artifactCount = step.artifactInputs?.count ?? 0
                                    let stateCount = step.stateInputs?.count ?? 0
                                    if artifactCount + stateCount > 0 {
                                        Text("Declared inputs · \(artifactCount) artifact role\(artifactCount == 1 ? "" : "s") · \(stateCount) state value\(stateCount == 1 ? "" : "s")")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let transitions = step.transitions, !transitions.isEmpty {
                                        Text("Routes · " + transitions.map { "\($0.outcome.rawValue) → \($0.targetStepID)" }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    if step.reviewContract != nil {
                                        Text("Schema-driven human decision").font(.caption2).foregroundStyle(Nord.auroraYellow)
                                    } else if step.waitContract != nil {
                                        Text("Durable resumable subscription").font(.caption2).foregroundStyle(Nord.frost0)
                                    } else if step.agentPolicy != nil {
                                        Text("Bounded agent · no direct effects").font(.caption2).foregroundStyle(Nord.frost0)
                                    }
                                }
                                Spacer()
                                if !step.isIdempotent { Text("No automatic retry").font(.caption2).foregroundStyle(Nord.auroraYellow) }
                            }
                        }
                        Divider()
                        if revision.permissions.permissions.isEmpty {
                            Text("Local read-only workflow").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(revision.permissions.permissions, id: \.self) { permission in
                                Label(permission.label, systemImage: permission.symbol).font(.caption)
                            }
                        }
                        LabeledContent("Manifest digest", value: String(revision.manifestDigest.prefix(20)) + "…")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let datasets = revision.datasetDefinitions, !datasets.isEmpty {
                            Divider()
                            Text("Declared datasets").font(.caption.weight(.semibold))
                            ForEach(datasets) { dataset in
                                WorkflowDatasetSummaryRow(
                                    definition: dataset,
                                    rowCount: model.snapshot.operations.workflows.datasetRows.filter {
                                        $0.workflowID == definition.id && $0.datasetID == dataset.id
                                    }.count
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                if definition.triggerKinds.contains(.email) {
                    DisclosureGroup("Email trigger scope") {
                        VStack(alignment: .leading, spacing: 10) {
                            if emailTriggerBindings.isEmpty {
                                Text("No mailbox is observed until you add and enable an account-scoped filter.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(emailTriggerBindings) { binding in
                                    WorkflowTriggerBindingRow(
                                        model: model, binding: binding,
                                        processExistingMatches: { processExistingMatches(binding) },
                                        rebaseline: nil
                                    )
                                }
                            }
                            if !googleAccounts.isEmpty {
                                HStack {
                                    googleAccountPicker
                                    TextField("Provider filter, for example from:sender@example.com", text: $emailFilter)
                                    Button("Add scope") {
                                        _ = model.bindWorkflowTrigger(
                                            workflowID: definition.id, trigger: .email, source: "mail",
                                            accountIDs: [selectedAccountID], sourceFilter: emailFilter, enabled: false
                                        )
                                        emailFilter = ""
                                    }
                                    .disabled(selectedAccountID.isEmpty || emailFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            } else {
                                Text("Connect a mail account to configure an email trigger.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    DisclosureGroup("Ownership and exclusions") {
                        Form {
                            Section("Current policy") {
                                let policies = model.snapshot.operations.workflows.ownershipPolicies.filter { $0.workflowID == definition.id }
                                WorkflowOwnershipPolicySummary(policies: policies)
                            }
                            Section("Add policy") {
                                HStack {
                                    googleAccountPicker
                                    TextField("Protected sender or exact query", text: $ownershipFilter)
                                    Picker("Mode", selection: $ownershipMode) {
                                        ForEach(DesktopWorkflowOwnershipMode.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Button("Add") {
                                        _ = model.upsertWorkflowOwnershipPolicy(
                                            workflowID: definition.id, accountID: selectedAccountID,
                                            sourceFilter: ownershipFilter, mode: ownershipMode
                                        )
                                        ownershipFilter = ""
                                    }
                                    .disabled(selectedAccountID.isEmpty || ownershipFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
                if definition.triggerKinds.contains(.calendar) {
                    DisclosureGroup("Calendar trigger scope") {
                        VStack(alignment: .leading, spacing: 10) {
                            if calendarTriggerBindings.isEmpty {
                                Text("No calendar is observed until you add and enable an exact source.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(calendarTriggerBindings) { binding in
                                    WorkflowTriggerBindingRow(
                                        model: model, binding: binding,
                                        processExistingMatches: nil,
                                        rebaseline: { _ = model.rebaselineWorkflowTrigger(id: binding.id) }
                                    )
                                }
                            }
                            if googleCalendarSources.isEmpty {
                                Text("Connect Google Calendar and enable a visible calendar first.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    Picker("Calendar", selection: $selectedCalendarSourceID) {
                                        Text("Choose calendar").tag("")
                                        ForEach(googleCalendarSources) { source in
                                            Text("\(source.displayName) · \(source.ownerIdentity)").tag(source.id)
                                        }
                                    }
                                    .frame(maxWidth: 360)
                                    Button("Add scope") {
                                        guard let source = googleCalendarSources.first(where: {
                                            $0.id == selectedCalendarSourceID
                                        }), let account = googleAccounts.first(where: {
                                            $0.identity == source.ownerIdentity
                                        }) else { return }
                                        _ = model.bindWorkflowTrigger(
                                            workflowID: definition.id, trigger: .calendar,
                                            source: "google-calendar", accountIDs: [account.id],
                                            sourceFilter: source.externalIdentifier, enabled: false
                                        )
                                        selectedCalendarSourceID = ""
                                    }
                                    .disabled(selectedCalendarSourceID.isEmpty)
                                }
                            }
                            Text("The first enabled check establishes a baseline. Later event revisions create durable episodes; the trigger grants no calendar-write authority.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                if definition.triggerKinds.contains(.schedule) {
                    DisclosureGroup("Schedule trigger") {
                        Grid(alignment: .leading, verticalSpacing: 10) {
                            let schedules = model.snapshot.operations.workflows.scheduleBindings.filter { $0.workflowID == definition.id }
                            ForEach(schedules) { schedule in
                                LabeledContent {
                                    Text(schedule.enabled ? "Enabled" : "Paused")
                                        .font(.caption).foregroundStyle(schedule.enabled ? Nord.auroraGreen : .secondary)
                                } label: {
                                    Text(DesktopScheduleEngine.humanSchedule(spec: schedule.spec, timeZoneIdentifier: schedule.timeZoneIdentifier))
                                        .font(.caption)
                                }
                            }
                            HStack {
                                DatePicker("Daily at", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                                TextField("Time zone", text: $scheduleZone).frame(width: 180)
                                Picker("Missed run", selection: $missedRunPolicy) {
                                    ForEach(DesktopAutomationRule.MissedRunPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                Button("Add schedule") {
                                    var calendar = Calendar(identifier: .gregorian)
                                    calendar.timeZone = TimeZone(identifier: scheduleZone) ?? .current
                                    let components = calendar.dateComponents([.hour, .minute], from: scheduleTime)
                                    _ = model.upsertWorkflowSchedule(
                                        workflowID: definition.id,
                                        spec: .anchored(frequency: .daily, hour: components.hour ?? 9, minute: components.minute ?? 0),
                                        timeZoneIdentifier: scheduleZone, missedRunPolicy: missedRunPolicy, enabled: true
                                    )
                                }
                                .disabled(TimeZone(identifier: scheduleZone) == nil)
                            }
                            Text("A schedule starts the workflow but never grants mailbox or connector authority by itself.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    }
                }
                workflowMigrationAcceptance
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private var workflowMigrationAcceptance: some View {
        let assessment = model.snapshot.operations.workflows.migrationAssessments
            .filter { $0.workflowID == definition.id }
            .sorted { ($0.updatedAtUnixMillis, $0.id) > ($1.updatedAtUnixMillis, $1.id) }
            .first
        DisclosureGroup("Migration acceptance") {
            VStack(alignment: .leading, spacing: 9) {
                if let assessment {
                    LabeledContent("Stage", value: assessment.stage.label)
                    Text("\(assessment.passedScenarioIDs.count) of \(assessment.requiredScenarioIDs.count) required scenarios passed")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(assessment.comparisonEvidenceIDs?.count ?? 0) integrity-bound comparison receipt(s)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let fixtureSuiteID = assessment.fixtureSuiteID,
                       let fixtureSuiteDigest = assessment.fixtureSuiteDigest {
                        Text("\(fixtureSuiteID) · \(fixtureSuiteDigest.prefix(16))…")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(assessment.blockingFindings, id: \.self) { finding in
                        Label(finding, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Nord.auroraYellow)
                    }
                    if let current = DesktopWorkflowMigrationStage.allCases.firstIndex(of: assessment.stage),
                       DesktopWorkflowMigrationStage.allCases.indices.contains(current + 1) {
                        Button("Advance to \(DesktopWorkflowMigrationStage.allCases[current + 1].label)") {
                            do {
                                try model.advanceWorkflowMigration(
                                    id: assessment.id, to: DesktopWorkflowMigrationStage.allCases[current + 1]
                                )
                            } catch { transferMessage = error.localizedDescription }
                        }
                        .disabled(!assessment.blockingFindings.isEmpty
                            || !Set(assessment.requiredScenarioIDs).isSubset(of: Set(assessment.passedScenarioIDs)))
                    }
                } else {
                    Text("Start with observe-only evidence. Live effects remain outside the comparison harness.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create acceptance checklist") {
                        _ = model.createWorkflowMigrationAssessment(
                            workflowID: definition.id,
                            requiredScenarioIDs: [
                                "fixture-parity", "backup-restore", "restart-resume", "unknown-outcome",
                                "account-expiry", "large-artifact", "correction-thread", "rollback",
                            ]
                        )
                    }
                }
                if let suite = catalogFixtureSuite {
                    Button("Run signed-package synthetic qualification", systemImage: "checkmark.seal") {
                        qualifySyntheticPackage(suite)
                    }
                    Text("Runs deterministic mail, model, connector, failure, and replay fixtures. The comparison baseline is synthetic package evidence, not private legacy acceptance.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func qualifySyntheticPackage(_ suite: DesktopWorkflowFixtureSuite) {
        do {
            let installation = model.workflowInstallations(workflowID: definition.id).first {
                $0.workflowRevisionID == definition.currentRevisionID
            }
            let requiredScenarios = Set(suite.cases.map(\.id))
            let assessmentID = model.snapshot.operations.workflows.migrationAssessments.first {
                $0.workflowID == definition.id
                    && Set($0.requiredScenarioIDs) == requiredScenarios
                    && ($0.fixtureSuiteDigest == nil || $0.fixtureSuiteDigest == suite.digest)
            }?.id ?? model.createWorkflowMigrationAssessment(
                workflowID: definition.id,
                requiredScenarioIDs: requiredScenarios.sorted(),
                installationID: installation?.id
            )
            guard let assessmentID else {
                throw DesktopWorkflowSimulationError.staleEvidence
            }
            for scenario in suite.cases {
                let runID = try model.simulateWorkflowFixture(
                    workflowID: definition.id, installationID: installation?.id,
                    suite: suite, scenarioID: scenario.id
                )
                guard let run = model.snapshot.operations.workflows.simulationRuns.first(where: { $0.id == runID }) else {
                    throw DesktopWorkflowSimulationError.expectationFailed
                }
                _ = try model.recordWorkflowMigrationComparison(
                    assessmentID: assessmentID, simulationRunID: runID,
                    legacySourceRevision: "synthetic-package-baseline@\(suite.digest)",
                    legacyOutputJSON: run.outputJSON
                )
            }
            transferMessage = "Synthetic qualification passed with exact package, dependency, fixture, timeline, and comparison receipts."
        } catch {
            transferMessage = "Synthetic qualification failed safely: \(error.localizedDescription)"
        }
    }

    private func readinessSymbol(_ state: DesktopWorkflowMigrationReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .blocked: "xmark.circle.fill"
        }
    }

    private func readinessTint(_ state: DesktopWorkflowMigrationReadinessState) -> Color {
        switch state {
        case .ready: Nord.auroraGreen
        case .attention: Nord.auroraYellow
        case .blocked: Nord.auroraRed
        }
    }
}

private struct WorkflowOwnershipPolicySummary: View {
    let policies: [DesktopWorkflowOwnershipPolicyRecord]

    var body: some View {
        Text(policies.isEmpty
            ? "Protect correspondence from broad cleanup workflows, or allow shared read-only observation explicitly."
            : policies.map {
                "\($0.enabled ? "Active" : "Paused") · \($0.mode.label)\n\($0.sourceFilter) · \($0.accountID)"
            }.joined(separator: "\n\n")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

struct WorkflowManualRunSheet: View {
    let definition: DesktopWorkflowDefinitionRecord
    let revision: DesktopWorkflowRevisionRecord?
    let start: (String, String, Data) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var request = ""
    @State private var input = "{}"
    @State private var values: [String: String] = [:]
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run \(definition.name)").font(.title2.weight(.bold))
            Text("This creates durable work and runs the exact installed revision. It does not change email unless a later reviewed effect is approved.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Work title", text: $title)
            TextField("What should this run accomplish?", text: $request, axis: .vertical)
                .lineLimit(2...5)
            if formFields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Structured input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(6)
                        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Manual workflow JSON input")
                }
            } else {
                Form {
                    Section("Run input") {
                        WorkflowSchemaFormView(fields: formFields, values: $values)
                    }
                }
                .formStyle(.grouped)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow)
            }
            DesktopSheetActionBar(
                primaryTitle: "Start run",
                isPrimaryEnabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                dismiss: dismiss.callAsFunction,
                performPrimary: submit
            )
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            title = definition.name
            for field in formFields where values[field.pointer] == nil {
                guard let value = field.defaultJSON else { continue }
                if field.control == .picker { values[field.pointer] = value }
                else if let data = value.data(using: .utf8),
                        let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    values[field.pointer] = decoded as? String ?? String(describing: decoded)
                }
            }
        }
    }

    private var formFields: [DesktopWorkflowFormField] {
        guard let schema = revision?.manualRunInputSchema else { return [] }
        return DesktopWorkflowSchemaForm.fields(schemaText: schema, hints: revision?.uiHints ?? [])
    }

    private func submit() {
        guard let data = formFields.isEmpty ? input.data(using: .utf8) : encodedForm(),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            validationMessage = "Enter valid JSON input."
            return
        }
        if start(title, request, data) { dismiss() }
        else { validationMessage = "Kaname could not queue this run. Review the workflow readiness details." }
    }

    private func encodedForm() -> Data? {
        var object: [String: Any] = [:]
        for field in formFields {
            let raw = values[field.pointer] ?? ""
            if raw.isEmpty && !field.required { continue }
            let key = String(field.pointer.dropFirst()).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch field.type {
            case "boolean": object[key] = raw == "true"
            case "integer": guard let value = Int(raw) else { return nil }; object[key] = value
            case "number": guard let value = Double(raw) else { return nil }; object[key] = value
            default:
                if field.control == .picker, let data = raw.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    object[key] = decoded
                } else { object[key] = raw }
            }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct WorkflowMetricValue: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let tint: Color
}

private struct WorkflowMetricsRow: View {
    let metrics: [WorkflowMetricValue]

    var body: some View {
        Grid(horizontalSpacing: 8) {
            GridRow {
                ForEach(metrics) { metric in
                    LabeledContent {
                        Text(metric.value).font(.caption.weight(.semibold)).foregroundStyle(metric.tint)
                    } label: {
                        Text(metric.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct WorkflowDefinitionHeader: View {
    @ObservedObject var model: DesktopAppModel
    let definition: DesktopWorkflowDefinitionRecord

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12) {
            GridRow {
                Image(systemName: definition.icon)
                    .font(.title2)
                    .foregroundStyle(definition.enabled ? Nord.frost1 : .secondary)
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text(definition.name).font(.headline) }
                    GridRow { Text(definition.summary).font(.caption).foregroundStyle(.secondary) }
                    GridRow { Text("\(definition.source) · \(definition.license)").font(.caption2).foregroundStyle(.secondary) }
                }
                Toggle("Enabled", isOn: Binding(
                    get: { definition.enabled },
                    set: { _ = model.setWorkflowEnabled(id: definition.id, enabled: $0) }
                ))
            }
        }
    }
}

private struct WorkflowTriggerBindingRow: View {
    @ObservedObject var model: DesktopAppModel
    let binding: DesktopWorkflowTriggerBindingRecord
    let processExistingMatches: (() -> Void)?
    let rebaseline: (() -> Void)?

    var body: some View {
        let health = model.snapshot.operations.workflows.triggerHealth.first { $0.bindingID == binding.id }
        LabeledContent {
            HStack {
                if let processExistingMatches {
                    Button("Process existing…", action: processExistingMatches)
                        .help("Preview and create workflow episodes for existing provider matches without changing mail")
                }
                if let rebaseline {
                    Button("Rebaseline", action: rebaseline)
                        .help("Discard only the expired source cursor and establish a new baseline without replaying existing items")
                }
                Toggle("Observe", isOn: Binding(
                    get: { binding.enabled },
                    set: { _ = model.setWorkflowTriggerPaused(bindingID: binding.id, paused: !$0) }
                ))
                .labelsHidden()
            }
        } label: {
            Label {
                Grid(alignment: .leading, verticalSpacing: 2) {
                    GridRow { Text(binding.sourceFilter).font(.caption.weight(.semibold)) }
                    GridRow {
                        Text("\(binding.accountIDs.count) account scope · \(binding.lastCursor == nil ? "No cursor yet" : "Cursor established")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let health {
                        GridRow {
                            Text(health.state.label + (health.lastSuccessAtUnixMillis.map { " · last verified " + Date(timeIntervalSince1970: Double($0) / 1_000).formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(health.state == .actionRequired ? Nord.auroraYellow : .secondary)
                        }
                    }
                }
            } icon: {
                Image(systemName: binding.trigger == .calendar ? "calendar.badge.clock" : "line.3.horizontal.decrease.circle")
            }
        }
    }
}

private struct WorkflowStatePill: View {
    let state: DesktopWorkflowWorkState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(state.tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(state.tint.opacity(0.8), lineWidth: 1))
            .accessibilityLabel("Workflow status: \(state.label)")
    }
}

private extension DesktopWorkflowWorkState {
    var symbol: String {
        switch self {
        case .open: "circle"
        case .preparing: "hourglass"
        case .running: "waveform.path.ecg"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .readyForEffect: "checkmark.shield"
        case .waitingExternal: "envelope.badge"
        case .accepted: "checkmark.seal.fill"
        case .operationallyClosed: "archivebox.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        case .superseded: "arrow.uturn.forward.circle"
        }
    }

    var tint: Color {
        switch self {
        case .accepted: Nord.auroraGreen
        case .running, .preparing: Nord.frost1
        case .needsAttention, .readyForEffect: Nord.auroraYellow
        case .failed: Nord.auroraRed
        case .waitingExternal: Nord.frost0
        case .open, .operationallyClosed, .cancelled, .superseded: .secondary
        }
    }
}

private extension DesktopWorkflowStepKind {
    var symbol: String {
        switch self {
        case .classifyEvent: "text.magnifyingglass"
        case .correlateWork: "link"
        case .compileContext: "square.stack.3d.up"
        case .structuredModel: "brain"
        case .invokeTool: "wrench.and.screwdriver"
        case .registerArtifact: "doc.badge.plus"
        case .validate: "checkmark.shield"
        case .branch: "arrow.triangle.branch"
        case .match: "arrow.triangle.swap"
        case .forEach: "square.stack.3d.down.right"
        case .agent: "brain.head.profile"
        case .effect: "bolt.horizontal.circle"
        case .humanReview: "person.crop.circle.badge.questionmark"
        case .requestApproval: "hand.raised"
        case .createEmailDraft: "square.and.pencil"
        case .sendEmail: "paperplane"
        case .waitForEmail: "envelope.badge"
        case .complete: "checkmark.circle"
        }
    }
}

private extension DesktopWorkflowPermission {
    var symbol: String {
        switch self {
        case .emailRead: "envelope.open"
        case .emailDraft: "square.and.pencil"
        case .emailSend: "paperplane"
        case .emailLabels: "tag"
        case .fileRead: "doc.text.magnifyingglass"
        case .fileWrite: "doc.badge.arrow.up"
        case .modelEgress: "brain"
        case .network: "network"
        case .externalEffects: "bolt.horizontal.circle"
        }
    }
}

private struct NewMailRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var mail: DesktopMailViewModel
    let accounts: [NativeGoogleAccountSnapshot]
    @State private var accountID: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Gmail standing rule").font(.title2.weight(.bold))
            Text("This saves the current tested query as reversible archive authority for one account. It never covers Trash or Send.")
                .foregroundStyle(.secondary)
            Picker("Account", selection: $accountID) {
                Text("Choose account").tag(String?.none)
                ForEach(accounts) { Text($0.identity).tag(Optional($0.id)) }
            }
            TextField("Rule name", text: $name).textFieldStyle(.roundedBorder)
            LabeledContent("Gmail query", value: mail.query)
            LabeledContent("Action", value: "Archive")
            DesktopSheetActionBar(
                primaryTitle: "Save rule",
                isPrimaryEnabled: accountID != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                dismiss: dismiss.callAsFunction
            ) {
                    guard let account = accounts.first(where: { $0.id == accountID }) else { return }
                    mail.createStandingRule(model: model, account: account, name: name, action: .archive)
                    dismiss()
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 560)
        .onAppear { accountID = accountID ?? accounts.first?.id }
    }
}

private struct DesktopSheetActionBar: View {
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let dismiss: () -> Void
    let performPrimary: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: performPrimary)
                .buttonStyle(.borderedProminent)
                .disabled(!isPrimaryEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct DesktopCalendarView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @StateObject private var calendar = DesktopCalendarViewModel()
    @State private var showsProposal = false
    @State private var eventEditRequest: CalendarEventEditRequest?

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
                    HStack(spacing: 8) {
                        Button("Refresh events", systemImage: "arrow.clockwise") {
                            calendar.refresh(
                                sources: model.snapshot.domains.calendarSources,
                                googleAccounts: integrations.googleAccounts
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(calendar.isBusy || model.snapshot.domains.calendarSources.filter(\.isEnabled).isEmpty)
                        Button("Propose event", systemImage: "calendar.badge.plus") { showsProposal = true }
                            .buttonStyle(.borderedProminent)
                    }
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        AccountStrip(accounts: accounts)
                        BoundaryCallout(
                            title: "Exact calendar authority",
                            detail: "Refresh is read-only. Create, change, and delete bind the exact account, calendar, event revision, recurrence scope, and resolved event fields before approval."
                        )
                        if !model.snapshot.domains.calendarSources.isEmpty {
                            SectionHeading(
                                title: "Visible calendars",
                                detail: "These private visibility choices never hide or delete calendars at the provider."
                            )
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                                ForEach(model.snapshot.domains.calendarSources) { source in
                                    CalendarSourceVisibilityCard(model: model, source: source)
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Label(
                        "Accounts & visible calendars",
                        systemImage: "calendar.badge.checkmark"
                    )
                    .font(.headline)
                }
                .panelStyle()

                SectionHeading(
                    title: "Upcoming events",
                    detail: "Read the next 90 days across enabled sources. Duplicate provider identities collapse before display."
                )
                if calendar.isBusy, calendar.events.isEmpty {
                    ProgressView("Reading enabled calendars…").frame(maxWidth: .infinity, minHeight: 180)
                } else if calendar.events.isEmpty {
                    EmptyPanel(symbol: "calendar", title: "Agenda not loaded", detail: "Refresh events when you want Kaname to read the enabled Google and Apple calendars.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                        ForEach(calendar.events) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: event.provider == .apple ? "apple.logo" : "g.circle.fill")
                                        .foregroundStyle(Nord.frost1)
                                    Text(event.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    if event.recurringEventID != nil { Image(systemName: "repeat").foregroundStyle(.secondary) }
                                }
                                Text(Date(timeIntervalSince1970: Double(event.startAtUnixMillis) / 1_000).formatted(date: .abbreviated, time: .shortened))
                                    .font(.title3.weight(.semibold))
                                Text("\(event.accountIdentity) · \(event.timeZoneIdentifier)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if event.sourceProvenance.count > 1 {
                                    Label("Shown once from \(event.sourceProvenance.count) linked sources", systemImage: "link")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if event.provider == .google, !event.canEdit {
                                    Label("Reconnect this Google account in Settings to enable approved event changes.", systemImage: "person.crop.circle.badge.exclamationmark")
                                        .font(.caption).foregroundStyle(Nord.auroraYellow)
                                }
                                HStack {
                                    Button("Change") { eventEditRequest = CalendarEventEditRequest(event: event, kind: .update) }
                                    Button("Delete", role: .destructive) { eventEditRequest = CalendarEventEditRequest(event: event, kind: .delete) }
                                }
                                .disabled(!event.canEdit || source(for: event)?.accessLevel.lowercased().contains("reader") == true)
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
                                LabeledContent(
                                    proposal.isAllDay == true ? "All-day span" : "Duration",
                                    value: proposal.isAllDay == true
                                        ? "\(max(1, proposal.durationMinutes / 1_440)) day(s)"
                                        : "\(proposal.durationMinutes) minutes"
                                )
                                LabeledContent("Pinned zone", value: proposal.timeZoneIdentifier)
                                LabeledContent("Recurrence", value: proposal.recurrence)
                                if let scope = proposal.recurrenceScope.flatMap(CalendarRecurrenceScope.init(rawValue:)) {
                                    LabeledContent("Scope", value: scope.label)
                                }
                                if proposal.status == .running, let phase = proposal.mutationPhase {
                                    LabeledContent("Recovery phase", value: phase.replacingOccurrences(of: "Applied", with: " applied").capitalized)
                                }
                                if let receipt = proposal.remoteReceipt {
                                    Text(receipt).foregroundStyle(proposal.status == .failed ? Nord.auroraRed : Nord.auroraGreen)
                                }
                                calendarProposalAction(proposal)
                            }
                            .font(.caption)
                            .panelStyle()
                        }
                    }
                }
                if !calendar.failedSources.isEmpty {
                    BoundaryCallout(title: "Partial calendar refresh", detail: "Other sources remain usable. Retry: \(calendar.failedSources.joined(separator: ", ")).")
                }
                if let message = calendar.message { BoundaryCallout(title: "Calendar status", detail: message) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0)
        .sheet(isPresented: $showsProposal) {
            NewCalendarProposalSheet(model: model)
        }
        .sheet(item: $eventEditRequest) { request in
            CalendarEventMutationSheet(
                request: request,
                source: source(for: request.event),
                model: model,
                calendar: calendar,
                googleAccounts: integrations.googleAccounts
            )
        }
    }

    @ViewBuilder
    private func calendarProposalAction(_ proposal: DesktopCalendarProposal) -> some View {
        let approval = proposal.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
        if proposal.status == .proposed,
           let source = model.snapshot.domains.calendarSources.first(where: { $0.id == proposal.calendarSourceID }) {
            Button("Review create") {
                calendar.proposeCreate(model: model, proposal: proposal, source: source, googleAccounts: integrations.googleAccounts)
            }
            .buttonStyle(.borderedProminent)
        } else if proposal.status == .needsReview {
            Button("Request approval") {
                calendar.selectProposal(proposal.id)
                calendar.requestApproval(model: model)
            }
            .buttonStyle(.borderedProminent)
        } else if approval?.state == .approved {
            Button(proposal.status == .running ? "Reconcile action" : "Apply approved action") {
                executeCalendarProposal(proposal)
            }
            .buttonStyle(.borderedProminent)
            .disabled(calendar.isBusy)
        } else if proposal.status == .waiting {
            Label("Waiting in Inbox", systemImage: "tray.full").foregroundStyle(Nord.auroraYellow)
        } else if proposal.status == .failed,
                  let source = model.snapshot.domains.calendarSources.first(where: { $0.id == proposal.calendarSourceID }) {
            Button("Review again") {
                calendar.selectProposal(proposal.id)
                calendar.prepareAgain(model: model, proposal: proposal, source: source, googleAccounts: integrations.googleAccounts)
            }
            .buttonStyle(.bordered)
        }
    }

    private func executeCalendarProposal(_ proposal: DesktopCalendarProposal) {
        calendar.selectProposal(proposal.id)
        calendar.execute(
            model: model,
            sources: model.snapshot.domains.calendarSources,
            googleAccounts: integrations.googleAccounts
        )
    }

    private func source(for event: CalendarEventSnapshot) -> DesktopCalendarSourceRecord? {
        model.snapshot.domains.calendarSources.first {
            $0.externalIdentifier == event.calendarID
                && $0.provider.rawValue == event.provider.rawValue
                && $0.ownerIdentity == event.accountIdentity
        }
    }
}

private struct CalendarSourceVisibilityCard: View {
    @ObservedObject var model: DesktopAppModel
    let source: DesktopCalendarSourceRecord

    var body: some View {
        LabeledContent {
            Toggle(
                "Visible",
                isOn: Binding(
                    get: { source.isEnabled },
                    set: { model.setCalendarSourceEnabled(id: source.id, enabled: $0) }
                )
            )
            .labelsHidden()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName).font(.subheadline.weight(.semibold))
                    Text("\(source.ownerIdentity) · \(source.accessLevel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: source.provider == .apple ? "apple.logo" : "g.circle.fill")
                    .foregroundStyle(source.isEnabled ? Nord.frost1 : .secondary)
            }
        }
        .padding(12)
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CalendarEventEditRequest: Identifiable {
    let id = UUID()
    let event: CalendarEventSnapshot
    let kind: DesktopCalendarProposal.MutationKind
}

private struct CalendarEventMutationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: CalendarEventEditRequest
    let source: DesktopCalendarSourceRecord?
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var calendar: DesktopCalendarViewModel
    let googleAccounts: [NativeGoogleAccountSnapshot]
    @State private var title: String
    @State private var start: Date
    @State private var durationMinutes: Int
    @State private var scope: CalendarRecurrenceScope

    init(
        request: CalendarEventEditRequest,
        source: DesktopCalendarSourceRecord?,
        model: DesktopAppModel,
        calendar: DesktopCalendarViewModel,
        googleAccounts: [NativeGoogleAccountSnapshot]
    ) {
        self.request = request
        self.source = source
        self.model = model
        self.calendar = calendar
        self.googleAccounts = googleAccounts
        _title = State(initialValue: request.event.title)
        _start = State(initialValue: Date(timeIntervalSince1970: Double(request.event.startAtUnixMillis) / 1_000))
        _durationMinutes = State(initialValue: max(1, Int((request.event.endAtUnixMillis - request.event.startAtUnixMillis) / 60_000)))
        _scope = State(initialValue: request.event.recurringEventID == nil ? .thisEvent : .thisEvent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.kind == .delete ? "Review event deletion" : "Propose event change").font(.title2.weight(.bold))
            Text("Nothing changes yet. Kaname binds the current event revision and recurrence scope before approval.")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("Calendar", value: source.map { "\($0.displayName) · \($0.ownerIdentity)" } ?? "Source unavailable")
                if request.kind == .update {
                    TextField("Title", text: $title)
                    DatePicker(
                        request.event.isAllDay ? "Date" : "Start",
                        selection: $start,
                        displayedComponents: request.event.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    if request.event.isAllDay {
                        Stepper("Span: \(max(1, durationMinutes / 1_440)) day(s)", value: $durationMinutes, in: 1_440...10_080, step: 1_440)
                    } else {
                        Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 5...10_080, step: 5)
                    }
                } else {
                    LabeledContent("Event", value: request.event.title)
                    LabeledContent("Starts", value: start.formatted())
                }
                if request.event.recurringEventID != nil {
                    Picker("Recurrence scope", selection: $scope) {
                        ForEach(CalendarRecurrenceScope.allCases.filter {
                            source?.provider != .apple || $0 != .entireSeries
                        }, id: \.self) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent("Recurrence scope", value: CalendarRecurrenceScope.thisEvent.label)
                }
                if scope == .thisAndFuture {
                    Label("Kaname validates the provider's recurrence before approval. Unsupported finite Google series are refused; Apple uses its native future-events span.", systemImage: "scissors")
                        .font(.caption).foregroundStyle(Nord.auroraYellow)
                }
                if source?.provider == .apple, request.event.recurringEventID != nil {
                    Text("EventKit does not expose a safe whole-series operation, so Apple Calendar offers only this event or this and future events.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(request.kind == .delete ? "Review deletion" : "Review change") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 600, idealHeight: 470)
    }

    private func save() {
        guard let source else { return }
        var pinnedCalendar = Calendar(identifier: .gregorian)
        pinnedCalendar.timeZone = TimeZone(identifier: request.event.timeZoneIdentifier) ?? .autoupdatingCurrent
        let normalizedStart = request.event.isAllDay ? pinnedCalendar.startOfDay(for: start) : start
        let startMillis = Int64(normalizedStart.timeIntervalSince1970 * 1_000)
        let factory = request.event.isAllDay ? CalendarEventDraft.allDay : CalendarEventDraft.timed
        let draft = factory(
            title,
            startMillis,
            startMillis + Int64(durationMinutes) * 60_000,
            request.event.timeZoneIdentifier,
            request.event.recurrence.first ?? (request.event.recurringEventID == nil ? "Does not repeat" : "Recurring")
        )
        calendar.proposeChange(
            model: model,
            event: request.event,
            source: source,
            kind: request.kind,
            scope: request.event.recurringEventID == nil ? .thisEvent : scope,
            draft: draft,
            googleAccounts: googleAccounts
        )
        dismiss()
    }
}

private struct DesktopAutomationsView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var scheduler: DesktopAutomationSchedulerViewModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel

    var body: some View {
        Group {
            if CommandLine.arguments.contains("--desktop-automation-workflows-prototype") {
                AutomationWorkflowDesignPreview()
            } else {
                AutomationWorkflowProductView(
                    model: model,
                    scheduler: scheduler,
                    integrations: integrations
                )
            }
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
    @State private var query = ""

    private var filteredSkills: [DesktopSkillRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.snapshot.domains.skills }
        return model.snapshot.domains.skills.filter {
            $0.name.lowercased().contains(normalized)
                || $0.kind.label.lowercased().contains(normalized)
                || $0.scope.lowercased().contains(normalized)
                || $0.source.lowercased().contains(normalized)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Section {
                    if filteredSkills.isEmpty {
                        EmptyPanel(
                            symbol: "hammer",
                            title: "No matching skills or tools",
                            detail: "Search by name, kind, source, or scope."
                        )
                        .frame(minHeight: 220)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                            ForEach(filteredSkills) { skill in
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
                    }
                    BoundaryCallout(
                        title: "Updates are reviewable",
                        detail: "Behavioral instructions and executables are pinned with source, revision, licence, requested capabilities, and a diff before installation or activation."
                    )
                } header: {
                    SurfaceHeader(
                        title: "Skills & Tools",
                        detail: "Progressive disclosure, provenance, scope, permissions, and update review",
                        symbol: DesktopDestination.skills.symbol
                    ) {
                        TextField("Search skills and tools", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .accessibilityLabel("Search skills and tools")
                    }
                }
            }
            .padding(22)
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
    let startConversation: (String?) -> Void
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
                        tint: Nord.frost1
                    )
                    codingPulse(
                        title: "Needs input",
                        value: model.activeThreads.filter {
                            $0.kind == .coding && ($0.attention == .needsInput || $0.attention == .needsApproval)
                        }.count,
                        symbol: "person.crop.circle.badge.questionmark",
                        tint: Nord.auroraYellow
                    )
                    codingPulse(
                        title: "Worktrees",
                        value: model.snapshot.operations.worktrees.filter { $0.state != .removed }.count,
                        symbol: "arrow.triangle.branch",
                        tint: Nord.frost2
                    )
                    codingPulse(
                        title: "Checks",
                        value: model.snapshot.operations.qualityGates.count,
                        symbol: "checkmark.seal.fill",
                        tint: Nord.auroraGreen
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
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
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
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            DesktopSettingsView(
                model: model,
                integrations: integrations,
                updates: updates,
                automaticBackup: automaticBackup,
                dismiss: dismiss
            )
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
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    @State private var draft: DesktopPreferences
    private let explicitDismiss: (() -> Void)?

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        automaticBackup: DesktopAutomaticBackupViewModel,
        dismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        self.automaticBackup = automaticBackup
        explicitDismiss = dismiss
        _draft = State(initialValue: model.snapshot.preferences)
    }

    var body: some View {
        DesktopSettingsShell(
            model: model,
            integrations: integrations,
            updates: updates,
            automaticBackup: automaticBackup,
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    private enum Category: String, CaseIterable, Identifiable {
        case general, commands, integrations, providers, updates, calendars, scheduling, privacy, backups, diagnostics
        private struct Presentation {
            let label: String
            let symbol: String
            let detail: String
        }
        var id: String { rawValue }
        private var presentation: Presentation {
            switch self {
            case .general: .init(label: "General", symbol: "gearshape.fill", detail: "Workspace presentation and review defaults")
            case .commands: .init(label: "Commands & Shortcuts", symbol: "command", detail: "Keyboard-first navigation and the Kaname Command Center")
            case .integrations: .init(label: "Integrations", symbol: "link", detail: "Personal services, account health, and explicit authorization")
            case .providers: .init(label: "Coding providers", symbol: "chevron.left.forwardslash.chevron.right", detail: "Local coding agents available to Kaname")
            case .updates: .init(label: "Updates", symbol: "arrow.triangle.2.circlepath.circle.fill", detail: "Verified switching, health checks, and rollback")
            case .calendars: .init(label: "Calendars", symbol: "calendar", detail: "Choose which connected calendars Kaname may show")
            case .scheduling: .init(label: "Scheduling", symbol: "clock.fill", detail: "Stable wall-clock behavior when you travel")
            case .privacy: .init(label: "Privacy & Safety", symbol: "lock.shield.fill", detail: "Notification content and execution authority")
            case .backups: .init(label: "Backup & Restore", symbol: "externaldrive.badge.icloud", detail: "Opt-in encrypted local, R2, or S3 recovery generations")
            case .diagnostics: .init(label: "Diagnostics", symbol: "lifepreserver.fill", detail: "Retention and privacy-safe support information")
            }
        }
        var label: String { presentation.label }
        var symbol: String { presentation.symbol }
        var detail: String { presentation.detail }
    }

    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    @ObservedObject var updates: DesktopUpdateViewModel
    @ObservedObject var automaticBackup: DesktopAutomaticBackupViewModel
    @Binding var draft: DesktopPreferences
    let dismiss: () -> Void
    @State private var category: Category = .general
    @State private var settingsQuery = ""
    @State private var showsUpdateInstallConfirmation = false
    @StateObject private var recoveryActions = DesktopRecoveryViewModel()
    @FocusState private var focusedCategory: Category?

    init(
        model: DesktopAppModel,
        integrations: DesktopPersonalIntegrationViewModel,
        updates: DesktopUpdateViewModel,
        automaticBackup: DesktopAutomaticBackupViewModel,
        draft: Binding<DesktopPreferences>,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.integrations = integrations
        self.updates = updates
        self.automaticBackup = automaticBackup
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
        .frame(minWidth: 720, idealWidth: 940, maxWidth: 1_040, minHeight: 480, idealHeight: 640, maxHeight: 660)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kaname settings")
        .onAppear {
            DispatchQueue.main.async { focusedCategory = category }
            if category == .updates { updates.checkForUpdates(manual: false) }
        }
        .onChange(of: category) { selected in
            if selected == .updates { updates.checkForUpdates(manual: false) }
        }
        .onChange(of: settingsQuery) { _ in
            if !filteredCategories.contains(category), let first = filteredCategories.first {
                category = first
            }
        }
        .alert(
            updateInstallConfirmationTitle,
            isPresented: $showsUpdateInstallConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Install and relaunch") { updates.switchAndRelaunch(model: model) }
        } message: {
            Text("Kaname will checkpoint the current UI, install the verified staged build, and relaunch. An active approval or a workspace persistence error blocks the switch, and a failed health check automatically restores the previous app.")
        }
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Settings", systemImage: "gearshape.fill")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            TextField("Search settings", text: $settingsQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .accessibilityLabel("Search settings categories")
            ForEach(filteredCategories) { item in
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
                .focused($focusedCategory, equals: item)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer()
            Button("Return to Kaname", systemImage: "arrow.left", action: dismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .frame(
            minWidth: usesAccessibilityTextLayout ? 230 : 180,
            idealWidth: usesAccessibilityTextLayout ? 260 : 205,
            maxWidth: usesAccessibilityTextLayout ? 290 : 230
        )
        .background(Nord.polarNight1)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack { footerStatus; Spacer(); refreshStatusButton }
            VStack(alignment: .leading, spacing: 8) {
                footerStatus
                refreshStatusButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
    }

    private var updateInstallConfirmationTitle: String {
        let version = updates.receipt.version ?? "the staged update"
        let build = updates.receipt.build.map { " (\($0))" } ?? ""
        return "Install Kaname \(version)\(build)?"
    }

    private var footerStatus: some View {
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
    }

    private var refreshStatusButton: some View {
        Button("Refresh all status", systemImage: "arrow.clockwise") {
            integrations.refreshAllStatus(model: model)
        }
    }

    private var usesAccessibilityTextLayout: Bool {
        usesQALargeText || dynamicTypeSize.isAccessibilitySize
    }

    private var filteredCategories: [Category] {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Category.allCases }
        return Category.allCases.filter {
            $0.label.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
        }
    }

    private var pageDetail: String {
        category.detail
    }

    @ViewBuilder private var categoryPage: some View {
        switch category {
        case .general: generalPage
        case .commands: commandsPage
        case .integrations: integrationsPage
        case .providers: providersPage
        case .updates: updatesPage
        case .calendars: calendarsPage
        case .scheduling: schedulingPage
        case .privacy: privacyPage
        case .backups: DesktopAutomaticBackupSettings(model: model, backup: automaticBackup)
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

    private var commandsPage: some View {
        SettingsSection(title: "Commands & shortcuts", symbol: "command") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Create and find").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                LabeledContent("Command Center", value: "⌘K")
                LabeledContent("New conversation draft", value: "⌘N")
                LabeledContent("Focus current composer", value: "⌘L")
                GridRow {
                    Text("Navigate and steer").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                LabeledContent("Home / Threads / Inbox / Projects", value: "⌘1 / ⌘2 / ⌘3 / ⌘4")
                LabeledContent("Back", value: "⌘[")
                LabeledContent("Toggle inspector", value: "⌘⌥I")
                LabeledContent("Interrupt current run", value: "⌘.")
                LabeledContent("Retry current turn", value: "⌘⇧R")
                GridRow {
                    Text("Contextual behavior").font(.subheadline.weight(.semibold))
                    Color.clear.frame(height: 1)
                }
                Text("Type > in the Command Center to find local actions. Plain text searches saved conversations, projects, domains, approvals, and artifacts without contacting a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
                Text("The default new-conversation path uses the selected project's kind, provider, model, and safe authority. Choose Configure new conversation from the toolbar menu or Command Center when you need to override them before opening the draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
            }
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
                if integrations.googleAccountLoadFailure != nil,
                   integrations.googleAccounts.isEmpty {
                    Button("Retry saved accounts", systemImage: "arrow.clockwise") {
                        integrations.retrySavedGoogleAccounts(model: model)
                    }
                } else {
                    Button(
                        integrations.googleAccounts.isEmpty ? "Connect Google" : "Add account",
                        systemImage: "person.badge.plus"
                    ) {
                        integrations.connectGoogleAccount(model: model)
                    }
                    .disabled(!integrations.hasGoogleClientConfiguration)
                }
                if !integrations.googleAccounts.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { integrations.refreshGoogle(model: model) }
                }
            } details: {
                if let loadFailure = integrations.googleAccountLoadFailure,
                   integrations.googleAccounts.isEmpty {
                    Text(loadFailure)
                        .font(.caption).foregroundStyle(.secondary)
                } else if integrations.googleAccounts.isEmpty {
                    Text(integrations.hasGoogleClientConfiguration
                        ? "Connect Google opens the system browser, asks for Gmail read/manage/compose plus Calendar list and event access, and returns directly to Kaname. Existing Google accounts must reconnect once before newer mail or approved Calendar changes can run."
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
            SettingsSection(title: "Update availability", symbol: "arrow.down.circle.fill") {
                LabeledContent("Installed", value: updates.currentVersionLabel)
                LabeledContent("Discovery", value: updates.discoveryStatus.rawValue.capitalized)
                if updates.environment.channel == .stable {
                    Toggle("Check the private local catalog automatically", isOn: Binding(
                        get: { updates.discoveryPreferences.automaticChecksEnabled },
                        set: { updates.setAutomaticChecksEnabled($0) }
                    ))
                    Text("Automatic checks run 15 seconds after launch and every four minutes while stable Kaname remains open. Activation and opening Updates check when the four-minute interval has elapsed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let checkedAt = updates.discoveryPreferences.lastSuccessAtUnixMillis {
                        LabeledContent(
                            "Last successful check",
                            value: Date(timeIntervalSince1970: Double(checkedAt) / 1_000).formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    HStack {
                        Button("Check now", systemImage: "arrow.clockwise") { updates.checkForUpdates(manual: true) }
                            .disabled(updates.isChecking || updates.isBusy)
                        if updates.discoveryStatus == .deferred {
                            Button("Review now", systemImage: "eye") { updates.reviewAvailableUpdate() }
                        }
                        if updates.discoveryStatus == .skipped {
                            Button("Unskip", systemImage: "arrow.uturn.backward") { updates.unskipAvailableUpdate() }
                        }
                    }
                    if let update = updates.availableUpdate,
                       updates.discoveryStatus != .deferred,
                       updates.discoveryStatus != .skipped {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Kaname \(update.version) (\(update.build))", systemImage: "shippingbox.fill")
                                .font(.headline)
                            LabeledContent("Source", value: update.sourceLabel)
                            LabeledContent("Published", value: Date(timeIntervalSince1970: Double(update.publishedAtUnixMillis) / 1_000).formatted(date: .abbreviated, time: .shortened))
                            Text(update.releaseNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Download update", systemImage: "arrow.down.circle") {
                                    updates.verifyAndStageAvailable()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(updates.isBusy || updates.discoveryStatus == .skipped)
                                Button("Remind me in 24 hours", systemImage: "clock") { updates.deferAvailableUpdate() }
                                    .disabled(updates.isBusy)
                            }
                            Button("Skip this exact build", systemImage: "forward.end") { updates.skipAvailableUpdate() }
                                .disabled(updates.isBusy)
                        }
                        .padding(12)
                        .background(Nord.polarNight2.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Label("Candidate never reads, publishes, or stages the stable update catalog.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(Nord.frost1)
                }
            }
            SettingsSection(title: "Update continuity", symbol: "arrow.triangle.2.circlepath.circle.fill") {
                LabeledContent("Channel", value: updates.environment.displayName)
                LabeledContent("State", value: updates.receipt.status.rawValue.capitalized)
                if let version = updates.receipt.version {
                    LabeledContent("Ready", value: "\(version) (\(updates.receipt.build ?? "—"))")
                }
                Text(updates.receipt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(
                    "Verification is same-signer, forward-only, and digest-bound.",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(Nord.frost1)
                if let releaseNotes = updates.receipt.releaseNotes,
                   !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Release notes") {
                        Text(releaseNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(10)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                if updates.environment.channel == .stable {
                    Grid(horizontalSpacing: 8) {
                        GridRow {
                            Button("Choose update manually…", systemImage: "folder") { updates.chooseAndStage() }
                                .disabled(updates.isBusy)
                            Button("Install and relaunch", systemImage: "arrow.clockwise") {
                                showsUpdateInstallConfirmation = true
                            }
                            .disabled(updates.isBusy || updates.receipt.status != .staged)
                            Button("Rollback", systemImage: "arrow.uturn.backward") { updates.rollback(model: model) }
                                .disabled(updates.isBusy || !updates.canRollback)
                        }
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
            HStack {
                Button("Inspect diagnostics…", systemImage: "doc.text.magnifyingglass") {
                    NotificationCenter.default.post(name: .kanamePresentDiagnostics, object: nil)
                }
                Button("Export verified backup…", systemImage: "externaldrive.badge.plus") {
                    recoveryActions.exportBackup(model: model)
                }
            }
            if let message = recoveryActions.message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Diagnostics are inspect-before-copy/export and include counts and health only. They exclude content, identities, paths, and credentials. Backups and crash information are never uploaded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Factory reset is available only from the read-only Recovery Center and only after a backup validates successfully.")
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

    private var connected: Bool { snapshot?.state == .ready }
    private var needsAttention: Bool {
        snapshot?.state == .authenticationRequired || snapshot?.state == .degraded
    }
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
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    @State private var panel: Panel = .outline
    @State private var activityPanel: ActivityPanel = .summary
    @State private var activitySearch = ""
    @State private var activityEventLimit = 400

    private enum Panel: String, CaseIterable, Identifiable {
        case outline
        case context
        var id: String { rawValue }
    }

    private enum ActivityPanel: String, CaseIterable, Identifiable {
        case summary
        case timeline
        case raw
        var id: String { rawValue }
    }

    private var selectedSummary: DesktopConversationRunSummary? {
        guard let selectedRunID,
              let run = model.providerRun(id: selectedRunID),
              run.threadID == thread.id else { return nil }
        return DesktopConversationRunSummary(
            run: run,
            events: model.providerEvents(threadID: thread.id).filter { $0.runID == selectedRunID }
        )
    }

    var body: some View {
        Group {
            if let selectedSummary {
                activityInspector(selectedSummary)
            } else {
                threadInspector
            }
        }
        .onChange(of: thread.id) { _ in
            selectedRunID = nil
            conversationAnchorID = nil
        }
        .onChange(of: selectedRunID) { _ in
            activityPanel = .summary
            activitySearch = ""
            activityEventLimit = 400
        }
    }

    private var threadInspector: some View {
        VStack(spacing: 0) {
            Picker("Thread inspector", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch panel {
                    case .outline: outline
                    case .context: context
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private var outline: some View {
        InspectorTitle(title: "Conversation outline", symbol: "list.bullet.indent")

        VStack(alignment: .leading, spacing: 10) {
            Text("Thread brief").font(.headline)
            if let goal = thread.messages.first(where: { $0.role == .user })?.body {
                Text("Goal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(goal).font(.subheadline).lineLimit(4)
            }
            Text("Current status").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(thread.summary.isEmpty ? "No current summary." : thread.summary)
                .font(.subheadline).foregroundStyle(.secondary)
            Divider()
            InspectorFact(label: "Messages", value: "\(thread.messages.count)")
            InspectorFact(label: "Runs", value: "\(model.providerRuns(threadID: thread.id).count)")
            InspectorFact(
                label: "Recorded activity",
                value: "\(model.providerEvents(threadID: thread.id).filter { !$0.kind.isTransportOnly }.count)"
            )
        }
        .panelStyle()

        VStack(alignment: .leading, spacing: 8) {
            Text("Turns").font(.headline)
            let userMessages = thread.messages.filter { $0.role == .user }
            if userMessages.isEmpty {
                Text("No user turns yet.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(userMessages.suffix(40).enumerated()), id: \.element.id) { index, message in
                    Button {
                        conversationAnchorID = message.id
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(max(1, userMessages.count - min(40, userMessages.count) + index + 1))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .trailing)
                            Text(message.body)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .accessibilityHint("Jump to this turn in the conversation")
                }
            }
        }
        .panelStyle()

        let runs = DesktopConversationNarrativePresentation.runSummaries(
            runs: model.providerRuns(threadID: thread.id),
            events: model.providerEvents(threadID: thread.id)
        )
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent runs").font(.headline)
                ForEach(runs.suffix(12)) { summary in
                    Button {
                        selectedRunID = summary.id
                    } label: {
                        DesktopInspectorRunLabel(summary: summary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .panelStyle()
        }
    }

    @ViewBuilder private var context: some View {
        InspectorTitle(title: "Thread context", symbol: "sidebar.right")
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.title).font(.headline)
            AttentionPill(attention: thread.attention)
            Divider()
            InspectorFact(label: "Kind", value: thread.kind.label)
            InspectorFact(label: "Provider", value: thread.provider)
            InspectorFact(label: "Model", value: thread.model)
            InspectorFact(label: "Project", value: model.project(id: thread.projectID)?.name ?? "Standalone")
        }
        .panelStyle()

        VStack(alignment: .leading, spacing: 10) {
            Text("Plan").font(.headline)
            if thread.plan.isEmpty {
                Text("No plan recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(thread.plan) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.state.symbol).foregroundStyle(item.state.tint)
                        Text(item.title).font(.subheadline)
                    }
                }
            }
        }
        .panelStyle()

        let artifacts = model.snapshot.operations.artifacts.filter { $0.threadID == thread.id }
        VStack(alignment: .leading, spacing: 10) {
            Text("Artifacts").font(.headline)
            if artifacts.isEmpty {
                Text("No artifacts attached.").foregroundStyle(.secondary)
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
            Text("Thread actions").font(.headline)
            Button("Mark complete") { model.setAttention(threadID: thread.id, attention: .completed) }
                .disabled(thread.attention == .completed)
            Button("Archive", role: .destructive) {
                model.setAttention(threadID: thread.id, attention: .archived)
            }
        }
        .panelStyle()
    }

    private func activityInspector(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(spacing: 0) {
            Button {
                selectedRunID = nil
            } label: {
                Label("Outline", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                Text(summary.run.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.run.state.tint)
            }
            .padding(14)

            Picker("Run activity", selection: $activityPanel) {
                ForEach(ActivityPanel.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            if activityPanel == .timeline {
                DesktopInspectorSearchField(text: $activitySearch, placeholder: "Filter this run")
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorTitle(title: "Run activity", symbol: "list.bullet.rectangle")
                    switch activityPanel {
                    case .summary: runSummary(summary)
                    case .timeline: runTimeline(summary)
                    case .raw: runRawEvidence(summary)
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private func runSummary(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.run.provider).font(.headline)
            Text(summary.run.model).font(.subheadline).foregroundStyle(.secondary)
            Divider()
            InspectorFact(label: "Activity", value: "\(summary.activityCount)")
            InspectorFact(label: "Tools", value: "\(summary.toolCount)")
            InspectorFact(label: "Diff updates", value: "\(summary.diffCount)")
            InspectorFact(label: "Reasoning", value: "\(summary.reasoningCount)")
            if let duration = summary.durationLabel { InspectorFact(label: "Duration", value: duration) }
            if let usage = summary.run.tokenUsage { InspectorFact(label: "Tokens", value: "\(usage)") }
        }
        .panelStyle()

        if let error = summary.run.errorSummary, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Nord.auroraRed)
                .textSelection(.enabled)
                .panelStyle()
        }
    }

    @ViewBuilder private func runTimeline(_ summary: DesktopConversationRunSummary) -> some View {
        let query = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? summary.events : summary.events.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.nativeType.localizedCaseInsensitiveContains(query)
        }
        let visible = Array(matching.suffix(activityEventLimit))
        if matching.isEmpty {
            Text(query.isEmpty ? "No provider activity was recorded for this run." : "No activity matches this filter.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                if matching.count > visible.count {
                    Button("Show \(min(400, matching.count - visible.count)) older events") {
                        activityEventLimit += 400
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                ForEach(visible) { event in
                    DesktopInspectorProviderEventRow(event: event)
                }
            }
        }
    }

    @ViewBuilder private func runRawEvidence(_ summary: DesktopConversationRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider identifiers").font(.headline)
            InspectorFact(label: "Run", value: summary.run.id)
            if let value = summary.run.nativeThreadID { InspectorFact(label: "Native thread", value: value) }
            if let value = summary.run.nativeTurnID { InspectorFact(label: "Native turn", value: value) }
            InspectorFact(label: "Brief digest", value: summary.run.briefDigest)
        }
        .textSelection(.enabled)
        .panelStyle()

        let evidenceArtifacts = model.snapshot.operations.artifacts.filter {
            $0.threadID == thread.id && $0.localPath.contains(summary.run.id)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Immutable evidence").font(.headline)
            if evidenceArtifacts.isEmpty {
                Text(summary.run.state == .running
                    ? "The sealed evidence log appears when this run finishes."
                    : "No sealed evidence artifact is registered for this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidenceArtifacts) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(artifact.name, systemImage: "doc.badge.gearshape")
                            .font(.caption.weight(.semibold))
                        Text(artifact.localPath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("SHA-256 \(artifact.digest)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            if summary.payloadWasTruncated {
                Label("One or more in-workspace payloads were capped; the sealed evidence log remains authoritative.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Nord.auroraYellow)
            }
        }
        .panelStyle()
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

private struct DesktopInspectorRunLabel: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            DesktopInspectorRunTitle(summary: summary)
            DesktopInspectorRunActivity(summary: summary)
        }
    }
}

private struct DesktopInspectorRunTitle: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        Label(summary.run.provider, systemImage: summary.run.state.accessibilitySymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(summary.run.state.tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct DesktopInspectorRunActivity: View {
    let summary: DesktopConversationRunSummary

    var body: some View {
        Text(summary.conciseActivityLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 24)
    }
}

private struct DesktopInspectorProviderEventRow: View {
    let event: DesktopProviderEventRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DesktopInspectorProviderEventTitle(event: event)
            DesktopInspectorProviderEventDetail(event: event)
        }
        .padding(8)
        .background(event.kind.timelineTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct DesktopInspectorProviderEventTitle: View {
    let event: DesktopProviderEventRecord

    var body: some View {
        Text(event.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(event.kind.timelineTint)
            .padding(.leading, 26)
            .overlay(alignment: .leading) {
                Image(systemName: event.kind.timelineSymbol)
                    .frame(width: 18)
            }
            .overlay(alignment: .trailing) {
                RelativeTime(unixMillis: event.createdAtUnixMillis)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct DesktopInspectorProviderEventDetail: View {
    let event: DesktopProviderEventRecord

    @ViewBuilder var body: some View {
        if !event.detail.isEmpty {
            Text(event.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 26)
        }
    }
}

private struct DesktopInspectorSearchField: View {
    @Binding var text: String
    var placeholder = "Search Kaname"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
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
        .desktopAdaptiveSheet(idealWidth: 540)
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
        .desktopAdaptiveSheet(idealWidth: 560, idealHeight: 430)
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
        .desktopAdaptiveSheet(idealWidth: 640, idealHeight: 600)
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
        .desktopAdaptiveSheet(idealWidth: 560, idealHeight: 440)
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
        .desktopAdaptiveSheet(idealWidth: 580, idealHeight: 520)
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
        .desktopAdaptiveSheet(idealWidth: 640, idealHeight: 560)
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

    init(
        model: DesktopAppModel,
        accountID: String? = nil,
        recipients: String = "",
        subject: String = "",
        body: String = ""
    ) {
        self.model = model
        _selectedAccountID = State(initialValue: accountID ?? model.snapshot.domains.accounts.first {
            $0.service == .gmail && $0.status == .ready
        }?.id)
        _recipients = State(initialValue: recipients)
        _subject = State(initialValue: subject)
        _draftBody = State(initialValue: body)
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
        .desktopAdaptiveSheet(idealWidth: 620, idealHeight: 500)
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
    @State private var isAllDay = false
    @State private var allDaySpanDays = 1
    @State private var timeZoneIdentifier: String
    @State private var recurrence = "Does not repeat"

    private static func eligibleWritableSources(
        in sources: [DesktopCalendarSourceRecord]
    ) -> [DesktopCalendarSourceRecord] {
        sources.filter { source in
            let access = source.accessLevel.lowercased()
            return source.isEnabled
                && !access.contains("read only")
                && !access.contains("reader")
                && !access.contains("reconnect")
        }
    }

    private var writableSources: [DesktopCalendarSourceRecord] {
        Self.eligibleWritableSources(in: model.snapshot.domains.calendarSources)
    }

    init(model: DesktopAppModel) {
        self.model = model
        let sources = Self.eligibleWritableSources(in: model.snapshot.domains.calendarSources)
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
                    Text("Select a calendar").tag(nil as String?)
                    ForEach(writableSources) { source in
                        Text("\(source.displayName) · \(source.ownerIdentity)").tag(source.id as String?)
                    }
                }
                if writableSources.isEmpty {
                    Text("Enable a writable calendar in Settings, or reconnect Google to grant Calendar event changes.")
                        .font(.caption).foregroundStyle(Nord.auroraYellow)
                }
                Toggle("All-day event", isOn: $isAllDay)
                DatePicker(
                    isAllDay ? "Date" : "Start",
                    selection: $start,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                    .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent)
                if isAllDay {
                    Stepper("Span: \(allDaySpanDays) day(s)", value: $allDaySpanDays, in: 1...7)
                } else {
                    Stepper("Duration: \(durationMinutes) minutes", value: $durationMinutes, in: 5...1_440, step: 5)
                }
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
        .desktopAdaptiveSheet(idealWidth: 540, idealHeight: 470)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && selectedCalendarSourceID != nil
    }

    private func save() {
        let source = selectedCalendarSourceID.flatMap { selectedID in
            model.snapshot.domains.calendarSources.first { $0.id == selectedID }
        }
        var pinnedCalendar = Calendar(identifier: .gregorian)
        pinnedCalendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        let normalizedStart = isAllDay ? pinnedCalendar.startOfDay(for: start) : start
        guard model.createCalendarProposal(
            accountID: source?.accountID,
            calendarSourceID: source?.id,
            title: title,
            startAtUnixMillis: Int64(normalizedStart.timeIntervalSince1970 * 1_000),
            durationMinutes: isAllDay ? allDaySpanDays * 1_440 : durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            recurrence: recurrence,
            isAllDay: isAllDay
        ) != nil else { return }
        dismiss()
    }
}

struct NewAutomationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DesktopAppModel
    let editingID: String?
    @State private var name = ""
    @State private var timeZoneIdentifier: String
    @State private var actionSummary = ""
    @State private var missedRunPolicy = DesktopAutomationRule.MissedRunPolicy.skip
    @State private var frequency = DesktopScheduleSpec.Frequency.weekly
    @State private var scheduledTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? .now
    @State private var onceDate = Date().addingTimeInterval(3_600)
    @State private var weekday = 2
    @State private var actionKind = DesktopAutomationActionKind.notification
    @State private var authority = DesktopAutomationAuthority.localOnly
    @State private var projectID: String?
    @State private var selectedSkillIDs: Set<String> = []
    @State private var notificationEnabled = true

    init(model: DesktopAppModel, editing rule: DesktopAutomationRule? = nil) {
        self.model = model
        editingID = rule?.id
        let spec = rule?.scheduleSpec
        _name = State(initialValue: rule?.name ?? "")
        _timeZoneIdentifier = State(initialValue: rule?.timeZoneIdentifier ?? model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
        _actionSummary = State(initialValue: rule?.actionSummary ?? "")
        _missedRunPolicy = State(initialValue: rule?.missedRunPolicy ?? .skip)
        _frequency = State(initialValue: spec?.frequency ?? .weekly)
        var components = DateComponents(hour: spec?.hour ?? 9, minute: spec?.minute ?? 0)
        components.timeZone = TimeZone(identifier: rule?.timeZoneIdentifier ?? model.snapshot.preferences.defaultScheduleTimeZoneIdentifier)
        _scheduledTime = State(initialValue: Calendar.current.date(from: components) ?? .now)
        _onceDate = State(initialValue: spec?.onceAtUnixMillis.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date().addingTimeInterval(3_600))
        _weekday = State(initialValue: spec?.weekday ?? 2)
        _actionKind = State(initialValue: rule?.actionKind ?? .notification)
        _authority = State(initialValue: rule?.authority ?? .localOnly)
        _projectID = State(initialValue: rule?.projectID)
        _selectedSkillIDs = State(initialValue: Set(rule?.skillIDs ?? []))
        _notificationEnabled = State(initialValue: rule?.notificationEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingID == nil ? "New automation draft" : "Edit automation")
                .font(.title2.weight(.bold))
            Text("Choose a deterministic trigger, one domain-aware action, and its exact authority. The rule remains disabled until review is complete.")
                .foregroundStyle(.secondary)
            Form {
                Section("Trigger") {
                    TextField("Name", text: $name)
                    Picker("Frequency", selection: $frequency) {
                        ForEach(DesktopScheduleSpec.Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if frequency == .once {
                        DatePicker("Run at", selection: $onceDate)
                    } else {
                        DatePicker("Time", selection: $scheduledTime, displayedComponents: .hourAndMinute)
                        if frequency == .weekly {
                            Picker("Weekday", selection: $weekday) {
                                ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, day in
                                    Text(day).tag(index + 1)
                                }
                            }
                        }
                    }
                    TextField("IANA time zone", text: $timeZoneIdentifier)
                    Picker("Missed run", selection: $missedRunPolicy) {
                        ForEach(DesktopAutomationRule.MissedRunPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Action") {
                    Picker("Kind", selection: $actionKind) {
                        ForEach(DesktopAutomationActionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Project", selection: $projectID) {
                        Text("No project").tag(String?.none)
                        ForEach(model.snapshot.projects.filter { $0.archivedAtUnixMillis == nil }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("What should happen?", text: $actionSummary, axis: .vertical).lineLimit(2...5)
                    if actionKind == .skill || actionKind == .conversation {
                        Text(actionKind == .skill
                            ? "Choose the registered capability context this read-only run must use."
                            : "Optional registered capability context")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.snapshot.domains.skills.filter(\.enabled)) { skill in
                            Toggle(skill.name, isOn: Binding(
                                get: { selectedSkillIDs.contains(skill.id) },
                                set: { enabled in
                                    if enabled { selectedSkillIDs.insert(skill.id) } else { selectedSkillIDs.remove(skill.id) }
                                }
                            ))
                        }
                    }
                    if actionKind != .notification {
                        Text("Scheduled provider turns run in Kaname's read-only, network-disabled conversation boundary. Selecting a capability supplies frozen, revision-bound context; it does not grant an external tool action.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Authority & attention") {
                    Picker("Authority", selection: $authority) {
                        ForEach(DesktopAutomationAuthority.allCases, id: \.self) { option in
                            if option != .localOnly || actionKind == .notification { Text(option.label).tag(option) }
                        }
                    }
                    Toggle("Notify when this rule completes or needs attention", isOn: $notificationEnabled)
                    Text("Agent conversations and skill runs require either exact approval for every occurrence or a separately approved visible standing rule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(editingID == nil ? "Save disabled draft" : "Save changes for review") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .desktopAdaptiveSheet(idealWidth: 650, idealHeight: 700)
        .onChange(of: actionKind) { newValue in
            if newValue != .notification, authority == .localOnly { authority = .askEveryRun }
            if newValue == .notification { selectedSkillIDs.removeAll() }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !actionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TimeZone(identifier: timeZoneIdentifier) != nil
            && (actionKind != .skill || !selectedSkillIDs.isEmpty)
            && (actionKind == .notification || authority != .localOnly)
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        let spec = DesktopScheduleSpec.anchored(
            frequency: frequency,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0,
            weekday: frequency == .weekly ? weekday : nil,
            onceAtUnixMillis: frequency == .once ? Int64(onceDate.timeIntervalSince1970 * 1_000) : nil
        )
        let schedule = DesktopScheduleEngine.humanSchedule(spec: spec, timeZoneIdentifier: timeZoneIdentifier)
        let saved: Bool
        if let editingID {
            saved = model.updateAutomation(
                id: editingID,
                name: name,
                schedule: schedule,
                timeZoneIdentifier: timeZoneIdentifier,
                actionSummary: actionSummary,
                missedRunPolicy: missedRunPolicy,
                scheduleSpec: spec,
                actionKind: actionKind,
                authority: authority,
                projectID: projectID,
                skillIDs: Array(selectedSkillIDs),
                notificationEnabled: notificationEnabled
            )
        } else {
            saved = model.createAutomation(
                name: name,
                schedule: schedule,
                timeZoneIdentifier: timeZoneIdentifier,
                actionSummary: actionSummary,
                missedRunPolicy: missedRunPolicy,
                scheduleSpec: spec,
                actionKind: actionKind,
                authority: authority,
                projectID: projectID,
                skillIDs: Array(selectedSkillIDs),
                toolNames: [],
                notificationEnabled: notificationEnabled
            ) != nil
        }
        guard saved else { return }
        dismiss()
    }
}

private struct NewDesktopThreadSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    @ObservedObject var model: DesktopAppModel
    let projectID: String?
    let capabilities: [ProviderCapabilitySnapshot]
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DesktopWorkKind = .coding
    @State private var provider: String
    @State private var runtimeModel: String
    @State private var reasoning: String
    @State private var runtimeMode: ConversationRuntimeMode = .approvalRequired
    @State private var networkAccess = false

    init(
        model: DesktopAppModel,
        projectID: String?,
        capabilities: [ProviderCapabilitySnapshot],
        created: @escaping (String) -> Void
    ) {
        self.model = model
        self.projectID = projectID
        self.capabilities = capabilities
        self.created = created
        _kind = State(initialValue: model.project(id: projectID)?.context.defaultKind ?? .coding)
        let initialProvider = model.project(id: projectID)?.context.defaultProvider ?? "Codex"
        let initialModel = ConversationRuntimeCatalog.selectedModel(
            provider: initialProvider,
            requested: model.project(id: projectID)?.context.defaultModel ?? "Use provider default",
            capabilities: capabilities
        )
        _provider = State(initialValue: initialProvider)
        _runtimeModel = State(initialValue: initialModel)
        _reasoning = State(initialValue: ConversationRuntimeCatalog.selectedReasoning(
            provider: initialProvider,
            model: initialModel,
            capabilities: capabilities
        ))
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
                    if usesQALargeText || dynamicTypeSize.isAccessibilitySize {
                        kindPicker.pickerStyle(.menu)
                    } else {
                        kindPicker.pickerStyle(.segmented)
                    }
                    Text(kind.startDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ConversationRuntimeEditor(
                    provider: $provider,
                    model: $runtimeModel,
                    reasoning: $reasoning,
                    runtimeMode: $runtimeMode,
                    networkAccess: $networkAccess,
                    capabilities: capabilities,
                    stagedCoding: kind == .coding,
                    initialFocus: .full
                )
                Section {
                    Label("No subject required", systemImage: "sparkles")
                    Text("Kaname opens a blank conversation and names it automatically from your first message.")
                        .foregroundStyle(.secondary)
                    Label(
                        kind == .coding
                            ? "Plan first · read-only · network disabled · explicit isolated implementation approval"
                            : ConversationRuntimeCatalog.boundarySummary(
                                provider: provider,
                                runtimeMode: runtimeMode,
                                networkAccess: networkAccess
                            ),
                        systemImage: kind == .coding
                            ? "checkmark.shield.fill"
                            : (runtimeMode == .fullAccess ? "exclamationmark.shield" : "lock.shield")
                    )
                    .foregroundStyle(kind != .coding && runtimeMode == .fullAccess ? Nord.auroraYellow : .secondary)
                }
            }
            .formStyle(.grouped)
            .padding(12)
            .navigationTitle("New conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start conversation") {
                        let id = model.createConversation(
                            kind: kind,
                            projectID: projectID,
                            provider: provider,
                            model: runtimeModel,
                            reasoningEffort: reasoning,
                            runtimeMode: runtimeMode,
                            networkAccess: networkAccess
                        )
                        created(id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .desktopAdaptiveSheet(idealWidth: 620, idealHeight: 720)
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) {
            ForEach(DesktopWorkKind.allCases, id: \.self) { kind in
                Text(kind.label).tag(kind)
            }
        }
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let state: DesktopRecordState

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            if differentiateWithoutColor {
                Image(systemName: state.accessibilitySymbol)
            }
        }
            .font(.caption2.weight(.bold))
            .foregroundStyle(state.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.18), in: Capsule())
            .overlay {
                if colorSchemeContrast == .increased {
                    Capsule().strokeBorder(state.foreground, lineWidth: 1.5)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(state.label)")
    }
}

private struct ActionStatePill: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let state: DesktopActionState

    var body: some View {
        Label {
            Text(state.label)
        } icon: {
            if differentiateWithoutColor {
                Image(systemName: state.accessibilitySymbol)
            }
        }
            .font(.caption2.weight(.bold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.tint.opacity(0.18), in: Capsule())
            .overlay {
                if colorSchemeContrast == .increased {
                    Capsule().strokeBorder(state.tint, lineWidth: 1.5)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Action status: \(state.label)")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.title). \(thread.summary). Attention: \(thread.attention.label). Provider: \(thread.provider)")
        .accessibilityHint("Open conversation")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.summary). Attention: \(thread.attention.label)")
        .accessibilityHint("Open conversation")
    }
}

private struct ThreadDirectoryLabel: View {
    let thread: DesktopThread
    let runs: [DesktopProviderRunRecord]

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: thread.kind.symbol)
                .foregroundStyle(ThreadDirectoryStatus(thread: thread, runs: runs).tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    if thread.unread { Circle().fill(Nord.frost1).frame(width: 7, height: 7) }
                }
                Text("\(thread.provider) · \(thread.kind.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ThreadDirectoryStatusView(status: ThreadDirectoryStatus(thread: thread, runs: runs))
            }
        }
        .padding(.vertical, 5)
        .frame(height: 70, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.provider). \(ThreadDirectoryStatus(thread: thread, runs: runs).label)"
        )
    }
}

private struct ThreadDirectoryStatus {
    let label: String
    let symbol: String
    let tint: Color
    let runningSinceUnixMillis: Int64?

    init(thread: DesktopThread, runs: [DesktopProviderRunRecord]) {
        let runningSince = runs.last(where: { $0.state == .running })?.startedAtUnixMillis
        switch thread.attention {
        case .needsApproval:
            (label, symbol, tint, runningSinceUnixMillis) = ("Approval required", "hand.raised.fill", Nord.auroraYellow, nil)
        case .needsInput:
            (label, symbol, tint, runningSinceUnixMillis) = ("Waiting for input", "questionmark.bubble.fill", Nord.auroraPurple, nil)
        case .failed:
            (label, symbol, tint, runningSinceUnixMillis) = ("Failed", "exclamationmark.circle.fill", Nord.auroraRed, nil)
        case .running:
            (label, symbol, tint, runningSinceUnixMillis) = ("Running", "circle.dashed", Nord.frost1, runningSince)
        case .queued:
            (label, symbol, tint, runningSinceUnixMillis) = ("Queued", "clock", .secondary, nil)
        case .needsResponse:
            (label, symbol, tint, runningSinceUnixMillis) = (
                thread.unread ? "Response ready" : "Ready",
                thread.unread ? "checkmark.circle.fill" : "circle",
                thread.unread ? Nord.auroraGreen : .secondary,
                nil
            )
        case .completed:
            (label, symbol, tint, runningSinceUnixMillis) = ("Complete", "checkmark", .secondary, nil)
        case .archived:
            (label, symbol, tint, runningSinceUnixMillis) = ("Archived", "archivebox", .secondary, nil)
        }
    }
}

private struct ThreadDirectoryStatusView: View {
    let status: ThreadDirectoryStatus

    var body: some View {
        Group {
            if let started = status.runningSinceUnixMillis {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusLabel(duration: max(0, Int64(context.date.timeIntervalSince1970 * 1_000) - started))
                }
            } else {
                statusLabel(duration: nil)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(status.tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLabel(duration: Int64?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
            Text(status.label)
            if let duration {
                Text(Self.durationLabel(milliseconds: duration))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    private static func durationLabel(milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(thread.unread ? "Unread. " : "")\(thread.title). \(thread.summary). Attention: \(thread.attention.label)")
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
                    .accessibilityLabel("Open \(thread.title). Attention: \(thread.attention.label)")
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
    let phase: DesktopPlanPhase
    let provider: String
    let requestChanges: () -> Void
    let approvePlan: () -> Void

    private var presentation: DesktopPlanPresentation {
        DesktopPlanPresentation(items: items, phase: phase)
    }

    var body: some View {
        VStack(spacing: 0) {
            planScrollSurface

            if phase == .awaitingApproval {
                Divider()
                planReviewFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var planScrollSurface: some View {
        ScrollView {
            planScrollContent
        }
    }

    private var planScrollContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if presentation.rows.isEmpty {
                emptyPlan
            } else {
                planHeader
                planOutline
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var emptyPlan: some View {
        EmptyPanel(
            symbol: "list.bullet.clipboard",
            title: "No plan yet",
            detail: "A provider plan remains separate from write approval. Request or revise it in Chat."
        )
    }

    private var planOutline: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                ThreadPlanRow(row: row)
                if index < presentation.rows.count - 1 {
                    Divider().padding(.leading, 66)
                }
            }
        }
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeading
            phaseCallout
        }
    }

    private var planHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            planTitle
            planProgress
        }
    }

    private var planTitle: some View {
        Text("Implementation plan")
            .font(.title2.weight(.bold))
    }

    private var planProgress: some View {
        Label(presentation.progressLabel, systemImage: "list.number")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var phaseCallout: some View {
        HStack(alignment: .top, spacing: 11) {
            phaseIcon
            VStack(alignment: .leading, spacing: 3) {
                phaseTitle
                phaseDetail
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(phase.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(phase.tint.opacity(0.24), lineWidth: 1)
        }
    }

    private var phaseIcon: some View {
        Image(systemName: phase.symbol)
            .font(.title3)
            .foregroundStyle(phase.tint)
            .frame(width: 24)
    }

    private var phaseTitle: some View {
        Text(phase.label)
            .font(.subheadline.weight(.semibold))
    }

    private var phaseDetail: some View {
        Text(phase.detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var planReviewFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                reviewBoundaryText
                Spacer(minLength: 12)
                reviewActions
            }
            VStack(alignment: .leading, spacing: 12) {
                reviewBoundaryText
                reviewActions
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Nord.polarNight1)
    }

    private var reviewBoundaryText: some View {
        VStack(alignment: .leading, spacing: 3) {
            reviewDecisionTitle
            reviewDecisionDetail
        }
    }

    private var reviewDecisionTitle: some View {
        Text("Ready for your decision")
            .font(.subheadline.weight(.semibold))
    }

    private var reviewDecisionDetail: some View {
        Text("Changes start another read-only plan. Approval authorizes one network-denied implementation turn in an isolated worktree.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reviewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                requestChangesButton
                approvePlanButton
            }
            VStack(alignment: .leading, spacing: 8) {
                requestChangesButton
                approvePlanButton
            }
        }
    }

    private var requestChangesButton: some View {
        Button("Request changes", systemImage: "text.bubble", action: requestChanges)
            .buttonStyle(.bordered)
            .tint(Nord.frost1)
    }

    private var approvePlanButton: some View {
        Button(action: approvePlan) {
            Label("Approve plan & implement", systemImage: "checkmark.shield.fill")
                .foregroundStyle(Nord.polarNight0)
        }
        .buttonStyle(.borderedProminent)
        .tint(Nord.auroraGreen)
        .disabled(items.isEmpty || !providerSupportsImplementation)
        .help(approvalHelp)
    }

    private var providerSupportsImplementation: Bool {
        provider.caseInsensitiveCompare("Codex") == .orderedSame
    }

    private var approvalHelp: String {
        if items.isEmpty { return "Wait for a readable plan before approving implementation" }
        return providerSupportsImplementation
            ? "Create an isolated worktree and authorize one network-denied implementation turn"
            : "Choose Codex to use Kaname's signed isolated implementation flow"
    }
}

private struct ThreadPlanRow: View {
    let row: DesktopPlanPresentation.Row

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ordinalBadge
            VStack(alignment: .leading, spacing: 8) {
                planStepTitle
                statusLabel
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.isCurrent ? row.tint.opacity(0.08) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var ordinalBadge: some View {
        Text("\(row.ordinal)")
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(row.tint)
            .frame(width: 28, height: 28)
            .background(row.tint.opacity(0.13), in: Circle())
    }

    private var planStepTitle: some View {
        Text(row.title)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var statusLabel: some View {
        Label(row.statusLabel, systemImage: row.statusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(row.tint)
            .fixedSize()
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
    let threadID: String

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
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.attachments) { attachment in
                                DesktopConversationImagePreview(
                                    threadID: threadID,
                                    attachment: attachment,
                                    size: CGSize(width: 140, height: 96)
                                )
                            }
                        }
                    }
                }
            }
            .padding(13)
            .background(message.role.background, in: RoundedRectangle(cornerRadius: 15))
            if message.role != .user { Spacer(minLength: 42) }
        }
    }
}

private struct DesktopComposerImageThumbnail: View {
    let threadID: String
    let attachment: ConversationImageAttachment
    let remove: () -> Void
    @State private var showsPreview = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { showsPreview = true } label: {
                DesktopConversationImagePreview(
                    threadID: threadID,
                    attachment: attachment,
                    size: CGSize(width: 58, height: 58)
                )
            }
            .buttonStyle(.plain)
            .help("Preview \(attachment.filename)")

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.72))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .popover(isPresented: $showsPreview) {
            VStack(alignment: .leading, spacing: 10) {
                DesktopConversationImagePreview(
                    threadID: threadID,
                    attachment: attachment,
                    size: CGSize(width: 520, height: 420)
                )
                Text(attachment.filename)
                    .font(.caption)
                Text("\(attachment.pixelWidth) × \(attachment.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
}

private struct DesktopConversationImagePreview: View {
    let threadID: String
    let attachment: ConversationImageAttachment
    let size: CGSize

    private var imageURL: URL? {
        let environment = KanameDesktopEnvironment.current
        let store = KanameConversationAttachmentStore(
            rootDirectory: environment.applicationSupportRoot
                .appending(path: "ConversationService", directoryHint: .isDirectory)
        )
        return try? store.attachmentURL(threadID: threadID, attachment: attachment)
    }

    var body: some View {
#if os(macOS)
        Group {
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Nord.polarNight2, in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("Attached image \(attachment.filename)")
#else
        EmptyView()
#endif
    }
}

struct SurfaceHeader<Actions: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let actions: Actions

    init(title: String, detail: String, symbol: String, @ViewBuilder actions: () -> Actions) {
        (self.title, self.detail, self.symbol, self.actions) = (title, detail, symbol, actions())
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
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            actions.fixedSize(horizontal: true, vertical: false)
        }
        .padding(22)
    }
}

private extension SurfaceHeader where Actions == EmptyView {
    init(title: String, detail: String, symbol: String) {
        self.init(title: title, detail: detail, symbol: symbol) { EmptyView() }
    }
}

struct EmptyPanel: View {
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let attention: DesktopAttention

    var body: some View {
        Label {
            Text(attention.label)
        } icon: {
            if differentiateWithoutColor {
                Image(systemName: attention.accessibilitySymbol)
            }
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(attention.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(attention.tint.opacity(0.12), in: Capsule())
            .overlay {
                if colorSchemeContrast == .increased {
                    Capsule().strokeBorder(attention.tint, lineWidth: 1.5)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attention: \(attention.label)")
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

struct SettingsSection<Content: View>: View {
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

    fileprivate func desktopAdaptiveSheet(
        idealWidth: Double,
        idealHeight: Double? = nil
    ) -> some View {
        modifier(DesktopAdaptiveSheetModifier(idealWidth: idealWidth, idealHeight: idealHeight))
    }
}

private struct DesktopAdaptiveSheetModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.desktopQALargeText) private var usesQALargeText
    let idealWidth: Double
    let idealHeight: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        let metrics = DesktopAccessibleSheetMetrics.adaptive(
            idealWidth: idealWidth,
            idealHeight: idealHeight,
            usesAccessibilityTextSize: usesQALargeText || dynamicTypeSize.isAccessibilitySize
        )
        if let minimumHeight = metrics.minimumHeight,
           let idealHeight = metrics.idealHeight,
           let maximumHeight = metrics.maximumHeight {
            content.frame(
                minWidth: CGFloat(metrics.minimumWidth),
                idealWidth: CGFloat(metrics.idealWidth),
                maxWidth: CGFloat(metrics.maximumWidth),
                minHeight: CGFloat(minimumHeight),
                idealHeight: CGFloat(idealHeight),
                maxHeight: CGFloat(maximumHeight)
            )
        } else {
            content.frame(
                minWidth: CGFloat(metrics.minimumWidth),
                idealWidth: CGFloat(metrics.idealWidth),
                maxWidth: CGFloat(metrics.maximumWidth)
            )
        }
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
        case .automations: "Workflow design, runs, components, readiness, schedules, and durable evidence."
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
    var accessibilitySymbol: String {
        switch self {
        case .ready: "checkmark.circle"
        case .draft: "pencil.circle"
        case .proposed: "lightbulb"
        case .paused: "pause.circle"
        case .disconnected: "bolt.slash"
        case .needsReview: "eye.circle"
        case .waiting: "clock"
        case .running: "progress.indicator"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: Nord.auroraGreen
        case .draft: Nord.frost1
        case .proposed: Nord.auroraPurple
        case .paused: Nord.auroraYellow
        case .disconnected: Nord.polarNight3
        case .needsReview: Nord.auroraOrange
        case .waiting: Nord.auroraYellow
        case .running: Nord.frost1
        case .failed: Nord.auroraRed
        }
    }

    var foreground: Color {
        self == .disconnected ? .secondary : tint
    }
}

private extension DesktopActionState {
    var accessibilitySymbol: String {
        switch self {
        case .proposed: "lightbulb"
        case .awaitingApproval: "checkmark.shield"
        case .approved: "hand.thumbsup"
        case .rejected: "hand.thumbsdown"
        case .running: "progress.indicator"
        case .completed, .reconciled: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "stop.circle"
        case .cancelled: "xmark.circle"
        }
    }

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

private extension DesktopAttention {
    var accessibilitySymbol: String {
        switch self {
        case .needsResponse: "bubble.left"
        case .needsApproval: "checkmark.shield"
        case .needsInput: "questionmark.bubble"
        case .running: "progress.indicator"
        case .queued: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .archived: "archivebox"
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
        case .needsInput: Nord.auroraPurple
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
        planStatusLabel
    }

    var symbol: String {
        planStatusSymbol
    }

    var tint: Color {
        switch self {
        case .pending: Nord.snowStorm0.opacity(0.78)
        case .inProgress: Nord.frost1
        case .complete: Nord.auroraGreen
        }
    }
}

private extension DesktopCodingWorkflowStage {
    func planPhase(hasSavedPlan: Bool) -> DesktopPlanPhase {
        switch self {
        case .discuss: hasSavedPlan ? .saved : .notStarted
        case .planning: .drafting
        case .planReview: .awaitingApproval
        case .preparing, .implementing: .implementing
        case .implementationReview, .evidenceReview, .knowledgeReview: .reviewingResult
        case .completed: .completed
        case .rejected, .failed: .stopped
        }
    }
}

private extension DesktopPlanPhase {
    var tint: Color {
        switch self {
        case .notStarted: Color.secondary
        case .saved: Nord.frost0
        case .drafting, .implementing: Nord.frost1
        case .awaitingApproval, .reviewingResult: Nord.auroraYellow
        case .completed: Nord.auroraGreen
        case .stopped: Nord.auroraRed
        }
    }
}

private extension DesktopPlanPresentation.Row {
    var tint: Color {
        state.tint
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
