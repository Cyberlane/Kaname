import Testing
@testable import KanameDesktop

struct DesktopPerformanceFoundationTests {
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
                durationNanoseconds: UInt64($0) * 1_000_000,
                recordedAtUnixMillis: Int64($0)
            )
        }
        let report = DesktopPerformanceReport(samples: samples, generatedAtUnixMillis: 1_000)
        let summary = try #require(report.summaries.first)

        #expect(summary.sampleCount == 100)
        #expect(summary.medianNanoseconds == 50_000_000)
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
                durationNanoseconds: index < 18 ? 400_000_000 : 1_700_000_000,
                recordedAtUnixMillis: Int64(index)
            )
        }
        let report = DesktopPerformanceReport(samples: samples, generatedAtUnixMillis: 1_000)
        let summary = try #require(report.summaries.first)

        #expect(summary.p95Nanoseconds == 1_700_000_000)
        #expect(summary.meetsBudget == false)
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
}
