import Foundation
import Testing
@testable import KanameWorkflowHost

struct DesktopWorkflowPollingPolicyTests {
    @Test("failed admission and failed page never commit a cursor")
    func failuresKeepCursorReplayable() {
        var event = DesktopWorkflowEventPolling.CursorAdmissionState(
            cursor: "100", maximumPages: 10, maximumEnrichments: 40
        )
        let reserved = event.reserveEnrichment()
        #expect(reserved)
        event.fail()
        #expect(event.committedCursor == nil)

        var page = DesktopWorkflowEventPolling.CursorAdmissionState(
            cursor: "100", maximumPages: 10, maximumEnrichments: 40
        )
        page.fail()
        let acceptedAfterFailure = page.acceptPage(latestCursor: "101", nextPageToken: nil)
        #expect(!acceptedAfterFailure)
        #expect(page.committedCursor == nil)
    }

    @Test("enrichment deferral persists and resumes after restart without starving the 41st event")
    func enrichmentBudgetResumes() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-pending-admissions")
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingURL = root.appendingPathComponent("mail-pending.json")
        let eventIDs = (1...41).map { "gmail:account:message-\($0)" }
        var first = DesktopWorkflowEventPolling.CursorAdmissionState(
            cursor: "100", maximumPages: 10, maximumEnrichments: 40
        )
        var admitted = Set<String>()
        for eventID in eventIDs {
            guard first.reserveEnrichment() else { break }
            admitted.insert(eventID)
        }
        #expect(admitted.count == 40)
        #expect(first.committedCursor == nil)
        let pending = ["account": DesktopMailEventPoller.PendingAdmissions(
            cursor: "100", eventIDs: admitted.sorted()
        )]
        #expect(DesktopMailEventPoller.savePendingChecked(pending, to: pendingURL))

        // A restart replays the same page, but the durable pending IDs let the
        // worker skip already admitted events and spend its budget on the rest.
        let restored = try #require(DesktopMailEventPoller.loadPending(pendingURL))
        let restoredIDs = try #require(restored["account"]?.eventIDs)
        #expect(restoredIDs.count == 40)
        var resumed = DesktopWorkflowEventPolling.CursorAdmissionState(
            cursor: "100", maximumPages: 10, maximumEnrichments: 40
        )
        for eventID in eventIDs where !Set(restoredIDs).contains(eventID) {
            if resumed.reserveEnrichment() { admitted.insert(eventID) }
        }
        #expect(admitted.count == 41)
        let resumedPageAccepted = resumed.acceptPage(latestCursor: "141", nextPageToken: nil)
        #expect(resumedPageAccepted)
        #expect(resumed.committedCursor == "141")
    }

    @Test("pending admission corruption and overflow fail closed")
    func pendingAdmissionPersistenceFailsClosed() throws {
        let root = try TestTemporaryDirectory.make(prefix: "kaname-pending-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingURL = root.appendingPathComponent("mail-pending.json")
        try Data("not-json".utf8).write(to: pendingURL)
        #expect(DesktopMailEventPoller.loadPending(pendingURL) == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mail-pending.error.json").path
        ))

        let overflow = ["account": DesktopMailEventPoller.PendingAdmissions(
            cursor: "100",
            eventIDs: (0...DesktopMailEventPoller.maximumPendingEventIDs).map(String.init)
        )]
        #expect(!DesktopMailEventPoller.savePendingChecked(overflow, to: pendingURL))
    }

    @Test("repeated page tokens and corrupt cursor files fail closed")
    func repeatedPagesAndCorruptCursorsFailClosed() throws {
        var pages = DesktopWorkflowEventPolling.CursorAdmissionState(
            cursor: "100", maximumPages: 2, maximumEnrichments: 40
        )
        let firstPageAccepted = pages.acceptPage(latestCursor: "101", nextPageToken: "page-1")
        #expect(firstPageAccepted)
        let repeatedPageAccepted = pages.acceptPage(latestCursor: "102", nextPageToken: "page-1")
        #expect(!repeatedPageAccepted)
        #expect(pages.committedCursor == nil)

        let root = try TestTemporaryDirectory.make(prefix: "kaname-corrupt-cursor")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail-cursors.json")
        try Data("not-json".utf8).write(to: url)
        #expect(DesktopWorkflowEventPolling.loadCursorsStrict(url) == nil)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mail-cursors.error.json").path
        ))
    }
}
