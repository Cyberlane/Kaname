import CryptoKit
import Foundation
import KanameConnectivity
import KanameDesktop
import KanameDomain
import KanameLocalCore

/// Turns new Gmail messages into workflow events from the durable worker.
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
public final class DesktopMailEventPoller: @unchecked Sendable {
    public static let shared = DesktopMailEventPoller()
    public static let eventContract = "mail.message.received"
    public static let maximumEnrichmentsPerPoll = 40
    private static let maximumPagesPerAccount = 100
    private static let maximumResultsPerPage = 100
    static let maximumPendingEventIDs = maximumPagesPerAccount * maximumResultsPerPage

    struct PendingAdmissions: Codable, Sendable, Equatable {
        var cursor: String
        var eventIDs: [String]
    }

    static func destinationFingerprint(accountID: String, conversationID: String) -> String {
        SHA256.hash(data: Data("gmail:\(accountID):\(conversationID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private let queue = DispatchQueue(label: "com.cyberlane.kaname.mail-event-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var environment: KanameDesktopEnvironment = .current
    private var adapter: (any MailProviderAdapter)?
    private var runner: LocalCoreRunner?
    private var isPolling = false

    private init() {}

    public func start(
        environment: KanameDesktopEnvironment,
        runner: LocalCoreRunner? = nil,
        googleClientConfiguration: GoogleOAuthClientConfiguration? = nil
    ) {
        queue.async { [self] in
            guard timer == nil else { return }
            self.environment = environment
            self.runner = runner
            let service = NativeGoogleIntegrationService(
                rootDirectory: environment.googleDirectory,
                keychainService: environment.googleKeychainService,
                clientConfiguration: googleClientConfiguration,
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

    private var pendingURL: URL {
        DesktopWorkflowEventPolling.cursorsURL(environment, file: "mail-pending.json")
    }

    private func poll() {
        guard !isPolling, let adapter, let runner = self.runner ?? LocalCoreRunner.bundled() else { return }
        isPolling = true
        _Concurrency.Task.detached { [self] in
            defer { queue.async { self.isPolling = false } }
            // Only spend Gmail API calls when at least one active workflow exists.
            guard await DesktopWorkflowEventPolling.hasActiveWorkflows(runner: runner, poller: "mail-poller") else { return }
            guard var cursors = DesktopWorkflowEventPolling.loadCursorsStrict(self.cursorsURL) else { return }
            guard var pending = Self.loadPending(self.pendingURL) else { return }
            guard let accounts = try? await adapter.accounts() else { return }
            var enriched = 0
            for account in accounts {
                let accountID = account.identity.localID
                guard let start = cursors[accountID] else {
                    pending.removeValue(forKey: accountID)
                    if let current = try? await adapter.currentCursor(accountID: accountID) {
                        cursors[accountID] = current
                    }
                    continue
                }
                var admittedEventIDs = Set(
                    pending[accountID].flatMap { $0.cursor == start ? $0.eventIDs : nil } ?? []
                )
                if pending[accountID]?.cursor != start { pending.removeValue(forKey: accountID) }
                var pageToken: String?
                var admission = DesktopWorkflowEventPolling.CursorAdmissionState(
                    cursor: start,
                    maximumPages: Self.maximumPagesPerAccount,
                    maximumEnrichments: Self.maximumEnrichmentsPerPoll
                )
                while !admission.failed {
                    let page: MailDeltaPage
                    do {
                        page = try await adapter.deltas(
                            accountID: accountID, startCursor: start, pageToken: pageToken, maximumResults: Self.maximumResultsPerPage,
                            resourceID: nil, kinds: [.messageAdded]
                        )
                    } catch {
                        // Keep the old cursor. The next poll retries the whole
                        // page so a transient provider failure cannot lose mail.
                        admission.fail()
                        break
                    }
                    for event in page.events where event.kind == .messageAdded {
                        let eventID = "gmail:\(accountID):\(event.messageID)"
                        if admittedEventIDs.contains(eventID) { continue }
                        // Enrichment is part of event admission. Once the
                        // bounded budget is exhausted, leave this and all later
                        // events for the next poll instead of admitting partial
                        // trigger inputs and advancing past them.
                        guard admission.reserveEnrichment(), enriched < Self.maximumEnrichmentsPerPoll else {
                            admission.fail()
                            break
                        }
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
                        let conversation: MailConversationSnapshot
                        do {
                            conversation = try await adapter.conversation(
                                accountID: accountID, conversationID: event.conversationID
                            )
                        } catch {
                            // An event without its bounded content is not the
                            // contract promised to the workflow. Replaying it
                            // is safe because Rust deduplicates admitted events.
                            admission.fail()
                            break
                        }
                        enriched += 1
                        guard conversation.messages.contains(where: { $0.id == event.messageID }) else {
                            admission.fail()
                            break
                        }
                        if let message = conversation.messages.first(where: { $0.id == event.messageID }) {
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
                        do {
                            _ = try await runner.fanOutWorkflowEvent(
                                contract: Self.eventContract,
                                eventID: "gmail:\(accountID):\(event.messageID)",
                                contractKey: event.conversationID,
                                input: input
                            )
                        } catch {
                            // Admission is transactional with cursor progress:
                            // no cursor is persisted for this account on error.
                            admission.fail()
                            break
                        }
                        admittedEventIDs.insert(eventID)
                        pending[accountID] = PendingAdmissions(
                            cursor: start, eventIDs: admittedEventIDs.sorted()
                        )
                        guard Self.savePendingChecked(pending, to: self.pendingURL) else {
                            admission.fail()
                            break
                        }
                    }
                    guard !admission.failed else { break }
                    if !page.latestCursor.isEmpty {
                        let order = await adapter.compareCursors(page.latestCursor, start)
                        guard order != .descending, order != .unordered else {
                            admission.fail()
                            break
                        }
                    }
                    pageToken = page.nextPageToken
                    guard admission.acceptPage(
                        latestCursor: page.latestCursor, nextPageToken: pageToken
                    ) else { break }
                    if pageToken == nil { break }
                }
                if let committed = admission.committedCursor {
                    cursors[accountID] = committed
                    // Persist the cursor before clearing replay IDs. If the
                    // process dies between these writes, the old pending entry
                    // is ignored because its cursor no longer matches.
                    if DesktopWorkflowEventPolling.saveCursorsChecked(cursors, to: self.cursorsURL) {
                        pending.removeValue(forKey: accountID)
                        Self.savePending(pending, to: self.pendingURL)
                    }
                }
            }
            DesktopWorkflowEventPolling.saveCursors(cursors, to: self.cursorsURL)
            Self.savePending(pending, to: self.pendingURL)
        }
    }

    static func loadPending(_ url: URL) -> [String: PendingAdmissions]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: PendingAdmissions].self, from: data),
              value.values.allSatisfy({ $0.eventIDs.count <= maximumPendingEventIDs })
        else {
            let marker = url.deletingPathExtension().appendingPathExtension("error.json")
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "error": "pending_admissions_file_malformed",
                "path": url.lastPathComponent,
                "detectedAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
            ]
            if let markerData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                try? markerData.write(to: marker, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
            return nil
        }
        return value
    }

    @discardableResult
    static func savePendingChecked(_ pending: [String: PendingAdmissions], to url: URL) -> Bool {
        guard pending.values.allSatisfy({ $0.eventIDs.count <= maximumPendingEventIDs }),
              let data = try? JSONEncoder().encode(pending) else {
            recordPendingPersistenceError(url)
            return false
        }
        let directory = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )) != nil,
        (try? data.write(to: url, options: [.atomic])) != nil,
        (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
        else {
            recordPendingPersistenceError(url)
            return false
        }
        return true
    }

    private static func savePending(_ pending: [String: PendingAdmissions], to url: URL) {
        _ = savePendingChecked(pending, to: url)
    }

    private static func recordPendingPersistenceError(_ url: URL) {
        let marker = url.deletingPathExtension().appendingPathExtension("error.json")
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "error": "pending_admissions_persist_failed",
            "path": url.lastPathComponent,
            "detectedAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: marker, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
}
