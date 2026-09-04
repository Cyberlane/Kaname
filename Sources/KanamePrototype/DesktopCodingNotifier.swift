import AppKit
import Foundation
import KanameDesktop
import UserNotifications

/// Local notifications for the moments a coding thread needs Justin: a plan
/// waiting for approval, an implementation turn finished, a knowledge draft
/// ready, or a run that stopped. Posted only while Kaname is not the active
/// app, so working inside the window stays quiet. Respects the preview privacy
/// preference by omitting thread titles when previews are hidden.
@MainActor
enum DesktopCodingNotifier {
    private static var requested = false

    static func notify(kind: Kind, threadTitle: String, hideDetails: Bool) {
        guard !NSApp.isActive else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            if !requested {
                requested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = kind.title
            content.body = hideDetails ? kind.genericBody : "\(threadTitle): \(kind.body)"
            content.sound = kind == .runFailed || kind == .automationRunFailed ? .defaultCritical : .default
            content.threadIdentifier = kind == .effectProposed || kind == .automationRunFailed ? "kaname.automations" : "kaname.coding"
            let request = UNNotificationRequest(
                identifier: "kaname.coding.\(kind.rawValue).\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    enum Kind: String {
        case planReady, implementationFinished, knowledgeDraftReady, runFailed, effectProposed, automationRunFailed

        var title: String {
            switch self {
            case .planReady: "Plan ready to approve"
            case .implementationFinished: "Implementation turn finished"
            case .knowledgeDraftReady: "Knowledge update drafted"
            case .runFailed: "Kaname run stopped"
            case .effectProposed: "Automation needs approval"
            case .automationRunFailed: "Automation run failed"
            }
        }

        var body: String {
            switch self {
            case .planReady: "review the plan, ask for changes, or approve."
            case .implementationFinished: "review Changes, run checks, or keep steering."
            case .knowledgeDraftReady: "review the proposed notes in the Knowledge tab."
            case .runFailed: "open the thread to see why and retry."
            case .effectProposed: "approve or reject the proposed effect in Run history."
            case .automationRunFailed: "open Run history to see which node failed and why."
            }
        }

        var genericBody: String {
            switch self {
            case .planReady: "A plan is waiting for your approval."
            case .implementationFinished: "An implementation turn finished."
            case .knowledgeDraftReady: "A knowledge update is ready to review."
            case .runFailed: "A run stopped and needs attention."
            case .effectProposed: "An automation effect needs your approval."
            case .automationRunFailed: "An automation run failed."
            }
        }
    }
}
