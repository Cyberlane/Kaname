@preconcurrency import Foundation
import CryptoKit

public struct GmailAttachmentSnapshot: Equatable, Identifiable, Sendable {
    public var id: String { attachmentID }
    public let attachmentID: String
    public let messageID: String
    public let filename: String
    public let mimeType: String
    public let size: Int
}

public struct GmailMessageSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let threadID: String
    public let sender: String
    public let recipients: String
    public let subject: String
    public let dateDescription: String
    public let body: String
    public let labels: [String]
    public let attachments: [GmailAttachmentSnapshot]
    public let inReplyTo: String
    public let references: String
}

public struct GmailThreadDetailSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let accountIdentity: String
    public let snippet: String
    public let historyID: String?
    public let messages: [GmailMessageSnapshot]

    public var labels: [String] { Array(Set(messages.flatMap(\.labels))).sorted() }
    public var stableID: String { "\(accountID):\(id)" }
}

public struct GmailThreadPage: Equatable, Sendable {
    public let accountID: String
    public let accountIdentity: String
    public let query: String
    public let threads: [GmailThreadDetailSnapshot]
    public let nextPageToken: String?
    public let failedThreadCount: Int
}

public enum GmailHistoryEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case messageAdded
    case messageDeleted
    case labelsAdded
    case labelsRemoved
}

public struct GmailHistoryEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let historyID: String
    public let kind: GmailHistoryEventKind
    public let messageID: String
    public let threadID: String
    public let labelIDs: [String]

    public static func record(
        id: String,
        historyID: String,
        kind: GmailHistoryEventKind,
        messageID: String,
        threadID: String,
        labelIDs: [String]
    ) -> Self {
        Self(id: id, historyID: historyID, kind: kind, messageID: messageID, threadID: threadID, labelIDs: labelIDs)
    }
}

public struct GmailHistoryPage: Equatable, Sendable {
    public let accountID: String
    public let accountIdentity: String
    public let startHistoryID: String
    public let latestHistoryID: String
    public let events: [GmailHistoryEvent]
    public let nextPageToken: String?
}

public struct GmailLabelSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String
}

public enum GmailThreadMutation: Equatable, Sendable {
    case archive
    case trash
    case applyLabels(add: [String], remove: [String])

    fileprivate var canonicalName: String {
        switch self {
        case .archive: "archive"
        case .trash: "trash"
        case .applyLabels: "labels"
        }
    }
}

public struct GmailMutationGrant: Equatable, Sendable {
    public let approvalID: String
    public let exactTarget: String

    public init(approvalID: String, exactTarget: String) {
        self.approvalID = approvalID
        self.exactTarget = exactTarget
    }
}

public struct GmailMutationReceipt: Equatable, Sendable {
    public let approvalID: String
    public let exactTarget: String
    public let reconciledThread: GmailThreadDetailSnapshot
}

public struct GmailOutboundAttachment: Equatable, Sendable {
    public static let maximumCount = 20
    public static let maximumTotalBytes = 25_000_000

    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct GmailOutboundMessage: Equatable, Sendable {
    public let recipients: String
    public let subject: String
    public let body: String
    public let inReplyTo: String?
    public let references: [String]
    public let threadID: String?
    public let attachments: [GmailOutboundAttachment]

    public init(
        recipients: String,
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        threadID: String? = nil,
        attachments: [GmailOutboundAttachment] = []
    ) {
        (self.recipients, self.subject, self.body, self.inReplyTo) = (recipients, subject, body, inReplyTo)
        self.references = references
        self.threadID = threadID
        self.attachments = attachments
    }
}

public struct GmailDraftReceipt: Equatable, Sendable {
    public let id: String
    public let messageID: String?
    public let accountID: String
    public let reconciliation: GmailOutboundReconciliation
}

public struct GmailSendReceipt: Equatable, Sendable {
    public let messageID: String
    public let threadID: String?
    public let accountID: String
    public let reconciliation: GmailOutboundReconciliation
}

public struct GmailOutboundReconciliation: Equatable, Sendable {
    public let recipients: String
    public let subject: String
    public let threadID: String
    public let attachmentNames: [String]
    public let attachmentDigests: [String]
    public let verifiedAttachmentBytes: Bool

    public var summary: String {
        let attachments = attachmentNames.isEmpty ? "no attachments" : "\(attachmentNames.count) attachment(s)"
        return "Verified recipients, subject, thread, and \(attachments) from Gmail"
            + (verifiedAttachmentBytes ? ", including attachment bytes." : ".")
    }
}

public enum GmailWorkError: Error, Equatable, LocalizedError, Sendable {
    case accountNotFound
    case invalidIdentifier
    case approvalMismatch
    case invalidMessage
    case reconciliationFailed

    public var errorDescription: String? {
        switch self {
        case .accountNotFound: "The selected Gmail account is no longer connected."
        case .invalidIdentifier: "Gmail returned or received an invalid item identifier."
        case .approvalMismatch: "The approval does not match this exact Gmail action."
        case .invalidMessage: "Enter at least one recipient and a non-empty message body."
        case .reconciliationFailed: "Gmail accepted the request but its remote result did not match the intended action."
        }
    }
}

public extension NativeGoogleIntegrationService {
    static func gmailMutationTarget(accountID: String, threadID: String, mutation: GmailThreadMutation) -> String {
        "gmail:\(accountID):thread:\(threadID):\(mutation.canonicalName)"
    }

    static func gmailDraftTarget(accountID: String, message: GmailOutboundMessage) throws -> String {
        try outboundTarget(accountID: accountID, operation: "draft", message: message)
    }

    static func gmailSendTarget(accountID: String, message: GmailOutboundMessage) throws -> String {
        try outboundTarget(accountID: accountID, operation: "send", message: message)
    }

    func searchMail(
        accountID: String,
        query: String,
        pageToken: String? = nil,
        limit: Int = 40
    ) async throws -> GmailThreadPage {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
        var items = [
            URLQueryItem(name: "maxResults", value: "\(min(max(limit, 1), 100))"),
            URLQueryItem(name: "q", value: query),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        let listData = try await authorizedData(url: components.url!, accessToken: token, service: "Gmail search")
        let page = try GmailAPIParser.threadPage(data: listData)
        var threads: [GmailThreadDetailSnapshot] = []
        var failures = 0
        for id in page.ids {
            do { threads.append(try await readMailThread(account: account, threadID: id, accessToken: token)) }
            catch { failures += 1 }
        }
        guard failures == 0 || !threads.isEmpty else { throw NativeGoogleIntegrationError.requestFailed("Gmail thread details") }
        return GmailThreadPage(
            accountID: account.id,
            accountIdentity: account.identity,
            query: query,
            threads: threads,
            nextPageToken: page.nextPageToken,
            failedThreadCount: failures
        )
    }

    func matchingGmailThreadIDs(
        accountID: String,
        query: String,
        maximumPages: Int = 20,
        maximumThreads: Int = 2_000
    ) async throws -> Set<String> {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, cleanQuery.utf8.count <= 2_048 else { throw GmailWorkError.invalidIdentifier }
        let pageLimit = min(max(maximumPages, 1), 100)
        let threadLimit = min(max(maximumThreads, 1), 10_000)
        var pageToken: String?
        var seenTokens = Set<String>()
        var identifiers = Set<String>()
        for _ in 0..<pageLimit {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
            var items = [
                URLQueryItem(name: "maxResults", value: "100"),
                URLQueryItem(name: "q", value: cleanQuery),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = items
            let data = try await authorizedData(
                url: components.url!,
                accessToken: token,
                service: "Gmail workflow filter"
            )
            let page = try GmailAPIParser.threadPage(data: data)
            identifiers.formUnion(page.ids)
            guard identifiers.count <= threadLimit else {
                throw NativeGoogleIntegrationError.invalidResponse("Gmail workflow filter exceeded its bounded thread limit")
            }
            guard let next = page.nextPageToken else { return identifiers }
            guard seenTokens.insert(next).inserted else {
                throw NativeGoogleIntegrationError.invalidResponse("Gmail workflow filter repeated a page")
            }
            pageToken = next
        }
        throw NativeGoogleIntegrationError.invalidResponse("Gmail workflow filter exceeded its bounded page limit")
    }

    func readMailThread(accountID: String, threadID: String) async throws -> GmailThreadDetailSnapshot {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        return try await readMailThread(
            account: account,
            threadID: try GmailAPIParser.validatedID(threadID),
            accessToken: token
        )
    }

    func listGmailLabels(accountID: String) async throws -> [GmailLabelSnapshot] {
        try await gmailGET(accountID: accountID, path: "labels", service: "Gmail labels", decode: GmailAPIParser.labels)
    }

    func gmailHistoryCursor(accountID: String) async throws -> String {
        try await gmailGET(accountID: accountID, path: "profile", service: "Gmail profile", decode: GmailAPIParser.profileHistoryID)
    }

    private func gmailGET<Value>(
        accountID: String,
        path: String,
        service: String,
        decode: (Data) throws -> Value
    ) async throws -> Value {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)") else {
            throw GmailWorkError.invalidIdentifier
        }
        return try decode(await authorizedData(url: url, accessToken: token, service: service))
    }

    func listGmailHistory(
        accountID: String,
        startHistoryID: String,
        pageToken: String? = nil,
        maximumResults: Int = 100,
        labelID: String? = nil,
        historyTypes: [GmailHistoryEventKind] = GmailHistoryEventKind.allCases
    ) async throws -> GmailHistoryPage {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        let start = try GmailAPIParser.validatedHistoryID(startHistoryID)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
        var items = [
            URLQueryItem(name: "startHistoryId", value: start),
            URLQueryItem(name: "maxResults", value: "\(min(max(maximumResults, 1), 500))"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        if let labelID { items.append(URLQueryItem(name: "labelId", value: try GmailAPIParser.validatedID(labelID))) }
        for kind in Array(Set(historyTypes)).sorted(by: { $0.rawValue < $1.rawValue }) {
            items.append(URLQueryItem(name: "historyTypes", value: kind.rawValue))
        }
        components.queryItems = items
        let data = try await authorizedData(url: components.url!, accessToken: token, service: "Gmail history")
        let page = try GmailAPIParser.historyPage(data: data)
        return GmailHistoryPage(
            accountID: account.id,
            accountIdentity: account.identity,
            startHistoryID: start,
            latestHistoryID: page.latestHistoryID,
            events: page.events,
            nextPageToken: page.nextPageToken
        )
    }

    func downloadGmailAttachment(
        accountID: String,
        messageID: String,
        attachmentID: String,
        maximumBytes: Int = 25_000_000
    ) async throws -> Data {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        let message = try GmailAPIParser.validatedID(messageID)
        let attachment = try GmailAPIParser.validatedID(attachmentID)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(message)/attachments/\(attachment)")!
        let data = try await authorizedData(url: url, accessToken: token, service: "Gmail attachment")
        let decoded = try GmailAPIParser.attachment(data: data)
        guard decoded.count <= maximumBytes else { throw NativeGoogleIntegrationError.invalidResponse("Gmail attachment") }
        return decoded
    }

    func mutateMailThread(
        accountID: String,
        threadID: String,
        mutation: GmailThreadMutation,
        grant: GmailMutationGrant
    ) async throws -> GmailMutationReceipt {
        let account = try gmailAccount(id: accountID)
        let thread = try GmailAPIParser.validatedID(threadID)
        let target = Self.gmailMutationTarget(accountID: account.id, threadID: thread, mutation: mutation)
        guard grant.exactTarget == target else { throw GmailWorkError.approvalMismatch }
        let token = try await validAccessToken(for: account)
        var request: URLRequest
        switch mutation {
        case .trash:
            request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(thread)/trash")!)
            request.httpMethod = "POST"
        case .archive:
            request = try GmailAPIParser.modifyRequest(threadID: thread, add: [], remove: ["INBOX"])
        case let .applyLabels(add, remove):
            request = try GmailAPIParser.modifyRequest(threadID: thread, add: add, remove: remove)
        }
        _ = try await authorizedData(request: request, accessToken: token, service: "Gmail mutation")
        let reconciled = try await readMailThread(account: account, threadID: thread, accessToken: token)
        guard GmailAPIParser.reconciled(mutation: mutation, labels: reconciled.labels) else {
            throw GmailWorkError.reconciliationFailed
        }
        return GmailMutationReceipt(approvalID: grant.approvalID, exactTarget: target, reconciledThread: reconciled)
    }

    func createGmailDraft(
        accountID: String,
        message: GmailOutboundMessage,
        grant: GmailMutationGrant
    ) async throws -> GmailDraftReceipt {
        try await draftValue(from: performOutbound(accountID: accountID, message: message, grant: grant, operation: .draft))
    }

    func sendGmailMessage(
        accountID: String,
        message: GmailOutboundMessage,
        grant: GmailMutationGrant
    ) async throws -> GmailSendReceipt {
        try await sentValue(from: performOutbound(accountID: accountID, message: message, grant: grant, operation: .send))
    }

    private enum OutboundOperation {
        case draft
        case send
    }

    private enum OutboundResult {
        case draft(GmailDraftReceipt)
        case sent(GmailSendReceipt)
    }

    private func performOutbound(
        accountID: String,
        message: GmailOutboundMessage,
        grant: GmailMutationGrant,
        operation: OutboundOperation
    ) async throws -> OutboundResult {
        let account = try gmailAccount(id: accountID)
        let raw = try GmailAPIParser.rawMessage(message)
        let target = try operation == .draft
            ? Self.gmailDraftTarget(accountID: account.id, message: message)
            : Self.gmailSendTarget(accountID: account.id, message: message)
        guard grant.exactTarget == target else { throw GmailWorkError.approvalMismatch }
        let path = operation == .draft ? "drafts" : "messages/send"
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var wireMessage: [String: Any] = ["raw": raw]
        if let threadID = message.threadID {
            wireMessage["threadId"] = try GmailAPIParser.validatedID(threadID)
        }
        let body: [String: Any] = operation == .draft ? ["message": wireMessage] : wireMessage
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let token = try await validAccessToken(for: account)
        let service = operation == .draft ? "Gmail draft" : "Gmail send"
        let data = try await authorizedData(
            request: request,
            accessToken: token,
            service: service
        )
        let wire = try GmailAPIParser.outboundReceipt(data: data, service: service)
        switch operation {
        case .draft:
            let draftID = try GmailAPIParser.validatedID(wire.id)
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts/\(draftID)?format=full")!
            let remoteData = try await authorizedData(url: url, accessToken: token, service: "Gmail draft reconciliation")
            let remote = try GmailAPIParser.draftMessage(data: remoteData, account: account)
            let reconciliation = try await reconcileOutbound(
                intended: message, remote: remote, account: account, accessToken: token
            )
            let receipt = GmailDraftReceipt(
                id: draftID, messageID: remote.id, accountID: account.id,
                reconciliation: reconciliation
            )
            return .draft(receipt)
        case .send:
            let messageID = try GmailAPIParser.validatedID(wire.id)
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)?format=full")!
            let remoteData = try await authorizedData(url: url, accessToken: token, service: "Gmail send reconciliation")
            let remote = try GmailAPIParser.message(data: remoteData, account: account)
            let reconciliation = try await reconcileOutbound(
                intended: message, remote: remote, account: account, accessToken: token
            )
            let receipt = GmailSendReceipt(
                messageID: messageID, threadID: remote.threadID, accountID: account.id,
                reconciliation: reconciliation
            )
            return .sent(receipt)
        }
    }

    private func reconcileOutbound(
        intended: GmailOutboundMessage,
        remote: GmailMessageSnapshot,
        account: NativeGoogleAccountSnapshot,
        accessToken: String
    ) async throws -> GmailOutboundReconciliation {
        let intendedNames = intended.attachments.map(\.filename)
        let remoteNames = remote.attachments.map(\.filename)
        guard GmailAPIParser.normalizedRecipients(intended.recipients) == GmailAPIParser.normalizedRecipients(remote.recipients),
              intended.subject == remote.subject,
              intended.threadID.map({ $0 == remote.threadID }) ?? true,
              intended.inReplyTo.map({ $0 == remote.inReplyTo }) ?? true,
              Set(intended.references).isSubset(of: Set(remote.references.split(separator: " ").map(String.init))),
              intendedNames == remoteNames else { throw GmailWorkError.reconciliationFailed }
        var digests: [String] = []
        for (index, attachment) in remote.attachments.enumerated() {
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(attachment.messageID)/attachments/\(attachment.attachmentID)")!
            let data = try await authorizedData(
                url: url, accessToken: accessToken, service: "Gmail outbound attachment reconciliation"
            )
            let bytes = try GmailAPIParser.attachment(data: data)
            guard bytes == intended.attachments[index].data else { throw GmailWorkError.reconciliationFailed }
            digests.append(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        return GmailOutboundReconciliation(
            recipients: remote.recipients, subject: remote.subject, threadID: remote.threadID,
            attachmentNames: remoteNames, attachmentDigests: digests,
            verifiedAttachmentBytes: remote.attachments.count == intended.attachments.count
        )
    }

    private func draftValue(from result: OutboundResult) throws -> GmailDraftReceipt {
        guard case let .draft(receipt) = result else { throw NativeGoogleIntegrationError.invalidResponse("Gmail draft") }
        return receipt
    }

    private func sentValue(from result: OutboundResult) throws -> GmailSendReceipt {
        guard case let .sent(receipt) = result else { throw NativeGoogleIntegrationError.invalidResponse("Gmail send") }
        return receipt
    }

    private static func outboundTarget(
        accountID: String,
        operation: String,
        message: GmailOutboundMessage
    ) throws -> String {
        let raw = try GmailAPIParser.rawMessage(message)
        return try ProviderActionTarget.sha256(
            scheme: "gmail",
            components: [accountID, operation],
            payload: Data(raw.utf8)
        )
    }

    private func gmailAccount(id: String) throws -> NativeGoogleAccountSnapshot {
        guard let account = try selectedAccounts([id]).first else { throw GmailWorkError.accountNotFound }
        return account
    }

    private func readMailThread(
        account: NativeGoogleAccountSnapshot,
        threadID: String,
        accessToken: String
    ) async throws -> GmailThreadDetailSnapshot {
        let id = try GmailAPIParser.validatedID(threadID)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?format=full")!
        let data = try await authorizedData(url: url, accessToken: accessToken, service: "Gmail thread")
        return try GmailAPIParser.thread(data: data, account: account)
    }
}

private struct GmailWirePart: Decodable {
    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let size: Int?; let data: String?; let attachmentId: String? }
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: Body?
    let parts: [GmailWirePart]?
}

private struct GmailWireMessage: Decodable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let payload: GmailWirePart?
}

private struct GmailWireDraft: Decodable {
    let id: String
    let message: GmailWireMessage
}

fileprivate struct GmailWireOutboundReceipt: Decodable {
    struct Message: Decodable { let id: String? }
    let id: String
    let message: Message?
    let threadId: String?
}

private struct GmailWireThread: Decodable {
    let id: String
    let snippet: String?
    let historyId: String?
    let messages: [GmailWireMessage]?
}

public enum GmailAPIParser {
    public struct HistoryPage: Equatable, Sendable {
        public let latestHistoryID: String
        public let events: [GmailHistoryEvent]
        public let nextPageToken: String?
    }

    public struct ThreadPage: Equatable, Sendable {
        public let ids: [String]
        public let nextPageToken: String?
    }

    public static func validatedID(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy(allowed.contains) else { throw GmailWorkError.invalidIdentifier }
        return value
    }

    public static func validatedHistoryID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 64, value.allSatisfy(\.isNumber) else {
            throw GmailWorkError.invalidIdentifier
        }
        return value
    }

    public static func profileHistoryID(data: Data) throws -> String {
        struct Response: Decodable { let historyId: String }
        let response = try GoogleAPIResponseParser.decode(Response.self, from: data, service: "Gmail profile")
        return try validatedHistoryID(response.historyId)
    }

    public static func historyPage(data: Data) throws -> HistoryPage {
        struct Response: Decodable {
            struct Message: Decodable {
                let id: String
                let threadId: String
                let labelIds: [String]?
            }
            struct Change: Decodable { let message: Message; let labelIds: [String]? }
            struct History: Decodable {
                let id: String
                let messagesAdded: [Change]?
                let messagesDeleted: [Change]?
                let labelsAdded: [Change]?
                let labelsRemoved: [Change]?
            }
            let history: [History]?
            let nextPageToken: String?
            let historyId: String
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            var events: [GmailHistoryEvent] = []
            for history in response.history ?? [] {
                let historyID = try validatedHistoryID(history.id)
                let groups: [(GmailHistoryEventKind, [Response.Change])] = [
                    (.messageAdded, history.messagesAdded ?? []),
                    (.messageDeleted, history.messagesDeleted ?? []),
                    (.labelsAdded, history.labelsAdded ?? []),
                    (.labelsRemoved, history.labelsRemoved ?? []),
                ]
                for (kind, changes) in groups {
                    for (ordinal, change) in changes.enumerated() {
                        let messageID = try validatedID(change.message.id)
                        let threadID = try validatedID(change.message.threadId)
                        let labels = try (change.labelIds ?? change.message.labelIds ?? []).map(validatedID).sorted()
                        events.append(GmailHistoryEvent.record(
                            id: "\(historyID):\(kind.rawValue):\(messageID):\(ordinal)",
                            historyID: historyID,
                            kind: kind,
                            messageID: messageID,
                            threadID: threadID,
                            labelIDs: labels
                        ))
                    }
                }
            }
            return HistoryPage(
                latestHistoryID: try validatedHistoryID(response.historyId),
                events: events,
                nextPageToken: response.nextPageToken
            )
        } catch let error as GmailWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail history") }
    }

    public static func threadPage(data: Data) throws -> ThreadPage {
        struct Response: Decodable {
            struct Reference: Decodable { let id: String }
            let threads: [Reference]?
            let nextPageToken: String?
        }
        let response = try GoogleAPIResponseParser.decode(Response.self, from: data, service: "Gmail search")
        return ThreadPage(ids: try (response.threads ?? []).map { try validatedID($0.id) }, nextPageToken: response.nextPageToken)
    }

    public static func thread(data: Data, account: NativeGoogleAccountSnapshot) throws -> GmailThreadDetailSnapshot {
        do {
            let decoded = try JSONDecoder().decode(GmailWireThread.self, from: data)
            let messages = try (decoded.messages ?? []).map { try messageSnapshot($0) }
            return GmailThreadDetailSnapshot(
                id: try validatedID(decoded.id),
                accountID: account.id,
                accountIdentity: account.identity,
                snippet: decoded.snippet ?? "",
                historyID: decoded.historyId,
                messages: messages
            )
        } catch let error as GmailWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail thread") }
    }

    public static func message(data: Data, account: NativeGoogleAccountSnapshot) throws -> GmailMessageSnapshot {
        try parsedMessage(data: data, service: "Gmail message") { (message: GmailWireMessage) in message }
    }

    public static func draftMessage(data: Data, account: NativeGoogleAccountSnapshot) throws -> GmailMessageSnapshot {
        try parsedMessage(data: data, service: "Gmail draft") { (draft: GmailWireDraft) in draft.message }
    }

    public static func normalizedRecipients(_ value: String) -> [String] {
        value.split(separator: ",").map {
            let recipient = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let opening = recipient.lastIndex(of: "<"), let closing = recipient[opening...].firstIndex(of: ">") {
                return String(recipient[recipient.index(after: opening)..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return recipient
        }.filter { !$0.isEmpty }.sorted()
    }

    private static func parsedMessage<Wire: Decodable>(
        data: Data,
        service: String,
        message: (Wire) -> GmailWireMessage
    ) throws -> GmailMessageSnapshot {
        try messageSnapshot(message(GoogleAPIResponseParser.decode(Wire.self, from: data, service: service)))
    }

    public static func labels(data: Data) throws -> [GmailLabelSnapshot] {
        struct Response: Decodable {
            struct Label: Decodable { let id: String; let name: String; let type: String? }
            let labels: [Label]?
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data).labels?.map {
                GmailLabelSnapshot(id: try validatedID($0.id), name: $0.name, type: $0.type ?? "user")
            } ?? []
        } catch let error as GmailWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail labels") }
    }

    public static func attachment(data: Data) throws -> Data {
        struct Response: Decodable { let data: String }
        do {
            let value = try JSONDecoder().decode(Response.self, from: data).data
            guard let decoded = Data(base64URLEncoded: value) else { throw GmailWorkError.invalidIdentifier }
            return decoded
        } catch let error as GmailWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail attachment") }
    }

    static func modifyRequest(threadID: String, add: [String], remove: [String]) throws -> URLRequest {
        let id = try validatedID(threadID)
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)/modify")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["addLabelIds": add, "removeLabelIds": remove])
        return request
    }

    public static func reconciled(mutation: GmailThreadMutation, labels: [String]) -> Bool {
        let current = Set(labels)
        return switch mutation {
        case .archive: !current.contains("INBOX")
        case .trash: current.contains("TRASH")
        case let .applyLabels(add, remove): Set(add).isSubset(of: current) && current.isDisjoint(with: Set(remove))
        }
    }

    static func rawMessage(_ message: GmailOutboundMessage) throws -> String {
        let recipients = message.recipients.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceValues = Array(Set(message.references + [message.inReplyTo].compactMap { $0 })).sorted()
        let attachmentBytes = message.attachments.reduce(0) { $0 + $1.data.count }
        guard !recipients.isEmpty, !body.isEmpty,
              !recipients.contains("\r"), !recipients.contains("\n"),
              !message.subject.contains("\r"), !message.subject.contains("\n"),
              message.attachments.count <= GmailOutboundAttachment.maximumCount,
              attachmentBytes <= GmailOutboundAttachment.maximumTotalBytes,
              referenceValues.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }),
              message.attachments.allSatisfy(validAttachment) else { throw GmailWorkError.invalidMessage }
        var headers = ["To: \(recipients)", "Subject: \(message.subject)", "MIME-Version: 1.0"]
        if let reply = message.inReplyTo {
            headers.append("In-Reply-To: \(reply)")
        }
        if !referenceValues.isEmpty { headers.append("References: \(referenceValues.joined(separator: " "))") }
        let messageData: Data
        if message.attachments.isEmpty {
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: base64")
            messageData = Data((headers + ["", foldedBase64(Data(message.body.utf8))]).joined(separator: "\r\n").utf8)
        } else {
            let boundarySeed = message.attachments.reduce(into: Data((message.subject + "\n" + message.body).utf8)) {
                $0.append(Data($1.filename.utf8))
                $0.append(Data($1.mimeType.utf8))
                $0.append($1.data)
            }
            let boundary = "kaname-\(SHA256.hash(data: boundarySeed).prefix(12).map { String(format: "%02x", $0) }.joined())"
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var lines = headers + ["", "--\(boundary)", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", foldedBase64(Data(message.body.utf8))]
            for attachment in message.attachments {
                let filename = attachment.filename.replacingOccurrences(of: "\"", with: "'")
                lines += [
                    "--\(boundary)",
                    "Content-Type: \(attachment.mimeType); name=\"\(filename)\"",
                    "Content-Disposition: attachment; filename=\"\(filename)\"",
                    "Content-Transfer-Encoding: base64",
                    "",
                    foldedBase64(attachment.data),
                ]
            }
            lines += ["--\(boundary)--", ""]
            messageData = Data(lines.joined(separator: "\r\n").utf8)
        }
        return messageData.base64URLEncodedString()
    }

    private static func validAttachment(_ attachment: GmailOutboundAttachment) -> Bool {
        let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let mimeType = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        return !filename.isEmpty && filename.utf8.count <= 512
            && !filename.contains("/") && !filename.contains("\\")
            && !filename.contains("\r") && !filename.contains("\n")
            && mimeType.range(of: #"^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func foldedBase64(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 76).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(76, encoded.count - offset))
            return String(encoded[start..<end])
        }.joined(separator: "\r\n")
    }

    fileprivate static func outboundReceipt(data: Data, service: String) throws -> GmailWireOutboundReceipt {
        try GoogleAPIResponseParser.decode(GmailWireOutboundReceipt.self, from: data, service: service)
    }

    private static func messageSnapshot(_ message: GmailWireMessage) throws -> GmailMessageSnapshot {
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var attachments: [GmailAttachmentSnapshot] = []
        let body = message.payload.map {
            bodyAndAttachments(part: $0, messageID: message.id, attachments: &attachments)
        } ?? ""
        return GmailMessageSnapshot(
            id: try validatedID(message.id), threadID: try validatedID(message.threadId),
            sender: header("From"), recipients: header("To"), subject: header("Subject"),
            dateDescription: header("Date"), body: body, labels: message.labelIds ?? [],
            attachments: attachments, inReplyTo: header("In-Reply-To"), references: header("References")
        )
    }

    private static func bodyAndAttachments(
        part: GmailWirePart,
        messageID: String,
        attachments: inout [GmailAttachmentSnapshot]
    ) -> String {
        let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !filename.isEmpty, let attachmentID = part.body?.attachmentId {
            attachments.append(GmailAttachmentSnapshot(
                attachmentID: attachmentID,
                messageID: messageID,
                filename: filename,
                mimeType: part.mimeType ?? "application/octet-stream",
                size: part.body?.size ?? 0
            ))
        }
        let parts = part.parts ?? []
        let children = parts.map {
            bodyAndAttachments(part: $0, messageID: messageID, attachments: &attachments)
        }
        if part.mimeType?.lowercased() == "multipart/alternative",
           let plainIndex = parts.firstIndex(where: { $0.mimeType?.lowercased() == "text/plain" }),
           !children[plainIndex].isEmpty {
            return children[plainIndex]
        }
        let nonemptyChildren = children.filter { !$0.isEmpty }
        if !nonemptyChildren.isEmpty { return nonemptyChildren.joined(separator: "\n\n") }
        guard filename.isEmpty, let encoded = part.body?.data,
              let data = Data(base64URLEncoded: encoded),
              let text = String(data: data, encoding: .utf8) else { return "" }
        if part.mimeType?.lowercased() == "text/html" {
            return text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return text
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

}
