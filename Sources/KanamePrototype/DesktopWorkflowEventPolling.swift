import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Shared plumbing for the app-side pollers that turn external changes (mail,
/// calendar, GitHub) into `trigger.event` occurrences: a cursor file under
/// `Workflows/`, and the gate that skips API calls while no workflow is active.
enum DesktopWorkflowEventPolling {
    static func cursorsURL(_ environment: KanameDesktopEnvironment, file: String) -> URL {
        environment.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent(file)
    }

    static func loadCursors(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    static func saveCursors(_ cursors: [String: String], to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if let data = try? JSONSerialization.data(withJSONObject: cursors, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// True when at least one workflow has an active revision, so a poller
    /// should spend external API calls at all.
    static func hasActiveWorkflows(runner: LocalCoreRunner, poller: String) async -> Bool {
        let library = DesktopWorkflowV2LibraryClient(transport: runner)
        guard let portfolio = try? await library.portfolio(requestID: "\(poller):\(UUID().uuidString.lowercased())") else {
            return false
        }
        return portfolio.contains { $0.activeRevisionID != nil }
    }

    /// The webhook endpoint the local control service publishes, if it has
    /// started at least once. Read-only view of `Workflows/webhook-endpoint.json`.
    struct WebhookEndpoint: Equatable {
        let port: UInt16
        let token: String

        func url(for contract: String) -> String { "http://127.0.0.1:\(port)/hook/\(contract)" }
    }

    static func webhookEndpoint(_ environment: KanameDesktopEnvironment) -> WebhookEndpoint? {
        let url = cursorsURL(environment, file: "webhook-endpoint.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String,
              port > 0, port <= 65_535, !token.isEmpty else { return nil }
        return WebhookEndpoint(port: UInt16(port), token: token)
    }
}
