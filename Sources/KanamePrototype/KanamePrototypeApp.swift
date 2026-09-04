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

#if DEBUG
private let kanameDesktopWindowTitle = "Kaname - Dev"
#else
private let kanameDesktopWindowTitle = "Kaname"
#endif
#endif

#if os(macOS)
@main
struct KanamePrototypeApp: App {
    @NSApplicationDelegateAdaptor(KanameDesktopAppDelegate.self) private var appDelegate
    private let singleInstance = KanameDesktopSingleInstanceCoordinator.acquireOrExit()

    var body: some Scene {
        Window(kanameDesktopWindowTitle, id: "main") {
            KanameDesktopWorkspace(gitControl: appDelegate.gitControl)
                .tint(KanameColor.accent)
                .modifier(KanameAppearanceModifier())
        }
        .defaultSize(width: 1_520, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(name: .kanameBeginConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Import Files into Draft…") {
                    NotificationCenter.default.post(name: .kanameImportFiles, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Current Context…") {
                    NotificationCenter.default.post(name: .kanameExportCurrent, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .kanamePresentSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Conversation") {
                Button("Focus Composer") {
                    NotificationCenter.default.post(name: .kanameFocusComposer, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Interrupt Current Run") {
                    NotificationCenter.default.post(name: .kanameInterruptCurrent, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
                Button("Retry Last Turn") {
                    NotificationCenter.default.post(name: .kanameRetryCurrent, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Open Command Center…") {
                    NotificationCenter.default.post(name: .kanamePresentGlobalSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                navigationButton("Home", destination: "home", key: "1")
                navigationButton("Conversations", destination: "threads", key: "2")
                navigationButton("Inbox", destination: "inbox", key: "3")
                navigationButton("Projects", destination: "projects", key: "4")
                Divider()
                Button("Go Back") {
                    NotificationCenter.default.post(name: .kanameGoBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .kanameToggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }

    private func navigationButton(_ title: String, destination: String, key: KeyEquivalent) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .kanameNavigate, object: destination)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
#else
@main
struct KanamePrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            IPhoneControlSurface()
                .tint(KanameColor.accent)
                .modifier(KanameAppearanceModifier())
        }
    }
}
#endif

#if os(macOS)
@MainActor
final class KanameDesktopAppDelegate: NSObject, NSApplicationDelegate {
    let gitControl = DesktopGitControlService(
        managedRoot: KanameDesktopEnvironment.current.worktreeDirectory
    )
    private var fallbackWindow: NSWindow?
    private var postedMouseBackEvent = false
    private var activationObserver: NSObjectProtocol?
    private var readinessObserver: NSObjectProtocol?
    private var mouseBackMonitor: Any?

    override init() {
        super.init()
        readinessObserver = NotificationCenter.default.addObserver(
            forName: .kanameDesktopReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeHealthHandshake() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Workflow effects reach Gmail through this app-owned bridge; the Rust
        // executor's connector host forwards to it over a local socket.
        DesktopWorkflowConnectorBridge.shared.start(environment: KanameDesktopEnvironment.current)
        // New Gmail messages and calendar changes become trigger.event
        // occurrences for active workflows while the app is open (Google
        // credentials live here). GitHub notifications and webhooks are polled
        // by the local control service, which runs with the app closed.
        DesktopMailEventPoller.shared.start(environment: KanameDesktopEnvironment.current)
        DesktopCalendarEventPoller.shared.start(environment: KanameDesktopEnvironment.current)
        // Failed runs and effects awaiting approval raise a notification even
        // when Run history is not on screen.
        DesktopAutomationRunWatcher.shared.start()
        KanameDevelopmentRuntimeLogger.shared.record(.applicationStarted)
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

    private func writeHealthHandshake() {
        let environment = KanameDesktopEnvironment.current
        let versionValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        let buildValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        let version = (versionValue as? String) ?? "development"
        let build = (buildValue as? String) ?? "0"
        var payload: [String: Any] = [
            "channel": environment.channel.rawValue,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? environment.bundleIdentifier,
            "executablePath": Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "",
            "version": version,
            "build": build,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "windowID": NSApplication.shared.keyWindow?.windowNumber
                ?? NSApplication.shared.windows.first(where: \.isVisible)?.windowNumber
                ?? 0,
            "healthyAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
            "workspaceSchemaVersion": KanameDesktopStateSchema.currentVersion,
            "healthNonce": commandLineValue(after: "--kaname-update-nonce") ?? "",
            "bundleDigest": commandLineValue(after: "--kaname-update-bundle-digest") ?? "",
        ]
        if let runtimeLogSessionID = KanameDevelopmentRuntimeLogger.shared.sessionID {
            payload["runtimeLogSessionID"] = runtimeLogSessionID
            payload["runtimeLogSchemaVersion"] = KanameDevelopmentRuntimeLogRecord.currentSchemaVersion
        }
        do {
            try FileManager.default.createDirectory(
                at: environment.runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: environment.runtimeDirectory.path
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: environment.healthHandshakeURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: environment.healthHandshakeURL.path
            )
            KanameDevelopmentRuntimeLogger.shared.record(.applicationReady)
        } catch {
            KanameDevelopmentRuntimeLogger.shared.record(.healthHandshakeFailed)
            fputs("Kaname could not write its private UI health handshake.\n", stderr)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KanameDevelopmentRuntimeLogger.shared.record(.applicationWillTerminate)
        if let mouseBackMonitor {
            NSEvent.removeMonitor(mouseBackMonitor)
            self.mouseBackMonitor = nil
        }
        if let readinessObserver {
            NotificationCenter.default.removeObserver(readinessObserver)
            self.readinessObserver = nil
        }
    }

    private func commandLineValue(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ensureVisibleWindow(allowCreation: !flag)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        _ = ensureVisibleWindow(allowCreation: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .kanameImportFiles, object: urls)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureInitialWindow(remainingAttempts: Int) {
        if ensureVisibleWindow(allowCreation: false) { return }
        guard remainingAttempts > 0 else {
            _ = ensureVisibleWindow(allowCreation: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.configureInitialWindow(remainingAttempts: remainingAttempts - 1)
        }
    }

    @discardableResult
    private func ensureVisibleWindow(allowCreation: Bool) -> Bool {
        if let existing = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            existing.title = kanameDesktopWindowTitle
            existing.sharingType = .readOnly
            existing.styleMask.insert(.resizable)
            existing.minSize = NSSize(width: 1_080, height: 700)
            existing.setFrameAutosaveName("KanameDesktopWindow-\(KanameDesktopEnvironment.current.channel.rawValue)")
            KanameWindowResizeCursorOverlay.install(in: existing)
            applyRequestedWindowSize(to: existing)
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            postMouseBackEventIfRequested(to: existing)
            verifyResizeCursorsIfRequested(window: existing)
            captureSnapshotIfRequested(window: existing)
            return true
        }
        guard allowCreation else { return false }
        let controller = NSHostingController(
            rootView: KanameDesktopWorkspace(gitControl: gitControl)
                .tint(KanameColor.accent)
                .modifier(KanameAppearanceModifier())
        )
        let window = NSWindow(contentViewController: controller)
        window.title = kanameDesktopWindowTitle
        window.sharingType = .readOnly
        window.styleMask.insert(.resizable)
        window.setContentSize(requestedWindowSize ?? NSSize(width: 1_520, height: 940))
        window.minSize = NSSize(width: 1_080, height: 700)
        window.center()
        window.setFrameAutosaveName("KanameDesktopWindow-\(KanameDesktopEnvironment.current.channel.rawValue)")
        KanameWindowResizeCursorOverlay.install(in: window)
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        postMouseBackEventIfRequested(to: window)
        verifyResizeCursorsIfRequested(window: window)
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
        guard let outputPath = commandLineValue(after: "--snapshot") else { return }
        let outputURL = URL(fileURLWithPath: outputPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyRequestedWindowSize(to: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let captureWindow = window.attachedSheet ?? window
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

    private func verifyResizeCursorsIfRequested(window: NSWindow) {
        guard let outputPath = commandLineValue(after: "--desktop-verify-resize-cursors") else { return }
        let outputURL = URL(fileURLWithPath: outputPath)
        guard let overlay = KanameWindowResizeCursorOverlay.installed(in: window) else {
            finishResizeCursorQualification(nil, at: outputURL)
        }
        let checks = overlay.qualificationChecks()
        let receipt: [String: Any] = [
            "schemaVersion": 1,
            "resizable": window.styleMask.contains(.resizable),
            "checks": checks,
        ]
        finishResizeCursorQualification(receipt, at: outputURL)
    }
}

private final class KanameDesktopSingleInstanceCoordinator: @unchecked Sendable {
    private let activationNotification: Notification.Name

    private let instanceLock: KanameDesktopInstanceLock
    private var distributedObserver: NSObjectProtocol?

    static func acquireOrExit() -> KanameDesktopSingleInstanceCoordinator {
        do {
            return try KanameDesktopSingleInstanceCoordinator()
        } catch KanameDesktopInstanceLockError.alreadyRunning {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(KanameDesktopEnvironment.current.activationNotificationName),
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
        let environment = KanameDesktopEnvironment.current
        activationNotification = Notification.Name(environment.activationNotificationName)
        instanceLock = try KanameDesktopInstanceLock(lockFileURL: environment.desktopUIInstanceLockURL)
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: activationNotification,
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

private func finishResizeCursorQualification(_ receipt: [String: Any]?, at outputURL: URL) -> Never {
    guard let receipt,
          JSONSerialization.isValidJSONObject(receipt),
          let checks = receipt["checks"] as? [String: Bool],
          !checks.isEmpty,
          checks.values.allSatisfy({ $0 }) else {
        fputs("Kaname resize-cursor qualification failed.\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL, options: .atomic)
        Darwin.exit(EXIT_SUCCESS)
    } catch {
        fputs("Kaname could not write the resize-cursor qualification receipt.\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
}

/// SwiftUI can replace the cursor rectangles owned by its hosting hierarchy.
/// Keep a hit-test-transparent layer on the native window frame so macOS still
/// advertises the standard resize cursors at every edge and corner.
final class KanameWindowResizeCursorOverlay: NSView {
    private enum ResizePosition {
        case top
        case bottom
        case left
        case right
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private static let identifier = NSUserInterfaceItemIdentifier("KanameWindowResizeCursorOverlay")
    private static let edgeThickness: CGFloat = 8
    private static let cornerLength: CGFloat = 18
    private var resizeTrackingAreas: [NSTrackingArea] = []

    static func install(in window: NSWindow) {
        guard window.styleMask.contains(.resizable),
              let frameView = window.contentView?.superview else { return }
        window.acceptsMouseMovedEvents = true
        if let existing = frameView.subviews.first(where: { $0.identifier == identifier }) {
            existing.frame = frameView.bounds
            window.invalidateCursorRects(for: existing)
            return
        }

        let overlay = KanameWindowResizeCursorOverlay(frame: frameView.bounds)
        overlay.identifier = identifier
        overlay.autoresizingMask = [.width, .height]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        window.invalidateCursorRects(for: overlay)
    }

    static func installed(in window: NSWindow) -> KanameWindowResizeCursorOverlay? {
        window.contentView?.superview?.subviews.first {
            $0.identifier == identifier
        } as? KanameWindowResizeCursorOverlay
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        resizePosition(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              let position = resizePosition(at: convert(event.locationInWindow, from: nil)) else { return }
        let initialFrame = window.frame
        let initialPointer = NSEvent.mouseLocation

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp { break }
            let pointer = NSEvent.mouseLocation
            let deltaX = pointer.x - initialPointer.x
            let deltaY = pointer.y - initialPointer.y
            var frame = resizedFrame(
                initialFrame,
                position: position,
                deltaX: deltaX,
                deltaY: deltaY
            )
            constrain(&frame, position: position, window: window, initialFrame: initialFrame)
            window.setFrame(frame, display: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in resizeTrackingAreas {
            removeTrackingArea(trackingArea)
        }
        resizeTrackingAreas = resizeRegions().map { region in
            let trackingArea = NSTrackingArea(
                rect: region.rect,
                options: [.activeInKeyWindow, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            return trackingArea
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in resizeRegions() {
            addCursorRect(region.rect, cursor: resizeCursor(at: region.position))
        }
    }

    private func resizeCursor(at position: ResizePosition) -> NSCursor {
        if #available(macOS 15.0, *) {
            let nativePosition: NSCursor.FrameResizePosition = switch position {
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return NSCursor.frameResize(position: nativePosition, directions: .all)
        }
        switch position {
        case .top, .bottom:
            return .resizeUpDown
        default:
            return .resizeLeftRight
        }
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let position = resizePosition(at: point) {
            resizeCursor(at: position).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func qualificationChecks() -> [String: Bool] {
        updateTrackingAreas()
        resetCursorRects()
        let inset = Self.edgeThickness / 2
        let samples: [(String, NSPoint, ResizePosition)] = [
            ("top", NSPoint(x: bounds.midX, y: bounds.maxY - inset), .top),
            ("bottom", NSPoint(x: bounds.midX, y: bounds.minY + inset), .bottom),
            ("left", NSPoint(x: bounds.minX + inset, y: bounds.midY), .left),
            ("right", NSPoint(x: bounds.maxX - inset, y: bounds.midY), .right),
            ("topLeft", NSPoint(x: bounds.minX + inset, y: bounds.maxY - inset), .topLeft),
            ("topRight", NSPoint(x: bounds.maxX - inset, y: bounds.maxY - inset), .topRight),
            ("bottomLeft", NSPoint(x: bounds.minX + inset, y: bounds.minY + inset), .bottomLeft),
            ("bottomRight", NSPoint(x: bounds.maxX - inset, y: bounds.minY + inset), .bottomRight),
        ]
        var checks: [String: Bool] = [
            "overlayCoversFrame": frame == superview?.bounds,
            "centerPassesThrough": hitTest(NSPoint(x: bounds.midX, y: bounds.midY)) == nil,
            "resizeTrackingAreasInstalled": resizeTrackingAreas.count == samples.count,
            "trackingAreasUseExplicitEdgeRects": resizeTrackingAreas.allSatisfy {
                !$0.options.contains(.inVisibleRect) && !$0.rect.contains(NSPoint(x: bounds.midX, y: bounds.midY))
            },
            "windowAcceptsMouseMovedEvents": window?.acceptsMouseMovedEvents == true,
        ]
        for (name, point, expectedPosition) in samples {
            checks["\(name)HitTarget"] = hitTest(point) === self
            let cursor = resizeCursor(at: expectedPosition)
            cursor.set()
            checks["\(name)CursorSet"] = NSCursor.current === cursor
        }
        let initial = NSRect(x: 100, y: 100, width: 1_200, height: 800)
        let left = resizedFrame(initial, position: .left, deltaX: 40, deltaY: 0)
        let top = resizedFrame(initial, position: .top, deltaX: 0, deltaY: 40)
        checks["horizontalResizeGeometry"] = left.origin.x == 140 && left.width == 1_160
        checks["verticalResizeGeometry"] = top.origin.y == 100 && top.height == 840
        return checks
    }

    private func resizeRegions() -> [(position: ResizePosition, rect: NSRect)] {
        guard window?.styleMask.contains(.resizable) == true,
              bounds.width > Self.cornerLength * 2,
              bounds.height > Self.cornerLength * 2 else { return [] }

        let edge = Self.edgeThickness
        let corner = Self.cornerLength
        let middleWidth = bounds.width - corner * 2
        let middleHeight = bounds.height - corner * 2
        return [
            (.top, NSRect(x: corner, y: bounds.maxY - edge, width: middleWidth, height: edge)),
            (.bottom, NSRect(x: corner, y: bounds.minY, width: middleWidth, height: edge)),
            (.left, NSRect(x: bounds.minX, y: corner, width: edge, height: middleHeight)),
            (.right, NSRect(x: bounds.maxX - edge, y: corner, width: edge, height: middleHeight)),
            (.topLeft, NSRect(x: bounds.minX, y: bounds.maxY - corner, width: corner, height: corner)),
            (.topRight, NSRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner)),
            (.bottomLeft, NSRect(x: bounds.minX, y: bounds.minY, width: corner, height: corner)),
            (.bottomRight, NSRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: corner)),
        ]
    }

    private func resizePosition(at point: NSPoint) -> ResizePosition? {
        let edge = Self.edgeThickness
        let left = point.x <= bounds.minX + edge
        let right = point.x >= bounds.maxX - edge
        let bottom = point.y <= bounds.minY + edge
        let top = point.y >= bounds.maxY - edge
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if top { return .top }
        if bottom { return .bottom }
        if left { return .left }
        if right { return .right }
        return nil
    }

    private func resizedFrame(
        _ initialFrame: NSRect,
        position: ResizePosition,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> NSRect {
        var frame = initialFrame
        switch position {
        case .left, .topLeft, .bottomLeft:
            frame.origin.x += deltaX
            frame.size.width -= deltaX
        case .right, .topRight, .bottomRight:
            frame.size.width += deltaX
        case .top, .bottom:
            break
        }
        switch position {
        case .bottom, .bottomLeft, .bottomRight:
            frame.origin.y += deltaY
            frame.size.height -= deltaY
        case .top, .topLeft, .topRight:
            frame.size.height += deltaY
        case .left, .right:
            break
        }
        return frame
    }

    private func constrain(
        _ frame: inout NSRect,
        position: ResizePosition,
        window: NSWindow,
        initialFrame: NSRect
    ) {
        let minimum = window.minSize
        let maximum = window.maxSize
        let constrainedWidth = min(max(frame.width, minimum.width), maximum.width)
        let constrainedHeight = min(max(frame.height, minimum.height), maximum.height)

        switch position {
        case .left, .topLeft, .bottomLeft:
            frame.origin.x = initialFrame.maxX - constrainedWidth
        default:
            break
        }
        switch position {
        case .bottom, .bottomLeft, .bottomRight:
            frame.origin.y = initialFrame.maxY - constrainedHeight
        default:
            break
        }
        frame.size = NSSize(width: constrainedWidth, height: constrainedHeight)
    }
}
#endif

/// Appearance preference: dark (the historical default), light, or follow the system.
struct KanameAppearanceModifier: ViewModifier {
    @AppStorage("kaname.appearance") private var appearance = "dark"

    func body(content: Content) -> some View {
        content.preferredColorScheme(
            appearance == "light" ? .light : (appearance == "system" ? nil : .dark)
        )
    }
}
