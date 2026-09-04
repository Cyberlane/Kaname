import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Turns GitHub notifications into workflow events.
///
/// Every three minutes the poller reads the authenticated `gh` user's
/// notification inbox and offers each new or updated entry to the Rust
/// executor as a `github.notification.received` event (review requests,
/// mentions, CI results, releases). The executor fans it out to every active
/// workflow whose entrypoint is `trigger.event` with that contract and
/// deduplicates by notification identity plus update time. Seen entries
/// persist under Workflows/github-cursors.json; the first poll only records
/// what already exists so the inbox is not replayed.
final class DesktopGitHubEventPoller: @unchecked Sendable {
    static let shared = DesktopGitHubEventPoller()
    static let eventContract = "github.notification.received"

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.github-event-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var environment: KanameDesktopEnvironment = .current
    private let service = GitHubControlService(timeout: .seconds(30))
    private var isPolling = false

    private init() {}

    func start(environment: KanameDesktopEnvironment) {
        queue.async { [self] in
            guard timer == nil else { return }
            self.environment = environment
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 100, repeating: 180)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private var cursorsURL: URL {
        DesktopWorkflowEventPolling.cursorsURL(environment, file: "github-cursors.json")
    }

    private func poll() {
        guard !isPolling, let runner = LocalCoreRunner.bundled() else { return }
        isPolling = true
        Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            guard await DesktopWorkflowEventPolling.hasActiveWorkflows(runner: runner, poller: "github-poller") else { return }
            guard let notifications = try? await service.notifications(unreadOnly: false, limit: 50) else { return }
            let seen = DesktopWorkflowEventPolling.loadCursors(self.cursorsURL)
            var next: [String: String] = [:]
            let baseline = seen.isEmpty
            for notification in notifications {
                next[notification.id] = notification.updatedAt
                guard !baseline, seen[notification.id] != notification.updatedAt else { continue }
                _ = try? await runner.fanOutWorkflowEvent(
                    contract: Self.eventContract,
                    eventID: "github:notification:\(notification.id):\(notification.updatedAt)",
                    contractKey: notification.subjectURL.isEmpty ? notification.id : notification.subjectURL,
                    input: [
                        "notificationId": notification.id,
                        "reason": notification.reason,
                        "unread": notification.unread,
                        "updatedAt": notification.updatedAt,
                        "repository": notification.repository,
                        "subjectTitle": notification.subjectTitle,
                        "subjectType": notification.subjectType,
                        "subjectUrl": notification.subjectURL,
                        "provider": "github",
                    ]
                )
            }
            // Keep the file bounded to what GitHub still lists, plus a marker so
            // an empty inbox does not look like a first run.
            if next.isEmpty { next["_baseline"] = seen["_baseline"] ?? ISO8601DateFormatter().string(from: Date()) }
            else { next["_baseline"] = seen["_baseline"] ?? ISO8601DateFormatter().string(from: Date()) }
            DesktopWorkflowEventPolling.saveCursors(next, to: self.cursorsURL)
        }
    }
}
