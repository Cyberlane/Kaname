import Foundation
import Testing
@testable import KanameConnectivity

struct MailProviderAdapterContractTests {
    @Test
    func fakeJMAPProviderProvesStableAccountsFeaturesQueriesAndLogicalResources() async throws {
        let adapter = FakeJMAPMailAdapter()
        let accounts = try await adapter.accounts()
        let account = try #require(accounts.first)
        let readiness = try await adapter.readiness(accountID: account.identity.localID)
        let page = try await adapter.search(accountID: account.identity.localID, query: MailQuery(text: "quarterly"))
        let resources = try await adapter.resources(accountID: account.identity.localID)

        #expect(adapter.identity.id == "example.jmap")
        #expect(account.identity.stableID == "example.jmap:account-1")
        #expect(readiness.features.allSatisfy { $0.ready })
        #expect(page.conversations.map(\.id) == ["conversation-1"])
        #expect(resources.map(\.kind) == [.folder, .folder])
        #expect(resources.map(\.id) == ["archive", "inbox"])
    }

    @Test
    func deltaPaginationDeduplicatesEventsAndPreservesResourceChanges() async throws {
        let adapter = FakeJMAPMailAdapter()
        try await MailProviderAdapterConformance.expectDeltaPagination(
            adapter: adapter,
            expectedEvents: [
            .init(
                id: "event-a", cursor: "101", kind: .messageAdded,
                messageID: "message-1", conversationID: "conversation-1", resourceIDs: ["inbox"]
            ),
            .init(
                id: "event-b", cursor: "104", kind: .resourcesRemoved,
                messageID: "message-1", conversationID: "conversation-1", resourceIDs: ["inbox"]
            ),
        ])
    }

    @Test
    func expiredCursorRequiresFullSyncWithoutSilentlyAdvancing() async throws {
        try await MailProviderAdapterConformance.expectExpiredCursor(
            adapter: FakeJMAPMailAdapter(expireCursor: true)
        )
    }

    @Test
    func mutationRequiresExactGrantAndReturnsReconciledPostcondition() async throws {
        let adapter = FakeJMAPMailAdapter()
        let target = try await adapter.exactMutationTarget(
            accountID: "account-1", conversationID: "conversation-1", mutation: .archive
        )
        await #expect(throws: MailProviderAdapterError.approvalMismatch) {
            _ = try await adapter.mutate(
                accountID: "account-1", conversationID: "conversation-1", mutation: .archive,
                grant: MailEffectGrant(approvalID: "approval", exactTarget: "wrong")
            )
        }
        let receipt = try await adapter.mutate(
            accountID: "account-1", conversationID: "conversation-1", mutation: .archive,
            grant: MailEffectGrant(approvalID: "approval", exactTarget: target)
        )
        #expect(receipt.exactTarget == target)
        #expect(await adapter.reconciles(.archive, conversation: receipt.reconciledConversation))
    }

    @Test
    func partialMutationKeepsUnknownOutcomeUntilEveryPostconditionIsReconciled() async throws {
        let adapter = FakeJMAPMailAdapter(failedMutationIDs: ["conversation-2"])
        let executor = MailMutationBatchExecutor(adapter: adapter)
        let execution = await executor.execute(
            accountID: "account-1", conversationIDs: ["conversation-1", "conversation-2"],
            mutation: .archive, approvalID: "approval"
        )
        #expect(execution.succeededConversationIDs == ["conversation-1"])
        #expect(execution.failures.keys.sorted() == ["conversation-2"])
        #expect(!execution.outcomeKnown)

        let reconciliation = await executor.reconcile(
            accountID: "account-1", conversationIDs: ["conversation-1", "conversation-2"],
            mutation: .archive
        )
        #expect(reconciliation.outcomeKnown)
        #expect(reconciliation.succeededConversationIDs == ["conversation-1"])
        #expect(reconciliation.failures.keys.sorted() == ["conversation-2"])
    }

    @Test
    func outboundDraftAndSendUseProviderTargetsAndReturnReconciliation() async throws {
        let adapter = FakeJMAPMailAdapter()
        let message = MailOutboundMessage(
            recipients: "recipient@example.test", subject: "Re: Quarterly report", body: "Approved.",
            conversationID: "conversation-1",
            attachments: [.init(filename: "report.pdf", mediaType: "application/pdf", data: Data("pdf".utf8))]
        )
        for operation in [MailOutboundOperation.draft, .send] {
            let target = try await adapter.exactOutboundTarget(
                accountID: "account-1", operation: operation, message: message
            )
            let receipt = try await adapter.performOutbound(
                accountID: "account-1", operation: operation, message: message,
                grant: MailEffectGrant(approvalID: "approval", exactTarget: target)
            )
            #expect(receipt.operation == operation)
            #expect(receipt.reconciliation.conversationID == "conversation-1")
            #expect(receipt.reconciliation.attachmentNames == ["report.pdf"])
            #expect(receipt.reconciliation.verifiedAttachmentBytes)
        }
    }
}

enum MailProviderAdapterConformance {
    static func expectDeltaPagination(
        adapter: any MailProviderAdapter,
        accountID: String = "account-1",
        startCursor: String = "100",
        expectedEvents: [MailDeltaEvent],
        expectedCursor: String = "105"
    ) async throws {
        let result = try await MailDeltaObserver(adapter: adapter).observe(
            accountID: accountID, startCursor: startCursor
        )
        #expect(result == .events(events: expectedEvents, advanceCursorTo: expectedCursor))
    }

    static func expectExpiredCursor(
        adapter: any MailProviderAdapter,
        accountID: String = "account-1",
        startCursor: String = "100"
    ) async throws {
        let result = try await MailDeltaObserver(adapter: adapter).observe(
            accountID: accountID, startCursor: startCursor
        )
        #expect(result == .fullSyncRequired(expiredCursor: startCursor))
    }
}

private actor FakeJMAPMailAdapter: MailProviderAdapter {
    nonisolated let identity = MailProviderIdentity(
        id: "example.jmap", kind: "mail", displayName: "Example JMAP", adapterVersion: 1
    )
    private let expireCursor: Bool
    private let failedMutationIDs: Set<String>
    private var archivedConversationIDs: Set<String> = []

    init(expireCursor: Bool = false, failedMutationIDs: Set<String> = []) {
        self.expireCursor = expireCursor
        self.failedMutationIDs = failedMutationIDs
    }

    func accounts() async throws -> [MailAccountSnapshot] {
        [.init(identity: account, address: "person@example.test", displayName: "Example")]
    }

    func readiness(accountID: String, allowCredentialInteraction: Bool) async throws -> MailProviderReadinessSnapshot {
        MailProviderReadinessSnapshot(
            provider: identity,
            account: account,
            features: MailProviderFeature.allCases.map {
                MailFeatureReadiness(feature: $0, supported: true, requiredScopes: [], grantedScopes: [])
            }
        )
    }

    func search(accountID: String, query: MailQuery) async throws -> MailConversationPage {
        MailConversationPage(account: account, conversations: [conversationSnapshot(id: "conversation-1")], nextPageToken: nil)
    }

    func conversation(accountID: String, conversationID: String) async throws -> MailConversationSnapshot {
        conversationSnapshot(id: conversationID)
    }

    func resources(accountID: String) async throws -> [MailResourceSnapshot] {
        [
            .init(id: "archive", providerID: identity.id, kind: .folder, name: "Archive", system: true),
            .init(id: "inbox", providerID: identity.id, kind: .folder, name: "Inbox", system: true),
        ]
    }

    func currentCursor(accountID: String) async throws -> String { "105" }

    func deltas(
        accountID: String,
        startCursor: String,
        pageToken: String?,
        maximumResults: Int,
        resourceID: String?,
        kinds: [MailDeltaKind]
    ) async throws -> MailDeltaPage {
        if expireCursor { throw MailProviderAdapterError.cursorExpired(startCursor) }
        let first = MailDeltaEvent(
            id: "event-a", cursor: "101", kind: .messageAdded,
            messageID: "message-1", conversationID: "conversation-1", resourceIDs: ["inbox"]
        )
        if pageToken == nil {
            return MailDeltaPage(
                account: account, startCursor: startCursor, latestCursor: "103",
                events: [first], nextPageToken: "next"
            )
        }
        return MailDeltaPage(
            account: account, startCursor: startCursor, latestCursor: "105",
            events: [first, .init(
                id: "event-b", cursor: "104", kind: .resourcesRemoved,
                messageID: "message-1", conversationID: "conversation-1", resourceIDs: ["inbox"]
            )], nextPageToken: nil
        )
    }

    func attachment(
        accountID: String, messageID: String, attachmentID: String, maximumBytes: Int
    ) async throws -> Data {
        Data("fixture".utf8)
    }

    func exactMutationTarget(
        accountID: String, conversationID: String, mutation: MailConversationMutation
    ) async throws -> String {
        "mail:\(identity.id):\(accountID):\(conversationID):archive"
    }

    func mutate(
        accountID: String,
        conversationID: String,
        mutation: MailConversationMutation,
        grant: MailEffectGrant
    ) async throws -> MailMutationReceipt {
        let target = try await exactMutationTarget(
            accountID: accountID, conversationID: conversationID, mutation: mutation
        )
        guard target == grant.exactTarget else { throw MailProviderAdapterError.approvalMismatch }
        if failedMutationIDs.contains(conversationID) {
            throw MailProviderAdapterError.reconciliationFailed
        }
        archivedConversationIDs.insert(conversationID)
        return MailMutationReceipt(
            approvalID: grant.approvalID, exactTarget: target,
            reconciledConversation: conversationSnapshot(id: conversationID)
        )
    }

    func reconciles(
        _ mutation: MailConversationMutation,
        conversation: MailConversationSnapshot
    ) async -> Bool {
        switch mutation {
        case .archive: !conversation.resourceIDs.contains("inbox")
        case .trash: conversation.resourceIDs.contains("trash")
        case .markRead: !conversation.resourceIDs.contains("unread")
        case let .applyResources(add, remove):
            Set(add).isSubset(of: Set(conversation.resourceIDs))
                && Set(remove).isDisjoint(with: Set(conversation.resourceIDs))
        }
    }

    func exactOutboundTarget(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage
    ) async throws -> String {
        "mail:\(identity.id):\(accountID):\(operation.rawValue):\(message.subject)"
    }

    func performOutbound(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage,
        grant: MailEffectGrant
    ) async throws -> MailOutboundReceipt {
        let target = try await exactOutboundTarget(accountID: accountID, operation: operation, message: message)
        guard grant.exactTarget == target else { throw MailProviderAdapterError.approvalMismatch }
        return MailOutboundReceipt(
            operation: operation, remoteID: "remote-1", messageID: "message-2", account: account,
            reconciliation: MailOutboundReconciliation(
                recipients: message.recipients, subject: message.subject,
                conversationID: message.conversationID ?? "conversation-2",
                attachmentNames: message.attachments.map(\.filename), attachmentDigests: [],
                verifiedAttachmentBytes: true
            )
        )
    }

    private var account: MailAccountIdentity {
        MailAccountIdentity(providerID: identity.id, localID: "account-1")
    }

    private func conversationSnapshot(id: String) -> MailConversationSnapshot {
        let resourceIDs = archivedConversationIDs.contains(id) ? ["archive"] : ["inbox", "unread"]
        return MailConversationSnapshot(
            id: id, account: account, accountAddress: "person@example.test",
            snippet: "Quarterly report", cursor: "105",
            messages: [.init(
                id: "message-1", conversationID: id,
                sender: "sender@example.test", recipients: "person@example.test",
                subject: "Quarterly report", dateDescription: "Today", body: "Body",
                resourceIDs: resourceIDs, attachments: []
            )]
        )
    }
}
