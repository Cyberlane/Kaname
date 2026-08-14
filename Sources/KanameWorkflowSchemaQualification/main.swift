import Foundation
import KanameDesktop

private struct ScenarioCorpus: Decodable {
    let scenarios: [Scenario]
}

private struct Scenario: Codable {
    let id: String
    let title: String
    let category: String
    let coverage: [String]
    let definition: DesktopWorkflowJSONValue
    let input: DesktopWorkflowJSONValue
    let expected: DesktopWorkflowJSONValue
    let visualRoutes: [String]
}

private struct CheckerRequest: Encodable {
    let schema: DesktopWorkflowJSONValue
    let instance: Scenario
}

private struct CheckerReport: Decodable {
    let draft: String
    let outcome: String
    let diagnostics: [Diagnostic]
    let diagnosticsTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case draft, outcome, diagnostics
        case diagnosticsTruncated = "diagnostics_truncated"
    }
}

private struct Diagnostic: Decodable {
    let code: String
    let instancePath: String
    let schemaPath: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case code, message
        case instancePath = "instance_path"
        case schemaPath = "schema_path"
    }
}

private struct QualificationReport: Encodable {
    let validator: String
    let draft: String
    let transport: String
    let corpusScenarioCount: Int
    let validCallPassed: Bool
    let invalidCallPassed: Bool
    let deterministicErrorsPassed: Bool
    let diagnosticsMasked: Bool
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let coreBinaryBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case validator, draft, transport
        case corpusScenarioCount = "corpus_scenario_count"
        case validCallPassed = "valid_call_passed"
        case invalidCallPassed = "invalid_call_passed"
        case deterministicErrorsPassed = "deterministic_errors_passed"
        case diagnosticsMasked = "diagnostics_masked"
        case medianMilliseconds = "median_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
        case coreBinaryBytes = "core_binary_bytes"
    }
}

@main
private enum KanameWorkflowSchemaQualification {
    static func main() throws {
        guard let corePath = value(after: "--core"),
              let corpusPath = value(after: "--corpus") else {
            throw QualificationError.usage
        }
        let core = URL(fileURLWithPath: corePath)
        let corpus = try JSONDecoder().decode(
            ScenarioCorpus.self,
            from: Data(contentsOf: URL(fileURLWithPath: corpusPath))
        )
        guard !corpus.scenarios.isEmpty else { throw QualificationError.emptyCorpus }
        let schema = try JSONDecoder().decode(DesktopWorkflowJSONValue.self, from: Data(schemaJSON.utf8))
        var samples = [Double]()
        var firstReports = [CheckerReport]()
        for scenario in corpus.scenarios {
            let started = ContinuousClock.now
            firstReports.append(try invoke(core: core, request: CheckerRequest(schema: schema, instance: scenario)))
            let elapsed = started.duration(to: ContinuousClock.now).components
            samples.append(
                Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            )
        }
        let repeated = try invoke(
            core: core,
            request: CheckerRequest(schema: schema, instance: corpus.scenarios[0])
        )
        let invalid = try invoke(core: core, request: CheckerRequest(
            schema: schema,
            instance: Scenario(
                id: "",
                title: corpus.scenarios[0].title,
                category: corpus.scenarios[0].category,
                coverage: [],
                definition: corpus.scenarios[0].definition,
                input: corpus.scenarios[0].input,
                expected: corpus.scenarios[0].expected,
                visualRoutes: corpus.scenarios[0].visualRoutes
            )
        ))
        samples.sort()
        let attributes = try FileManager.default.attributesOfItem(atPath: core.path)
        let report = QualificationReport(
            validator: "jsonschema-rs 0.49.9",
            draft: "2020-12",
            transport: "Swift Process -> bounded JSON stdin -> Rust -> JSON stdout",
            corpusScenarioCount: corpus.scenarios.count,
            validCallPassed: firstReports.allSatisfy { $0.outcome == "valid" && $0.draft == "2020-12" },
            invalidCallPassed: invalid.outcome == "invalid_instance" && !invalid.diagnostics.isEmpty,
            deterministicErrorsPassed: repeated == firstReports[0],
            diagnosticsMasked: invalid.diagnostics.allSatisfy {
                !$0.message.contains(corpus.scenarios[0].title) && !$0.diagnosticsTextContainsPrivateValue
            },
            medianMilliseconds: samples[samples.count / 2],
            p95Milliseconds: samples[min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.up)) - 1)],
            coreBinaryBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        )
        guard report.validCallPassed, report.invalidCallPassed,
              report.deterministicErrorsPassed, report.diagnosticsMasked else {
            throw QualificationError.checkFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func invoke(core: URL, request: CheckerRequest) throws -> CheckerReport {
        let input = try JSONEncoder().encode(request)
        guard !input.isEmpty, input.count <= 512 * 1024 else { throw QualificationError.requestTooLarge }
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = core
        process.arguments = ["workflow-schema-check"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, output.count <= 64 * 1024 else {
            throw QualificationError.coreFailed(String(decoding: error.prefix(512), as: UTF8.self))
        }
        return try JSONDecoder().decode(CheckerReport.self, from: output)
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static let schemaJSON = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["id", "title", "category", "coverage", "definition", "input", "expected", "visualRoutes"],
      "properties": {
        "id": {"type": "string", "pattern": "^W2-[0-9]{3}$"},
        "title": {"type": "string", "minLength": 1},
        "category": {"type": "string", "minLength": 1},
        "coverage": {"type": "array", "minItems": 1, "items": {"type": "string"}},
        "definition": {"type": "object"},
        "input": {},
        "expected": {"type": "object"},
        "visualRoutes": {"type": "array", "minItems": 1, "items": {"type": "string"}}
      },
      "unevaluatedProperties": false
    }
    """#
}

private enum QualificationError: Error {
    case usage
    case emptyCorpus
    case requestTooLarge
    case coreFailed(String)
    case checkFailed
}

extension CheckerReport: Equatable {}
extension Diagnostic: Equatable {}

private extension Diagnostic {
    var diagnosticsTextContainsPrivateValue: Bool {
        message.localizedCaseInsensitiveContains("private-value")
    }
}
