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
private let kanameDesktopDidResignActiveNotification = NSApplication.didResignActiveNotification
private let kanameDesktopWillTerminateNotification = NSApplication.willTerminateNotification
#else
private let kanameDesktopDidResignActiveNotification = Notification.Name("com.cyberlane.kaname.desktop.lifecycle.did-resign-active")
private let kanameDesktopWillTerminateNotification = Notification.Name("com.cyberlane.kaname.desktop.lifecycle.will-terminate")
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

enum DesktopDestination: String, CaseIterable, Identifiable {
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
    case links
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
        case .links: "Kaname Link"
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
        case .links: "link"
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

struct DesktopSearchNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let target: DesktopGlobalSearchNavigationTarget
    let title: String
}

private struct DesktopSearchFallbackNotice: Equatable {
    let destination: DesktopDestination
    let title: String
    let detail: String
}

enum DesktopCommandCenterAction: Identifiable, Equatable {
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

extension EnvironmentValues {
    var desktopQALargeText: Bool {
        get { self[DesktopQALargeTextKey.self] }
        set { self[DesktopQALargeTextKey.self] = newValue }
    }
}

struct KanameDesktopWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.locale) private var locale
    @Environment(\.sizeCategory) private var sizeCategory
    private let uiRestoreStore: DesktopUIRestoreStore
    private let initialGlobalSearchQuery: String
    private let usesQALargeText: Bool
    private let designCapture: DesktopDesignCaptureConfiguration?
    private let usesSyntheticFixtures: Bool
    private let gitControl: DesktopGitControlService
    @StateObject private var model: DesktopAppModel
    @StateObject private var conversationRuntime: DesktopConversationRuntime
    @StateObject private var automationScheduler: DesktopAutomationSchedulerViewModel
    @StateObject private var personalIntegrations: DesktopPersonalIntegrationViewModel
    @StateObject private var updates: DesktopUpdateViewModel
    @StateObject private var automaticBackup: DesktopAutomaticBackupViewModel
    @StateObject private var link: DesktopLinkViewModel
    @StateObject private var portableTransfer = DesktopPortableTransferViewModel()
    @State private var destination: DesktopDestination
    @State private var selectedThreadID: String?
    @State private var selectedProjectID: String?
    @State private var searchText = ""
    @State private var inboxFilter: DesktopAttention? = nil
    @State private var newConversationRequest: NewConversationRequest?
    @State private var showsNewProject = false
    @State private var showsInspector = true
    @State private var showsCompactInspector = false
    @State private var workspaceUsesCompactLayout = true
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
    @State private var pendingThreadArchiveID: String?
#if os(macOS)
    @State private var searchPreviousResponder: NSResponder?
    @State private var modalPreviousResponder: NSResponder?
    @State private var importPreviousResponder: NSResponder?
    @State private var diagnosticsPreviousResponder: NSResponder?
    @State private var compactInspectorPreviousResponder: NSResponder?
    @State private var navigationPreviousResponders: [NSResponder?] = []
#endif

    init(gitControl: DesktopGitControlService) {
        let environment = KanameDesktopEnvironment.current
        self.gitControl = gitControl
        let arguments = CommandLine.arguments
        let designCapture = DesktopDesignCaptureConfiguration.resolve(arguments: arguments)
        self.designCapture = designCapture
        usesSyntheticFixtures = designCapture != nil
            || arguments.contains("--desktop-plan-review-fixture")
            || arguments.contains("--desktop-link-synthetic-fixture")
            || arguments.contains("--desktop-workflow-fixture")
        let desktopStore: any DesktopStateStoring
        let forkFailure: String?
        if designCapture != nil {
            desktopStore = VolatileDesktopStateStore()
            forkFailure = nil
        } else {
            do {
                _ = try DesktopDevelopmentDataFork.prepareIfNeeded(environment: environment)
                desktopStore = FileDesktopStateStore(fileURL: environment.workspaceFileURL)
                forkFailure = nil
            } catch {
                desktopStore = VolatileDesktopStateStore()
                forkFailure = error.localizedDescription
            }
        }
        let restoreStore = DesktopUIRestoreStore(fileURL: environment.desktopDirectory.appending(path: "ui-restore.json"))
        let restoredUI = forkFailure == nil && designCapture == nil ? restoreStore.load() : nil
        uiRestoreStore = restoreStore
        let desktopModel = DesktopAppModel(store: desktopStore)
        designCapture?.seed(desktopModel)
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
        let runtime = DesktopConversationRuntime(
            model: desktopModel,
            environment: environment,
            gitControl: gitControl
        )
        _developmentForkFailure = State(initialValue: forkFailure)
        _model = StateObject(wrappedValue: desktopModel)
        _conversationRuntime = StateObject(wrappedValue: runtime)
        _automationScheduler = StateObject(wrappedValue: DesktopAutomationSchedulerViewModel(model: desktopModel, runtime: runtime, environment: environment))
        _personalIntegrations = StateObject(wrappedValue: DesktopPersonalIntegrationViewModel(environment: environment))
        _updates = StateObject(wrappedValue: DesktopUpdateViewModel(environment: environment))
        _automaticBackup = StateObject(wrappedValue: DesktopAutomaticBackupViewModel(environment: environment))
        if arguments.contains("--desktop-link-synthetic-fixture") || designCapture?.scenario.usesSyntheticLink == true {
            _link = StateObject(wrappedValue: DesktopLinkViewModel(
                service: KanameLinkSyntheticGatewayService.fixture(),
                initialSnapshot: KanameLinkSyntheticGatewayService.fixtureSnapshot
            ))
        } else {
#if os(macOS)
            let linkRoot = environment.applicationSupportRoot
                .appending(path: "Link", directoryHint: .isDirectory)
            if let gatewayURL = Bundle.main.url(
                forResource: "kaname-link-gateway",
                withExtension: nil
            ), let gatewayRuntime = try? KanameLinkGatewayRuntime(
                executableURL: gatewayURL,
                stateRootURL: linkRoot
            ) {
                _link = StateObject(wrappedValue: DesktopLinkViewModel(runtime: gatewayRuntime))
            } else {
                _link = StateObject(wrappedValue: DesktopLinkViewModel(
                    unavailableMessage: "The exact bundled Link gateway is unavailable in this app build."
                ))
            }
#else
            _link = StateObject(wrappedValue: DesktopLinkViewModel(
                unavailableMessage: "The Link gateway host is available only in the macOS primary app."
            ))
#endif
        }
        if let fixtureIndex = arguments.firstIndex(of: "--desktop-workflow-fixture"),
           arguments.indices.contains(fixtureIndex + 1) {
            seedSyntheticWorkflowFixture(model: desktopModel, manifestPath: arguments[fixtureIndex + 1])
        }
        usesQALargeText = arguments.contains("--desktop-large-text") || designCapture?.scenario.usesLargeText == true
        initialGlobalSearchQuery = arguments.firstIndex(of: "--desktop-search-query")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? ""
        _showsGlobalSearch = State(initialValue: arguments.contains("--desktop-global-search"))
        _showsDiagnostics = State(initialValue: arguments.contains("--desktop-diagnostics"))
        let explicitDestination = designCapture.flatMap { DesktopDestination(rawValue: $0.scenario.destination) }
            ?? arguments.firstIndex(of: "--desktop-destination")
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
            .background(KanameColor.canvas)
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
                    KanameColor.canvas.ignoresSafeArea()
                    ContentUnavailableView {
                        Label("Development data fork stopped safely", systemImage: "lock.shield.fill")
                            .foregroundStyle(KanameColor.warning)
                    } description: {
                        Text(developmentForkFailure)
                        Text("The Stable workspace was not modified. Quit Development, resolve the reported condition, then relaunch it through the Dev launcher.")
                            .foregroundStyle(KanameColor.accent)
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
        .confirmationDialog(
            threadArchiveConfirmationTitle,
            isPresented: Binding(
                get: { pendingThreadArchiveID != nil },
                set: { if !$0 { pendingThreadArchiveID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive conversation", role: .destructive) {
                confirmThreadArchive()
            }
            Button("Cancel", role: .cancel) {
                pendingThreadArchiveID = nil
            }
        } message: {
            Text("The conversation will leave active views. Archiving does not mark it complete.")
        }
    }

    private var lifecycleWorkspace: some View {
        presentedWorkspace
        .task {
            guard developmentForkFailure == nil, !model.isRecoveryReadOnly else { return }
            if designCapture != nil {
                NotificationCenter.default.post(name: .kanameDesktopReady, object: nil)
                return
            }
            personalIntegrations.startMonitoring(model: model)
            automaticBackup.start(model: model)
            await _Concurrency.Task<Never, Never>.yield()
            NotificationCenter.default.post(name: .kanameDesktopReady, object: nil)
            updates.startAutomaticChecks()
            await link.startIfNeeded()
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
            _Concurrency.Task { await link.startIfNeeded() }
        }
        .onChange(of: destination) { _ in persistUIRestoreState() }
        .onChange(of: selectedThreadID) { _ in persistUIRestoreState() }
        .onChange(of: selectedProjectID) { _ in persistUIRestoreState() }
        .onChange(of: showsInspector) { _ in persistUIRestoreState() }
        .onDisappear {
            _Concurrency.Task { await link.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: kanameDesktopDidResignActiveNotification)) { _ in
            _ = model.flushComposerDrafts()
        }
        .onReceive(NotificationCenter.default.publisher(for: kanameDesktopWillTerminateNotification)) { _ in
            _ = model.flushComposerDrafts()
        }
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

    private var designCaptureWorkspace: some View {
        VStack(spacing: 0) {
            if usesSyntheticFixtures {
                KanameSyntheticDataBanner()
            }
            primaryCommandWorkspace
        }
    }

    private var navigationCommandWorkspace: some View {
        designCaptureWorkspace
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
    }

    private var lifecycleCommandWorkspace: some View {
        navigationCommandWorkspace
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
    }

    var body: some View {
        lifecycleCommandWorkspace
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsSettings)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsGlobalSearch)
        .environment(
            \.sizeCategory,
            usesQALargeText ? .accessibilityExtraLarge : sizeCategory
        )
        .environment(\.desktopQALargeText, usesQALargeText)
        .environment(\.locale, designCapture?.locale ?? locale)
        .environment(
            \.kanameAccessibilityPreferences,
            KanameAccessibilityPreferences(
                differentiateWithoutColor: designCapture?.scenario.differentiatesWithoutColor ?? differentiateWithoutColor,
                reduceMotion: designCapture?.reduceMotion ?? reduceMotion,
                increasedContrast: false,
                syntheticTextScale: usesQALargeText ? .accessibility3 : .standard
            )
        )
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
            let presentation = DesktopWorkspaceChromePresentation(
                availableWidth: Double(geometry.size.width),
                splitInspectorVisible: showsInspector,
                compactInspectorPresented: showsCompactInspector
            )
            Group {
                if presentation.inspectorPlacement == .split {
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
            .onAppear { updateWorkspaceWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateWorkspaceWidth(width) }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if inspectorSupportsFiltering,
               !searchText.isEmpty,
               workspaceChromePresentation.inspectorPlacement == .hidden {
                activeInspectorFilterBanner
                Divider()
            }
            if let notice = searchFallbackNotice, notice.destination == destination {
                searchFallbackBanner(notice)
                Divider()
            }
            content
        }
        .toolbar { toolbar }
        .background(KanameColor.canvas)
    }

    private var activeInspectorFilterBanner: some View {
        HStack(spacing: KanameSpacing.small) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(KanameColor.accent)
                .accessibilityHidden(true)
            Text("Filtered by “\(searchText)”")
                .kanameSemanticFont(.caption.weight(.semibold))
                .foregroundStyle(KanameColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: KanameSpacing.small)
            Button("Edit filter") {
                toggleInspector()
            }
            .buttonStyle(.borderless)
            .kanameMinimumInteractiveTarget()
            Button("Clear") {
                searchText = ""
            }
            .buttonStyle(.borderless)
            .kanameMinimumInteractiveTarget()
        }
        .padding(.horizontal, KanameSpacing.large)
        .background(KanameColor.raised)
        .accessibilityElement(children: .contain)
    }

    private func searchFallbackBanner(_ notice: DesktopSearchFallbackNotice) -> some View {
        KanameSectionHeader(
            "Opened the closest local view for “\(notice.title)”",
            detail: notice.detail
        ) {
            Button("Dismiss search navigation notice", systemImage: "xmark") {
                searchFallbackNotice = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .kanameMinimumInteractiveTarget()
        }
        .padding(.horizontal, KanameSpacing.large)
        .padding(.vertical, KanameSpacing.small)
        .background(KanameColor.raised)
    }

    private var workspaceHeader: some View {
        HStack(spacing: KanameSpacing.medium) {
            Image(systemName: destination.symbol)
                .foregroundStyle(KanameColor.accentStrong)
                .accessibilityHidden(true)
            Text(workspaceTitle)
                .kanameSemanticFont(KanameTypography.sectionTitle)
                .foregroundStyle(KanameColor.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: KanameSpacing.small)

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
                    .kanameMinimumInteractiveTarget()
                }
                Button {
                    presentGlobalSearch()
                } label: {
                    Label("Open Command Center", systemImage: "command")
                }
                .help("Open Command Center (Command-K)")
                .kanameMinimumInteractiveTarget()
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)

            primaryNewConversationHeaderAction

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
                Button("Open Kaname Link") { navigate(to: .links) }
                Button("Open Coding") { navigate(to: .liveCodex) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("More workspace actions")
            .kanameMinimumInteractiveTarget()
        }
        .padding(.horizontal, KanameSpacing.large)
        .padding(.vertical, KanameSpacing.small)
        .frame(minHeight: 56)
        .background(KanameColor.canvas)
    }

    private var primaryNewConversationHeaderAction: some View {
        Group {
            if [.home, .threads, .inbox].contains(destination) {
                ViewThatFits(in: .horizontal) {
                    Button {
                        beginConversation(projectID: inheritedProjectID)
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .kanameSemanticFont(.body.weight(.semibold))
                            .foregroundStyle(KanameColor.canvas)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KanameColor.accent)
                    .help("New conversation")
                    .kanameMinimumInteractiveTarget()

                    compactProminentNewConversationHeaderAction
                }
            } else {
                compactSecondaryNewConversationHeaderAction
            }
        }
        .accessibilityIdentifier("workspace-new-conversation")
    }

    private var compactProminentNewConversationHeaderAction: some View {
        Button {
            beginConversation(projectID: inheritedProjectID)
        } label: {
            Label("New conversation", systemImage: "square.and.pencil")
                .foregroundStyle(KanameColor.canvas)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .tint(KanameColor.accent)
        .help("New conversation")
        .kanameMinimumInteractiveTarget()
    }

    private var compactSecondaryNewConversationHeaderAction: some View {
        Button {
            beginConversation(projectID: inheritedProjectID)
        } label: {
            Label("New conversation", systemImage: "square.and.pencil")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(KanameColor.accentStrong)
        .help("New conversation")
        .kanameMinimumInteractiveTarget()
    }

    /// Focus mode keeps the sidebar to the daily surfaces. The remaining
    /// destinations still exist and open from the Advanced section.
    @AppStorage("kaname.sidebar.showAdvancedDestinations") private var showAdvancedDestinations = false

    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    KanameIdentityRow()
                        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
                        .listRowBackground(Color.clear)
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

                Section("Coding") {
                    destinationButton(.projects, count: model.snapshot.projects.count)
                    destinationButton(.skills, count: model.snapshot.domains.skills.filter(\.enabled).count)
                }

                Section("Automations") {
                    destinationButton(.automations, count: model.snapshot.domains.automations.count)
                }

                Section("Knowledge") {
                    destinationButton(.knowledge, count: model.snapshot.domains.knowledgeSources.count)
                }

                Section("Collaboration") {
                    destinationButton(.links, count: link.pendingDeviceCount)
                }

                if showAdvancedDestinations {
                    Section("Advanced") {
                        destinationButton(.research, count: model.snapshot.domains.research.count)
                        destinationButton(.email, count: model.snapshot.domains.emailDrafts.count)
                        destinationButton(.calendar, count: model.snapshot.domains.calendarProposals.count)
                        destinationButton(.github, count: model.snapshot.domains.gitWorkspaces.count)
                        destinationButton(.liveCodex)
                        destinationButton(.localCore)
                        destinationButton(.devices)
                    }
                }

                Section {
                    Toggle("Show advanced destinations", isOn: $showAdvancedDestinations)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(KanameColor.sidebar)
            .listStyle(.sidebar)

            Divider()
            if let notice = updates.sidebarNotice,
               KanameUpdateNoticeProjection.isVisible(
                   notice,
                   dismissedIdentity: dismissedUpdateIdentity
               ) {
                DesktopUpdateNotificationCard(
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
            Button(action: presentSettings) {
                Label("Settings", systemImage: DesktopDestination.settings.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .kanameSemanticFont(showsSettings ? .body.weight(.semibold) : .body)
            .foregroundStyle(KanameColor.textPrimary)
            .kanameMinimumInteractiveTarget()
            .padding(.horizontal, KanameSpacing.small)
            .background(
                showsSettings ? KanameColor.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
            )
            .padding(.horizontal, KanameSpacing.small)
            .padding(.vertical, KanameSpacing.xSmall)
            .accessibilityAddTraits(showsSettings ? .isSelected : [])
        }
        .frame(minWidth: 230, idealWidth: 258, maxWidth: 300)
        .background(KanameColor.sidebar)
        .navigationTitle("Kaname")
    }

    private func destinationButton(_ item: DesktopDestination, count: Int? = nil) -> some View {
        let visibleCount = count.flatMap { $0 > 0 ? $0 : nil }
        return Button {
            navigate(to: item)
        } label: {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(destination == item ? KanameColor.accent : KanameColor.textSecondary)
            }
            .padding(.trailing, visibleCount == nil ? 0 : KanameSpacing.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let visibleCount {
                    Text("\(visibleCount)")
                        .kanameSemanticFont(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(destination == item ? KanameColor.accent : KanameColor.textTertiary)
                }
            }
            .padding(.horizontal, KanameSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kanameSemanticFont(destination == item ? .body.weight(.semibold) : .body)
        .foregroundStyle(KanameColor.textPrimary)
        .kanameMinimumInteractiveTarget()
        .background(
            destination == item ? KanameColor.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
        )
        .listRowInsets(EdgeInsets(
            top: KanameSpacing.hairline,
            leading: KanameSpacing.small,
            bottom: KanameSpacing.hairline,
            trailing: KanameSpacing.small
        ))
        .listRowBackground(Color.clear)
        .accessibilityLabel(item.title)
        .accessibilityValue(count.map { $0 == 1 ? "1 item" : "\($0) items" } ?? "")
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
                    requestArchive: requestThreadArchive,
                    openDestination: navigate,
                    startConversation: { beginConversation(projectID: inheritedProjectID) },
                    startConversationInProject: { beginConversation(projectID: $0) }
                )
            case .threads:
                DesktopThreadsView(
                    model: model,
                    runtime: conversationRuntime,
                    gitControl: gitControl,
                    capabilities: personalIntegrations.providerCapabilities,
                    searchText: searchText,
                    selectedThreadID: threadSelection,
                    selectedRunID: $selectedThreadRunID,
                    conversationAnchorID: $selectedConversationAnchorID,
                    composerFocusRequest: composerFocusRequest,
                    requestArchive: requestThreadArchive,
                    showsDirectory: $showsThreadDirectory
                )
            case .inbox:
                DesktopInboxView(
                    model: model,
                    searchText: searchText,
                    filter: $inboxFilter,
                    selectedThreadID: threadSelection,
                    requestArchive: requestThreadArchive
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
            case .links:
                DesktopLinkView(model: link)
            case .liveCodex:
                DesktopCodingView(
                    model: model,
                    integrations: personalIntegrations,
                    runtime: conversationRuntime,
                    gitControl: gitControl,
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
                conversationAnchorID: $selectedConversationAnchorID,
                requestArchive: requestThreadArchive
            )
        } else {
            DesktopContextInspector(destination: destination, model: model)
        }
    }

    private var inspectorColumn: some View {
        inspectorColumn(focusSearchOnAppear: false)
    }

    private func inspectorColumn(focusSearchOnAppear: Bool) -> some View {
        VStack(spacing: 0) {
            if inspectorSupportsFiltering {
                DesktopInspectorSearchField(
                    text: $searchText,
                    focusOnAppear: focusSearchOnAppear
                )
                    .padding(.horizontal, KanameSpacing.large)
                    .padding(.vertical, KanameSpacing.medium)

                Divider()
            }

            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KanameColor.surface)
    }

    private var inspectorSupportsFiltering: Bool {
        [.home, .threads, .inbox].contains(destination)
    }

    private var workspaceChromePresentation: DesktopWorkspaceChromePresentation {
        DesktopWorkspaceChromePresentation(
            availableWidth: workspaceUsesCompactLayout
                ? 0
                : DesktopWorkspaceChromePresentation.splitInspectorMinimumWidth,
            splitInspectorVisible: showsInspector,
            compactInspectorPresented: showsCompactInspector
        )
    }

    private var compactInspectorPopoverBinding: Binding<Bool> {
        Binding(
            get: { workspaceChromePresentation.inspectorPlacement == .popover },
            set: { isPresented in
                if isPresented {
                    presentCompactInspector()
                } else {
                    dismissCompactInspector(restoringFocus: true)
                }
            }
        )
    }

    private var compactInspectorPopover: some View {
        inspectorColumn(focusSearchOnAppear: true)
            .safeAreaInset(edge: .top, spacing: 0) {
                KanameSectionHeader("Inspector", detail: workspaceTitle) {
                    Button("Close Inspector", systemImage: "xmark") {
                        toggleInspector()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .kanameMinimumInteractiveTarget()
                }
                .padding(.horizontal, KanameSpacing.large)
                .padding(.vertical, KanameSpacing.small)
                .background(KanameColor.surface)
                .overlay(alignment: .bottom) { Divider() }
            }
            .foregroundStyle(KanameColor.textPrimary)
            .background(KanameColor.surface)
            .desktopAdaptiveSheet(idealWidth: 420, idealHeight: 620)
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
            let presentation = workspaceChromePresentation
            Button {
                toggleInspector()
            } label: {
                Label(
                    presentation.inspectorToggleTitle,
                    systemImage: presentation.inspectorToggleSystemImage
                )
            }
            .help(presentation.inspectorToggleTitle)
            .accessibilityIdentifier("workspace-inspector-toggle")
            .popover(isPresented: compactInspectorPopoverBinding, arrowEdge: .bottom) {
                compactInspectorPopover
            }
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

    private var threadArchiveConfirmationTitle: String {
        guard let thread = model.thread(id: pendingThreadArchiveID) else {
            return "Archive conversation?"
        }
        return "Archive \(thread.title)?"
    }

    private func requestThreadArchive(_ threadID: String) {
        guard let thread = model.thread(id: threadID), thread.attention != .archived else { return }
        if model.requiresArchiveConfirmation {
            pendingThreadArchiveID = threadID
        } else {
            model.setAttention(threadID: threadID, attention: .archived)
        }
    }

    private func confirmThreadArchive() {
        guard let threadID = pendingThreadArchiveID else { return }
        pendingThreadArchiveID = nil
        model.setAttention(threadID: threadID, attention: .archived)
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
            KanameAccessibilityAnnouncement.post(message)
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
        dismissCompactInspector(restoringFocus: false)
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
        let action = workspaceChromePresentation.inspectorToggleAction
        switch action {
        case let .setSplitVisible(isVisible):
#if os(macOS)
            let previousResponder = currentDesktopResponder()
#endif
            preservingWindowFrame {
                showsInspector = isVisible
                showsCompactInspector = false
            }
#if os(macOS)
            restoreDesktopResponder(previousResponder)
#endif
        case let .setCompactPopoverPresented(isPresented):
            if isPresented {
                presentCompactInspector()
            } else {
                dismissCompactInspector(restoringFocus: true)
            }
        }
    }

    private func presentCompactInspector() {
        guard !showsCompactInspector else { return }
#if os(macOS)
        compactInspectorPreviousResponder = currentDesktopResponder()
#endif
        showsCompactInspector = true
    }

    private func dismissCompactInspector(restoringFocus: Bool) {
#if os(macOS)
        guard showsCompactInspector || compactInspectorPreviousResponder != nil else { return }
#else
        guard showsCompactInspector else { return }
#endif
        showsCompactInspector = false
#if os(macOS)
        let responder = compactInspectorPreviousResponder
        compactInspectorPreviousResponder = nil
        if restoringFocus {
            restoreDesktopResponder(responder)
        }
#endif
    }

    private func updateWorkspaceWidth(_ width: CGFloat) {
        let resolvedWidth = width.isFinite ? max(0, Double(width)) : 0
        let usesCompactLayout = resolvedWidth < DesktopWorkspaceChromePresentation.splitInspectorMinimumWidth
        guard workspaceUsesCompactLayout != usesCompactLayout else { return }
        workspaceUsesCompactLayout = usesCompactLayout
        if !usesCompactLayout {
            dismissCompactInspector(restoringFocus: true)
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
        if showsCompactInspector {
            dismissCompactInspector(restoringFocus: true)
            return true
        }
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
        dismissCompactInspector(restoringFocus: false)
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
func currentDesktopResponder() -> NSResponder? {
    (NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow)?.firstResponder
}

@MainActor
func restoreDesktopResponder(_ responder: NSResponder?) {
    DispatchQueue.main.async {
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        guard let responder, window?.makeFirstResponder(responder) == true else {
            window?.makeFirstResponder(nil)
            return
        }
    }
}

#endif

private struct KanameIdentityRow: View {
    var body: some View {
        HStack(spacing: KanameSpacing.medium) {
            ZStack {
                // The identity mark is Kaname's one brand-only primitive exception;
                // product chrome around it continues to use adaptive semantic roles.
                RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [KanameColor.accent, KanameColor.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("要")
                    .kanameSemanticFont(.title2.weight(.bold))
                    .foregroundStyle(KanameColor.canvas)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            KanameSectionHeader("Kaname", detail: "Local-first desktop")
        }
        .accessibilityElement(children: .combine)
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
