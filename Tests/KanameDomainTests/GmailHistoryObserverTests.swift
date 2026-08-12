import Foundation
import Testing
@testable import KanameConnectivity

struct GmailHistoryObserverTests {
    @Test
    func paginationDeduplicatesEventsAndAdvancesOnlyAfterTheFinalPage() async throws {
        let service = FakeGmailHistoryService(pages: [
            nil: .init(
                accountID: "account", accountIdentity: "person@example.test", startHistoryID: "100",
                latestHistoryID: "103", events: [Self.event(id: "a", historyID: "101")], nextPageToken: "next"
            ),
            "next": .init(
                accountID: "account", accountIdentity: "person@example.test", startHistoryID: "100",
                latestHistoryID: "105", events: [Self.event(id: "a", historyID: "101"), Self.event(id: "b", historyID: "104")], nextPageToken: nil
            ),
        ])
        let result = try await GmailHistoryObserver(service: service).observe(accountID: "account", startHistoryID: "100")
        #expect(result == .events(events: [Self.event(id: "a", historyID: "101"), Self.event(id: "b", historyID: "104")], advanceCursorTo: "105"))
    }

    @Test
    func expiredCursorRequiresBoundedFullSyncInsteadOfSilentAdvance() async throws {
        let result = try await GmailHistoryObserver(service: ExpiredGmailHistoryService())
            .observe(accountID: "account", startHistoryID: "100")
        #expect(result == .fullSyncRequired(expiredCursor: "100"))
    }

    private static func event(id: String, historyID: String) -> GmailHistoryEvent {
        GmailHistoryEvent.record(
            id: id, historyID: historyID, kind: .messageAdded,
            messageID: "message-\(id)", threadID: "thread-\(id)", labelIDs: ["INBOX"]
        )
    }
}

private actor FakeGmailHistoryService: GmailHistoryListing {
    let pages: [String?: GmailHistoryPage]

    init(pages: [String?: GmailHistoryPage]) { self.pages = pages }
    func gmailHistoryCursor(accountID: String) async throws -> String { "105" }
    func listGmailHistory(
        accountID: String,
        startHistoryID: String,
        pageToken: String?,
        maximumResults: Int,
        labelID: String?,
        historyTypes: [GmailHistoryEventKind]
    ) async throws -> GmailHistoryPage {
        try #require(pages[pageToken])
    }
}

private actor ExpiredGmailHistoryService: GmailHistoryListing {
    func gmailHistoryCursor(accountID: String) async throws -> String { "200" }
    func listGmailHistory(
        accountID: String,
        startHistoryID: String,
        pageToken: String?,
        maximumResults: Int,
        labelID: String?,
        historyTypes: [GmailHistoryEventKind]
    ) async throws -> GmailHistoryPage {
        throw NativeGoogleIntegrationError.httpStatus("Gmail history", 404)
    }
}
