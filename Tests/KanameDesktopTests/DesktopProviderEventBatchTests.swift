import Foundation
import Dispatch
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopProviderEventBatchTests {
    @Test
    func batchPersistsOnceAndPreservesAcceptedOrderAssistantDeltasAndTitles() throws {
        let fixture = makeFixture()
        fixture.store.resetSaveCount()
        let first = event(fixture, ordinal: 1, title: "First title", detail: "First detail")
        let third = event(fixture, ordinal: 3, title: "Third title", detail: "Third detail")
        let duplicateFirst = event(fixture, ordinal: 1, title: "Ignored duplicate", detail: "Ignored")
        let second = event(fixture, ordinal: 2, title: "Second title", detail: "Second detail")

        let result = try #require(fixture.model.recordProviderEvents([
            .init(event: first, assistantDelta: "A"),
            .init(event: third, assistantDelta: "C"),
            .init(event: duplicateFirst, assistantDelta: "X"),
            .init(event: second, assistantDelta: "B"),
        ]))

        #expect(result.acceptedEventIDs == [first.id, third.id, second.id])
        #expect(result.duplicateEventIDs == [first.id])
        #expect(fixture.store.saveCount == 1)
        #expect(fixture.model.snapshot.operations.providerEvents.map(\.id) == [first.id, third.id, second.id])
        #expect(fixture.model.snapshot.operations.providerEvents.map(\.title) == ["First title", "Third title", "Second title"])
        #expect(fixture.model.thread(id: fixture.threadID)?.messages.last?.body == "ACB")

        let restarted = DesktopAppModel(store: fixture.store, now: { 9_000 })
        #expect(restarted.snapshot.operations.providerEvents.map(\.id) == [first.id, third.id, second.id])
        #expect(restarted.thread(id: fixture.threadID)?.messages.last?.body == "ACB")
    }

    @Test
    func failedBatchSaveDoesNotAdvanceSnapshotAndRetriesExactlyAfterRestart() throws {
        let fixture = makeFixture()
        let durableBeforeBatch = fixture.store.data
        let first = event(fixture, ordinal: 1, title: "One", detail: "First")
        let second = event(fixture, ordinal: 2, title: "Two", detail: "Second")
        fixture.store.resetSaveCount()
        fixture.store.failsSave = true

        #expect(fixture.model.recordProviderEvents([
            .init(event: first, assistantDelta: "first"),
            .init(event: second, assistantDelta: "second"),
        ]) == nil)
        #expect(fixture.store.saveCount == 1)
        #expect(fixture.store.data == durableBeforeBatch)
        #expect(fixture.model.snapshot.operations.providerEvents.isEmpty)
        #expect(fixture.model.thread(id: fixture.threadID)?.messages.last?.role == .user)
        #expect(fixture.model.persistenceError != nil)

        fixture.store.failsSave = false
        let retried = try #require(fixture.model.recordProviderEvents([
            .init(event: first, assistantDelta: "first"),
            .init(event: second, assistantDelta: "second"),
        ]))
        #expect(retried.acceptedEventIDs == [first.id, second.id])
        #expect(fixture.model.persistenceError == nil)

        let restarted = DesktopAppModel(store: fixture.store, now: { 9_000 })
        #expect(restarted.snapshot.operations.providerEvents.map(\.id) == [first.id, second.id])
        #expect(restarted.thread(id: fixture.threadID)?.messages.last?.body == "firstsecond")
    }

    @Test
    func restartRetainsOrdinalGapsAndDeduplicatesBeforeFillingThem() throws {
        let fixture = makeFixture()
        let first = event(fixture, ordinal: 1, title: "One", detail: "First")
        let third = event(fixture, ordinal: 3, title: "Three", detail: "Third")
        _ = try #require(fixture.model.recordProviderEvents([.init(event: first), .init(event: third)]))
        let restarted = DesktopAppModel(store: fixture.store, now: { 9_000 })
        fixture.store.resetSaveCount()
        let second = event(fixture, ordinal: 2, title: "Two", detail: "Second")

        let result = try #require(restarted.recordProviderEvents([.init(event: third), .init(event: second)]))

        #expect(result.acceptedEventIDs == [second.id])
        #expect(result.duplicateEventIDs == [third.id])
        #expect(fixture.store.saveCount == 1)
        #expect(restarted.snapshot.operations.providerEvents.map(\.id) == [first.id, third.id, second.id])
    }

    @Test
    func oversizedBatchIsRejectedWithoutAStoreWriteOrPartialAcceptance() {
        let fixture = makeFixture()
        fixture.store.resetSaveCount()
        let items = (1...65).map {
            DesktopProviderEventBatchItem(event: event(fixture, ordinal: $0, title: "Event \($0)", detail: "Detail"))
        }

        #expect(fixture.model.recordProviderEvents(items) == nil)
        #expect(fixture.store.saveCount == 0)
        #expect(fixture.model.snapshot.operations.providerEvents.isEmpty)
    }

    @Test
    func maximumBatchPersistsSixtyFourEventsInOneSnapshotWrite() throws {
        let fixture = makeFixture()
        fixture.store.resetSaveCount()
        let items = (1...64).map {
            DesktopProviderEventBatchItem(
                event: event(fixture, ordinal: $0, title: "Event \($0)", detail: "Detail"),
                assistantDelta: "\($0),"
            )
        }

        let result = try #require(fixture.model.recordProviderEvents(items))

        #expect(result.acceptedEventIDs.count == 64)
        #expect(result.duplicateEventIDs.isEmpty)
        #expect(fixture.store.saveCount == 1)
        #expect(fixture.model.snapshot.operations.providerEvents.count == 64)
        #expect(fixture.model.thread(id: fixture.threadID)?.messages.last?.body.hasPrefix("1,2,3,") == true)
    }

    @Test
    func largePersistedHistoryBatchP95StaysWithinBudget() throws {
        var snapshot = DesktopAppSnapshot.starter(now: 1)
        snapshot.operations.providerEvents = (1...5_000).map {
            standaloneEvent(id: "history-\($0)", ordinal: $0)
        }
        let durableHistory = try JSONEncoder().encode(snapshot)
        var performance = DesktopConversationPerformanceStore(maximumSamplesPerMetric: 5)

        for iteration in 0..<5 {
            let store = CountingBatchDesktopStateStore(data: durableHistory)
            let model = DesktopAppModel(store: store, now: { 2_000 })
            let batch = (1...64).map {
                DesktopProviderEventBatchItem(event: standaloneEvent(id: "new-\(iteration)-\($0)", ordinal: $0))
            }
            store.resetSaveCount()
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try #require(model.recordProviderEvents(batch))
            let ended = DispatchTime.now().uptimeNanoseconds
            #expect(result.acceptedEventIDs.count == 64)
            #expect(store.saveCount == 1)
            performance.record(.init(
                metric: .providerEventBatchPersistence,
                durationNanoseconds: ended >= started ? ended - started : 0,
                itemCount: batch.count
            ))
        }

        #expect(
            try #require(performance.p95Nanoseconds(for: .providerEventBatchPersistence))
                <= DesktopConversationPerformanceBudget.providerEventBatchP95Nanoseconds
        )
    }

    private func makeFixture() -> BatchFixture {
        let store = CountingBatchDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        let messageID = model.appendUserMessage(threadID: threadID, body: "Start a batch")!
        let runID = model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID)!
        return BatchFixture(store: store, model: model, threadID: threadID, runID: runID)
    }

    private func event(
        _ fixture: BatchFixture,
        ordinal: Int,
        title: String,
        detail: String
    ) -> DesktopProviderEventRecord {
        DesktopProviderEventRecord(
            id: "\(fixture.runID)-service-\(ordinal)",
            threadID: fixture.threadID,
            runID: fixture.runID,
            kind: .assistantText,
            title: title,
            detail: detail,
            nativeType: "item/agentMessage/delta",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn",
            approvalID: nil,
            rawPayloadBase64: nil,
            payloadWasTruncated: false,
            createdAtUnixMillis: Int64(ordinal)
        )
    }

    private func standaloneEvent(id: String, ordinal: Int) -> DesktopProviderEventRecord {
        DesktopProviderEventRecord(
            id: id,
            threadID: "thread-performance",
            runID: "run-performance",
            kind: .native,
            title: "Performance event",
            detail: "Bounded event",
            nativeType: "performance",
            nativeThreadID: nil,
            nativeTurnID: nil,
            approvalID: nil,
            rawPayloadBase64: nil,
            payloadWasTruncated: false,
            createdAtUnixMillis: Int64(ordinal)
        )
    }

}

private struct BatchFixture {
    let store: CountingBatchDesktopStateStore
    let model: DesktopAppModel
    let threadID: String
    let runID: String
}

private final class CountingBatchDesktopStateStore: DesktopStateStoring {
    var data: Data?
    var saveCount = 0
    var failsSave = false

    init(data: Data? = nil) {
        self.data = data
    }

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
        saveCount += 1
        if failsSave { throw BatchStoreError.saveFailed }
        self.data = data
    }

    func resetSaveCount() {
        saveCount = 0
    }
}

private enum BatchStoreError: Error {
    case saveFailed
}
