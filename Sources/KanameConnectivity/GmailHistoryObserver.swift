import Foundation

public protocol GmailHistoryListing: Sendable {
    func gmailHistoryCursor(accountID: String) async throws -> String
    func listGmailHistory(
        accountID: String,
        startHistoryID: String,
        pageToken: String?,
        maximumResults: Int,
        labelID: String?,
        historyTypes: [GmailHistoryEventKind]
    ) async throws -> GmailHistoryPage
}

extension NativeGoogleIntegrationService: GmailHistoryListing {}

public enum GmailHistoryObservationDisposition: Equatable, Sendable {
    case events(events: [GmailHistoryEvent], advanceCursorTo: String)
    case fullSyncRequired(expiredCursor: String)
}

public enum GmailHistoryObserverError: Error, Equatable, LocalizedError, Sendable {
    case invalidCursor
    case paginationLoop
    case pageLimitExceeded
    case eventLimitExceeded
    case cursorRegressed

    public var errorDescription: String? {
        switch self {
        case .invalidCursor: "The Gmail history cursor is invalid."
        case .paginationLoop: "Gmail returned a repeated history page token."
        case .pageLimitExceeded: "The Gmail history update exceeded Kaname's bounded page limit."
        case .eventLimitExceeded: "The Gmail history update exceeded Kaname's bounded event limit."
        case .cursorRegressed: "Gmail returned a history cursor older than the requested cursor."
        }
    }
}

public struct GmailHistoryObserver: Sendable {
    public let service: any GmailHistoryListing
    public let maximumPages: Int
    public let maximumEvents: Int

    public init(
        service: any GmailHistoryListing,
        maximumPages: Int = 100,
        maximumEvents: Int = 25_000
    ) {
        self.service = service
        self.maximumPages = min(max(maximumPages, 1), 1_000)
        self.maximumEvents = min(max(maximumEvents, 1), 100_000)
    }

    public func observe(
        accountID: String,
        startHistoryID: String,
        labelID: String? = nil,
        historyTypes: [GmailHistoryEventKind] = GmailHistoryEventKind.allCases
    ) async throws -> GmailHistoryObservationDisposition {
        let start = try GmailAPIParser.validatedHistoryID(startHistoryID)
        var pageToken: String?
        var seenTokens = Set<String>()
        var events: [GmailHistoryEvent] = []
        var latest = start
        var pages = 0
        do {
            repeat {
                pages += 1
                guard pages <= maximumPages else { throw GmailHistoryObserverError.pageLimitExceeded }
                let page = try await service.listGmailHistory(
                    accountID: accountID,
                    startHistoryID: start,
                    pageToken: pageToken,
                    maximumResults: 500,
                    labelID: labelID,
                    historyTypes: historyTypes
                )
                guard decimalCompare(page.latestHistoryID, start) != .orderedAscending else {
                    throw GmailHistoryObserverError.cursorRegressed
                }
                latest = decimalCompare(page.latestHistoryID, latest) == .orderedDescending
                    ? page.latestHistoryID
                    : latest
                events.append(contentsOf: page.events)
                guard events.count <= maximumEvents else { throw GmailHistoryObserverError.eventLimitExceeded }
                pageToken = page.nextPageToken
                if let pageToken, !seenTokens.insert(pageToken).inserted {
                    throw GmailHistoryObserverError.paginationLoop
                }
            } while pageToken != nil
        } catch let NativeGoogleIntegrationError.httpStatus(service, status)
            where service == "Gmail history" && status == 404 {
            return .fullSyncRequired(expiredCursor: start)
        }
        var deduplicated: [String: GmailHistoryEvent] = [:]
        for event in events { deduplicated[event.id] = event }
        return .events(
            events: deduplicated.values.sorted {
                let order = decimalCompare($0.historyID, $1.historyID)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            },
            advanceCursorTo: latest
        )
    }

    private func decimalCompare(_ left: String, _ right: String) -> ComparisonResult {
        let lhs = left.drop(while: { $0 == "0" })
        let rhs = right.drop(while: { $0 == "0" })
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        if lhs == rhs { return .orderedSame }
        return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
    }
}
