import Dispatch
import Foundation

public enum DesktopPerformanceMetric: String, Codable, CaseIterable, Sendable {
    case coldLaunch
    case warmResume
    case projectionLatency
    case frameDuration
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

public struct DesktopPerformanceSample: Codable, Equatable, Sendable {
    public let metric: DesktopPerformanceMetric
    public let durationNanoseconds: UInt64
    public let recordedAtUnixMillis: Int64

    public init(metric: DesktopPerformanceMetric, durationNanoseconds: UInt64, recordedAtUnixMillis: Int64) {
        self.metric = metric
        self.durationNanoseconds = durationNanoseconds
        self.recordedAtUnixMillis = recordedAtUnixMillis
    }
}

public struct DesktopPerformanceSummary: Codable, Equatable, Sendable {
    public let metric: DesktopPerformanceMetric
    public let sampleCount: Int
    public let medianNanoseconds: UInt64
    public let p95Nanoseconds: UInt64
    public let p99Nanoseconds: UInt64
    public let maximumNanoseconds: UInt64
    public let budgetNanoseconds: UInt64?
    public let meetsBudget: Bool?
}

public struct DesktopPerformanceReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAtUnixMillis: Int64
    public let summaries: [DesktopPerformanceSummary]

    public init(
        samples: [DesktopPerformanceSample],
        budgets: [DesktopPerformanceBudget] = DesktopPerformanceBudget.desktopDefaults,
        generatedAtUnixMillis: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAtUnixMillis = generatedAtUnixMillis
        let budgetsByMetric = budgets.reduce(into: [DesktopPerformanceMetric: UInt64]()) {
            $0[$1.metric] = $1.maximumDurationNanoseconds
        }
        summaries = DesktopPerformanceMetric.allCases.compactMap { metric in
            let durations = samples.filter { $0.metric == metric }.map(\.durationNanoseconds).sorted()
            guard let maximum = durations.last else { return nil }
            let budget = budgetsByMetric[metric]
            let p95 = Self.percentile(0.95, in: durations)
            return DesktopPerformanceSummary(
                metric: metric,
                sampleCount: durations.count,
                medianNanoseconds: Self.percentile(0.5, in: durations),
                p95Nanoseconds: p95,
                p99Nanoseconds: Self.percentile(0.99, in: durations),
                maximumNanoseconds: maximum,
                budgetNanoseconds: budget,
                meetsBudget: budget.map { p95 <= $0 }
            )
        }
    }

    private static func percentile(_ percentile: Double, in sorted: [UInt64]) -> UInt64 {
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
        budgets: [DesktopPerformanceBudget] = DesktopPerformanceBudget.desktopDefaults,
        generatedAtUnixMillis: Int64
    ) -> DesktopPerformanceReport {
        DesktopPerformanceReport(samples: samples, budgets: budgets, generatedAtUnixMillis: generatedAtUnixMillis)
    }
}
