import Foundation
import Testing
@testable import KanameDesktop

@Suite
struct DesktopWorkflowJSONSchemaTests {
    @Test
    func sharedNodeGoldensCanonicallyRoundTripThroughSwift() throws {
        let data = try fixtureData("schema-v1-node-goldens.json")
        let goldens = try JSONDecoder().decode([String: DesktopWorkflowJSONValue].self, from: data)

        #expect(goldens.count == 26)
        for (nodeType, golden) in goldens {
            try expectStableCanonicalRoundTrip(golden, identifier: nodeType)
        }
    }

    @Test
    func sharedCommonGoldensCanonicallyRoundTripThroughSwift() throws {
        let data = try fixtureData("schema-v1-common-goldens.json")
        let goldens = try JSONDecoder().decode([CommonGolden].self, from: data)

        #expect(goldens.count == 21)
        #expect(Set(goldens.map(\.schema)).count == goldens.count)
        for golden in goldens {
            try expectStableCanonicalRoundTrip(
                golden.valid,
                identifier: "\(golden.schema):valid"
            )
            try expectStableCanonicalRoundTrip(
                golden.invalid,
                identifier: "\(golden.schema):invalid"
            )
        }
    }

    @Test
    func swiftMatchesTheRustCanonicalGoldenBytesWithOnlyExplicitDifferences() throws {
        let corpus = try JSONDecoder().decode(
            CanonicalCorpus.self,
            from: fixtureData("canonical-vectors.json")
        )

        #expect(corpus.contract == "RFC 8785")
        #expect(corpus.vectors.count == 6)
        #expect(corpus.rejected.count == 6)
        #expect(Set(corpus.vectors.map(\.id)) == ["schema-lock", "layout", "configuration-contract", "compiled-artifact", "semantic-graph", "dependency-lock"])
        #expect(Set(corpus.rejected.map(\.id)) == ["duplicate-key", "unsafe-integer", "lone-surrogate", "non-finite", "trailing-data", "empty"])
        var observedDifferences = Set<String>()
        for vector in corpus.vectors {
            let value = try DesktopWorkflowJSONValue.decodeCanonicalInput(Data(vector.input.utf8))
            let swiftCanonical = try value.canonicalData()
            let expectedCanonical = Data(vector.canonical.utf8)
            if swiftCanonical != expectedCanonical {
                observedDifferences.insert(vector.id)
                let tolerance = Self.toleratedCanonicalDifferences[vector.id]
                #expect(tolerance != nil, "\(vector.id) differs without an explicit tolerance")
                if let tolerance {
                    #expect(!tolerance.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    #expect(swiftCanonical == Data(tolerance.swiftCanonical.utf8))
                }
            }

            let decodedAgain = try DesktopWorkflowJSONValue.decode(swiftCanonical)
            #expect(decodedAgain == value, "\(vector.id) changed value on canonical round-trip")
            #expect(
                try decodedAgain.canonicalData() == swiftCanonical,
                "\(vector.id) changed bytes on its second canonical encoding"
            )
        }

        #expect(observedDifferences == Set(Self.toleratedCanonicalDifferences.keys))
        for vector in corpus.rejected {
            #expect(!vector.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(throws: (any Error).self) {
                let value = try DesktopWorkflowJSONValue.decodeCanonicalInput(Data(vector.input.utf8))
                _ = try value.canonicalData()
            }
        }
    }

    @Test
    func strictCanonicalInputRejectsResourceExhaustionBeforeDecoding() throws {
        let exactBound = Data(("\"" + String(repeating: "a", count: 512 * 1_024 - 2) + "\"").utf8)
        #expect(try DesktopWorkflowJSONValue.decodeCanonicalInput(exactBound) != .null)

        let oversized = Data(("\"" + String(repeating: "a", count: 512 * 1_024 - 1) + "\"").utf8)
        #expect(throws: (any Error).self) {
            _ = try DesktopWorkflowJSONValue.decodeCanonicalInput(oversized)
        }

        for (name, accepted, rejected) in nestingBoundaryInputs() {
            #expect(try DesktopWorkflowJSONValue.decodeCanonicalInput(Data(accepted.utf8)) != .null, "\(name) depth 127")
            #expect(throws: (any Error).self, "\(name) depth 128") {
                _ = try DesktopWorkflowJSONValue.decodeCanonicalInput(Data(rejected.utf8))
            }
        }
    }

    private func nestingBoundaryInputs() -> [(String, String, String)] {
        func arrays(_ count: Int) -> String {
            String(repeating: "[", count: count) + "null" + String(repeating: "]", count: count)
        }
        func objects(_ count: Int) -> String {
            String(repeating: "{\"v\":", count: count) + "null" + String(repeating: "}", count: count)
        }
        func mixed(_ count: Int) -> String {
            (0..<count).map { $0.isMultiple(of: 2) ? "[" : "{\"v\":" }.joined()
                + "null"
                + (0..<count).reversed().map { $0.isMultiple(of: 2) ? "]" : "}" }.joined()
        }
        return [
            ("array", arrays(127), arrays(128)),
            ("object", objects(127), objects(128)),
            ("mixed", mixed(127), mixed(128)),
        ]
    }

    private struct CommonGolden: Decodable {
        let schema: String
        let valid: DesktopWorkflowJSONValue
        let invalid: DesktopWorkflowJSONValue
    }

    private struct CanonicalCorpus: Decodable {
        let contract: String
        let vectors: [CanonicalVector]
        let rejected: [RejectedCanonicalVector]
    }

    private struct RejectedCanonicalVector: Decodable {
        let id: String
        let input: String
        let error: String
    }

    private struct CanonicalVector: Decodable {
        let id: String
        let input: String
        let canonical: String
    }

    private struct ToleratedCanonicalDifference {
        let swiftCanonical: String
        let reason: String
    }

    /// Differences are never accepted implicitly. A future exception must name
    /// the vector, pin Swift's exact bytes, and explain why parity is impossible.
    private static let toleratedCanonicalDifferences: [String: ToleratedCanonicalDifference] = [:]

    private func expectStableCanonicalRoundTrip(
        _ value: DesktopWorkflowJSONValue,
        identifier: String
    ) throws {
        let first = try value.canonicalData()
        let decoded = try DesktopWorkflowJSONValue.decode(first)
        let second = try decoded.canonicalData()
        #expect(decoded == value, "\(identifier) changed value on canonical round-trip")
        #expect(second == first, "\(identifier) changed bytes on its second canonical encoding")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent("Fixtures/workflow-v2/\(name)"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
