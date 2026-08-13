@preconcurrency import Foundation

public struct MailProviderIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let displayName: String
    public let adapterVersion: Int

    public init(id: String, kind: String, displayName: String, adapterVersion: Int = 1) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.adapterVersion = adapterVersion
    }
}

public struct MailAccountIdentity: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let localID: String

    public init(providerID: String, localID: String) {
        self.providerID = providerID
        self.localID = localID
    }

    public var stableID: String { "\(providerID):\(localID)" }
}

public struct MailAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { identity.stableID }
    public let identity: MailAccountIdentity
    public let address: String
    public let displayName: String

    public init(identity: MailAccountIdentity, address: String, displayName: String) {
        self.identity = identity
        self.address = address
        self.displayName = displayName
    }
}

public enum MailProviderFeature: String, Codable, CaseIterable, Equatable, Sendable {
    case boundedSearch = "bounded-search"
    case conversationRead = "conversation-read"
    case deltaSync = "delta-sync"
    case logicalResourceBinding = "logical-resource-binding"
    case attachmentFetch = "attachment-fetch"
    case conversationMutation = "conversation-mutation"
    case draft
    case send
}

public struct MailFeatureReadiness: Codable, Equatable, Identifiable, Sendable {
    public var id: String { feature.rawValue }
    public let feature: MailProviderFeature
    public let supported: Bool
    public let requiredScopes: [String]
    public let grantedScopes: [String]
    public let extensionIDs: [String]

    public init(
        feature: MailProviderFeature,
        supported: Bool,
        requiredScopes: [String] = [],
        grantedScopes: [String] = [],
        extensionIDs: [String] = []
    ) {
        self.feature = feature
        self.supported = supported
        self.requiredScopes = Array(Set(requiredScopes)).sorted()
        self.grantedScopes = Array(Set(grantedScopes)).sorted()
        self.extensionIDs = Array(Set(extensionIDs)).sorted()
    }

    public var missingScopes: [String] {
        Array(Set(requiredScopes).subtracting(grantedScopes)).sorted()
    }

    public var ready: Bool { supported && missingScopes.isEmpty }
}

public struct MailProviderReadinessSnapshot: Codable, Equatable, Sendable {
    public let provider: MailProviderIdentity
    public let account: MailAccountIdentity
    public let features: [MailFeatureReadiness]

    public init(provider: MailProviderIdentity, account: MailAccountIdentity, features: [MailFeatureReadiness]) {
        self.provider = provider
        self.account = account
        self.features = features.sorted { $0.feature.rawValue < $1.feature.rawValue }
    }

    public func feature(_ feature: MailProviderFeature) -> MailFeatureReadiness? {
        features.first { $0.feature == feature }
    }
}

public enum MailResourceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case label
    case folder
    case category
}

public struct MailResourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: String
    public let kind: MailResourceKind
    public let name: String
    public let system: Bool

    public init(id: String, providerID: String, kind: MailResourceKind, name: String, system: Bool = false) {
        self.id = id
        self.providerID = providerID
        self.kind = kind
        self.name = name
        self.system = system
    }
}

public struct MailQuery: Codable, Equatable, Sendable {
    public let text: String
    public let pageToken: String?
    public let limit: Int
    /// Namespaced adapter values, such as `gmail.raw-query`. Reusable packages
    /// must declare the corresponding extension before supplying one.
    public let extensions: [String: String]

    public init(text: String, pageToken: String? = nil, limit: Int = 40, extensions: [String: String] = [:]) {
        self.text = text
        self.pageToken = pageToken
        self.limit = min(max(limit, 1), 100)
        self.extensions = extensions
    }
}

public struct MailAttachmentSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { attachmentID }
    public let attachmentID: String
    public let messageID: String
    public let filename: String
    public let mediaType: String
    public let size: Int

    public init(attachmentID: String, messageID: String, filename: String, mediaType: String, size: Int) {
        self.attachmentID = attachmentID
        self.messageID = messageID
        self.filename = filename
        self.mediaType = mediaType
        self.size = size
    }
}

public struct MailMessageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let conversationID: String
    public let sender: String
    public let recipients: String
    public let subject: String
    public let dateDescription: String
    public let body: String
    public let resourceIDs: [String]
    public let attachments: [MailAttachmentSnapshot]
    public let inReplyTo: String
    public let references: String
    public let projectedHeaders: [String: String]

    public init(
        id: String, conversationID: String, sender: String, recipients: String, subject: String,
        dateDescription: String, body: String, resourceIDs: [String], attachments: [MailAttachmentSnapshot],
        inReplyTo: String = "", references: String = "", projectedHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.dateDescription = dateDescription
        self.body = body
        self.resourceIDs = resourceIDs
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.projectedHeaders = projectedHeaders
    }
}

public struct MailConversationSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let account: MailAccountIdentity
    public let accountAddress: String
    public let snippet: String
    public let cursor: String?
    public let messages: [MailMessageSnapshot]

    public init(
        id: String, account: MailAccountIdentity, accountAddress: String, snippet: String,
        cursor: String?, messages: [MailMessageSnapshot]
    ) {
        self.id = id
        self.account = account
        self.accountAddress = accountAddress
        self.snippet = snippet
        self.cursor = cursor
        self.messages = messages
    }

    public var resourceIDs: [String] { Array(Set(messages.flatMap(\.resourceIDs))).sorted() }
    public var stableID: String { "\(account.stableID):\(id)" }
}

public struct MailConversationPage: Codable, Equatable, Sendable {
    public let account: MailAccountIdentity
    public let conversations: [MailConversationSnapshot]
    public let nextPageToken: String?
    public let failedConversationCount: Int

    public init(
        account: MailAccountIdentity, conversations: [MailConversationSnapshot],
        nextPageToken: String?, failedConversationCount: Int = 0
    ) {
        self.account = account
        self.conversations = conversations
        self.nextPageToken = nextPageToken
        self.failedConversationCount = failedConversationCount
    }
}

public enum MailDeltaKind: String, Codable, CaseIterable, Equatable, Sendable {
    case messageAdded
    case messageDeleted
    case resourcesAdded
    case resourcesRemoved
}

public struct MailDeltaEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cursor: String
    public let kind: MailDeltaKind
    public let messageID: String
    public let conversationID: String
    public let resourceIDs: [String]

    public init(
        id: String, cursor: String, kind: MailDeltaKind, messageID: String,
        conversationID: String, resourceIDs: [String] = []
    ) {
        self.id = id
        self.cursor = cursor
        self.kind = kind
        self.messageID = messageID
        self.conversationID = conversationID
        self.resourceIDs = resourceIDs
    }
}

public struct MailDeltaPage: Codable, Equatable, Sendable {
    public let account: MailAccountIdentity
    public let startCursor: String
    public let latestCursor: String
    public let events: [MailDeltaEvent]
    public let nextPageToken: String?

    public init(
        account: MailAccountIdentity, startCursor: String, latestCursor: String,
        events: [MailDeltaEvent], nextPageToken: String?
    ) {
        self.account = account
        self.startCursor = startCursor
        self.latestCursor = latestCursor
        self.events = events
        self.nextPageToken = nextPageToken
    }
}

public enum MailCursorOrder: String, Codable, Equatable, Sendable {
    case ascending
    case same
    case descending
    case unordered
}

public enum MailConversationMutation: Equatable, Sendable {
    case archive
    case trash
    case markRead
    case applyResources(add: [String], remove: [String])
}

public struct MailEffectGrant: Equatable, Sendable {
    public let approvalID: String
    public let exactTarget: String

    public init(approvalID: String, exactTarget: String) {
        self.approvalID = approvalID
        self.exactTarget = exactTarget
    }
}

public struct MailMutationReceipt: Equatable, Sendable {
    public let approvalID: String
    public let exactTarget: String
    public let reconciledConversation: MailConversationSnapshot

    public init(approvalID: String, exactTarget: String, reconciledConversation: MailConversationSnapshot) {
        self.approvalID = approvalID
        self.exactTarget = exactTarget
        self.reconciledConversation = reconciledConversation
    }
}

public struct MailOutboundAttachment: Equatable, Sendable {
    public let filename: String
    public let mediaType: String
    public let data: Data

    public init(filename: String, mediaType: String, data: Data) {
        self.filename = filename
        self.mediaType = mediaType
        self.data = data
    }
}

public struct MailOutboundMessage: Equatable, Sendable {
    public let recipients: String
    public let subject: String
    public let body: String
    public let inReplyTo: String?
    public let references: [String]
    public let conversationID: String?
    public let attachments: [MailOutboundAttachment]

    public init(
        recipients: String, subject: String, body: String, inReplyTo: String? = nil,
        references: [String] = [], conversationID: String? = nil,
        attachments: [MailOutboundAttachment] = []
    ) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.conversationID = conversationID
        self.attachments = attachments
    }
}

public enum MailOutboundOperation: String, Codable, Equatable, Sendable {
    case draft
    case send
}

public struct MailOutboundReconciliation: Equatable, Sendable {
    public let recipients: String
    public let subject: String
    public let conversationID: String
    public let attachmentNames: [String]
    public let attachmentDigests: [String]
    public let verifiedAttachmentBytes: Bool

    public init(
        recipients: String, subject: String, conversationID: String, attachmentNames: [String],
        attachmentDigests: [String], verifiedAttachmentBytes: Bool
    ) {
        self.recipients = recipients
        self.subject = subject
        self.conversationID = conversationID
        self.attachmentNames = attachmentNames
        self.attachmentDigests = attachmentDigests
        self.verifiedAttachmentBytes = verifiedAttachmentBytes
    }
}

public struct MailOutboundReceipt: Equatable, Sendable {
    public let operation: MailOutboundOperation
    public let remoteID: String
    public let messageID: String?
    public let account: MailAccountIdentity
    public let reconciliation: MailOutboundReconciliation

    public init(
        operation: MailOutboundOperation, remoteID: String, messageID: String?,
        account: MailAccountIdentity, reconciliation: MailOutboundReconciliation
    ) {
        self.operation = operation
        self.remoteID = remoteID
        self.messageID = messageID
        self.account = account
        self.reconciliation = reconciliation
    }
}

public enum MailProviderAdapterError: Error, Equatable, LocalizedError, Sendable {
    case accountNotFound
    case unsupportedExtension(String)
    case invalidIdentifier
    case cursorExpired(String)
    case approvalMismatch
    case reconciliationFailed

    public var errorDescription: String? {
        switch self {
        case .accountNotFound: "The selected mail account is no longer connected."
        case let .unsupportedExtension(id): "The mail provider does not declare the requested extension: \(id)."
        case .invalidIdentifier: "The mail provider received an invalid identifier."
        case .cursorExpired: "The mail change cursor expired and requires a bounded full sync."
        case .approvalMismatch: "The approval does not match this exact mail action."
        case .reconciliationFailed: "The provider accepted the request but its postcondition could not be verified."
        }
    }
}

public protocol MailProviderAdapter: Sendable {
    var identity: MailProviderIdentity { get }
    func accounts() async throws -> [MailAccountSnapshot]
    func readiness(accountID: String, allowCredentialInteraction: Bool) async throws -> MailProviderReadinessSnapshot
    func search(accountID: String, query: MailQuery) async throws -> MailConversationPage
    func conversation(accountID: String, conversationID: String) async throws -> MailConversationSnapshot
    func resources(accountID: String) async throws -> [MailResourceSnapshot]
    func currentCursor(accountID: String) async throws -> String
    func deltas(
        accountID: String, startCursor: String, pageToken: String?, maximumResults: Int,
        resourceID: String?, kinds: [MailDeltaKind]
    ) async throws -> MailDeltaPage
    func compareCursors(_ left: String, _ right: String) async -> MailCursorOrder
    func attachment(accountID: String, messageID: String, attachmentID: String, maximumBytes: Int) async throws -> Data
    func exactMutationTarget(accountID: String, conversationID: String, mutation: MailConversationMutation) async throws -> String
    func mutate(
        accountID: String, conversationID: String, mutation: MailConversationMutation, grant: MailEffectGrant
    ) async throws -> MailMutationReceipt
    func reconciles(_ mutation: MailConversationMutation, conversation: MailConversationSnapshot) async -> Bool
    func exactOutboundTarget(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage
    ) async throws -> String
    func performOutbound(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage, grant: MailEffectGrant
    ) async throws -> MailOutboundReceipt
}

public extension MailProviderAdapter {
    func readiness(accountID: String) async throws -> MailProviderReadinessSnapshot {
        try await readiness(accountID: accountID, allowCredentialInteraction: false)
    }

    func compareCursors(_ left: String, _ right: String) async -> MailCursorOrder {
        left == right ? .same : .unordered
    }
}

public enum MailDeltaObservationDisposition: Equatable, Sendable {
    case events(events: [MailDeltaEvent], advanceCursorTo: String)
    case fullSyncRequired(expiredCursor: String)
}

public enum MailDeltaObserverError: Error, Equatable, LocalizedError, Sendable {
    case invalidCursor
    case paginationLoop
    case pageLimitExceeded
    case eventLimitExceeded
    case cursorRegressed

    public var errorDescription: String? {
        switch self {
        case .invalidCursor: "The mail change cursor is invalid."
        case .paginationLoop: "The mail provider returned a repeated change page token."
        case .pageLimitExceeded: "The mail update exceeded its bounded page limit."
        case .eventLimitExceeded: "The mail update exceeded its bounded event limit."
        case .cursorRegressed: "The mail provider returned a change cursor older than the requested cursor."
        }
    }
}

public struct MailDeltaObserver: Sendable {
    public let adapter: any MailProviderAdapter
    public let maximumPages: Int
    public let maximumEvents: Int

    public init(adapter: any MailProviderAdapter, maximumPages: Int = 100, maximumEvents: Int = 25_000) {
        self.adapter = adapter
        self.maximumPages = min(max(maximumPages, 1), 1_000)
        self.maximumEvents = min(max(maximumEvents, 1), 100_000)
    }

    public func observe(
        accountID: String, startCursor: String, resourceID: String? = nil,
        kinds: [MailDeltaKind] = MailDeltaKind.allCases
    ) async throws -> MailDeltaObservationDisposition {
        guard !startCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailDeltaObserverError.invalidCursor
        }
        var pageToken: String?
        var seenTokens = Set<String>()
        var events: [MailDeltaEvent] = []
        var latest = startCursor
        var pages = 0
        do {
            repeat {
                pages += 1
                guard pages <= maximumPages else { throw MailDeltaObserverError.pageLimitExceeded }
                let page = try await adapter.deltas(
                    accountID: accountID, startCursor: startCursor, pageToken: pageToken,
                    maximumResults: 500, resourceID: resourceID, kinds: kinds
                )
                guard await adapter.compareCursors(page.latestCursor, startCursor) != .ascending else {
                    throw MailDeltaObserverError.cursorRegressed
                }
                let order = await adapter.compareCursors(page.latestCursor, latest)
                if order == .descending || order == .unordered { latest = page.latestCursor }
                events.append(contentsOf: page.events)
                guard events.count <= maximumEvents else { throw MailDeltaObserverError.eventLimitExceeded }
                pageToken = page.nextPageToken
                if let pageToken, !seenTokens.insert(pageToken).inserted {
                    throw MailDeltaObserverError.paginationLoop
                }
            } while pageToken != nil
        } catch let MailProviderAdapterError.cursorExpired(expiredCursor) {
            return .fullSyncRequired(expiredCursor: expiredCursor)
        }
        var seenEventIDs = Set<String>()
        let deduplicated = events.filter { seenEventIDs.insert($0.id).inserted }
        return .events(
            events: deduplicated,
            advanceCursorTo: latest
        )
    }
}

public struct MailMutationBatchResult: Equatable, Sendable {
    public let succeededConversationIDs: [String]
    public let failures: [String: String]
    public let outcomeKnown: Bool

    public init(succeededConversationIDs: [String], failures: [String: String], outcomeKnown: Bool) {
        self.succeededConversationIDs = succeededConversationIDs.sorted()
        self.failures = failures
        self.outcomeKnown = outcomeKnown
    }
}

public struct MailMutationBatchExecutor: Sendable {
    public let adapter: any MailProviderAdapter

    public init(adapter: any MailProviderAdapter) { self.adapter = adapter }

    public func execute(
        accountID: String,
        conversationIDs: [String],
        mutation: MailConversationMutation,
        approvalID: String
    ) async -> MailMutationBatchResult {
        var succeeded: [String] = []
        var failures: [String: String] = [:]
        for conversationID in conversationIDs {
            do {
                let exactTarget = try await adapter.exactMutationTarget(
                    accountID: accountID, conversationID: conversationID, mutation: mutation
                )
                _ = try await adapter.mutate(
                    accountID: accountID, conversationID: conversationID, mutation: mutation,
                    grant: MailEffectGrant(approvalID: approvalID, exactTarget: exactTarget)
                )
                succeeded.append(conversationID)
            } catch {
                failures[conversationID] = error.localizedDescription
            }
        }
        return MailMutationBatchResult(
            succeededConversationIDs: succeeded,
            failures: failures,
            // A failed request cannot distinguish rejection from a transport
            // failure after dispatch; a separate postcondition read is required.
            outcomeKnown: failures.isEmpty
        )
    }

    public func reconcile(
        accountID: String,
        conversationIDs: [String],
        mutation: MailConversationMutation
    ) async -> MailMutationBatchResult {
        var succeeded: [String] = []
        var failures: [String: String] = [:]
        for conversationID in conversationIDs {
            do {
                let conversation = try await adapter.conversation(
                    accountID: accountID, conversationID: conversationID
                )
                if await adapter.reconciles(mutation, conversation: conversation) {
                    succeeded.append(conversationID)
                } else {
                    failures[conversationID] = "The provider postcondition does not hold."
                }
            } catch {
                failures[conversationID] = error.localizedDescription
            }
        }
        return MailMutationBatchResult(
            succeededConversationIDs: succeeded, failures: failures, outcomeKnown: true
        )
    }
}
