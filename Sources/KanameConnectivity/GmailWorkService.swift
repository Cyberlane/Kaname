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

public struct GmailOutboundMessage: Equatable, Sendable {
    public let recipients: String
    public let subject: String
    public let body: String
    public let inReplyTo: String?

    public init(recipients: String, subject: String, body: String, inReplyTo: String? = nil) {
        (self.recipients, self.subject, self.body, self.inReplyTo) = (recipients, subject, body, inReplyTo)
    }
}

public struct GmailDraftReceipt: Equatable, Sendable {
    public let id: String
    public let messageID: String?
    public let accountID: String
}

public struct GmailSendReceipt: Equatable, Sendable {
    public let messageID: String
    public let threadID: String?
    public let accountID: String
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
        let account = try gmailAccount(id: accountID)
        let token = try await validAccessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!
        let data = try await authorizedData(url: url, accessToken: token, service: "Gmail labels")
        return try GmailAPIParser.labels(data: data)
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
        let body: [String: Any] = operation == .draft ? ["message": ["raw": raw]] : ["raw": raw]
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
            let receipt = GmailDraftReceipt(
                id: try GmailAPIParser.validatedID(wire.id),
                messageID: wire.message?.id,
                accountID: account.id
            )
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts/\(receipt.id)?format=minimal")!
            _ = try await authorizedData(url: url, accessToken: token, service: "Gmail draft reconciliation")
            return .draft(receipt)
        case .send:
            let receipt = GmailSendReceipt(
                messageID: try GmailAPIParser.validatedID(wire.id),
                threadID: wire.threadId,
                accountID: account.id
            )
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(receipt.messageID)?format=minimal")!
            _ = try await authorizedData(url: url, accessToken: token, service: "Gmail send reconciliation")
            return .sent(receipt)
        }
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
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "gmail:\(accountID):\(operation):sha256=\(digest)"
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

    public static func threadPage(data: Data) throws -> ThreadPage {
        struct Response: Decodable {
            struct Reference: Decodable { let id: String }
            let threads: [Reference]?
            let nextPageToken: String?
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            return ThreadPage(ids: try (response.threads ?? []).map { try validatedID($0.id) }, nextPageToken: response.nextPageToken)
        } catch let error as GmailWorkError { throw error }
        catch { throw NativeGoogleIntegrationError.invalidResponse("Gmail search") }
    }

    public static func thread(data: Data, account: NativeGoogleAccountSnapshot) throws -> GmailThreadDetailSnapshot {
        do {
            let decoded = try JSONDecoder().decode(GmailWireThread.self, from: data)
            let messages = try (decoded.messages ?? []).map { message in
                let headers = message.payload?.headers ?? []
                func header(_ name: String) -> String {
                    headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
                }
                var attachments: [GmailAttachmentSnapshot] = []
                let body = message.payload.map {
                    bodyAndAttachments(part: $0, messageID: message.id, attachments: &attachments)
                } ?? ""
                return GmailMessageSnapshot(
                    id: try validatedID(message.id),
                    threadID: try validatedID(message.threadId),
                    sender: header("From"),
                    recipients: header("To"),
                    subject: header("Subject"),
                    dateDescription: header("Date"),
                    body: body,
                    labels: message.labelIds ?? [],
                    attachments: attachments
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

    static func reconciled(mutation: GmailThreadMutation, labels: [String]) -> Bool {
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
        guard !recipients.isEmpty, !body.isEmpty,
              !recipients.contains("\r"), !recipients.contains("\n"),
              !message.subject.contains("\r"), !message.subject.contains("\n") else { throw GmailWorkError.invalidMessage }
        var headers = ["To: \(recipients)", "Subject: \(message.subject)", "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8"]
        if let reply = message.inReplyTo, !reply.contains("\r"), !reply.contains("\n") {
            headers.append("In-Reply-To: \(reply)")
            headers.append("References: \(reply)")
        }
        return Data((headers + ["", message.body]).joined(separator: "\r\n").utf8).base64URLEncodedString()
    }

    fileprivate static func outboundReceipt(data: Data, service: String) throws -> GmailWireOutboundReceipt {
        do { return try JSONDecoder().decode(GmailWireOutboundReceipt.self, from: data) }
        catch { throw NativeGoogleIntegrationError.invalidResponse(service) }
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
