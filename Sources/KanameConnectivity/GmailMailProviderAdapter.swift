import Foundation

public protocol GmailMailServing: Sendable {
    func accounts() async throws -> [NativeGoogleAccountSnapshot]
    func authorizationScopeDiff(
        accountID: String, requestedScopes: [String], reason: String,
        affectedWorkflowIDs: [String], allowKeychainInteraction: Bool
    ) async throws -> GoogleAuthorizationScopeDiff
    func searchMail(accountID: String, query: String, pageToken: String?, limit: Int) async throws -> GmailThreadPage
    func readMailThread(accountID: String, threadID: String) async throws -> GmailThreadDetailSnapshot
    func listGmailLabels(accountID: String) async throws -> [GmailLabelSnapshot]
    func gmailHistoryCursor(accountID: String) async throws -> String
    func listGmailHistory(
        accountID: String, startHistoryID: String, pageToken: String?, maximumResults: Int,
        labelID: String?, historyTypes: [GmailHistoryEventKind]
    ) async throws -> GmailHistoryPage
    func downloadGmailAttachment(
        accountID: String, messageID: String, attachmentID: String, maximumBytes: Int
    ) async throws -> Data
    func mutateMailThread(
        accountID: String, threadID: String, mutation: GmailThreadMutation, grant: GmailMutationGrant
    ) async throws -> GmailMutationReceipt
    func createGmailDraft(
        accountID: String, message: GmailOutboundMessage, grant: GmailMutationGrant
    ) async throws -> GmailDraftReceipt
    func sendGmailMessage(
        accountID: String, message: GmailOutboundMessage, grant: GmailMutationGrant
    ) async throws -> GmailSendReceipt
}

extension NativeGoogleIntegrationService: GmailMailServing {}

public struct GmailMailProviderAdapter: MailProviderAdapter, Sendable {
    public static let rawQueryExtensionID = "gmail.raw-query"
    public static let projectedHeadersExtensionID = "gmail.projected-headers"
    public static let modifyScope = "https://www.googleapis.com/auth/gmail.modify"
    public static let composeScope = "https://www.googleapis.com/auth/gmail.compose"

    public let identity = MailProviderIdentity(
        id: "google.gmail", kind: "mail", displayName: "Gmail", adapterVersion: 1
    )
    public let service: any GmailMailServing

    public init(service: any GmailMailServing) {
        self.service = service
    }

    public func accounts() async throws -> [MailAccountSnapshot] {
        try await service.accounts().map { account in
            MailAccountSnapshot(
                identity: accountIdentity(account.id),
                address: account.identity,
                displayName: account.displayName
            )
        }
    }

    public func readiness(
        accountID: String,
        allowCredentialInteraction: Bool
    ) async throws -> MailProviderReadinessSnapshot {
        let diff = try await service.authorizationScopeDiff(
            accountID: accountID,
            requestedScopes: [Self.modifyScope, Self.composeScope],
            reason: "Evaluate provider features required by installed mail workflows.",
            affectedWorkflowIDs: [],
            allowKeychainInteraction: allowCredentialInteraction
        )
        let readExtensions = [Self.rawQueryExtensionID, Self.projectedHeadersExtensionID]
        let features = MailProviderFeature.allCases.map { feature -> MailFeatureReadiness in
            let scopes: [String]
            let extensions: [String]
            switch feature {
            case .draft, .send:
                scopes = [Self.composeScope]
                extensions = []
            case .boundedSearch, .conversationRead:
                scopes = [Self.modifyScope]
                extensions = readExtensions
            default:
                scopes = [Self.modifyScope]
                extensions = []
            }
            return MailFeatureReadiness(
                feature: feature, supported: true, requiredScopes: scopes,
                grantedScopes: diff.grantedScopes, extensionIDs: extensions
            )
        }
        return MailProviderReadinessSnapshot(
            provider: identity, account: accountIdentity(accountID), features: features
        )
    }

    public func search(accountID: String, query: MailQuery) async throws -> MailConversationPage {
        let allowedExtensions = Set([Self.rawQueryExtensionID])
        guard Set(query.extensions.keys).isSubset(of: allowedExtensions) else {
            throw MailProviderAdapterError.unsupportedExtension(
                Set(query.extensions.keys).subtracting(allowedExtensions).sorted().first ?? "unknown"
            )
        }
        let expression = query.extensions[Self.rawQueryExtensionID] ?? query.text
        let page = try await service.searchMail(
            accountID: accountID, query: expression, pageToken: query.pageToken, limit: query.limit
        )
        return MailConversationPage(
            account: accountIdentity(page.accountID),
            conversations: page.threads.map(conversation),
            nextPageToken: page.nextPageToken,
            failedConversationCount: page.failedThreadCount
        )
    }

    public func conversation(accountID: String, conversationID: String) async throws -> MailConversationSnapshot {
        conversation(try await service.readMailThread(accountID: accountID, threadID: conversationID))
    }

    public func resources(accountID: String) async throws -> [MailResourceSnapshot] {
        try await service.listGmailLabels(accountID: accountID).map { label in
            MailResourceSnapshot(
                id: label.id, providerID: identity.id, kind: .label,
                name: label.name, system: label.type.uppercased() == "SYSTEM"
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func currentCursor(accountID: String) async throws -> String {
        try await service.gmailHistoryCursor(accountID: accountID)
    }

    public func deltas(
        accountID: String,
        startCursor: String,
        pageToken: String?,
        maximumResults: Int,
        resourceID: String?,
        kinds: [MailDeltaKind]
    ) async throws -> MailDeltaPage {
        do {
            let page = try await service.listGmailHistory(
                accountID: accountID,
                startHistoryID: startCursor,
                pageToken: pageToken,
                maximumResults: maximumResults,
                labelID: resourceID,
                historyTypes: kinds.map(gmailHistoryKind)
            )
            return MailDeltaPage(
                account: accountIdentity(page.accountID),
                startCursor: page.startHistoryID,
                latestCursor: page.latestHistoryID,
                events: page.events.map(deltaEvent),
                nextPageToken: page.nextPageToken
            )
        } catch let NativeGoogleIntegrationError.httpStatus(serviceName, status)
            where serviceName == "Gmail history" && status == 404 {
            throw MailProviderAdapterError.cursorExpired(startCursor)
        }
    }

    public func compareCursors(_ left: String, _ right: String) async -> MailCursorOrder {
        let lhs = left.drop(while: { $0 == "0" })
        let rhs = right.drop(while: { $0 == "0" })
        guard lhs.allSatisfy(\.isNumber), rhs.allSatisfy(\.isNumber) else {
            return left == right ? .same : .unordered
        }
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .ascending : .descending }
        if lhs == rhs { return .same }
        return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
    }

    public func attachment(
        accountID: String,
        messageID: String,
        attachmentID: String,
        maximumBytes: Int
    ) async throws -> Data {
        try await service.downloadGmailAttachment(
            accountID: accountID, messageID: messageID,
            attachmentID: attachmentID, maximumBytes: maximumBytes
        )
    }

    public func exactMutationTarget(
        accountID: String,
        conversationID: String,
        mutation: MailConversationMutation
    ) async throws -> String {
        NativeGoogleIntegrationService.gmailMutationTarget(
            accountID: accountID, threadID: conversationID, mutation: gmailMutation(mutation)
        )
    }

    public func mutate(
        accountID: String,
        conversationID: String,
        mutation: MailConversationMutation,
        grant: MailEffectGrant
    ) async throws -> MailMutationReceipt {
        do {
            let receipt = try await service.mutateMailThread(
                accountID: accountID,
                threadID: conversationID,
                mutation: gmailMutation(mutation),
                grant: GmailMutationGrant(approvalID: grant.approvalID, exactTarget: grant.exactTarget)
            )
            return MailMutationReceipt(
                approvalID: receipt.approvalID,
                exactTarget: receipt.exactTarget,
                reconciledConversation: conversation(receipt.reconciledThread)
            )
        } catch GmailWorkError.approvalMismatch {
            throw MailProviderAdapterError.approvalMismatch
        } catch GmailWorkError.reconciliationFailed {
            throw MailProviderAdapterError.reconciliationFailed
        }
    }

    public func reconciles(
        _ mutation: MailConversationMutation,
        conversation: MailConversationSnapshot
    ) async -> Bool {
        GmailAPIParser.reconciled(mutation: gmailMutation(mutation), labels: conversation.resourceIDs)
    }

    public func exactOutboundTarget(
        accountID: String,
        operation: MailOutboundOperation,
        message: MailOutboundMessage
    ) async throws -> String {
        let gmail = gmailMessage(message)
        return try operation == .send
            ? NativeGoogleIntegrationService.gmailSendTarget(accountID: accountID, message: gmail)
            : NativeGoogleIntegrationService.gmailDraftTarget(accountID: accountID, message: gmail)
    }

    public func performOutbound(
        accountID: String,
        operation: MailOutboundOperation,
        message: MailOutboundMessage,
        grant: MailEffectGrant
    ) async throws -> MailOutboundReceipt {
        let gmail = gmailMessage(message)
        let gmailGrant = GmailMutationGrant(approvalID: grant.approvalID, exactTarget: grant.exactTarget)
        do { switch operation {
        case .draft:
            let receipt = try await service.createGmailDraft(
                accountID: accountID, message: gmail, grant: gmailGrant
            )
            return MailOutboundReceipt(
                operation: .draft, remoteID: receipt.id, messageID: receipt.messageID,
                account: accountIdentity(receipt.accountID),
                reconciliation: reconciliation(receipt.reconciliation)
            )
        case .send:
            let receipt = try await service.sendGmailMessage(
                accountID: accountID, message: gmail, grant: gmailGrant
            )
            return MailOutboundReceipt(
                operation: .send, remoteID: receipt.messageID, messageID: receipt.messageID,
                account: accountIdentity(receipt.accountID),
                reconciliation: reconciliation(receipt.reconciliation)
            )
        } } catch GmailWorkError.approvalMismatch {
            throw MailProviderAdapterError.approvalMismatch
        } catch GmailWorkError.reconciliationFailed {
            throw MailProviderAdapterError.reconciliationFailed
        }
    }

    private func accountIdentity(_ localID: String) -> MailAccountIdentity {
        MailAccountIdentity(providerID: identity.id, localID: localID)
    }

    private func conversation(_ thread: GmailThreadDetailSnapshot) -> MailConversationSnapshot {
        MailConversationSnapshot(
            id: thread.id,
            account: accountIdentity(thread.accountID),
            accountAddress: thread.accountIdentity,
            snippet: thread.snippet,
            cursor: thread.historyID,
            messages: thread.messages.map { message in
                MailMessageSnapshot(
                    id: message.id,
                    conversationID: message.threadID,
                    sender: message.sender,
                    recipients: message.recipients,
                    subject: message.subject,
                    dateDescription: message.dateDescription,
                    body: message.body,
                    resourceIDs: message.labels,
                    attachments: message.attachments.map {
                        MailAttachmentSnapshot(
                            attachmentID: $0.attachmentID,
                            messageID: $0.messageID,
                            filename: $0.filename,
                            mediaType: $0.mimeType,
                            size: $0.size
                        )
                    },
                    inReplyTo: message.inReplyTo,
                    references: message.references,
                    projectedHeaders: message.projectedHeaders
                )
            }
        )
    }

    private func gmailHistoryKind(_ kind: MailDeltaKind) -> GmailHistoryEventKind {
        switch kind {
        case .messageAdded: .messageAdded
        case .messageDeleted: .messageDeleted
        case .resourcesAdded: .labelsAdded
        case .resourcesRemoved: .labelsRemoved
        }
    }

    private func deltaEvent(_ event: GmailHistoryEvent) -> MailDeltaEvent {
        let kind: MailDeltaKind = switch event.kind {
        case .messageAdded: .messageAdded
        case .messageDeleted: .messageDeleted
        case .labelsAdded: .resourcesAdded
        case .labelsRemoved: .resourcesRemoved
        }
        return MailDeltaEvent(
            id: event.id,
            cursor: event.historyID,
            kind: kind,
            messageID: event.messageID,
            conversationID: event.threadID,
            resourceIDs: event.labelIDs
        )
    }

    private func gmailMutation(_ mutation: MailConversationMutation) -> GmailThreadMutation {
        switch mutation {
        case .archive: .archive
        case .trash: .trash
        case .markRead: .applyLabels(add: [], remove: ["UNREAD"])
        case let .applyResources(add, remove): .applyLabels(add: add, remove: remove)
        }
    }

    private func gmailMessage(_ message: MailOutboundMessage) -> GmailOutboundMessage {
        GmailOutboundMessage(
            recipients: message.recipients,
            subject: message.subject,
            body: message.body,
            inReplyTo: message.inReplyTo,
            references: message.references,
            threadID: message.conversationID,
            attachments: message.attachments.map {
                GmailOutboundAttachment(filename: $0.filename, mimeType: $0.mediaType, data: $0.data)
            }
        )
    }

    private func reconciliation(_ value: GmailOutboundReconciliation) -> MailOutboundReconciliation {
        MailOutboundReconciliation(
            recipients: value.recipients,
            subject: value.subject,
            conversationID: value.threadID,
            attachmentNames: value.attachmentNames,
            attachmentDigests: value.attachmentDigests,
            verifiedAttachmentBytes: value.verifiedAttachmentBytes
        )
    }
}
