import Dispatch
import Foundation

public enum DesktopPerformanceMetric: String, Codable, CaseIterable, Sendable {
    case coldLaunch
    case warmResume
    case projectionLatency
    case frameDuration
}

public enum DesktopPerformanceMeasurementDefinition {
    public static let maximumRepetitions = 100
    public static let coldLaunch = "Fresh packaged process launch from spawn until that exact PID publishes its ready receipt; the application-support root is fresh, but operating-system and filesystem caches are not purged."
    public static let warmForegroundResume = "Same already-ready process PID from the foreground activation request until macOS reports that exact PID frontmost, after the harness has confirmed it is backgrounded; process launch is excluded."
}

fileprivate protocol DesktopPerformanceFlatPayloadRecord: Codable {
    associatedtype Payload: Codable & Equatable & Sendable

    var payload: Payload { get }

    init(payload: Payload)
}

extension DesktopPerformanceFlatPayloadRecord {
    public init(from decoder: any Decoder) throws {
        self.init(payload: try Payload(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
    }
}

public struct DesktopPerformanceBudget: Codable, Equatable, Sendable {
    public let metric: DesktopPerformanceMetric
    public let maximumDurationNanoseconds: UInt64

    public init(metric: DesktopPerformanceMetric, maximumDurationNanoseconds: UInt64) {
        self.metric = metric
        self.maximumDurationNanoseconds = maximumDurationNanoseconds
    }

    public static let desktopDefaults: [DesktopPerformanceBudget] = [
        DesktopPerformanceBudget(metric: .coldLaunch, maximumDurationNanoseconds: 2_000_000_000),
        DesktopPerformanceBudget(metric: .warmResume, maximumDurationNanoseconds: 1_500_000_000),
        DesktopPerformanceBudget(metric: .projectionLatency, maximumDurationNanoseconds: 150_000_000),
        DesktopPerformanceBudget(metric: .frameDuration, maximumDurationNanoseconds: 100_000_000),
    ]
}

public struct DesktopPerformanceSample: Codable, Equatable, Sendable, DesktopPerformanceFlatPayloadRecord {
    fileprivate struct Payload: Codable, Equatable, Sendable {
        let metric: DesktopPerformanceMetric
        let repetition: Int
        let durationNanoseconds: UInt64
        let residentKilobytes: UInt64?
        let recordedAtUnixMillis: Int64
    }

    fileprivate let payload: Payload

    public var metric: DesktopPerformanceMetric { payload.metric }
    public var repetition: Int { payload.repetition }
    public var durationNanoseconds: UInt64 { payload.durationNanoseconds }
    public var residentKilobytes: UInt64? { payload.residentKilobytes }
    public var recordedAtUnixMillis: Int64 { payload.recordedAtUnixMillis }
}

extension DesktopPerformanceSample {
    public init(
        metric: DesktopPerformanceMetric,
        repetition: Int = 1,
        durationNanoseconds: UInt64,
        residentKilobytes: UInt64? = nil,
        recordedAtUnixMillis: Int64
    ) {
        payload = Payload(
            metric: metric,
            repetition: repetition,
            durationNanoseconds: durationNanoseconds,
            residentKilobytes: residentKilobytes,
            recordedAtUnixMillis: recordedAtUnixMillis
        )
    }
}

public struct DesktopPerformanceFailure: Codable, Equatable, Sendable, DesktopPerformanceFlatPayloadRecord {
    fileprivate struct Payload: Codable, Equatable, Sendable {
        let metric: DesktopPerformanceMetric
        let repetition: Int
        let stage: String
        let code: String
        let message: String
        let recordedAtUnixMillis: Int64
    }

    fileprivate let payload: Payload

    public var metric: DesktopPerformanceMetric { payload.metric }
    public var repetition: Int { payload.repetition }
    public var stage: String { payload.stage }
    public var code: String { payload.code }
    public var message: String { payload.message }
    public var recordedAtUnixMillis: Int64 { payload.recordedAtUnixMillis }
}

extension DesktopPerformanceFailure {
    public init(
        metric: DesktopPerformanceMetric,
        repetition: Int,
        stage: String,
        code: String,
        message: String,
        recordedAtUnixMillis: Int64
    ) {
        self.init(payload: Payload(
            metric: metric,
            repetition: repetition,
            stage: stage,
            code: code,
            message: message,
            recordedAtUnixMillis: recordedAtUnixMillis
        ))
    }
}

public struct DesktopPerformanceSummary: Codable, Equatable, Sendable {
    public let metric: DesktopPerformanceMetric
    public let requestedRepetitions: Int?
    public let repetitionSetComplete: Bool
    public let attemptCount: Int
    public let sampleCount: Int
    public let failureCount: Int
    public let p50Nanoseconds: UInt64?
    public let p95Nanoseconds: UInt64?
    public let p99Nanoseconds: UInt64?
    public let maximumNanoseconds: UInt64?
    public let maximumResidentKilobytes: UInt64?
    public let budgetNanoseconds: UInt64?
    public let meetsBudget: Bool?

    public var medianNanoseconds: UInt64? { p50Nanoseconds }
}

public struct DesktopPerformanceReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAtUnixMillis: Int64
    public let samples: [DesktopPerformanceSample]
    public let failures: [DesktopPerformanceFailure]
    public let summaries: [DesktopPerformanceSummary]
    public let allAttemptsSucceeded: Bool

    public init(
        samples: [DesktopPerformanceSample],
        failures: [DesktopPerformanceFailure] = [],
        requestedRepetitions: [DesktopPerformanceMetric: Int] = [:],
        budgets: [DesktopPerformanceBudget] = DesktopPerformanceBudget.desktopDefaults,
        generatedAtUnixMillis: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAtUnixMillis = generatedAtUnixMillis
        self.samples = samples
        self.failures = failures
        let budgetsByMetric = budgets.reduce(into: [DesktopPerformanceMetric: UInt64]()) {
            $0[$1.metric] = $1.maximumDurationNanoseconds
        }
        summaries = DesktopPerformanceMetric.allCases.compactMap { metric in
            let metricSamples = samples.filter { $0.metric == metric }
            let metricFailures = failures.filter { $0.metric == metric }
            guard !metricSamples.isEmpty || !metricFailures.isEmpty || requestedRepetitions[metric] != nil else {
                return nil
            }
            let durations = metricSamples.map(\.durationNanoseconds).sorted()
            let budget = budgetsByMetric[metric]
            let p95 = Self.percentile(0.95, in: durations)
            let expected = requestedRepetitions[metric]
            let attemptCount = metricSamples.count + metricFailures.count
            let observedRepetitions = (metricSamples.map(\.repetition) + metricFailures.map(\.repetition)).sorted()
            let repetitionSetComplete: Bool
            if let expected,
               (1...DesktopPerformanceMeasurementDefinition.maximumRepetitions).contains(expected),
               observedRepetitions.count == expected {
                repetitionSetComplete = observedRepetitions.enumerated().allSatisfy { offset, repetition in
                    repetition == offset + 1
                }
            } else {
                repetitionSetComplete = false
            }
            return DesktopPerformanceSummary(
                metric: metric,
                requestedRepetitions: expected,
                repetitionSetComplete: repetitionSetComplete,
                attemptCount: attemptCount,
                sampleCount: durations.count,
                failureCount: metricFailures.count,
                p50Nanoseconds: Self.percentile(0.5, in: durations),
                p95Nanoseconds: p95,
                p99Nanoseconds: Self.percentile(0.99, in: durations),
                maximumNanoseconds: durations.last,
                maximumResidentKilobytes: metricSamples.compactMap(\.residentKilobytes).max(),
                budgetNanoseconds: budget,
                meetsBudget: budget.map {
                    guard let p95 else { return false }
                    return metricFailures.isEmpty && repetitionSetComplete && p95 <= $0
                }
            )
        }
        allAttemptsSucceeded = !summaries.isEmpty && summaries.allSatisfy {
            $0.failureCount == 0
                && $0.repetitionSetComplete
        }
    }

    private static func percentile(_ percentile: Double, in sorted: [UInt64]) -> UInt64? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

public enum DesktopPerformanceProbe {
    public static func measure<Value>(
        metric: DesktopPerformanceMetric,
        recordedAtUnixMillis: Int64,
        operation: () throws -> Value
    ) rethrows -> (value: Value, sample: DesktopPerformanceSample) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        let ended = DispatchTime.now().uptimeNanoseconds
        return (value, DesktopPerformanceSample(
            metric: metric,
            durationNanoseconds: ended >= started ? ended - started : 0,
            recordedAtUnixMillis: recordedAtUnixMillis
        ))
    }

    public static func measure<Value>(
        metric: DesktopPerformanceMetric,
        recordedAtUnixMillis: Int64,
        operation: () async throws -> Value
    ) async rethrows -> (value: Value, sample: DesktopPerformanceSample) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let ended = DispatchTime.now().uptimeNanoseconds
        return (value, DesktopPerformanceSample(
            metric: metric,
            durationNanoseconds: ended >= started ? ended - started : 0,
            recordedAtUnixMillis: recordedAtUnixMillis
        ))
    }
}

public actor DesktopPerformanceCollector {
    private let maximumSamplesPerMetric: Int
    private var samples: [DesktopPerformanceSample] = []

    public init(maximumSamplesPerMetric: Int = 200) {
        self.maximumSamplesPerMetric = max(1, maximumSamplesPerMetric)
    }

    public func record(_ sample: DesktopPerformanceSample) {
        samples.append(sample)
        let metricSamples = samples.indices.filter { samples[$0].metric == sample.metric }
        let overflow = metricSamples.count - maximumSamplesPerMetric
        if overflow > 0 {
            for index in metricSamples.prefix(overflow).reversed() {
                samples.remove(at: index)
            }
        }
    }

    public func report(
        requestedRepetitions: [DesktopPerformanceMetric: Int] = [:],
        budgets: [DesktopPerformanceBudget] = DesktopPerformanceBudget.desktopDefaults,
        generatedAtUnixMillis: Int64
    ) -> DesktopPerformanceReport {
        DesktopPerformanceReport(
            samples: samples,
            requestedRepetitions: requestedRepetitions,
            budgets: budgets,
            generatedAtUnixMillis: generatedAtUnixMillis
        )
    }
}
