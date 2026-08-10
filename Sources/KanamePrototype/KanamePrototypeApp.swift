import Foundation
import SwiftUI
import KanameConnectivity
import KanameDesktop
import KanameDomain
import KanameFixtures
import KanamePrototypeUI
#if os(macOS)
import AppKit
import Darwin
#endif

@main
struct KanamePrototypeApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(KanameDesktopAppDelegate.self) private var appDelegate
    private let singleInstance = KanameDesktopSingleInstanceCoordinator.acquireOrExit()
#endif

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            KanameDesktopWorkspace()
                .tint(Nord.frost2)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_520, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
#else
        WindowGroup {
            IPhoneControlSurface()
                .tint(Nord.frost2)
                .preferredColorScheme(.dark)
        }
#endif
    }
}

#if os(macOS)
@MainActor
final class KanameDesktopAppDelegate: NSObject, NSApplicationDelegate {
    private var fallbackWindow: NSWindow?
    private var postedMouseBackEvent = false
    private var activationObserver: NSObjectProtocol?
    private var mouseBackMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mouseBackMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
            guard event.buttonNumber == 3 else { return event }
            let handled = DesktopBackCommandRouter.shared.performBack()
            if CommandLine.arguments.contains("--require-mouse-back-handled"), !handled {
                fputs("Kaname did not handle the requested mouse Back event.\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
            return handled ? nil : event
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: .kanameActivateExistingInstance,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.ensureVisibleWindow(allowCreation: true)
            }
        }
        configureInitialWindow(remainingAttempts: 20)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseBackMonitor {
            NSEvent.removeMonitor(mouseBackMonitor)
            self.mouseBackMonitor = nil
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ensureVisibleWindow(allowCreation: !flag)
        return true
    }

    private func configureInitialWindow(remainingAttempts: Int) {
        if ensureVisibleWindow(allowCreation: false) { return }
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.configureInitialWindow(remainingAttempts: remainingAttempts - 1)
        }
    }

    @discardableResult
    private func ensureVisibleWindow(allowCreation: Bool) -> Bool {
        if let existing = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            existing.sharingType = .readOnly
            applyRequestedWindowSize(to: existing)
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            postMouseBackEventIfRequested(to: existing)
            captureSnapshotIfRequested(window: existing)
            return true
        }
        guard allowCreation else { return false }
        let controller = NSHostingController(
            rootView: KanameDesktopWorkspace()
                .tint(Nord.frost2)
                .preferredColorScheme(.dark)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Kaname"
        window.sharingType = .readOnly
        window.setContentSize(requestedWindowSize ?? NSSize(width: 1_520, height: 940))
        window.minSize = NSSize(width: 1_080, height: 700)
        window.center()
        window.setFrameAutosaveName("KanameDesktopWindow")
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        postMouseBackEventIfRequested(to: window)
        captureSnapshotIfRequested(window: window)
        return true
    }

    private var requestedWindowSize: NSSize? {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--desktop-window-size"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        let dimensions = arguments[flagIndex + 1].lowercased().split(separator: "x", maxSplits: 1)
        guard dimensions.count == 2,
              let width = Double(dimensions[0]),
              let height = Double(dimensions[1]),
              width >= 1_080,
              height >= 700 else { return nil }
        return NSSize(width: width, height: height)
    }

    private func applyRequestedWindowSize(to window: NSWindow) {
        guard let requestedWindowSize else { return }
        window.setContentSize(requestedWindowSize)
        window.center()
    }

    private func postMouseBackEventIfRequested(to window: NSWindow) {
        guard CommandLine.arguments.contains("--post-mouse-back"), !postedMouseBackEvent else { return }
        postedMouseBackEvent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let button = CGMouseButton(rawValue: 3),
                  let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .otherMouseUp,
                    mouseCursorPosition: CGPoint(x: window.frame.midX, y: window.frame.midY),
                    mouseButton: button
                  ),
                  let nativeEvent = NSEvent(cgEvent: event) else { return }
            NSApplication.shared.postEvent(nativeEvent, atStart: false)
        }
    }

    private func captureSnapshotIfRequested(window: NSWindow) {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.indices.contains(flagIndex + 1) else { return }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyRequestedWindowSize(to: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let captureWindow = window.attachedSheet ?? window
                if let capture = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    CGWindowID(captureWindow.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]
                ),
                let png = NSBitmapImageRep(cgImage: capture)
                    .representation(using: .png, properties: [:]) {
                    finishSnapshotCapture(png, at: outputURL)
                }
                guard let contentView = captureWindow.contentView else {
                    finishSnapshotCapture(nil, at: outputURL)
                }
                contentView.layoutSubtreeIfNeeded()
                guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                    finishSnapshotCapture(nil, at: outputURL)
                }
                contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
                finishSnapshotCapture(
                    bitmap.representation(using: .png, properties: [:]),
                    at: outputURL
                )
            }
        }
    }
}

private final class KanameDesktopSingleInstanceCoordinator: @unchecked Sendable {
    private static let activationNotification = Notification.Name(
        "com.cyberlane.kaname.desktop.activate-existing-instance"
    )

    private let instanceLock: KanameDesktopInstanceLock
    private var distributedObserver: NSObjectProtocol?

    static func acquireOrExit() -> KanameDesktopSingleInstanceCoordinator {
        do {
            return try KanameDesktopSingleInstanceCoordinator()
        } catch KanameDesktopInstanceLockError.alreadyRunning {
            DistributedNotificationCenter.default().postNotificationName(
                activationNotification,
                object: nil,
                deliverImmediately: true
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("Kaname could not establish its single-instance lock.\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private init() throws {
        instanceLock = try KanameDesktopInstanceLock()
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.activationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .kanameActivateExistingInstance, object: nil)
            }
        }
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }
}

private extension Notification.Name {
    static let kanameActivateExistingInstance = Notification.Name(
        "com.cyberlane.kaname.desktop.activate-existing-instance.local"
    )
}

private func finishSnapshotCapture(_ png: Data?, at outputURL: URL) -> Never {
    guard let png else {
        fputs("Kaname could not capture the requested snapshot.\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
    do {
        try png.write(to: outputURL, options: .atomic)
        Darwin.exit(EXIT_SUCCESS)
    } catch {
        fputs("Kaname could not write the requested snapshot.\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
}
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
                .background(Nord.polarNight1)
                .frame(maxHeight: .infinity)

                    Divider()
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Nord.snowStorm0)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .navigationTitle("Kaname")
            .background(Nord.polarNight1)
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            } content: {
            content
                .background(Nord.polarNight0)
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
                .background(Nord.polarNight1)
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
                .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))

                if drafted {
                    Label("Local starter draft created — no external action taken", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Nord.auroraGreen)
                }

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 500, minHeight: 380, alignment: .topLeading)
            .background(Nord.polarNight0)
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
        .preferredColorScheme(.dark)
        .tint(Nord.frost2)
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
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
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
                    .foregroundStyle(Nord.frost1)
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
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
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

private struct PhaseBanner: View {
    var body: some View {
        Label("Phase 0 validation — deterministic fixtures only", systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Nord.frost1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Nord.polarNight2, in: Capsule())
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
            StatusLine(label: "Fixture provider", detail: "available", tint: Nord.auroraGreen)
            StatusLine(label: "External accounts", detail: "not connected", tint: Nord.polarNight3)
            StatusLine(label: "Mobile design", detail: "separate redesign pending", tint: Nord.frost2)
        }
        .padding(14)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
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
                    AttentionBadge(attention: projection?.attention ?? .none)
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
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open the thread for \(fixture.thread.title)")
    }
}

private struct AttentionBadge: View {
    let attention: AttentionState

    var body: some View {
        Text(attention.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(attention.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(attention.tint.opacity(0.13), in: Capsule())
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

private struct ThreadsView: View {
    let fixtures: [Phase0Fixture]
    let openFixture: (Phase0Fixture) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhaseBanner()
                Text("Conversations with durable context")
                    .font(.largeTitle.weight(.bold))
                Text("Threads are the chat-like continuity for a task. Inbox is the separate attention view over those same conversations.")
                    .foregroundStyle(.secondary)

                LazyVStack(spacing: 10) {
                    ForEach(fixtures, id: \.name) { fixture in
                        Button {
                            openFixture(fixture)
                        } label: {
                            ThreadDirectoryRow(fixture: fixture)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ThreadDirectoryRow: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: fixture.thread.workspaceKind.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(fixture.thread.title)
                        .font(.headline)
                    Spacer()
                    AttentionBadge(attention: projection?.attention ?? .none)
                }
                Text(fixture.task.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(fixture.providerSession.provider) · \(fixture.thread.workspaceKind.displayName) context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(16)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum ThreadPanel: String, CaseIterable, Identifiable {
    case conversation
    case work
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .work: "Work"
        case .review: "Review"
        }
    }
}

private struct ThreadWorkspaceView: View {
    let fixture: Phase0Fixture
    let returnTitle: String?
    let onBack: () -> Void
    @State private var selectedPanel: ThreadPanel = .conversation

    var body: some View {
        let projection = try? fixture.makeProjection()

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PhaseBanner()

                if let returnTitle {
                    Button {
                        onBack()
                    } label: {
                        Label("Back to \(returnTitle)", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fixture.thread.title)
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        AttentionBadge(attention: projection?.attention ?? .none)
                    }
                    Text("\(fixture.providerSession.provider) · \(fixture.thread.workspaceKind.displayName) workspace")
                        .foregroundStyle(.secondary)
                }

                ThreadSummary(fixture: fixture, projection: projection)

                if fixture.thread.workspaceKind == .coding {
                    Picker("Thread panel", selection: $selectedPanel) {
                        ForEach(ThreadPanel.allCases) { panel in
                            Text(panel.title).tag(panel)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            switch selectedPanel {
            case .conversation:
                ThreadConversationView(fixture: fixture)
                    .padding(.horizontal, 24)
            case .work:
                ScrollView {
                    CodingWorkView(fixture: fixture)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            case .review:
                ScrollView {
                    CodeReviewView(fixture: fixture)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Nord.polarNight0)
        .onChange(of: fixture.name) { _ in
            selectedPanel = .conversation
        }
    }
}

private struct ThreadConversationView: View {
    let fixture: Phase0Fixture
    @State private var showsActivity = false
    @State private var draft = ""
    @State private var locallyQueuedReplies: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConversationBubble(
                        role: .user,
                        author: "Justin",
                        message: "Could you \(fixture.task.title.lowercased())? Keep the selected \(fixture.thread.workspaceKind.displayName.lowercased()) context separate from unrelated work."
                    )
                    ConversationBubble(
                        role: .agent,
                        author: fixture.providerSession.provider,
                        message: fixture.conversationSummary
                    )

                    if !fixture.approvals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Decision required")
                                .font(.headline)
                            ForEach(fixture.approvals, id: \.id) { approval in
                                ApprovalCard(approval: approval)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsActivity.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Label("Agent activity · \(fixture.events.count) events", systemImage: "bolt.horizontal.circle")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: showsActivity ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Nord.frost1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Agent activity")
                        .accessibilityHint(showsActivity ? "Collapse activity" : "Expand activity")

                        if showsActivity {
                            VStack(spacing: 8) {
                                ForEach(fixture.events, id: \.id) { event in
                                    EventRow(event: event)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))

                    if !fixture.queueItems.isEmpty {
                        QueueCard(queueItems: fixture.queueItems)
                    }

                    if !locallyQueuedReplies.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Queued locally")
                                .font(.headline)
                            ForEach(locallyQueuedReplies, id: \.self) { reply in
                                Text(reply)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Nord.frost3.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Reply or queue a follow-up", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button("Queue") {
                        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedDraft.isEmpty else { return }
                        locallyQueuedReplies.append(trimmedDraft)
                        draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Fixture only: queuing changes local prototype state and never contacts a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Nord.polarNight1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum ConversationRole {
    case user
    case agent
}

private struct ConversationBubble: View {
    let role: ConversationRole
    let author: String
    let message: String

    var body: some View {
        HStack(alignment: .top) {
            if role == .agent {
                bubble
                Spacer(minLength: 80)
            } else {
                Spacer(minLength: 80)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(author)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            role == .user ? Nord.frost3.opacity(0.32) : Nord.polarNight1,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

private struct CodingWorkView: View {
    let fixture: Phase0Fixture

    var body: some View {
        Group {
            if fixture.thread.workspaceKind != .coding {
                DomainUnavailableView(
                    title: "No coding workspace attached",
                    detail: "This conversation has a \(fixture.thread.workspaceKind.displayName.lowercased()) context, so it has no worktree or code-quality evidence."
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Work stays attached to this conversation")
                        .font(.title2.weight(.bold))
                    Text("The quality loop is a review model inside coding work, not a separate destination.")
                        .foregroundStyle(.secondary)
                    QualityProgressStrip()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Current plan", systemImage: "list.bullet.clipboard")
                            .font(.headline)
                        Text("1. Inspect the selected repository context.\n2. Make the smallest isolated change.\n3. Present diffs, tests, and any not-run boundary for review.")
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    HStack {
                        CompactEvidence(label: "Workspace", value: "isolated fixture", tint: .blue)
                        CompactEvidence(label: "Plan", value: "approved", tint: .green)
                        CompactEvidence(label: "Evidence", value: "ready for review", tint: .orange)
                        CompactEvidence(label: "Knowledge", value: "proposal only", tint: .secondary)
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

private struct QualityProgressStrip: View {
    private let stages = ["Discuss", "Plan", "Approve", "Implement", "Review", "Accept", "Knowledge"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                VStack(spacing: 6) {
                    Circle()
                        .fill(index < 4 ? Color.green : (index == 4 ? Color.orange : Color.secondary.opacity(0.4)))
                        .frame(width: 12, height: 12)
                    Text(stage)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(height: 1)
                        .padding(.bottom, 18)
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ThreadSummary: View {
    let fixture: Phase0Fixture
    let projection: ThreadProjection?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fixture.thread.workspaceKind.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current task")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(fixture.task.title)
                    .font(.headline)
                Text("Run state: \(projection?.taskState.displayName ?? "Unknown") · event cursor \(projection?.latestSequence ?? 0)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Prototype data")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ApprovalCard: View {
    let approval: Approval
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    approval.status == .pending ? "Approval required" : "Approval \(approval.status.displayName)",
                    systemImage: "checkmark.shield"
                )
                .font(.headline)
                Spacer()
                Text(approval.action.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.13), in: Capsule())
            }

            LabeledContent("Target", value: approval.target)
            LabeledContent("Consequence", value: approval.consequence)

            if showsDetail {
                Divider()
                LabeledContent("Data leaving this Mac", value: approval.action.egressDescription)
                LabeledContent("Alternative", value: approval.action.alternativeDescription)
                Text("This is a fixture: these controls never contact a provider, account, repository, or calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(showsDetail ? "Hide decision detail" : "Inspect decision detail") {
                showsDetail.toggle()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CodingEvidenceSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Coding quality loop")
                    .font(.headline)
                Spacer()
                Text("Provider completed ≠ accepted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                CompactEvidence(label: "Plan", value: "approved", tint: .green)
                CompactEvidence(label: "Diff", value: "proposed", tint: .blue)
                CompactEvidence(label: "Tests", value: "review", tint: .orange)
                CompactEvidence(label: "Knowledge", value: "not updated", tint: .secondary)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CompactEvidence: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EventRow: View {
    let event: EventEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbolName)
                .frame(width: 22)
                .foregroundStyle(event.kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind.displayName)
                    .font(.body.weight(.medium))
                Text(event.origin.nativeType ?? event.kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("#\(event.sequence)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QueueCard: View {
    let queueItems: [QueueItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Offline queue", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                Text("Editable before dispatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(queueItems, id: \.id) { item in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(item.position)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(item.body)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CodeReviewView: View {
    let fixture: Phase0Fixture
    @State private var selectedFileID = DiffFixture.files[0].id
    @State private var question = ""
    @State private var draftedQuestion: String?

    private var selectedFile: DiffFile {
        DiffFixture.files.first { $0.id == selectedFileID } ?? DiffFixture.files[0]
    }

    var body: some View {
        Group {
            if fixture.thread.workspaceKind != .coding {
                DomainUnavailableView(
                    title: "No diff in this context",
                    detail: "Code review appears only in a coding conversation. Email, calendar, research, and knowledge work retain their own evidence surfaces."
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review evidence")
                                .font(.title2.weight(.bold))
                            Text("Changed files, diff, checks, and a scoped agent follow-up stay in the same coding conversation.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        AttentionBadge(attention: .needsReview)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Changed files")
                                .font(.headline)
                            ForEach(DiffFixture.files) { file in
                                Button {
                                    selectedFileID = file.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.path)
                                            .font(.caption.monospaced())
                                            .lineLimit(2)
                                        Text(file.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedFileID == file.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 220, alignment: .leading)

                        ScrollView(.horizontal) {
                            SyntaxHighlightedDiff(file: selectedFile)
                                .padding(14)
                        }
                        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
                    }

                    ReviewEvidenceList()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ask an agent about this review")
                            .font(.headline)
                        HStack {
                            TextField("For example: explain this change or investigate a failing check", text: $question)
                            Button("Draft task") {
                                let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmedQuestion.isEmpty else { return }
                                draftedQuestion = trimmedQuestion
                                question = ""
                            }
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .textFieldStyle(.roundedBorder)
                        if let draftedQuestion {
                            Text("Drafted locally: \(draftedQuestion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct DiffFile: Identifiable {
    let id: String
    let path: String
    let language: String
    let summary: String
    let patch: String
}

private enum DiffFixture {
    static let files: [DiffFile] = [
        DiffFile(
            id: "search-contract",
            path: "Sources/KanameDomain/SearchContract.swift",
            language: "Swift",
            summary: "+21 −4 · bounded result contract",
            patch: """
            --- a/Sources/KanameDomain/SearchContract.swift
            +++ b/Sources/KanameDomain/SearchContract.swift
            @@
            - let maximumResults = 1_000
            + let maximumResults = policy.maximumResults
            + guard policy.maximumResults > 0 else {
            +     throw SearchError.invalidLimit
            + }
            + return SearchPage(items: items.prefix(policy.maximumResults))
            """
        ),
        DiffFile(
            id: "search-tests",
            path: "Tests/KanameDomainTests/SearchContractTests.swift",
            language: "Swift",
            summary: "+18 · limit and error coverage",
            patch: """
            --- a/Tests/KanameDomainTests/SearchContractTests.swift
            +++ b/Tests/KanameDomainTests/SearchContractTests.swift
            @@
            + @Test func rejectsZeroLimit() throws {
            +     #expect(throws: SearchError.invalidLimit) {
            +         try makePage(limit: 0)
            +     }
            + }
            """
        ),
    ]
}

private struct SyntaxHighlightedDiff: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(file.language) syntax", systemImage: "textformat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Nord.frost1)
                Spacer()
                Text("+ addition  − deletion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            ForEach(Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Nord.polarNight3)
                        .frame(width: 24, alignment: .trailing)
                    syntaxText(for: String(line))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(lineBackground(for: String(line)), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(minWidth: 430, alignment: .leading)
    }

    private func lineBackground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Nord.auroraGreen.opacity(0.13)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Nord.auroraRed.opacity(0.13)
        }
        return .clear
    }

    private func syntaxText(for line: String) -> Text {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return Text(line).foregroundColor(Nord.frost1)
        }

        let first = line.first.map(String.init) ?? ""
        let source = first == "+" || first == "-" ? String(line.dropFirst()) : line
        let prefixColor = first == "+" ? Nord.auroraGreen : (first == "-" ? Nord.auroraRed : Nord.snowStorm0)
        return Text(first).foregroundColor(prefixColor) + swiftTokens(source, baseColor: Nord.snowStorm0)
    }

    private func swiftTokens(_ source: String, baseColor: Color) -> Text {
        let keywords: Set<String> = ["let", "var", "guard", "else", "throw", "return", "func", "try", "struct", "enum"]
        let tokens = source.split(separator: " ", omittingEmptySubsequences: false)

        return tokens.enumerated().reduce(Text("")) { result, entry in
            let token = String(entry.element)
            let normalized = token.trimmingCharacters(in: .punctuationCharacters)
            let color: Color
            if keywords.contains(normalized) {
                color = Nord.auroraPurple
            } else if token.contains("Search") || token.contains("Error") || token.contains("Page") {
                color = Nord.frost1
            } else if token.contains("\"") || token.allSatisfy({ $0.isNumber || $0 == "_" }) {
                color = Nord.auroraYellow
            } else {
                color = baseColor
            }
            return result + Text(token).foregroundColor(color)
        }
    }
}

private struct ReviewEvidenceList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Checks and evidence")
                .font(.headline)
            ReviewEvidenceRow(name: "Swift unit tests", status: "passed", detail: "4 deterministic projection tests", tint: .green)
            ReviewEvidenceRow(name: "Generic iOS build", status: "passed", detail: "iOS 16 compile target", tint: .green)
            ReviewEvidenceRow(name: "Visual QA", status: "not run", detail: "requires review after a real UI change", tint: .secondary)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ReviewEvidenceRow: View {
    let name: String
    let status: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(name)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct DomainUnavailableView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private struct CodingQualityLoopView: View {
    let fixture: Phase0Fixture
    @State private var selectedStage: QualityStage = .review

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhaseBanner()
                Text("Evidence before acceptance")
                    .font(.largeTitle.weight(.bold))
                Text("This surface keeps the plan, implementation evidence, and knowledge update distinct so provider completion is never mistaken for accepted work.")
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(QualityStage.allCases) { stage in
                        QualityStageCard(
                            stage: stage,
                            isSelected: selectedStage == stage
                        ) {
                            selectedStage = stage
                        }
                    }
                }

                QualityStageDetail(stage: selectedStage, fixture: fixture)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum QualityStage: String, CaseIterable, Identifiable {
    case discuss
    case plan
    case approve
    case implement
    case review
    case accept
    case updateKnowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discuss: "Discuss"
        case .plan: "Plan"
        case .approve: "Approve"
        case .implement: "Implement"
        case .review: "Review evidence"
        case .accept: "Accept"
        case .updateKnowledge: "Update knowledge"
        }
    }

    var status: String {
        switch self {
        case .discuss: "captured"
        case .plan: "approved"
        case .approve: "recorded"
        case .implement: "simulated"
        case .review: "current gate"
        case .accept: "waiting"
        case .updateKnowledge: "proposed"
        }
    }

    var tint: Color {
        switch self {
        case .discuss, .plan, .approve: .green
        case .implement: .blue
        case .review: .orange
        case .accept: .purple
        case .updateKnowledge: .secondary
        }
    }

    var detail: String {
        switch self {
        case .discuss:
            "The requested search workflow is attached to the coding thread with an explicit repository scope."
        case .plan:
            "The plan identifies the intended change, its verification, and the separate knowledge-update proposal."
        case .approve:
            "A code-change approval records its target, consequence, and reversibility before any implementation begins."
        case .implement:
            "The fixture renders a provider trace only. It makes no repository, worktree, or provider change."
        case .review:
            "Review gathers the diff, tests, diagnostics, and any not-run boundaries. This is the current gate in the fixture."
        case .accept:
            "Justin accepts or rejects evidence. Provider completion alone cannot advance this step."
        case .updateKnowledge:
            "A Lode or Obsidian update is proposed as a reviewable change after acceptance, never silently written."
        }
    }
}

private struct QualityStageCard: View {
    let stage: QualityStage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(stage.title)
                    .font(.subheadline.weight(.semibold))
                Text(stage.status)
                    .font(.caption)
                    .foregroundStyle(stage.tint)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(
                isSelected ? stage.tint.opacity(0.16) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? stage.tint : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct QualityStageDetail: View {
    let stage: QualityStage
    let fixture: Phase0Fixture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(stage.title)
                    .font(.title2.weight(.bold))
                Spacer()
                Text(stage.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stage.tint)
            }
            Text(stage.detail)
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("Thread", value: fixture.thread.title)
            LabeledContent("Evidence source", value: "deterministic coding-review fixture")
            LabeledContent("Boundary", value: stage == .review ? "provider completed; user acceptance not recorded" : "prototype only")
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StackPrototypeView: View {
    @State private var selectedLayerID = StackSample.layers[1].id
    @State private var agentDraft = ""
    @State private var draftedAgentTask: String?

    private var selectedLayer: StackLayer {
        StackSample.layers.first { $0.id == selectedLayerID } ?? StackSample.layers[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhaseBanner()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Stack-aware review")
                            .font(.largeTitle.weight(.bold))
                        Text("A stack is a dependency graph with layer-specific evidence, not a flat list of pull requests.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Open Cyberlane/Kaname", destination: URL(string: "https://github.com/Cyberlane/Kaname")!)
                        .font(.subheadline.weight(.semibold))
                }

                Text("Fixture mode: these layers are illustrative. A live GitHub adapter will replace them with actual pull-request URLs, checks, logs, reviews, and stack state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(StackSample.layers.enumerated()), id: \.element.id) { index, layer in
                            StackLayerRow(
                                layer: layer,
                                isSelected: selectedLayerID == layer.id,
                                showsConnector: index < StackSample.layers.count - 1
                            ) {
                                selectedLayerID = layer.id
                            }
                        }
                    }
                    .frame(maxWidth: 430, alignment: .leading)

                    StackLayerDetail(layer: selectedLayer)
                        .frame(maxWidth: 540, alignment: .leading)
                }

                StackAgentTaskComposer(
                    draft: $agentDraft,
                    draftedTask: $draftedAgentTask,
                    layer: selectedLayer
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StackLayer: Identifiable {
    let id: String
    let title: String
    let branch: String
    let pullRequest: String
    let checks: String
    let evidence: String
    let status: StackLayerStatus
}

private enum StackLayerStatus: String {
    case ready
    case review
    case blocked

    var tint: Color {
        switch self {
        case .ready: Nord.auroraGreen
        case .review: Nord.auroraYellow
        case .blocked: Nord.auroraRed
        }
    }

    var displayName: String { rawValue.capitalized }
}

private enum StackSample {
    static let layers: [StackLayer] = [
        StackLayer(
            id: "contracts",
            title: "Define search contracts",
            branch: "feat/search-contracts",
            pullRequest: "PR #18",
            checks: "4 checks passing",
            evidence: "Domain contract and deterministic fixtures reviewed.",
            status: .ready
        ),
        StackLayer(
            id: "adapter",
            title: "Add fake search adapter",
            branch: "feat/fake-search-adapter",
            pullRequest: "PR #19",
            checks: "1 review requested",
            evidence: "Depends on #18. The provider-native mapping stays visible here.",
            status: .review
        ),
        StackLayer(
            id: "surface",
            title: "Show search evidence",
            branch: "feat/search-evidence-surface",
            pullRequest: "PR #20",
            checks: "Waiting on #19",
            evidence: "May not merge until the lower adapter layer is accepted.",
            status: .blocked
        ),
    ]
}

private struct StackLayerRow: View {
    let layer: StackLayer
    let isSelected: Bool
    let showsConnector: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(layer.status.tint)
                        .frame(width: 12, height: 12)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(layer.title)
                                .font(.headline)
                            Spacer()
                            Text(layer.status.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(layer.status.tint)
                        }
                        Text("\(layer.pullRequest) · \(layer.branch)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(
                    isSelected ? layer.status.tint.opacity(0.14) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)

            if showsConnector {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 2, height: 24)
                    .padding(.leading, 19)
            }
        }
    }
}

private struct StackLayerDetail: View {
    let layer: StackLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(layer.pullRequest)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                AttentionBadge(attention: layer.status.attention)
            }
            Text(layer.title)
                .font(.title2.weight(.bold))
            Text(layer.evidence)
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("Branch", value: layer.branch)
            LabeledContent("Checks", value: layer.checks)
            LabeledContent("Merge rule", value: "Bottom-up dependency order")
            LabeledContent("Connection", value: "Thread, plan, worktree, and evidence attach to this layer")
            Divider()
            StackCheckList(layerID: layer.id)
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StackCheck: Identifiable {
    let id: String
    let name: String
    let status: StackLayerStatus
    let summary: String
    let logExcerpt: String
}

private enum StackCheckFixture {
    static func checks(for layerID: String) -> [StackCheck] {
        switch layerID {
        case "contracts":
            [
                StackCheck(
                    id: "contracts-tests",
                    name: "Swift unit tests",
                    status: .ready,
                    summary: "4 checks passed in 1.1 s",
                    logExcerpt: "ThreadProjectionTests: all deterministic replay checks passed."
                ),
                StackCheck(
                    id: "contracts-build",
                    name: "iOS build",
                    status: .ready,
                    summary: "generic iOS target built",
                    logExcerpt: "KanamePrototype compiled for iOS 16.0."
                ),
            ]
        case "adapter":
            [
                StackCheck(
                    id: "adapter-review",
                    name: "Code review",
                    status: .review,
                    summary: "one comment needs response",
                    logExcerpt: "Question: should unknown provider events be retained as opaque payloads?"
                ),
                StackCheck(
                    id: "adapter-tests",
                    name: "Contract tests",
                    status: .ready,
                    summary: "12 checks passed",
                    logExcerpt: "Adapter capabilities and degraded states match the fixture contract."
                ),
            ]
        default:
            [
                StackCheck(
                    id: "surface-dependency",
                    name: "Dependency gate",
                    status: .blocked,
                    summary: "waiting for PR #19 review",
                    logExcerpt: "This layer cannot merge until the adapter layer is accepted."
                ),
                StackCheck(
                    id: "surface-ui",
                    name: "Native UI test",
                    status: .review,
                    summary: "not run while dependency is blocked",
                    logExcerpt: "Run the focused native UI suite after the lower layer is current."
                ),
            ]
        }
    }
}

private struct StackCheckList: View {
    let layerID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CI, review, and diagnostics")
                .font(.headline)
            ForEach(StackCheckFixture.checks(for: layerID)) { check in
                StackCheckRow(check: check)
            }
        }
    }
}

private struct StackCheckRow: View {
    let check: StackCheck
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(check.status.tint).frame(width: 8, height: 8)
                Text(check.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(check.status.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(check.status.tint)
            }
            Text(check.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(showsLog ? "Hide details" : "Show diagnostic") {
                showsLog.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if showsLog {
                Text(check.logExcerpt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(check.status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StackAgentTaskComposer: View {
    @Binding var draft: String
    @Binding var draftedTask: String?
    let layer: StackLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a scoped agent conversation")
                .font(.headline)
            Text("Useful actions include explaining a failed check, proposing a minimal fix, reviewing a dependency, or preparing a re-run plan. The fixture only drafts the task locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Explain check") {
                    draft = "Explain the current CI and review state for \(layer.pullRequest)."
                }
                .buttonStyle(.bordered)
                Button("Propose fix") {
                    draft = "Propose the smallest safe fix for the blocked or failing evidence on \(layer.pullRequest)."
                }
                .buttonStyle(.bordered)
                Button("Plan re-run") {
                    draft = "List the checks to re-run for \(layer.pullRequest), their order, and expected evidence."
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("Ask an agent about this stack layer", text: $draft)
                Button("Draft task") {
                    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedDraft.isEmpty else { return }
                    draftedTask = trimmedDraft
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let draftedTask {
                Text("Local draft ready to attach to a new conversation: \(draftedTask)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case providers
    case projects
    case integrations
    case schedules
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "General & appearance"
        case .providers: "Providers & models"
        case .projects: "Projects & workspaces"
        case .integrations: "Integrations & accounts"
        case .schedules: "Schedules & notifications"
        case .privacy: "Privacy, security & data"
        case .about: "About, skills & updates"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .providers: "cpu"
        case .projects: "folder"
        case .integrations: "puzzlepiece.extension"
        case .schedules: "clock"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

private struct SettingsModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.64)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isPresented = false
                }

            SettingsPrototypeView {
                isPresented = false
            }
            .frame(maxWidth: 1_080, maxHeight: 720)
            .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Nord.polarNight3, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
            .padding(40)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { }
            .accessibilityAddTraits(.isModal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(macOS)
        .onExitCommand {
            isPresented = false
        }
#endif
    }
}

private struct SettingsPrototypeView: View {
    let close: () -> Void
    @AppStorage("kaname.fixture.settings.selected-category") private var selectedCategoryRaw = SettingsCategory.appearance.rawValue

    private var selectedCategory: SettingsCategory {
        SettingsCategory(rawValue: selectedCategoryRaw) ?? .appearance
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List {
                    Section("Kaname settings") {
                        ForEach(SettingsCategory.allCases) { category in
                            Button {
                                selectedCategoryRaw = category.rawValue
                            } label: {
                                Label(category.title, systemImage: category.symbolName)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .font(selectedCategory == category ? .body.weight(.semibold) : .body)
                                    .foregroundStyle(selectedCategory == category ? Nord.frost1 : Nord.snowStorm0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Nord.polarNight1)
                .frame(maxHeight: .infinity)

                Divider()
                Button {
                    close()
                } label: {
                    Label("Return to Kaname", systemImage: "arrow.left")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Nord.frost1)
                .padding(14)
            }
            .background(Nord.polarNight1)
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)

            Divider()

            SettingsDetail(category: selectedCategory, close: close)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Nord.polarNight0)
        }
        .frame(minWidth: 900, minHeight: 640)
    }
}

private struct SettingsDetail: View {
    let category: SettingsCategory
    let close: () -> Void
    @State private var theme = "Nord Dark"
    @State private var density = "Comfortable"
    @State private var inspectorVisible = true
    @State private var reduceMotion = false
    @State private var defaultProvider = "Choose per project"
    @State private var showProviderUsage = true
    @State private var networkToolApproval = true
    @State private var workspacePolicy = "Isolated worktree"
    @State private var requireGitReview = true
    @State private var suggestKnowledgeUpdate = true
    @State private var missedRunPolicy = "Skip / do nothing"
    @State private var scheduledNotifications = true
    @State private var maximumConcurrentRuns = 1
    @State private var externalCommunicationApproval = true
    @State private var keepAuditTrail = true
    @State private var retention = "90 days"
    @State private var localNotice: String?

    private var subtitle: String {
        switch category {
        case .appearance: "Personalize the Kaname workspace. Nord Dark remains your default; other themes are an OSS preference, not a different product state."
        case .providers: "Provider defaults are capability-aware and remain visible in the work they affect. This fixture has no authenticated provider."
        case .projects: "These defaults apply when creating a project; project-specific instructions and authority remain inspectable before a task runs."
        case .integrations: "Connections stay account-scoped and require an explicit setup flow. This prototype never opens an account or requests a credential."
        case .schedules: "Choose global defaults for durable scheduled work. Each task still shows its own time zone, trigger, authority, and missed-run policy."
        case .privacy: "Privacy controls establish safe defaults. They never bypass approval, disclose a secret, or join previously separate contexts."
        case .about: "Inspect the fixture's local state, planned skills provenance, and update behaviour without performing a network operation."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(category.title, systemImage: category.symbolName)
                        .font(.title.weight(.bold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                    Text("Phase 0 controls affect local preview state only.")
                        .font(.caption)
                        .foregroundStyle(Nord.frost1)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close Settings")
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                controls
            }
            .formStyle(.grouped)

            if let localNotice {
                Text(localNotice)
                    .font(.caption)
                    .foregroundStyle(Nord.frost1)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch category {
        case .appearance:
            Section("Theme") {
                Picker("Appearance", selection: $theme) {
                    Text("Nord Dark").tag("Nord Dark")
                    Text("Nord Light").tag("Nord Light")
                    Text("Follow system").tag("Follow system")
                }
                Picker("Workspace density", selection: $density) {
                    Text("Comfortable").tag("Comfortable")
                    Text("Compact").tag("Compact")
                }
            }
            Section("Workspace") {
                Toggle("Show context inspector by default", isOn: $inspectorVisible)
                Toggle("Reduce nonessential motion", isOn: $reduceMotion)
            }
        case .providers:
            Section("Defaults") {
                Picker("New coding conversations", selection: $defaultProvider) {
                    Text("Choose per project").tag("Choose per project")
                    Text("Claude — when available").tag("Claude — when available")
                    Text("Codex — when available").tag("Codex — when available")
                    Text("OpenCode — when available").tag("OpenCode — when available")
                }
                Toggle("Show provider usage in conversations", isOn: $showProviderUsage)
                Toggle("Request approval before a new network tool", isOn: $networkToolApproval)
            }
            Section("Connection state") {
                LabeledContent("Fixture provider", value: "No live account")
                Button("Review provider setup requirements") {
                    localNotice = "Provider setup is intentionally not implemented in this local fixture."
                }
            }
        case .projects:
            Section("New project defaults") {
                Picker("Workspace policy", selection: $workspacePolicy) {
                    Text("Isolated worktree").tag("Isolated worktree")
                    Text("Read-only review").tag("Read-only review")
                    Text("No repository").tag("No repository")
                }
                Toggle("Require review before Git branch actions", isOn: $requireGitReview)
                Toggle("Propose a knowledge update after acceptance", isOn: $suggestKnowledgeUpdate)
            }
            Section("Instructions and skills") {
                LabeledContent("Repository instructions", value: "Read before task start")
                LabeledContent("Project skills", value: "Scoped and auditable")
            }
        case .integrations:
            Section("Connections") {
                IntegrationSettingsRow(name: "GitHub", detail: "Not connected", action: { localNotice = "GitHub connection setup is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Obsidian", detail: "No vault operation", action: { localNotice = "Obsidian access is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Gmail", detail: "No account connected", action: { localNotice = "Gmail setup is unavailable in the fixture." })
                IntegrationSettingsRow(name: "Calendars", detail: "No account connected", action: { localNotice = "Calendar setup is unavailable in the fixture." })
            }
            Section("Safety") {
                Text("Connection setup will show the account, scope, data egress, permission, and recovery path before it stores a provider-managed reference.")
            }
        case .schedules:
            Section("Scheduled work") {
                Picker("Missed run default", selection: $missedRunPolicy) {
                    Text("Skip / do nothing").tag("Skip / do nothing")
                    Text("Run once when available").tag("Run once when available")
                    Text("Catch up").tag("Catch up")
                }
                Stepper("Maximum concurrent runs: \(maximumConcurrentRuns)", value: $maximumConcurrentRuns, in: 1...4)
                Toggle("Notify when scheduled work needs attention", isOn: $scheduledNotifications)
            }
            Section("Always per task") {
                LabeledContent("Time zone", value: "Explicit")
                LabeledContent("Run history", value: "Durable")
            }
        case .privacy:
            Section("Confirmation defaults") {
                Toggle("Confirm external communication", isOn: $externalCommunicationApproval)
                Toggle("Keep an inspectable local audit trail", isOn: $keepAuditTrail)
                Picker("Operational-data retention", selection: $retention) {
                    Text("30 days").tag("30 days")
                    Text("90 days").tag("90 days")
                    Text("1 year").tag("1 year")
                }
            }
            Section("Secrets and context") {
                LabeledContent("Secrets", value: "Provider-managed references only")
                LabeledContent("Context sharing", value: "Explicit attachments only")
            }
        case .about:
            Section("Fixture") {
                LabeledContent("Phase", value: "0 — deterministic local fixture")
                LabeledContent("Network", value: "No connection attempted")
                LabeledContent("Skills", value: "No runtime skill loaded")
            }
            Section("Diagnostics") {
                Button("Prepare local diagnostics summary") {
                    localNotice = "Local diagnostics summary prepared in the UI only; nothing was copied or sent."
                }
            }
        }
    }
}

private struct IntegrationSettingsRow: View {
    let name: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up…", action: action)
                .buttonStyle(.bordered)
        }
    }
}

private struct ContextInspector: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        List {
            Section("Selected context") {
                LabeledContent("Workspace", value: fixture.thread.workspaceKind.displayName)
                LabeledContent("Task", value: fixture.task.title)
                LabeledContent("Provider", value: fixture.providerSession.provider)
                LabeledContent("Native session", value: fixture.providerSession.nativeSessionID ?? "not exposed")
            }
            Section("State projection") {
                LabeledContent("Attention", value: projection?.attention.displayName ?? "Unknown")
                LabeledContent("Run", value: projection?.taskState.displayName ?? "Unknown")
                LabeledContent("Event cursor", value: "\(projection?.latestSequence ?? 0)")
            }
            Section("Trust boundary") {
                Text("Fixture-only: no provider, repository, account, vault, or notification service is contacted.")
                Text("Provider completion and accepted work are separate states.")
            }
        }
        .navigationTitle("Inspector")
    }
}

private struct LiveCodexContextInspector: View {
    var body: some View {
        List {
            Section("Execution contract") {
                LabeledContent("Provider", value: "Codex app-server")
                LabeledContent("Model", value: "GPT-5.6 Terra")
                LabeledContent("Reasoning", value: "Extra high")
                LabeledContent("Workspace", value: "Selected in this review")
            }
            Section("Isolation") {
                LabeledContent("Filesystem", value: "Selected worktree only")
                LabeledContent("Network", value: "Denied during write runs")
                LabeledContent("MCP servers", value: "None")
                LabeledContent("Apps", value: "Disabled")
            }
            Section("Authority") {
                Text("The local journal owns approvals and review decisions. Provider completion never accepts work automatically.")
                Text("Only the context explicitly selected in the coding surface is sent to Codex.")
            }
        }
        .navigationTitle("Live boundary")
    }
}

private extension Phase0Fixture {
    var conversationSummary: String {
        switch thread.workspaceKind {
        case .coding:
            "I’ve attached the plan, isolated-workspace boundary, and review evidence to this coding conversation. Open Work for the plan and Review for the proposed diff and checks."
        case .research:
            "I retained the provider-native streaming evidence and made the failure explicit. No conclusion has been accepted from this failed research run."
        case .email:
            "The draft is prepared, but sending remains a separate approval with its recipient scope and data egress visible."
        case .calendar:
            "The requested event change is ready for review. It remains pending until its consequence and alternatives are explicitly approved."
        case .knowledge:
            "The selected knowledge context is attached to this conversation and remains separate from unrelated projects and personal domains."
        }
    }
}

private extension TaskState {
    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .queued: "Queued"
        case .starting: "Starting"
        case .running: "Running"
        case .waitingForUser: "Waiting for you"
        case .completed: "Completed"
        case .accepted: "Accepted"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

private extension EventKind {
    var displayName: String {
        switch self {
        case .taskQueued: "Task queued"
        case .runStarting: "Run starting"
        case .runStarted: "Run started"
        case .approvalRequested: "Approval requested"
        case .approvalApproved: "Approval approved"
        case .approvalRejected: "Approval rejected"
        case .providerCompleted: "Provider completed"
        case .workAccepted: "Work accepted"
        case .runFailed: "Run failed"
        case .runCancelled: "Run cancelled"
        case .runInterrupted: "Run interrupted"
        case .nativeProviderEvent: "Native provider event"
        }
    }

    var detail: String {
        switch self {
        case .taskQueued: "Intent is durable and waiting for a run."
        case .runStarting: "Provider session is starting."
        case .runStarted: "Provider execution is active."
        case .approvalRequested: "A scoped decision is required before the side effect."
        case .approvalApproved: "The approval was recorded; the run may continue."
        case .approvalRejected: "The requested side effect was declined."
        case .providerCompleted: "Provider returned a result; review evidence is still required."
        case .workAccepted: "Justin accepted the reviewed outcome."
        case .runFailed: "The run ended with an explicit failure state."
        case .runCancelled: "The run was cancelled before completion."
        case .runInterrupted: "The run was deliberately interrupted."
        case .nativeProviderEvent: "Raw provider semantics are retained alongside the normalized event."
        }
    }

    var symbolName: String {
        switch self {
        case .taskQueued: "clock"
        case .runStarting, .runStarted: "play.circle"
        case .approvalRequested: "checkmark.shield"
        case .approvalApproved: "checkmark.circle"
        case .approvalRejected: "xmark.circle"
        case .providerCompleted: "checkmark.seal"
        case .workAccepted: "checkmark.seal.fill"
        case .runFailed: "exclamationmark.triangle"
        case .runCancelled, .runInterrupted: "pause.circle"
        case .nativeProviderEvent: "wrench.and.screwdriver"
        }
    }

    var tint: Color {
        switch self {
        case .approvalRequested, .providerCompleted: Nord.auroraYellow
        case .runFailed, .approvalRejected: Nord.auroraRed
        case .workAccepted, .approvalApproved: Nord.auroraGreen
        case .runCancelled, .runInterrupted: Nord.auroraPurple
        default: Nord.polarNight3
        }
    }
}

private extension StackLayerStatus {
    var attention: AttentionState {
        switch self {
        case .ready: .none
        case .review: .needsReview
        case .blocked: .failed
        }
    }
}
