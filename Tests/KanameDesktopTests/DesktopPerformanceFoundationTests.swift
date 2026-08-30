import Foundation
import Testing
@testable import KanameDesktop

struct DesktopPerformanceFoundationTests {
    private enum InvalidRepetitionPlanScenario: String, CaseIterable, Sendable {
        case missingPlan
        case missingRepetition
        case duplicateRepetition
        case outOfRangeRepetition
        case zeroRequested
        case negativeRequested
        case aboveMaximumRequested
        case maximumIntegerRequested
    }

    private struct InvalidRepetitionPlanFixture: Sendable {
        let metric: DesktopPerformanceMetric
        let report: DesktopPerformanceReport
        let expectedRequestedRepetitions: Int?
        let expectedAttemptCount: Int
        let expectedFailureCount: Int
    }

    @Test
    func defaultBudgetsMatchTheDesktopAcceptanceContract() {
        let budgets = Dictionary(uniqueKeysWithValues: DesktopPerformanceBudget.desktopDefaults.map {
            ($0.metric, $0.maximumDurationNanoseconds)
        })

        #expect(budgets[.coldLaunch] == 2_000_000_000)
        #expect(budgets[.warmResume] == 1_500_000_000)
        #expect(budgets[.projectionLatency] == 150_000_000)
        #expect(budgets[.frameDuration] == 100_000_000)
    }

    @Test
    func reportUsesDeterministicNearestRankPercentilesAndP95BudgetStatus() throws {
        let samples = (1...100).map {
            DesktopPerformanceSample(
                metric: .projectionLatency,
                repetition: $0,
                durationNanoseconds: UInt64($0) * 1_000_000,
                recordedAtUnixMillis: Int64($0)
            )
        }
        let report = DesktopPerformanceReport(
            samples: samples,
            requestedRepetitions: [.projectionLatency: 100],
            generatedAtUnixMillis: 1_000
        )
        let summary = try #require(report.summaries.first)

        #expect(report.schemaVersion == 2)
        #expect(report.samples == samples)
        #expect(report.failures.isEmpty)
        #expect(report.allAttemptsSucceeded)
        #expect(summary.attemptCount == 100)
        #expect(summary.sampleCount == 100)
        #expect(summary.failureCount == 0)
        #expect(summary.p50Nanoseconds == 50_000_000)
        #expect(summary.medianNanoseconds == summary.p50Nanoseconds)
        #expect(summary.p95Nanoseconds == 95_000_000)
        #expect(summary.p99Nanoseconds == 99_000_000)
        #expect(summary.maximumNanoseconds == 100_000_000)
        #expect(summary.budgetNanoseconds == 150_000_000)
        #expect(summary.meetsBudget == true)
    }

    @Test
    func reportFailsTheMetricWhenItsP95ExceedsTheBudget() throws {
        let samples = (0..<20).map { index in
            DesktopPerformanceSample(
                metric: .warmResume,
                repetition: index + 1,
                durationNanoseconds: index < 18 ? 400_000_000 : 1_700_000_000,
                recordedAtUnixMillis: Int64(index)
            )
        }
        let report = DesktopPerformanceReport(
            samples: samples,
            requestedRepetitions: [.warmResume: 20],
            generatedAtUnixMillis: 1_000
        )
        let summary = try #require(report.summaries.first)

        #expect(summary.p95Nanoseconds == 1_700_000_000)
        #expect(summary.meetsBudget == false)
    }

    @Test
    func reportRetainsEveryFailureAndFailsClosedWhenSuccessfulSamplesMeetTheBudget() throws {
        let samples = (1...4).map {
            DesktopPerformanceSample(
                metric: .warmResume,
                repetition: $0,
                durationNanoseconds: UInt64($0) * 100_000_000,
                residentKilobytes: UInt64(10_000 + $0),
                recordedAtUnixMillis: Int64($0)
            )
        }
        let failure = DesktopPerformanceFailure(
            metric: .warmResume,
            repetition: 5,
            stage: "foreground-confirmation",
            code: "foreground-timeout",
            message: "The exact process did not become frontmost before the deadline.",
            recordedAtUnixMillis: 5
        )

        let report = DesktopPerformanceReport(
            samples: samples,
            failures: [failure],
            requestedRepetitions: [.warmResume: 5],
            generatedAtUnixMillis: 6
        )
        let summary = try #require(report.summaries.first)

        #expect(report.samples == samples)
        #expect(report.failures == [failure])
        #expect(!report.allAttemptsSucceeded)
        #expect(summary.requestedRepetitions == 5)
        #expect(summary.repetitionSetComplete == true)
        #expect(summary.attemptCount == 5)
        #expect(summary.sampleCount == 4)
        #expect(summary.failureCount == 1)
        #expect(summary.p95Nanoseconds == 400_000_000)
        #expect(summary.maximumResidentKilobytes == 10_004)
        #expect(summary.meetsBudget == false)
    }

    @Test(arguments: InvalidRepetitionPlanScenario.allCases)
    private func reportRejectsInvalidRepetitionPlan(_ scenario: InvalidRepetitionPlanScenario) throws {
        let fixture = invalidRepetitionPlanFixture(for: scenario)
        let summary = try #require(fixture.report.summaries.first { $0.metric == fixture.metric })

        #expect(summary.requestedRepetitions == fixture.expectedRequestedRepetitions)
        #expect(summary.attemptCount == fixture.expectedAttemptCount)
        #expect(summary.failureCount == fixture.expectedFailureCount)
        #expect(summary.repetitionSetComplete == false)
        #expect(summary.meetsBudget == false)
        #expect(!fixture.report.allAttemptsSucceeded)
    }

    @Test
    func failureOnlyMetricStillProducesAnExplicitSummary() throws {
        let report = DesktopPerformanceReport(
            samples: [],
            failures: [
                DesktopPerformanceFailure(
                    metric: .coldLaunch,
                    repetition: 1,
                    stage: "ready-receipt",
                    code: "ready-timeout",
                    message: "The exact process did not publish a ready receipt before the deadline.",
                    recordedAtUnixMillis: 1
                ),
            ],
            requestedRepetitions: [.coldLaunch: 1],
            generatedAtUnixMillis: 2
        )
        let summary = try #require(report.summaries.first)

        #expect(summary.sampleCount == 0)
        #expect(summary.failureCount == 1)
        #expect(summary.p50Nanoseconds == nil)
        #expect(summary.p95Nanoseconds == nil)
        #expect(summary.p99Nanoseconds == nil)
        #expect(summary.maximumNanoseconds == nil)
        #expect(summary.meetsBudget == false)
    }

    @Test
    func measurementDefinitionsSeparateProcessLaunchFromSamePIDForegroundResume() {
        #expect(DesktopPerformanceMeasurementDefinition.maximumRepetitions == 100)
        #expect(DesktopPerformanceMeasurementDefinition.coldLaunch.contains("operating-system and filesystem caches are not purged"))
        #expect(DesktopPerformanceMeasurementDefinition.warmForegroundResume.contains("Same already-ready process PID"))
        #expect(DesktopPerformanceMeasurementDefinition.warmForegroundResume.contains("process launch is excluded"))
    }

    @Test
    func attemptRecordsRoundTripWithExactFlatCodableKeys() throws {
        let sample = DesktopPerformanceSample(
            metric: .warmResume,
            repetition: 2,
            durationNanoseconds: 42,
            residentKilobytes: 84,
            recordedAtUnixMillis: 126
        )
        let failure = DesktopPerformanceFailure(
            metric: .coldLaunch,
            repetition: 3,
            stage: "ready-receipt",
            code: "ready-timeout",
            message: "The exact process did not publish its ready receipt.",
            recordedAtUnixMillis: 168
        )
        let encoder = JSONEncoder()
        let sampleData = try encoder.encode(sample)
        let failureData = try encoder.encode(failure)
        let sampleObject = try #require(JSONSerialization.jsonObject(with: sampleData) as? [String: Any])
        let failureObject = try #require(JSONSerialization.jsonObject(with: failureData) as? [String: Any])

        #expect(Set(sampleObject.keys) == ["metric", "repetition", "durationNanoseconds", "residentKilobytes", "recordedAtUnixMillis"])
        #expect(Set(failureObject.keys) == ["metric", "repetition", "stage", "code", "message", "recordedAtUnixMillis"])
        #expect(sampleObject["payload"] == nil)
        #expect(failureObject["payload"] == nil)
        #expect(try JSONDecoder().decode(DesktopPerformanceSample.self, from: sampleData) == sample)
        #expect(try JSONDecoder().decode(DesktopPerformanceFailure.self, from: failureData) == failure)
    }

    @Test
    func probeReturnsTheValueAndAProcessLocalDuration() {
        let measured = DesktopPerformanceProbe.measure(
            metric: .coldLaunch,
            recordedAtUnixMillis: 9_000
        ) {
            "ready"
        }

        #expect(measured.value == "ready")
        #expect(measured.sample.metric == .coldLaunch)
        #expect(measured.sample.repetition == 1)
        #expect(measured.sample.residentKilobytes == nil)
        #expect(measured.sample.recordedAtUnixMillis == 9_000)
    }

    @Test
    func collectorKeepsOnlyTheNewestBoundedSamplesPerMetric() async throws {
        let collector = DesktopPerformanceCollector(maximumSamplesPerMetric: 2)
        await collector.record(.init(metric: .frameDuration, durationNanoseconds: 1, recordedAtUnixMillis: 1))
        await collector.record(.init(metric: .frameDuration, durationNanoseconds: 2, recordedAtUnixMillis: 2))
        await collector.record(.init(metric: .frameDuration, durationNanoseconds: 3, recordedAtUnixMillis: 3))
        await collector.record(.init(metric: .warmResume, durationNanoseconds: 4, recordedAtUnixMillis: 4))

        let report = await collector.report(generatedAtUnixMillis: 5)
        let frame = try #require(report.summaries.first { $0.metric == .frameDuration })
        let resume = try #require(report.summaries.first { $0.metric == .warmResume })
        #expect(frame.sampleCount == 2)
        #expect(frame.maximumNanoseconds == 3)
        #expect(resume.sampleCount == 1)
    }

    private func invalidRepetitionPlanFixture(
        for scenario: InvalidRepetitionPlanScenario
    ) -> InvalidRepetitionPlanFixture {
        let coldSample = DesktopPerformanceSample(
            metric: .coldLaunch,
            repetition: 1,
            durationNanoseconds: 100,
            recordedAtUnixMillis: 1
        )
        switch scenario {
        case .missingPlan:
            return InvalidRepetitionPlanFixture(
                metric: .coldLaunch,
                report: DesktopPerformanceReport(samples: [coldSample], generatedAtUnixMillis: 2),
                expectedRequestedRepetitions: nil,
                expectedAttemptCount: 1,
                expectedFailureCount: 0
            )
        case .missingRepetition:
            return invalidRequestedCountFixture(
                requested: 2,
                samples: [coldSample],
                expectedAttemptCount: 1
            )
        case .duplicateRepetition:
            let duplicate = DesktopPerformanceFailure(
                metric: .coldLaunch,
                repetition: 1,
                stage: "ready-receipt",
                code: "ready-timeout",
                message: "The duplicate outcome must not stand in for repetition two.",
                recordedAtUnixMillis: 2
            )
            return InvalidRepetitionPlanFixture(
                metric: .coldLaunch,
                report: DesktopPerformanceReport(
                    samples: [coldSample],
                    failures: [duplicate],
                    requestedRepetitions: [.coldLaunch: 2],
                    generatedAtUnixMillis: 3
                ),
                expectedRequestedRepetitions: 2,
                expectedAttemptCount: 2,
                expectedFailureCount: 1
            )
        case .outOfRangeRepetition:
            let samples = [1, 3].map {
                DesktopPerformanceSample(
                    metric: .warmResume,
                    repetition: $0,
                    durationNanoseconds: 100,
                    recordedAtUnixMillis: Int64($0)
                )
            }
            return InvalidRepetitionPlanFixture(
                metric: .warmResume,
                report: DesktopPerformanceReport(
                    samples: samples,
                    requestedRepetitions: [.warmResume: 2],
                    generatedAtUnixMillis: 3
                ),
                expectedRequestedRepetitions: 2,
                expectedAttemptCount: 2,
                expectedFailureCount: 0
            )
        case .zeroRequested:
            return invalidRequestedCountFixture(requested: 0)
        case .negativeRequested:
            return invalidRequestedCountFixture(requested: -1)
        case .aboveMaximumRequested:
            return invalidRequestedCountFixture(requested: 101)
        case .maximumIntegerRequested:
            return invalidRequestedCountFixture(requested: Int.max)
        }
    }

    private func invalidRequestedCountFixture(
        requested: Int,
        samples: [DesktopPerformanceSample] = [],
        expectedAttemptCount: Int = 0
    ) -> InvalidRepetitionPlanFixture {
        InvalidRepetitionPlanFixture(
            metric: .coldLaunch,
            report: DesktopPerformanceReport(
                samples: samples,
                requestedRepetitions: [.coldLaunch: requested],
                generatedAtUnixMillis: 1
            ),
            expectedRequestedRepetitions: requested,
            expectedAttemptCount: expectedAttemptCount,
            expectedFailureCount: 0
        )
    }
}
