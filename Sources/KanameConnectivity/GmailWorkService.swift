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
    /// Canonical readable text used by summaries, workflows, and other semantic consumers.
    public let body: String
    /// A bounded, DOM-derived Reader representation for first-party presentation only.
    public let readerMarkdown: String?
    /// The bounded original HTML representation. It is never substituted for `body`.
    public let htmlBody: String?
    /// An inert, allowlisted HTML document for the isolated mail viewer.
    public let sanitizedHTML: String?
    /// A separately sanitized variant that permits direct HTTPS image loads.
    /// It is presentation-only and must require an explicit per-message action.
    public let directRemoteImagesHTML: String?
    public let remoteImageCount: Int
    public let insecureRemoteImageCount: Int
    public let embeddedImageCount: Int
    /// Explains when Kaname had to fall back from the full message representation.
    public let bodyDisplayNotice: String?
    public let labels: [String]
    public let attachments: [GmailAttachmentSnapshot]
    public let inReplyTo: String
    public let references: String
    /// A deliberately bounded projection. Raw Gmail headers are never exposed
    /// through the workflow surface merely because a message was fetched.
    public let projectedHeaders: [String: String]

    init(
        id: String,
        threadID: String,
        sender: String,
        recipients: String,
        subject: String,
        dateDescription: String,
        body: String,
        readerMarkdown: String? = nil,
        htmlBody: String? = nil,
        sanitizedHTML: String? = nil,
        directRemoteImagesHTML: String? = nil,
        remoteImageCount: Int = 0,
        insecureRemoteImageCount: Int = 0,
        embeddedImageCount: Int = 0,
        bodyDisplayNotice: String? = nil,
        labels: [String],
        attachments: [GmailAttachmentSnapshot],
        inReplyTo: String,
        references: String,
        projectedHeaders: [String: String]
    ) {
        self.id = id
        self.threadID = threadID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.dateDescription = dateDescription
        self.body = body
        self.readerMarkdown = readerMarkdown
        self.htmlBody = htmlBody
        self.sanitizedHTML = sanitizedHTML
        self.directRemoteImagesHTML = directRemoteImagesHTML
        self.remoteImageCount = remoteImageCount
        self.insecureRemoteImageCount = insecureRemoteImageCount
        self.embeddedImageCount = embeddedImageCount
        self.bodyDisplayNotice = bodyDisplayNotice
        self.labels = labels
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.projectedHeaders = projectedHeaders
    }
}

struct GmailExternalBodyReference: Equatable, Hashable, Sendable {
    let messageID: String
    let attachmentID: String
    let expectedSize: Int

    init(messageID: String, attachmentID: String, expectedSize: Int) {
        self.messageID = messageID
        self.attachmentID = attachmentID
        self.expectedSize = expectedSize
    }
}

struct GmailInlineImageReference: Equatable, Hashable, Sendable {
    let messageID: String
    let attachmentID: String
    let expectedSize: Int
    let contentID: String
    let mimeType: String
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

public struct GmailMessageMetadataSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let threadID: String
    public let headers: [String: String]
    public let labels: [String]
}

public struct GmailThreadMetadataSnapshot: Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let historyID: String?
    public let messages: [GmailMessageMetadataSnapshot]
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

    func readMailThreadMetadata(
        accountID: String,
        threadID: String,
        selectedHeaders: [String]
    ) async throws -> GmailThreadMetadataSnapshot {
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        let id = try GmailAPIParser.validatedID(threadID)
        let headers = try GmailAPIParser.validatedMetadataHeaders(selectedHeaders)
        var components = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)"
        )!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(
                name: "fields",
                value: "id,historyId,messages(id,threadId,labelIds,payload/headers)"
            ),
        ]
            + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        let data = try await authorizedData(
            url: components.url!, accessToken: token, service: "Gmail thread metadata"
        )
        guard data.count <= 1_048_576 else {
            throw NativeGoogleIntegrationError.invalidResponse(
                "Gmail thread metadata exceeded its bounded response limit"
            )
        }
        return try GmailAPIParser.threadMetadata(
            data: data, account: account, selectedHeaders: headers
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
        try requireExternalMutationAccess()
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
        try requireExternalMutationAccess()
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
        let references = try GmailAPIParser.externalBodyReferences(data: data)
        var externalBodyData: [GmailExternalBodyReference: Data] = [:]
        var fetchedBytes = 0
        for reference in references {
            let attachmentURL = URL(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(reference.messageID)/attachments/\(reference.attachmentID)"
            )!
            let response = try await authorizedData(
                url: attachmentURL,
                accessToken: accessToken,
                service: "Gmail text body"
            )
            let decoded = try GmailAPIParser.attachment(data: response)
            fetchedBytes += decoded.count
            guard decoded.count <= GmailAPIParser.maximumExternalBodyPartBytes,
                  fetchedBytes <= GmailAPIParser.maximumExternalBodyTotalBytes else {
                throw NativeGoogleIntegrationError.invalidResponse(
                    "Gmail text body exceeded its bounded response limit"
                )
            }
            externalBodyData[reference] = decoded
        }
        let inlineImageReferences = try GmailAPIParser.externalInlineImageReferences(
            data: data,
            externalBodyData: externalBodyData
        )
        var externalInlineImageData: [GmailInlineImageReference: Data] = [:]
        var fetchedInlineImageBytes = 0
        for reference in inlineImageReferences {
            let attachmentURL = URL(
                string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(reference.messageID)/attachments/\(reference.attachmentID)"
            )!
            do {
                let response = try await authorizedData(
                    url: attachmentURL,
                    accessToken: accessToken,
                    service: "Gmail inline image"
                )
                let decoded = try GmailAPIParser.attachment(data: response)
                guard decoded.count <= GmailAPIParser.maximumInlineImagePartBytes,
                      fetchedInlineImageBytes + decoded.count <= GmailAPIParser.maximumInlineImageTotalBytes else {
                    continue
                }
                fetchedInlineImageBytes += decoded.count
                externalInlineImageData[reference] = decoded
            } catch {
                // An unavailable decorative image must not make the readable message fail.
                continue
            }
        }
        return try GmailAPIParser.thread(
            data: data,
            account: account,
            externalBodyData: externalBodyData,
            externalInlineImageData: externalInlineImageData
        )
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
    let snippet: String?
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

private struct GmailParsedBody {
    static let empty = GmailParsedBody(
        semanticText: "",
        readerMarkdown: nil,
        htmlBody: nil,
        sanitizedHTML: nil,
        directRemoteImagesHTML: nil,
        remoteImageCount: 0,
        insecureRemoteImageCount: 0,
        embeddedImageCount: 0,
        displayNotice: nil,
        containsPlainRepresentation: false
    )

    let semanticText: String
    let readerMarkdown: String?
    let htmlBody: String?
    let sanitizedHTML: String?
    let directRemoteImagesHTML: String?
    let remoteImageCount: Int
    let insecureRemoteImageCount: Int
    let embeddedImageCount: Int
    let displayNotice: String?
    let containsPlainRepresentation: Bool

    var isEmpty: Bool {
        semanticText.isEmpty && (readerMarkdown?.isEmpty ?? true) && (htmlBody?.isEmpty ?? true)
    }
}

public enum GmailAPIParser {
    static let maximumExternalBodyPartBytes = MailHTMLReader.maximumInputBytes
    static let maximumExternalBodyTotalBytes = 4_000_000
    static let maximumExternalBodyPartCount = 32
    static let maximumInlineImagePartBytes = MailHTMLReader.maximumEmbeddedImageBytes
    static let maximumInlineImageTotalBytes = 8_000_000
    static let maximumInlineImagePartCount = 32
    private static let maximumMIMEPartCount = 5_000

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

    public static func validatedMetadataHeaders(_ values: [String]) throws -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen: Set<String> = []
        let normalized = trimmed.sorted { lhs, rhs in
            let left = lhs.lowercased()
            let right = rhs.lowercased()
            return left == right ? lhs < rhs : left < right
        }.filter {
            seen.insert($0.lowercased()).inserted
        }
        guard !normalized.isEmpty, normalized.count <= 32,
              normalized.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 128
                      && $0.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw GmailWorkError.invalidIdentifier
        }
        return normalized
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

    public static func thread(
        data: Data,
        account: NativeGoogleAccountSnapshot
    ) throws -> GmailThreadDetailSnapshot {
        try thread(
            data: data,
            account: account,
            externalBodyData: [:],
            externalInlineImageData: [:]
        )
    }

    static func thread(
        data: Data,
        account: NativeGoogleAccountSnapshot,
        externalBodyData: [GmailExternalBodyReference: Data],
        externalInlineImageData: [GmailInlineImageReference: Data] = [:]
    ) throws -> GmailThreadDetailSnapshot {
        do {
            let decoded = try JSONDecoder().decode(GmailWireThread.self, from: data)
            let messages = try (decoded.messages ?? []).map {
                try messageSnapshot(
                    $0,
                    externalBodyData: externalBodyData,
                    externalInlineImageData: externalInlineImageData
                )
            }
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

    static func externalBodyReferences(data: Data) throws -> [GmailExternalBodyReference] {
        var references: [GmailExternalBodyReference] = []
        var seen = Set<GmailExternalBodyReference>()
        var declaredBytes = 0

        for message in try boundedMIMEMessages(data: data) {
            for part in message.parts {
                let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let mimeType = baseMIMEType(part)
                guard filename.isEmpty,
                      mimeType == "text/plain" || mimeType == "text/html",
                      part.body?.data == nil,
                      let attachmentID = part.body?.attachmentId else { continue }
                let expectedSize = part.body?.size ?? 0
                guard expectedSize >= 0,
                      expectedSize <= maximumExternalBodyPartBytes else {
                    throw NativeGoogleIntegrationError.invalidResponse(
                        "Gmail text body exceeded its bounded part limit"
                    )
                }
                let reference = GmailExternalBodyReference(
                    messageID: message.id,
                    attachmentID: try validatedID(attachmentID),
                    expectedSize: expectedSize
                )
                guard seen.insert(reference).inserted else { continue }
                references.append(reference)
                declaredBytes += expectedSize
                guard references.count <= maximumExternalBodyPartCount,
                      declaredBytes <= maximumExternalBodyTotalBytes else {
                    throw NativeGoogleIntegrationError.invalidResponse(
                        "Gmail text body exceeded its bounded thread limit"
                    )
                }
            }
        }
        return references
    }

    static func externalInlineImageReferences(
        data: Data,
        externalBodyData: [GmailExternalBodyReference: Data] = [:]
    ) throws -> [GmailInlineImageReference] {
        var references: [GmailInlineImageReference] = []
        var seen = Set<GmailInlineImageReference>()
        var declaredBytes = 0

        for message in try boundedMIMEMessages(data: data) {
            let referencedIDs = message.root.map {
                referencedContentIDs(
                    part: $0,
                    messageID: message.id,
                    externalBodyData: externalBodyData
                )
            } ?? []
            for part in message.parts {
                guard let contentID = contentID(for: part),
                      referencedIDs.contains(contentID),
                      let mimeType = inlineImageMIMEType(for: part),
                      part.body?.data == nil,
                      let attachmentID = part.body?.attachmentId else { continue }
                let expectedSize = part.body?.size ?? 0
                guard expectedSize >= 0,
                      expectedSize <= maximumInlineImagePartBytes,
                      references.count < maximumInlineImagePartCount,
                      declaredBytes + expectedSize <= maximumInlineImageTotalBytes else {
                    continue
                }
                let reference = GmailInlineImageReference(
                    messageID: message.id,
                    attachmentID: try validatedID(attachmentID),
                    expectedSize: expectedSize,
                    contentID: contentID,
                    mimeType: mimeType
                )
                guard seen.insert(reference).inserted else { continue }
                references.append(reference)
                declaredBytes += expectedSize
            }
        }
        return references
    }

    private struct BoundedMIMEMessage {
        let id: String
        let root: GmailWirePart?
        let parts: [GmailWirePart]
    }

    private static func boundedMIMEMessages(data: Data) throws -> [BoundedMIMEMessage] {
        do {
            let decoded = try JSONDecoder().decode(GmailWireThread.self, from: data)
            var messages: [BoundedMIMEMessage] = []
            var visitedParts = 0

            for message in decoded.messages ?? [] {
                let messageID = try validatedID(message.id)
                var flattenedParts: [GmailWirePart] = []
                var stack = message.payload.map { [$0] } ?? []
                while let part = stack.popLast() {
                    visitedParts += 1
                    guard visitedParts <= maximumMIMEPartCount else {
                        throw NativeGoogleIntegrationError.invalidResponse(
                            "Gmail MIME tree exceeded its bounded part limit"
                        )
                    }
                    flattenedParts.append(part)
                    stack.append(contentsOf: part.parts ?? [])
                }
                messages.append(BoundedMIMEMessage(
                    id: messageID,
                    root: message.payload,
                    parts: flattenedParts
                ))
            }
            return messages
        } catch let error as GmailWorkError {
            throw error
        } catch let error as NativeGoogleIntegrationError {
            throw error
        } catch {
            throw NativeGoogleIntegrationError.invalidResponse("Gmail thread")
        }
    }

    public static func threadMetadata(
        data: Data,
        account: NativeGoogleAccountSnapshot,
        selectedHeaders: [String]
    ) throws -> GmailThreadMetadataSnapshot {
        do {
            let allowed = try validatedMetadataHeaders(selectedHeaders)
            let decoded = try JSONDecoder().decode(GmailWireThread.self, from: data)
            let messages = try (decoded.messages ?? []).map { message in
                let wireHeaders = message.payload?.headers ?? []
                let headers = Dictionary(uniqueKeysWithValues: allowed.compactMap { name in
                    wireHeaders.first {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }.map { (name, String($0.value.prefix(8_192))) }
                })
                return GmailMessageMetadataSnapshot(
                    id: try validatedID(message.id),
                    threadID: try validatedID(message.threadId),
                    headers: headers,
                    labels: Array(Set(try (message.labelIds ?? []).map(validatedID))).sorted()
                )
            }
            return GmailThreadMetadataSnapshot(
                id: try validatedID(decoded.id),
                accountID: account.id,
                historyID: decoded.historyId,
                messages: messages
            )
        } catch let error as GmailWorkError {
            throw error
        } catch {
            throw NativeGoogleIntegrationError.invalidResponse("Gmail thread metadata")
        }
    }

    public static func message(
        data: Data,
        account: NativeGoogleAccountSnapshot
    ) throws -> GmailMessageSnapshot {
        try message(
            data: data,
            account: account,
            externalBodyData: [:],
            externalInlineImageData: [:]
        )
    }

    static func message(
        data: Data,
        account: NativeGoogleAccountSnapshot,
        externalBodyData: [GmailExternalBodyReference: Data],
        externalInlineImageData: [GmailInlineImageReference: Data] = [:]
    ) throws -> GmailMessageSnapshot {
        try parsedMessage(
            data: data,
            service: "Gmail message",
            externalBodyData: externalBodyData,
            externalInlineImageData: externalInlineImageData
        ) { (message: GmailWireMessage) in message }
    }

    public static func draftMessage(
        data: Data,
        account: NativeGoogleAccountSnapshot
    ) throws -> GmailMessageSnapshot {
        try draftMessage(
            data: data,
            account: account,
            externalBodyData: [:],
            externalInlineImageData: [:]
        )
    }

    static func draftMessage(
        data: Data,
        account: NativeGoogleAccountSnapshot,
        externalBodyData: [GmailExternalBodyReference: Data],
        externalInlineImageData: [GmailInlineImageReference: Data] = [:]
    ) throws -> GmailMessageSnapshot {
        try parsedMessage(
            data: data,
            service: "Gmail draft",
            externalBodyData: externalBodyData,
            externalInlineImageData: externalInlineImageData
        ) { (draft: GmailWireDraft) in draft.message }
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
        externalBodyData: [GmailExternalBodyReference: Data],
        externalInlineImageData: [GmailInlineImageReference: Data],
        message: (Wire) -> GmailWireMessage
    ) throws -> GmailMessageSnapshot {
        try messageSnapshot(
            message(GoogleAPIResponseParser.decode(Wire.self, from: data, service: service)),
            externalBodyData: externalBodyData,
            externalInlineImageData: externalInlineImageData
        )
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

    private static func messageSnapshot(
        _ message: GmailWireMessage,
        externalBodyData: [GmailExternalBodyReference: Data],
        externalInlineImageData: [GmailInlineImageReference: Data]
    ) throws -> GmailMessageSnapshot {
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        var attachments: [GmailAttachmentSnapshot] = []
        let resolvedEmbeddedImages = message.payload.map {
            embeddedImages(
                part: $0,
                messageID: message.id,
                externalInlineImageData: externalInlineImageData
            )
        } ?? [:]
        let body = message.payload.map {
            bodyAndAttachments(
                part: $0,
                messageID: message.id,
                attachments: &attachments,
                externalBodyData: externalBodyData,
                embeddedImages: resolvedEmbeddedImages
            )
        } ?? .empty
        let fallbackSnippet = MailHTMLReader.boundedPlainText(message.snippet ?? "")
        let semanticText = body.semanticText.isEmpty ? fallbackSnippet : body.semanticText
        let displayNotice: String? = if let notice = body.displayNotice {
            notice
        } else if body.semanticText.isEmpty && !fallbackSnippet.isEmpty {
            "The full message body was unavailable. Showing Gmail's text preview instead."
        } else {
            nil
        }
        return GmailMessageSnapshot(
            id: try validatedID(message.id), threadID: try validatedID(message.threadId),
            sender: header("From"), recipients: header("To"), subject: header("Subject"),
            dateDescription: header("Date"), body: semanticText,
            readerMarkdown: body.readerMarkdown, htmlBody: body.htmlBody,
            sanitizedHTML: body.sanitizedHTML,
            directRemoteImagesHTML: body.directRemoteImagesHTML,
            remoteImageCount: body.remoteImageCount,
            insecureRemoteImageCount: body.insecureRemoteImageCount,
            embeddedImageCount: body.embeddedImageCount,
            bodyDisplayNotice: displayNotice,
            labels: message.labelIds ?? [],
            attachments: attachments, inReplyTo: header("In-Reply-To"), references: header("References"),
            projectedHeaders: Dictionary(uniqueKeysWithValues: [
                "List-Unsubscribe", "List-Unsubscribe-Post", "Auto-Submitted", "Precedence",
            ].compactMap { name in
                let value = header(name)
                return value.isEmpty ? nil : (name, String(value.prefix(8_192)))
            })
        )
    }

    private static func bodyAndAttachments(
        part: GmailWirePart,
        messageID: String,
        attachments: inout [GmailAttachmentSnapshot],
        externalBodyData: [GmailExternalBodyReference: Data],
        embeddedImages: [String: MailHTMLEmbeddedImage]
    ) -> GmailParsedBody {
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
            bodyAndAttachments(
                part: $0,
                messageID: messageID,
                attachments: &attachments,
                externalBodyData: externalBodyData,
                embeddedImages: embeddedImages
            )
        }
        if baseMIMEType(part) == "multipart/alternative" {
            let plain = children.last { $0.containsPlainRepresentation && !$0.semanticText.isEmpty }
            let html = children.last {
                $0.sanitizedHTML?.isEmpty == false || $0.htmlBody?.isEmpty == false
            }
            let display = children.last { !$0.isEmpty } ?? .empty
            let semantic = plain?.semanticText ?? html?.semanticText ?? display.semanticText
            return GmailParsedBody(
                semanticText: semantic,
                readerMarkdown: html?.readerMarkdown ?? display.readerMarkdown,
                htmlBody: html?.htmlBody,
                sanitizedHTML: html?.sanitizedHTML,
                directRemoteImagesHTML: html?.directRemoteImagesHTML ?? display.directRemoteImagesHTML,
                remoteImageCount: html?.remoteImageCount ?? display.remoteImageCount,
                insecureRemoteImageCount: html?.insecureRemoteImageCount ?? display.insecureRemoteImageCount,
                embeddedImageCount: html?.embeddedImageCount ?? display.embeddedImageCount,
                displayNotice: plain == nil && html?.sanitizedHTML == nil
                    ? (html?.displayNotice ?? display.displayNotice)
                    : nil,
                containsPlainRepresentation: plain != nil
            )
        }
        let nonemptyChildren = children.filter { !$0.isEmpty }
        if !nonemptyChildren.isEmpty {
            let semantic = MailHTMLReader.boundedPlainText(
                nonemptyChildren.map(\.semanticText).filter { !$0.isEmpty }.joined(separator: "\n\n")
            )
            let reader = boundedReaderMarkdown(
                nonemptyChildren.compactMap { child in
                    child.readerMarkdown ?? (child.semanticText.isEmpty
                        ? nil : MailHTMLReader.markdown(fromPlainText: child.semanticText))
                }.joined(separator: "\n\n---\n\n")
            )
            let html = boundedHTML(
                nonemptyChildren.compactMap(\.htmlBody).joined(separator: "\n<hr>\n")
            )
            let displayChild = nonemptyChildren.last {
                $0.sanitizedHTML?.isEmpty == false
            }
            let sanitizedHTML = displayChild?.sanitizedHTML
            return GmailParsedBody(
                semanticText: semantic,
                readerMarkdown: reader,
                htmlBody: html,
                sanitizedHTML: sanitizedHTML,
                directRemoteImagesHTML: displayChild?.directRemoteImagesHTML,
                remoteImageCount: displayChild?.remoteImageCount ?? 0,
                insecureRemoteImageCount: displayChild?.insecureRemoteImageCount ?? 0,
                embeddedImageCount: displayChild?.embeddedImageCount ?? 0,
                displayNotice: sanitizedHTML == nil
                    ? nonemptyChildren.compactMap(\.displayNotice).first
                    : nil,
                containsPlainRepresentation: nonemptyChildren.contains(where: \.containsPlainRepresentation)
            )
        }

        guard filename.isEmpty,
              let data = bodyData(
                  part: part,
                  messageID: messageID,
                  externalBodyData: externalBodyData
              ),
              let text = decodedText(data, for: part) else { return .empty }
        switch baseMIMEType(part) {
        case "text/html":
            guard let reader = MailHTMLReader.render(text, embeddedImages: embeddedImages) else {
                return GmailParsedBody(
                    semanticText: "",
                    readerMarkdown: nil,
                    htmlBody: boundedHTML(text),
                    sanitizedHTML: nil,
                    directRemoteImagesHTML: nil,
                    remoteImageCount: 0,
                    insecureRemoteImageCount: 0,
                    embeddedImageCount: 0,
                    displayNotice: "Kaname could not safely render the full HTML body. Showing Gmail's text preview instead.",
                    containsPlainRepresentation: false
                )
            }
            return GmailParsedBody(
                semanticText: reader.plainText,
                readerMarkdown: reader.markdown,
                htmlBody: reader.sourceHTML,
                sanitizedHTML: reader.sanitizedHTML,
                directRemoteImagesHTML: reader.directRemoteImagesHTML,
                remoteImageCount: reader.remoteImageCount,
                insecureRemoteImageCount: reader.insecureRemoteImageCount,
                embeddedImageCount: reader.embeddedImageCount,
                displayNotice: reader.sanitizedHTML == nil
                    ? "Kaname could not safely preserve this message's formatting. Showing readable text instead."
                    : nil,
                containsPlainRepresentation: false
            )
        case "text/plain", "":
            return GmailParsedBody(
                semanticText: MailHTMLReader.boundedPlainText(text),
                readerMarkdown: nil,
                htmlBody: nil,
                sanitizedHTML: nil,
                directRemoteImagesHTML: nil,
                remoteImageCount: 0,
                insecureRemoteImageCount: 0,
                embeddedImageCount: 0,
                displayNotice: nil,
                containsPlainRepresentation: true
            )
        default:
            return .empty
        }
    }

    private static func bodyData(
        part: GmailWirePart,
        messageID: String,
        externalBodyData: [GmailExternalBodyReference: Data]
    ) -> Data? {
        if let encoded = part.body?.data { return Data(base64URLEncoded: encoded) }
        guard let attachmentID = part.body?.attachmentId else { return nil }
        let reference = GmailExternalBodyReference(
            messageID: messageID,
            attachmentID: attachmentID,
            expectedSize: part.body?.size ?? 0
        )
        return externalBodyData[reference]
    }

    private static func embeddedImages(
        part: GmailWirePart,
        messageID: String,
        externalInlineImageData: [GmailInlineImageReference: Data]
    ) -> [String: MailHTMLEmbeddedImage] {
        var images: [String: MailHTMLEmbeddedImage] = [:]
        var ambiguousContentIDs = Set<String>()
        var stack = [part]
        var acceptedBytes = 0
        var visitedParts = 0

        while let candidate = stack.popLast() {
            visitedParts += 1
            guard visitedParts <= maximumMIMEPartCount else { break }
            stack.append(contentsOf: candidate.parts ?? [])

            guard images.count < maximumInlineImagePartCount,
                  let contentID = contentID(for: candidate),
                  !ambiguousContentIDs.contains(contentID),
                  let mimeType = inlineImageMIMEType(for: candidate) else { continue }

            let data: Data?
            if let encoded = candidate.body?.data,
               encoded.utf8.count <= maximumInlineImagePartBytes * 2 {
                data = Data(base64URLEncoded: encoded)
            } else if let attachmentID = candidate.body?.attachmentId {
                let reference = GmailInlineImageReference(
                    messageID: messageID,
                    attachmentID: attachmentID,
                    expectedSize: candidate.body?.size ?? 0,
                    contentID: contentID,
                    mimeType: mimeType
                )
                data = externalInlineImageData[reference]
            } else {
                data = nil
            }

            guard let data,
                  data.count <= maximumInlineImagePartBytes,
                  acceptedBytes + data.count <= maximumInlineImageTotalBytes else { continue }
            if images[contentID] != nil {
                images.removeValue(forKey: contentID)
                ambiguousContentIDs.insert(contentID)
                continue
            }
            images[contentID] = MailHTMLEmbeddedImage(mimeType: mimeType, data: data)
            acceptedBytes += data.count
        }
        return images
    }

    private static func referencedContentIDs(
        part: GmailWirePart,
        messageID: String,
        externalBodyData: [GmailExternalBodyReference: Data]
    ) -> Set<String> {
        var identifiers = Set<String>()
        var stack = [part]
        var visitedParts = 0
        while let candidate = stack.popLast() {
            visitedParts += 1
            guard visitedParts <= maximumMIMEPartCount else { break }
            stack.append(contentsOf: candidate.parts ?? [])
            guard baseMIMEType(candidate) == "text/html",
                  let data = bodyData(
                      part: candidate,
                      messageID: messageID,
                      externalBodyData: externalBodyData
                  ),
                  let html = decodedText(data, for: candidate) else { continue }
            identifiers.formUnion(MailHTMLReader.referencedContentIDs(in: html))
        }
        return identifiers
    }

    private static func contentID(for part: GmailWirePart) -> String? {
        let rawValue = part.headers?.first {
            $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame
        }?.value ?? ""
        return MailHTMLReader.normalizedContentID(rawValue)
    }

    private static func inlineImageMIMEType(for part: GmailWirePart) -> String? {
        switch baseMIMEType(part) {
        case "image/jpeg", "image/jpg": "image/jpeg"
        case "image/png": "image/png"
        case "image/gif": "image/gif"
        case "image/webp": "image/webp"
        default: nil
        }
    }

    private static func decodedText(_ data: Data, for part: GmailWirePart) -> String? {
        let declared = declaredCharset(part)
        let declaredEncoding: String.Encoding? = switch declared {
        case "utf-8", "utf8": .utf8
        case "us-ascii", "ascii": .ascii
        case "iso-8859-1", "iso8859-1", "latin1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "utf-16", "utf16": .utf16
        case "utf-16le", "utf16le": .utf16LittleEndian
        case "utf-16be", "utf16be": .utf16BigEndian
        default: nil
        }
        if let declaredEncoding, let text = String(data: data, encoding: declaredEncoding) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func declaredCharset(_ part: GmailWirePart) -> String? {
        let contentType = part.headers?.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? part.mimeType ?? ""
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].caseInsensitiveCompare("charset") == .orderedSame else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        }
        return nil
    }

    private static func baseMIMEType(_ part: GmailWirePart) -> String {
        (part.mimeType ?? part.headers?.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func boundedReaderMarkdown(_ markdown: String) -> String? {
        guard !markdown.isEmpty else { return nil }
        guard markdown.utf8.count > MailHTMLReader.maximumOutputBytes else { return markdown }
        return String(decoding: markdown.utf8.prefix(MailHTMLReader.maximumOutputBytes), as: UTF8.self)
            + "\n\nMessage text was truncated for safe display."
    }

    private static func boundedHTML(_ html: String) -> String? {
        guard !html.isEmpty else { return nil }
        return String(decoding: html.utf8.prefix(MailHTMLReader.maximumInputBytes), as: UTF8.self)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

}
