import CryptoKit
import Foundation
import Testing

@Suite
struct DesktopWorkflowV2AcceptanceCorpusTests {
    @Test
    func manifestBindsACompleteSyntheticScenarioCorpus() throws {
        let root = repositoryRoot
        let manifestData = try Data(contentsOf: root.appendingPathComponent("Fixtures/workflow-v2/corpus-manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let scenarioPath = try #require(manifest["scenarioFile"] as? String)
        let scenarioData = try Data(contentsOf: root.appendingPathComponent(scenarioPath))
        let document = try #require(try JSONSerialization.jsonObject(with: scenarioData) as? [String: Any])
        let scenarios = try #require(document["scenarios"] as? [[String: Any]])

        #expect(manifest["corpusVersion"] as? Int == 1)
        #expect(document["corpusVersion"] as? Int == 1)
        #expect(manifest["privacyClass"] as? String == "synthetic-public")
        #expect(manifest["scenarioCount"] as? Int == scenarios.count)
        #expect(hexDigest(scenarioData) == manifest["scenarioFileSHA256"] as? String)

        let identifiers = try scenarios.map { try #require($0["id"] as? String) }
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers == identifiers.sorted())
        #expect(identifiers == (1...25).map { String(format: "W2-%03d", $0) })

        let requiredCoverage = Set(try #require(manifest["requiredCoverage"] as? [String]))
        let observedCoverage = Set(scenarios.flatMap { $0["coverage"] as? [String] ?? [] })
        #expect(observedCoverage == requiredCoverage)

        for scenario in scenarios {
            let identifier = try #require(scenario["id"] as? String)
            let title = scenario["title"] as? String ?? ""
            #expect(!title.isEmpty, "\(identifier) needs a title")
            #expect(scenario["definition"] is [String: Any], "\(identifier) needs a definition")
            #expect(scenario["input"] is [String: Any], "\(identifier) needs input")
            let expected = try #require(scenario["expected"] as? [String: Any])
            let compile = try #require(expected["compile"] as? String)
            let diagnostics = try #require(expected["diagnosticCodes"] as? [String])
            let visualRoutes = try #require(scenario["visualRoutes"] as? [String])
            let inspectionGroups = try #require(expected["inspectionGroups"] as? [String])
            #expect(["valid", "rejected"].contains(compile), "\(identifier) has an unknown compile result")
            #expect(!visualRoutes.isEmpty, "\(identifier) needs a visible proof route")
            #expect(!inspectionGroups.isEmpty, "\(identifier) needs inspection expectations")
            if compile == "valid" {
                #expect(diagnostics.isEmpty, "\(identifier) is valid but expects blocking diagnostics")
            } else {
                #expect(!diagnostics.isEmpty, "\(identifier) is rejected without a diagnostic")
                #expect(expected["run"] as? String == "notRun")
            }
        }
    }

    @Test
    func corpusContainsNoPrivateIdentityCredentialOrHostPath() throws {
        let root = repositoryRoot
        let files = [
            root.appendingPathComponent("Fixtures/workflow-v2/README.md"),
            root.appendingPathComponent("Fixtures/workflow-v2/corpus-manifest.json"),
            root.appendingPathComponent("Fixtures/workflow-v2/scenarios.json"),
            root.appendingPathComponent("Fixtures/workflow-v2/visual-manifest.json"),
            root.appendingPathComponent("Scripts/capture-workflow-v2-visual-fixtures.sh"),
        ]
        let prohibitedFragments = [
            "justin@", "cyber-lane", "simplykay", "smbc", "gmail.com",
            "1password", "keychain", "/users/", "~/", "bearer ", "oauth_client_secret",
        ]

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8).lowercased()
            for fragment in prohibitedFragments {
                #expect(!contents.contains(fragment), "\(file.lastPathComponent) contains prohibited fragment \(fragment)")
            }
        }
    }

    @Test
    func visualManifestCoversEveryScenarioRouteAndCompactLayouts() throws {
        let root = repositoryRoot
        let scenarioData = try Data(contentsOf: root.appendingPathComponent("Fixtures/workflow-v2/scenarios.json"))
        let scenarioDocument = try #require(try JSONSerialization.jsonObject(with: scenarioData) as? [String: Any])
        let scenarios = try #require(scenarioDocument["scenarios"] as? [[String: Any]])
        let requiredRoutes = Set(scenarios.flatMap { $0["visualRoutes"] as? [String] ?? [] })

        let visualData = try Data(contentsOf: root.appendingPathComponent("Fixtures/workflow-v2/visual-manifest.json"))
        let visualDocument = try #require(try JSONSerialization.jsonObject(with: visualData) as? [String: Any])
        let captures = try #require(visualDocument["captures"] as? [[String: Any]])
        let coveredRoutes = Set(captures.flatMap { $0["routes"] as? [String] ?? [] })
        let names = try captures.map { try #require($0["name"] as? String) }

        #expect(visualDocument["manifestVersion"] as? Int == 1)
        #expect(visualDocument["privacyClass"] as? String == "synthetic-public")
        #expect(Set(names).count == names.count)
        #expect(requiredRoutes.isSubset(of: coveredRoutes))
        #expect(captures.contains { ($0["width"] as? Int) == 1_080 && ($0["height"] as? Int) == 700 })
        #expect(captures.contains { ($0["width"] as? Int) == 1_520 && ($0["height"] as? Int) == 940 })
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
