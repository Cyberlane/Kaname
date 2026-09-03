import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore

/// Turns new Gmail messages into workflow events.
///
/// Every two minutes, for each Google account, the poller reads the mailbox
/// delta since the stored cursor and offers each added message to the Rust
/// executor as a `mail.message.received` event. The executor fans it out to
/// every active workflow whose entrypoint is `trigger.event` with that
/// contract and deduplicates by message identity. Cursors persist under
/// Workflows/mail-cursors.json; the first observation of an account only
/// records its cursor so the existing backlog is not replayed.
final class DesktopMailEventPoller: @unchecked Sendable {
    static let shared = DesktopMailEventPoller()
    static let eventContract = "mail.message.received"

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.mail-event-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var environment: KanameDesktopEnvironment = .current
    private var adapter: (any MailProviderAdapter)?
    private var isPolling = false

    private init() {}

    func start(environment: KanameDesktopEnvironment) {
        queue.async { [self] in
            guard timer == nil else { return }
            self.environment = environment
            let service = NativeGoogleIntegrationService(
                rootDirectory: environment.googleDirectory,
                keychainService: environment.googleKeychainService,
                clientConfiguration: nil,
                accessMode: environment.googleIntegrationAccessMode
            )
            adapter = GmailMailProviderAdapter(service: service)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 45, repeating: 120)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private var cursorsURL: URL {
        environment.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("mail-cursors.json")
    }

    private func loadCursors() -> [String: String] {
        guard let data = try? Data(contentsOf: cursorsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    private func saveCursors(_ cursors: [String: String]) {
        let directory = cursorsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: cursors, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: cursorsURL, options: [.atomic])
        }
    }

    private func poll() {
        guard !isPolling, let adapter, let runner = LocalCoreRunner.bundled() else { return }
        isPolling = true
        Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            // Only spend Gmail API calls when at least one active workflow exists.
            let library = DesktopWorkflowV2LibraryClient(transport: runner)
            guard let portfolio = try? await library.portfolio(requestID: "mail-poller:\(UUID().uuidString.lowercased())"),
                  portfolio.contains(where: { $0.activeRevisionID != nil }) else { return }
            guard let accounts = try? await adapter.accounts() else { return }
            var cursors = self.loadCursors()
            for account in accounts {
                let accountID = account.identity.localID
                guard let start = cursors[accountID] else {
                    if let current = try? await adapter.currentCursor(accountID: accountID) {
                        cursors[accountID] = current
                    }
                    continue
                }
                var pageToken: String?
                var latest = start
                var pages = 0
                repeat {
                    guard let page = try? await adapter.deltas(
                        accountID: accountID, startCursor: start, pageToken: pageToken, maximumResults: 100,
                        resourceID: nil, kinds: [.messageAdded]
                    ) else { break }
                    for event in page.events where event.kind == .messageAdded {
                        _ = try? await runner.fanOutWorkflowEvent(
                            contract: Self.eventContract,
                            eventID: "gmail:\(accountID):\(event.messageID)",
                            contractKey: event.conversationID,
                            input: [
                                "accountBindingId": accountID,
                                "accountId": accountID,
                                "messageId": event.messageID,
                                "conversationId": event.conversationID,
                                "resourceIds": event.resourceIDs,
                                "cursor": event.cursor,
                                "provider": "gmail",
                            ]
                        )
                    }
                    latest = page.latestCursor.isEmpty ? latest : page.latestCursor
                    pageToken = page.nextPageToken
                    pages += 1
                } while pageToken != nil && pages < 10
                cursors[accountID] = latest
            }
            self.saveCursors(cursors)
        }
    }
}
