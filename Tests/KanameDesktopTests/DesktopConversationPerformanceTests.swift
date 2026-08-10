import Dispatch
import Testing
@testable import KanameDesktop

struct DesktopConversationPerformanceTests {
    @Test
    func cursorCompactsContiguousOrdinalsAndRetainsGapsExactly() {
        let index = DesktopConversationEventCursorIndex(persistedEvents: [
            identity(run: "run-1", ordinal: 3),
            identity(run: "run-1", ordinal: 1),
            identity(run: "run-1", ordinal: 2),
            DesktopConversationEventIdentity(id: "legacy-event", runID: "legacy-run", ordinal: 0),
        ])

        #expect(index.runCount == 1)
        #expect(index.sparseOrdinalCount == 0)
        #expect(index.fallbackIDCount == 1)
        #expect(index.contains(identity(run: "run-1", ordinal: 1)))
        #expect(index.contains(identity(run: "run-1", ordinal: 3)))
        #expect(!index.contains(identity(run: "run-1", ordinal: 4)))
        #expect(index.contains(.init(id: "legacy-event", runID: "legacy-run", ordinal: 0)))
        #expect(!index.contains(.init(id: "other-legacy-event", runID: "legacy-run", ordinal: 0)))
    }

    @Test
    func unseenBatchIsBoundedOrderedAndDoesNotAdvanceBeforePersistence() {
        var index = DesktopConversationEventCursorIndex(persistedEvents: [
            identity(run: "run-1", ordinal: 1),
            identity(run: "run-1", ordinal: 3),
        ])
        let events = [
            identity(run: "run-1", ordinal: 1),
            identity(run: "run-1", ordinal: 2),
            identity(run: "run-1", ordinal: 3),
            identity(run: "run-1", ordinal: 4),
            identity(run: "run-1", ordinal: 5),
        ]

        let first = index.unseenBatch(from: events, maximumCount: 2, identity: { $0 })
        #expect(first.map(\.ordinal) == [2, 4])
        #expect(!index.contains(identity(run: "run-1", ordinal: 2)))

        index.markPersisted(first[0])
        let afterFirstDurableSave = index.unseenBatch(from: events, maximumCount: 3, identity: { $0 })
        #expect(afterFirstDurableSave.map(\.ordinal) == [4, 5])
        index.markPersisted(first[1])
        index.markPersisted(identity(run: "run-1", ordinal: 5))
        #expect(index.sparseOrdinalCount == 0)
        #expect(index.contains(identity(run: "run-1", ordinal: 5)))
    }

    @Test
    func rebuildingAfterRestartPreservesDeduplicationAcrossAnOrdinalGap() {
        let durable = [
            identity(run: "run-1", ordinal: 1),
            identity(run: "run-1", ordinal: 3),
        ]
        var live = DesktopConversationEventCursorIndex(persistedEvents: durable)
        let recovered = live.unseenBatch(
            from: [
                identity(run: "run-1", ordinal: 2),
                identity(run: "run-1", ordinal: 3),
                identity(run: "run-1", ordinal: 4),
            ],
            maximumCount: 64,
            identity: { $0 }
        )
        #expect(recovered.map(\.ordinal) == [2, 4])
        recovered.forEach { live.markPersisted($0) }

        let restarted = DesktopConversationEventCursorIndex(persistedEvents: durable + recovered)
        #expect((1...4).allSatisfy { restarted.contains(identity(run: "run-1", ordinal: $0)) })
        #expect(restarted.sparseOrdinalCount == 0)
    }

    @Test
    func pollingPolicyUsesBoundedBatchesAndAdaptiveIntervals() {
        let policy = DesktopConversationPollingPolicy()

        #expect(policy.maximumEventsPerCycle == 64)
        #expect(policy.intervalNanoseconds(hasCandidateThreads: true) == 100_000_000)
        #expect(policy.intervalNanoseconds(hasCandidateThreads: false) == 250_000_000)
        #expect(policy.orphanedRunCheckCount == 10)
    }

    @Test
    func performanceStoreRetainsAStableBoundedP95Window() {
        var store = DesktopConversationPerformanceStore(maximumSamplesPerMetric: 3)
        for duration in [1, 2, 3, 4] {
            store.record(.init(metric: .pollingCycle, durationNanoseconds: UInt64(duration), itemCount: 1))
        }
        store.record(.init(metric: .historyIndex, durationNanoseconds: 20, itemCount: 50_000))

        #expect(store.retainedSamples(for: .pollingCycle).map(\.durationNanoseconds) == [2, 3, 4])
        #expect(store.p95Nanoseconds(for: .pollingCycle) == 4)
        #expect(store.p95Nanoseconds(for: .historyIndex) == 20)
        #expect(store.p95Nanoseconds(for: .eventBatchSelection) == nil)
    }

    @Test
    func largeHistoryIndexP95StaysWithinTheRetainedBudget() {
        let history = (0..<DesktopConversationPerformanceBudget.largeHistoryItemCount).map { offset in
            identity(run: "run-\(offset / 100)", ordinal: (offset % 100) + 1)
        }
        let result = measuredP95(iterations: 7) {
            let index = DesktopConversationEventCursorIndex(persistedEvents: history)
            #expect(index.runCount == 500)
            #expect(index.sparseOrdinalCount == 0)
        }

        #expect(result <= DesktopConversationPerformanceBudget.historyIndexP95Nanoseconds)
    }

    @Test
    func streamingBurstSelectionP95StaysWithinTheRetainedBudget() {
        let incoming = (1...DesktopConversationPerformanceBudget.streamingBurstItemCount).map {
            identity(run: "stream-run", ordinal: $0)
        }
        let index = DesktopConversationEventCursorIndex(persistedEvents: [DesktopConversationEventIdentity]())
        let result = measuredP95(iterations: 15) {
            let batch = index.unseenBatch(from: incoming, maximumCount: 64, identity: { $0 })
            #expect(batch.count == 64)
        }

        #expect(result <= DesktopConversationPerformanceBudget.eventBatchSelectionP95Nanoseconds)
    }

    private func identity(run: String, ordinal: Int) -> DesktopConversationEventIdentity {
        DesktopConversationEventIdentity(id: "\(run)-service-\(ordinal)", runID: run, ordinal: ordinal)
    }

    private func measuredP95(iterations: Int, operation: () -> Void) -> UInt64 {
        var durations: [UInt64] = []
        for _ in 0..<iterations {
            let started = DispatchTime.now().uptimeNanoseconds
            operation()
            let ended = DispatchTime.now().uptimeNanoseconds
            durations.append(ended >= started ? ended - started : 0)
        }
        let sorted = durations.sorted()
        let rank = max(1, Int(ceil(0.95 * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}
