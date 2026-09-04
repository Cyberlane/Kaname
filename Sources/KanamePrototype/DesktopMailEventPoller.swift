import CryptoKit
import Foundation
import KanameConnectivity
import KanameDesktop
import KanameDomain
import KanameLocalCore

/// Turns new Gmail messages into workflow events.
///
/// Every two minutes, for each Google account, the poller reads the mailbox
/// delta since the stored cursor and offers each added message to the Rust
/// executor as a `mail.message.received` event. The executor fans it out to
/// every active workflow whose entrypoint is `trigger.event` with that
/// contract and deduplicates by message identity. Each event carries the
/// message's sender, recipients, subject, date, labels, and a bounded body
/// excerpt so a compute.llm node can classify it without another read.
/// Cursors persist under Workflows/mail-cursors.json; the first observation of
/// an account only records its cursor so the existing backlog is not replayed.
final class DesktopMailEventPoller: @unchecked Sendable {
    static let shared = DesktopMailEventPoller()
    static let eventContract = "mail.message.received"
    static let maximumEnrichmentsPerPoll = 40

    static func destinationFingerprint(accountID: String, conversationID: String) -> String {
        SHA256.hash(data: Data("gmail:\(accountID):\(conversationID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
        DesktopWorkflowEventPolling.cursorsURL(environment, file: "mail-cursors.json")
    }

    private func poll() {
        guard !isPolling, let adapter, let runner = LocalCoreRunner.bundled() else { return }
        isPolling = true
        _Concurrency.Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            // Only spend Gmail API calls when at least one active workflow exists.
            guard await DesktopWorkflowEventPolling.hasActiveWorkflows(runner: runner, poller: "mail-poller") else { return }
            guard let accounts = try? await adapter.accounts() else { return }
            var cursors = DesktopWorkflowEventPolling.loadCursors(self.cursorsURL)
            var enriched = 0
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
                        var input: [String: Any] = [
                            "accountBindingId": accountID,
                            "accountId": accountID,
                            "messageId": event.messageID,
                            "conversationId": event.conversationID,
                            // Mail effects pin their target by a 64-hex digest; workflows
                            // pass this through to label, archive, or mark the thread.
                            "destinationFingerprint": Self.destinationFingerprint(accountID: accountID, conversationID: event.conversationID),
                            "resourceIds": event.resourceIDs,
                            "cursor": event.cursor,
                            "provider": "gmail",
                        ]
                        // Read the message once so workflows can classify on
                        // content; bounded per poll to keep API use predictable.
                        if enriched < Self.maximumEnrichmentsPerPoll,
                           let conversation = try? await adapter.conversation(accountID: accountID, conversationID: event.conversationID) {
                            enriched += 1
                            if let message = conversation.messages.first(where: { $0.id == event.messageID }) ?? conversation.messages.last {
                                input["sender"] = message.sender
                                input["recipients"] = message.recipients
                                input["subject"] = message.subject
                                input["date"] = message.dateDescription
                                input["labelIds"] = message.resourceIDs
                                input["attachmentCount"] = message.attachments.count
                                input["bodyExcerpt"] = KanameTextBounds.utf8Prefix(
                                    message.body.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 4_000
                                )
                                input["listUnsubscribe"] = message.projectedHeaders["List-Unsubscribe"] ?? message.projectedHeaders["list-unsubscribe"] ?? ""
                            }
                            input["snippet"] = conversation.snippet
                            input["accountAddress"] = conversation.accountAddress
                        }
                        _ = try? await runner.fanOutWorkflowEvent(
                            contract: Self.eventContract,
                            eventID: "gmail:\(accountID):\(event.messageID)",
                            contractKey: event.conversationID,
                            input: input
                        )
                    }
                    latest = page.latestCursor.isEmpty ? latest : page.latestCursor
                    pageToken = page.nextPageToken
                    pages += 1
                } while pageToken != nil && pages < 10
                cursors[accountID] = latest
            }
            DesktopWorkflowEventPolling.saveCursors(cursors, to: self.cursorsURL)
        }
    }
}
