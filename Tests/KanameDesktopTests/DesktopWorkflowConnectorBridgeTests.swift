import Foundation
import Testing
import KanameConnectivity
@testable import KanameWorkflowHost

struct DesktopWorkflowConnectorBridgeTests {
    @Test("expired dispatch stops before the provider adapter is touched")
    func expiredDispatchIsRejectedAtBoundary() async throws {
        let adapter = BridgeFixtureMailAdapter(reconciliation: .success)
        let bridge = DesktopWorkflowConnectorBridge(
            environment: KanameDesktopEnvironment(channel: .candidate), adapter: adapter
        )
        let line = try JSONSerialization.data(withJSONObject: [
            "mode": "dispatch",
            "request": [
                "action": "archive",
                "accountBindingId": "account-1",
                "deadlineUnixMillis": 1,
                "input": ["accountId": "account-1", "conversationIds": ["conversation-1"]],
            ],
        ])

        let result = await bridge.handle(line)
        #expect(result["outcome"] as? String == "outcome_unknown")
        #expect(result["errorCode"] as? String == "connector.dispatch_expired")
        #expect(await adapter.accountsCallCount == 0)
        #expect(await adapter.conversationCallCount == 0)
    }

    @Test("partial reconciliation stays unknown when one target cannot be verified")
    func partialReconciliationStaysUnknown() async throws {
        let adapter = BridgeFixtureMailAdapter(reconciliation: .partial)
        let bridge = DesktopWorkflowConnectorBridge(
            environment: KanameDesktopEnvironment(channel: .candidate), adapter: adapter
        )
        let result = await bridge.handle(try reconciliationLine(conversationIDs: ["good", "bad"]))
        #expect(result["outcome"] as? String == "still_unknown")
        #expect(result["errorCode"] as? String == "connector.reconciliation_incomplete")
    }

    @Test("failed reconciliation stays unknown when the provider read fails")
    func failedReconciliationStaysUnknown() async throws {
        let adapter = BridgeFixtureMailAdapter(reconciliation: .failure)
        let bridge = DesktopWorkflowConnectorBridge(
            environment: KanameDesktopEnvironment(channel: .candidate), adapter: adapter
        )
        let result = await bridge.handle(try reconciliationLine(conversationIDs: ["failed"]))
        #expect(result["outcome"] as? String == "still_unknown")
        #expect(result["errorCode"] as? String == "connector.reconciliation_incomplete")
    }

    private func reconciliationLine(conversationIDs: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "mode": "reconcile",
            "request": [
                "action": "archive",
                "accountBindingId": "account-1",
                "input": [
                    "accountId": "account-1",
                    "conversationIds": conversationIDs,
                ],
            ],
        ])
    }
}

private actor BridgeFixtureMailAdapter: MailProviderAdapter {
    enum Reconciliation: Equatable, Sendable {
        case success
        case partial
        case failure
    }

    nonisolated let identity = MailProviderIdentity(
        id: "fixture.mail", kind: "mail", displayName: "Fixture Mail", adapterVersion: 1
    )
    private let reconciliation: Reconciliation
    private(set) var accountsCallCount = 0
    private(set) var conversationCallCount = 0

    init(reconciliation: Reconciliation) {
        self.reconciliation = reconciliation
    }

    func accounts() async throws -> [MailAccountSnapshot] {
        accountsCallCount += 1
        return [MailAccountSnapshot(identity: account, address: "person@example.test", displayName: "Fixture")]
    }

    func readiness(accountID: String, allowCredentialInteraction: Bool) async throws -> MailProviderReadinessSnapshot {
        MailProviderReadinessSnapshot(
            provider: identity,
            account: account,
            features: MailProviderFeature.allCases.map {
                MailFeatureReadiness(feature: $0, supported: true)
            }
        )
    }

    func search(accountID: String, query: MailQuery) async throws -> MailConversationPage {
        MailConversationPage(account: account, conversations: [], nextPageToken: nil)
    }

    func conversation(accountID: String, conversationID: String) async throws -> MailConversationSnapshot {
        conversationCallCount += 1
        if reconciliation == .failure || (reconciliation == .partial && conversationID == "bad") {
            throw MailProviderAdapterError.reconciliationFailed
        }
        return conversationSnapshot(id: conversationID, archived: reconciliation == .success || conversationID == "good")
    }

    func resources(accountID: String) async throws -> [MailResourceSnapshot] { [] }
    func currentCursor(accountID: String) async throws -> String { "1" }

    func deltas(
        accountID: String,
        startCursor: String,
        pageToken: String?,
        maximumResults: Int,
        resourceID: String?,
        kinds: [MailDeltaKind]
    ) async throws -> MailDeltaPage {
        MailDeltaPage(account: account, startCursor: startCursor, latestCursor: startCursor, events: [], nextPageToken: nil)
    }

    func attachment(accountID: String, messageID: String, attachmentID: String, maximumBytes: Int) async throws -> Data {
        Data()
    }

    func exactMutationTarget(
        accountID: String, conversationID: String, mutation: MailConversationMutation
    ) async throws -> String {
        "fixture:\(accountID):\(conversationID)"
    }

    func mutate(
        accountID: String, conversationID: String, mutation: MailConversationMutation, grant: MailEffectGrant
    ) async throws -> MailMutationReceipt {
        MailMutationReceipt(
            approvalID: grant.approvalID,
            exactTarget: grant.exactTarget,
            reconciledConversation: conversationSnapshot(id: conversationID, archived: true)
        )
    }

    func reconciles(_ mutation: MailConversationMutation, conversation: MailConversationSnapshot) async -> Bool {
        conversation.resourceIDs.contains("archive")
    }

    func exactOutboundTarget(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage
    ) async throws -> String {
        "fixture-outbound"
    }

    func performOutbound(
        accountID: String, operation: MailOutboundOperation, message: MailOutboundMessage, grant: MailEffectGrant
    ) async throws -> MailOutboundReceipt {
        MailOutboundReceipt(
            operation: operation,
            remoteID: "remote-1",
            messageID: "message-1",
            account: account,
            reconciliation: MailOutboundReconciliation(
                recipients: message.recipients,
                subject: message.subject,
                conversationID: message.conversationID ?? "conversation-1",
                attachmentNames: [],
                attachmentDigests: [],
                verifiedAttachmentBytes: true
            )
        )
    }

    private var account: MailAccountIdentity {
        MailAccountIdentity(providerID: identity.id, localID: "account-1")
    }

    private func conversationSnapshot(id: String, archived: Bool) -> MailConversationSnapshot {
        MailConversationSnapshot(
            id: id,
            account: account,
            accountAddress: "person@example.test",
            snippet: "Fixture",
            cursor: "1",
            messages: [MailMessageSnapshot(
                id: "message-\(id)",
                conversationID: id,
                sender: "sender@example.test",
                recipients: "person@example.test",
                subject: "Fixture",
                dateDescription: "Today",
                body: "Fixture",
                resourceIDs: archived ? ["archive"] : ["inbox"],
                attachments: []
            )]
        )
    }
}
