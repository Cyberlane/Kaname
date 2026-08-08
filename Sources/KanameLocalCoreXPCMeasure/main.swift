import Foundation
import KanameLocalCore

private struct Report: Encodable {
    let fixtureID: String
    let repetitions: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let failures: Int

    enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case repetitions
        case p50Milliseconds = "p50_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
        case p99Milliseconds = "p99_milliseconds"
        case failures
    }
}

@main
private enum KanameLocalCoreXPCMeasure {
    static func main() async {
        guard let machService = value(after: "--mach-service"),
              let requirement = value(after: "--service-requirement") else {
            FileHandle.standardError.write(Data("usage: KanameLocalCoreXPCMeasure --mach-service <name> --service-requirement <requirement>\n".utf8))
            exit(64)
        }
        let repetitions = Int(value(after: "--repetitions") ?? "25") ?? 25
        let runner = LocalCoreRunner(machService: machService, serviceRequirement: requirement)
        var samples: [Double] = []
        var failures = 0
        for _ in 0..<max(1, repetitions) {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await runner.runScenario("F-01")
            } catch {
                failures += 1
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        samples.sort()
        let percentile: (Double) -> Double = { percent in
            samples[(Int((Double(samples.count) * percent).rounded(.up)) - 1).clamped(to: 0...(samples.count - 1))]
        }
        let report = Report(
            fixtureID: "F-01",
            repetitions: samples.count,
            p50Milliseconds: percentile(0.50),
            p95Milliseconds: percentile(0.95),
            p99Milliseconds: percentile(0.99),
            failures: failures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
