import Foundation
import Testing
@testable import KanameConnectivity

struct GmailAdapterConformanceTests {
    @Test
    func adapterPublishesScopesExtensionsResourcesAndStableProviderIdentity() async throws {
        let service = GmailConformanceFixtureService(grantedScopes: [GmailMailProviderAdapter.modifyScope])
        let adapter = GmailMailProviderAdapter(service: service)
        let account = try #require(try await adapter.accounts().first)
        let readiness = try await adapter.readiness(accountID: "account-1")
        let resources = try await adapter.resources(accountID: "account-1")

        #expect(account.identity.stableID == "google.gmail:account-1")
        #expect(readiness.feature(.boundedSearch)?.ready == true)
        #expect(readiness.feature(.boundedSearch)?.extensionIDs == [
            GmailMailProviderAdapter.projectedHeadersExtensionID,
            GmailMailProviderAdapter.rawQueryExtensionID,
        ])
        #expect(readiness.feature(.send)?.missingScopes == [GmailMailProviderAdapter.composeScope])
        #expect(resources.map(\.id) == ["INBOX", "Label_1"])
    }

    @Test
    func adapterHistoryUsesSharedPaginationDuplicateAndLabelChangeContract() async throws {
        let adapter = GmailMailProviderAdapter(service: GmailConformanceFixtureService())
        try await MailProviderAdapterConformance.expectDeltaPagination(
            adapter: adapter,
            expectedEvents: [
            .init(
                id: "a", cursor: "101", kind: .messageAdded,
                messageID: "message-1", conversationID: "thread-1", resourceIDs: ["INBOX"]
            ),
            .init(
                id: "b", cursor: "104", kind: .resourcesRemoved,
                messageID: "message-1", conversationID: "thread-1", resourceIDs: ["UNREAD"]
            ),
        ])
    }

    @Test
    func adapterConvertsExpiredHistoryToFullSyncDisposition() async throws {
        let adapter = GmailMailProviderAdapter(service: GmailConformanceFixtureService(expireCursor: true))
        try await MailProviderAdapterConformance.expectExpiredCursor(adapter: adapter)
    }

    @Test
    func adapterUsesTheBodyFreeMetadataSurfaceForWorkflowObservation() async throws {
        let adapter = GmailMailProviderAdapter(service: GmailConformanceFixtureService())
        let metadata = try await adapter.conversationMetadata(
            accountID: "account-1", conversationID: "thread-1",
            selectedHeaders: ["From", "Date"]
        )

        #expect(metadata.id == "thread-1")
        #expect(metadata.account.stableID == "google.gmail:account-1")
        #expect(metadata.cursor == "105")
        #expect(metadata.messages.first?.headers == ["Date": "fixture", "From": "fixture"])
        #expect(metadata.resourceIDs == ["INBOX"])
    }

    @Test
    func adapterRejectsUndeclaredQueryExtensions() async {
        let adapter = GmailMailProviderAdapter(service: GmailConformanceFixtureService())
        await #expect(throws: MailProviderAdapterError.unsupportedExtension("portable.unknown")) {
            _ = try await adapter.search(
                accountID: "account-1",
                query: MailQuery(text: "inbox", extensions: ["portable.unknown": "value"])
            )
        }
    }

    @Test
    func adapterDraftAndSendTargetsBindGenericMessageToGmailReconciliation() async throws {
        let adapter = GmailMailProviderAdapter(service: GmailConformanceFixtureService())
        let message = MailOutboundMessage(
            recipients: "recipient@example.test", subject: "Subject", body: "Body",
            conversationID: "thread-1"
        )
        for operation in [MailOutboundOperation.draft, .send] {
            let target = try await adapter.exactOutboundTarget(
                accountID: "account-1", operation: operation, message: message
            )
            let receipt = try await adapter.performOutbound(
                accountID: "account-1", operation: operation, message: message,
                grant: MailEffectGrant(approvalID: "approval", exactTarget: target)
            )
            #expect(target.hasPrefix("gmail:account-1:\(operation.rawValue):sha256="))
            #expect(receipt.operation == operation)
            #expect(receipt.reconciliation.conversationID == "thread-1")
        }
    }
}

private actor GmailConformanceFixtureService: GmailMailServing {
    private let grantedScopes: [String]
    private let expireCursor: Bool

    init(
        grantedScopes: [String] = [GmailMailProviderAdapter.modifyScope, GmailMailProviderAdapter.composeScope],
        expireCursor: Bool = false
    ) {
        self.grantedScopes = grantedScopes
        self.expireCursor = expireCursor
    }

    func accounts() async throws -> [NativeGoogleAccountSnapshot] {
        [.init(
            id: "account-1", identity: "person@example.test", displayName: "Person",
            capabilities: ["Gmail"], authorizationVersion: 2
        )]
    }

    func authorizationScopeDiff(
        accountID: String, requestedScopes: [String], reason: String,
        affectedWorkflowIDs: [String], allowKeychainInteraction: Bool
    ) async throws -> GoogleAuthorizationScopeDiff {
        GoogleAuthorizationScopeDiff(
            accountID: accountID, grantedScopes: grantedScopes,
            requestedScopes: requestedScopes,
            addedScopes: Array(Set(requestedScopes).subtracting(grantedScopes)).sorted(),
            reason: reason, affectedWorkflowIDs: affectedWorkflowIDs
        )
    }

    func searchMail(
        accountID: String, query: String, pageToken: String?, limit: Int
    ) async throws -> GmailThreadPage {
        GmailThreadPage(
            accountID: accountID, accountIdentity: "person@example.test", query: query,
            threads: [thread()], nextPageToken: nil, failedThreadCount: 0
        )
    }

    func readMailThread(accountID: String, threadID: String) async throws -> GmailThreadDetailSnapshot {
        thread()
    }

    func readMailThreadMetadata(
        accountID: String,
        threadID: String,
        selectedHeaders: [String]
    ) async throws -> GmailThreadMetadataSnapshot {
        GmailThreadMetadataSnapshot(
            id: "thread-1",
            accountID: accountID,
            historyID: "105",
            messages: [.init(
                id: "message-1",
                threadID: "thread-1",
                headers: Dictionary(uniqueKeysWithValues: selectedHeaders.map { ($0, "fixture") }),
                labels: ["INBOX"]
            )]
        )
    }

    func listGmailLabels(accountID: String) async throws -> [GmailLabelSnapshot] {
        [
            .init(id: "INBOX", name: "Inbox", type: "system"),
            .init(id: "Label_1", name: "Projects", type: "user"),
        ]
    }

    func gmailHistoryCursor(accountID: String) async throws -> String { "105" }

    func listGmailHistory(
        accountID: String, startHistoryID: String, pageToken: String?, maximumResults: Int,
        labelID: String?, historyTypes: [GmailHistoryEventKind]
    ) async throws -> GmailHistoryPage {
        if expireCursor { throw NativeGoogleIntegrationError.httpStatus("Gmail history", 404) }
        let first = GmailHistoryEvent.record(
            id: "a", historyID: "101", kind: .messageAdded,
            messageID: "message-1", threadID: "thread-1", labelIDs: ["INBOX"]
        )
        if pageToken == nil {
            return GmailHistoryPage(
                accountID: accountID, accountIdentity: "person@example.test",
                startHistoryID: startHistoryID, latestHistoryID: "103",
                events: [first], nextPageToken: "next"
            )
        }
        return GmailHistoryPage(
            accountID: accountID, accountIdentity: "person@example.test",
            startHistoryID: startHistoryID, latestHistoryID: "105",
            events: [first, .record(
                id: "b", historyID: "104", kind: .labelsRemoved,
                messageID: "message-1", threadID: "thread-1", labelIDs: ["UNREAD"]
            )], nextPageToken: nil
        )
    }

    func downloadGmailAttachment(
        accountID: String, messageID: String, attachmentID: String, maximumBytes: Int
    ) async throws -> Data { Data("fixture".utf8) }

    func mutateMailThread(
        accountID: String, threadID: String, mutation: GmailThreadMutation, grant: GmailMutationGrant
    ) async throws -> GmailMutationReceipt {
        GmailMutationReceipt(approvalID: grant.approvalID, exactTarget: grant.exactTarget, reconciledThread: thread())
    }

    func createGmailDraft(
        accountID: String, message: GmailOutboundMessage, grant: GmailMutationGrant
    ) async throws -> GmailDraftReceipt {
        GmailDraftReceipt(id: "draft-1", messageID: "message-2", accountID: accountID, reconciliation: reconciliation(message))
    }

    func sendGmailMessage(
        accountID: String, message: GmailOutboundMessage, grant: GmailMutationGrant
    ) async throws -> GmailSendReceipt {
        GmailSendReceipt(messageID: "message-2", threadID: "thread-1", accountID: accountID, reconciliation: reconciliation(message))
    }

    private func thread() -> GmailThreadDetailSnapshot {
        GmailThreadDetailSnapshot(
            id: "thread-1", accountID: "account-1", accountIdentity: "person@example.test",
            snippet: "Hello", historyID: "105",
            messages: [.init(
                id: "message-1", threadID: "thread-1", sender: "sender@example.test",
                recipients: "person@example.test", subject: "Hello", dateDescription: "Today",
                body: "Body", labels: ["INBOX"], attachments: [], inReplyTo: "", references: "",
                projectedHeaders: [:]
            )]
        )
    }

    private func reconciliation(_ message: GmailOutboundMessage) -> GmailOutboundReconciliation {
        GmailOutboundReconciliation(
            recipients: message.recipients, subject: message.subject,
            threadID: message.threadID ?? "thread-1",
            attachmentNames: message.attachments.map(\.filename), attachmentDigests: [],
            verifiedAttachmentBytes: true
        )
    }
}
