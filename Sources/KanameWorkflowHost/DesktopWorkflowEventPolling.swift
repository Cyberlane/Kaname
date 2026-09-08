import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Shared plumbing for the durable pollers that turn external changes (mail
/// and calendar) into `trigger.event` occurrences: cursor files under
/// `Workflows/`, and the gate that skips API calls while no workflow is active.
public enum DesktopWorkflowEventPolling {
    /// Bounded transaction state shared by provider pollers. A cursor is
    /// committed only after every fetched page and every event on those pages
    /// has been admitted. A failed transaction deliberately replays from its
    /// original cursor.
    struct CursorAdmissionState: Sendable {
        let originalCursor: String
        let maximumPages: Int
        let maximumEnrichments: Int
        private(set) var latestCursor: String
        private(set) var pages = 0
        private(set) var enrichments = 0
        private(set) var failed = false
        private(set) var complete = false
        private var seenPageTokens = Set<String>()

        init(cursor: String, maximumPages: Int, maximumEnrichments: Int) {
            self.originalCursor = cursor
            self.maximumPages = max(maximumPages, 1)
            self.maximumEnrichments = max(maximumEnrichments, 1)
            self.latestCursor = cursor
        }

        mutating func reserveEnrichment() -> Bool {
            guard !failed, enrichments < maximumEnrichments else {
                failed = true
                return false
            }
            enrichments += 1
            return true
        }

        mutating func acceptPage(latestCursor: String, nextPageToken: String?) -> Bool {
            guard !failed else { return false }
            pages += 1
            guard pages <= maximumPages else {
                failed = true
                return false
            }
            if !latestCursor.isEmpty { self.latestCursor = latestCursor }
            if let nextPageToken {
                guard seenPageTokens.insert(nextPageToken).inserted else {
                    failed = true
                    return false
                }
                complete = false
            } else {
                complete = true
            }
            return true
        }

        mutating func fail() { failed = true }

        var committedCursor: String? {
            guard !failed, complete else { return nil }
            return latestCursor
        }
    }

    static func cursorsURL(_ environment: KanameDesktopEnvironment, file: String) -> URL {
        environment.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent(file)
    }

    /// Returns nil for a present but malformed cursor file. Callers must stop
    /// before provider access so corruption cannot be interpreted as an empty
    /// cursor map and silently baseline away a backlog.
    static func loadCursorsStrict(_ url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            let marker = url.deletingPathExtension().appendingPathExtension("error.json")
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "error": "cursor_file_malformed",
                "path": url.lastPathComponent,
                "detectedAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
            ]
            if let markerData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? markerData.write(to: marker, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
            return nil
        }
        return object
    }

    static func loadCursors(_ url: URL) -> [String: String] {
        loadCursorsStrict(url) ?? [:]
    }

    @discardableResult
    static func saveCursorsChecked(_ cursors: [String: String], to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )) != nil,
        let data = try? JSONSerialization.data(withJSONObject: cursors, options: [.prettyPrinted, .sortedKeys]),
        (try? data.write(to: url, options: [.atomic])) != nil,
        (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
        else { return false }
        return true
    }

    static func saveCursors(_ cursors: [String: String], to url: URL) {
        _ = saveCursorsChecked(cursors, to: url)
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
    public struct WebhookEndpoint: Equatable {
        public let port: UInt16
        public let token: String

        public func url(for contract: String) -> String { "http://127.0.0.1:\(port)/hook/\(contract)" }
    }

    public static func webhookEndpoint(_ environment: KanameDesktopEnvironment) -> WebhookEndpoint? {
        let url = cursorsURL(environment, file: "webhook-endpoint.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String,
              port > 0, port <= 65_535, !token.isEmpty else { return nil }
        return WebhookEndpoint(port: UInt16(port), token: token)
    }
}
