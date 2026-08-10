import Foundation

public struct DesktopProviderEventBatchItem: Equatable, Sendable {
    public let event: DesktopProviderEventRecord
    public let assistantDelta: String?

    public init(event: DesktopProviderEventRecord, assistantDelta: String? = nil) {
        self.event = event
        self.assistantDelta = assistantDelta
    }
}

public struct DesktopProviderEventBatchResult: Equatable, Sendable {
    public let acceptedEventIDs: [String]
    public let duplicateEventIDs: [String]

    public init(acceptedEventIDs: [String], duplicateEventIDs: [String]) {
        self.acceptedEventIDs = acceptedEventIDs
        self.duplicateEventIDs = duplicateEventIDs
    }
}

public struct DesktopConversationEventIdentity: Equatable, Sendable {
    public let id: String
    public let runID: String
    public let ordinal: Int

    public init(id: String, runID: String, ordinal: Int) {
        self.id = id
        self.runID = runID
        self.ordinal = ordinal
    }
}

public struct DesktopConversationEventCursorIndex: Equatable, Sendable {
    private struct RunCursor: Equatable, Sendable {
        var contiguousThrough = 0
        var sparseOrdinals: Set<Int> = []

        func contains(_ ordinal: Int) -> Bool {
            ordinal <= contiguousThrough || sparseOrdinals.contains(ordinal)
        }

        mutating func insert(_ ordinal: Int) {
            guard ordinal > contiguousThrough else { return }
            sparseOrdinals.insert(ordinal)
            while sparseOrdinals.remove(contiguousThrough + 1) != nil {
                contiguousThrough += 1
            }
        }
    }

    private var runCursors: [String: RunCursor] = [:]
    private var exactFallbackIDs: Set<String> = []

    public init<S: Sequence>(persistedEvents: S) where S.Element == DesktopConversationEventIdentity {
        for event in persistedEvents {
            markPersisted(event)
        }
    }

    public var runCount: Int { runCursors.count }
    public var sparseOrdinalCount: Int { runCursors.values.reduce(0) { $0 + $1.sparseOrdinals.count } }
    public var fallbackIDCount: Int { exactFallbackIDs.count }

    public func contains(_ event: DesktopConversationEventIdentity) -> Bool {
        guard event.ordinal > 0 else { return exactFallbackIDs.contains(event.id) }
        return runCursors[event.runID]?.contains(event.ordinal) == true
    }

    public mutating func markPersisted(_ event: DesktopConversationEventIdentity) {
        guard event.ordinal > 0 else {
            exactFallbackIDs.insert(event.id)
            return
        }
        var cursor = runCursors[event.runID] ?? RunCursor()
        cursor.insert(event.ordinal)
        runCursors[event.runID] = cursor
    }

    public func unseenBatch<Event>(
        from events: [Event],
        maximumCount: Int,
        identity: (Event) -> DesktopConversationEventIdentity
    ) -> [Event] {
        guard maximumCount > 0 else { return [] }
        var working = self
        var batch: [Event] = []
        batch.reserveCapacity(min(events.count, maximumCount))
        for event in events {
            let eventIdentity = identity(event)
            guard !working.contains(eventIdentity) else { continue }
            batch.append(event)
            working.markPersisted(eventIdentity)
            if batch.count == maximumCount { break }
        }
        return batch
    }
}

public struct DesktopConversationPollingPolicy: Equatable, Sendable {
    public let maximumEventsPerCycle: Int
    public let activeIntervalNanoseconds: UInt64
    public let idleIntervalNanoseconds: UInt64
    public let orphanedRunCheckCount: Int

    public init(
        maximumEventsPerCycle: Int = 64,
        activeIntervalNanoseconds: UInt64 = 100_000_000,
        idleIntervalNanoseconds: UInt64 = 250_000_000,
        orphanedRunCheckCount: Int = 10
    ) {
        self.maximumEventsPerCycle = max(1, maximumEventsPerCycle)
        self.activeIntervalNanoseconds = max(10_000_000, activeIntervalNanoseconds)
        self.idleIntervalNanoseconds = max(self.activeIntervalNanoseconds, idleIntervalNanoseconds)
        self.orphanedRunCheckCount = max(1, orphanedRunCheckCount)
    }

    public func intervalNanoseconds(hasCandidateThreads: Bool) -> UInt64 {
        hasCandidateThreads ? activeIntervalNanoseconds : idleIntervalNanoseconds
    }
}

public enum DesktopConversationPerformanceMetric: String, Codable, CaseIterable, Sendable {
    case historyIndex
    case eventBatchSelection
    case providerEventBatchPersistence
    case pollingCycle
}

public struct DesktopConversationPerformanceSample: Codable, Equatable, Sendable {
    public let metric: DesktopConversationPerformanceMetric
    public let durationNanoseconds: UInt64
    public let itemCount: Int

    public init(metric: DesktopConversationPerformanceMetric, durationNanoseconds: UInt64, itemCount: Int) {
        self.metric = metric
        self.durationNanoseconds = durationNanoseconds
        self.itemCount = itemCount
    }
}

public struct DesktopConversationPerformanceBudget: Equatable, Sendable {
    public static let largeHistoryItemCount = 50_000
    public static let streamingBurstItemCount = 5_000
    public static let historyIndexP95Nanoseconds: UInt64 = 250_000_000
    public static let eventBatchSelectionP95Nanoseconds: UInt64 = 20_000_000
    public static let providerEventBatchP95Nanoseconds: UInt64 = 250_000_000
    public static let pollingCycleP95Nanoseconds: UInt64 = 100_000_000

    public init() {}
}

public struct DesktopConversationPerformanceStore: Sendable {
    private let maximumSamplesPerMetric: Int
    private var samplesByMetric: [DesktopConversationPerformanceMetric: [DesktopConversationPerformanceSample]] = [:]

    public init(maximumSamplesPerMetric: Int = 100) {
        self.maximumSamplesPerMetric = max(1, maximumSamplesPerMetric)
    }

    public mutating func record(_ sample: DesktopConversationPerformanceSample) {
        var retained = samplesByMetric[sample.metric, default: []]
        retained.append(sample)
        if retained.count > maximumSamplesPerMetric {
            retained.removeFirst(retained.count - maximumSamplesPerMetric)
        }
        samplesByMetric[sample.metric] = retained
    }

    public func retainedSamples(for metric: DesktopConversationPerformanceMetric) -> [DesktopConversationPerformanceSample] {
        samplesByMetric[metric, default: []]
    }

    public func p95Nanoseconds(for metric: DesktopConversationPerformanceMetric) -> UInt64? {
        let durations = retainedSamples(for: metric).map(\.durationNanoseconds).sorted()
        guard !durations.isEmpty else { return nil }
        let rank = max(1, Int(ceil(0.95 * Double(durations.count))))
        return durations[min(rank - 1, durations.count - 1)]
    }
}
