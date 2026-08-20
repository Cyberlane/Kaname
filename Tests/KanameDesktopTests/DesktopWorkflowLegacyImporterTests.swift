import Foundation
import Testing
@testable import KanameDesktop

@MainActor
struct DesktopWorkflowLegacyImporterTests {
    @Test
    func terminalWorkflowImportsLosslesslyAndIdempotentlyWithoutMutatingSource() throws {
        let (model, source) = try installedSource()
        let sourceBefore = try DesktopWorkflowCanonicalJSON.encode(source)
        let snapshotBefore = try DesktopWorkflowCanonicalJSON.encode(model.snapshot)

        let first = try DesktopWorkflowLegacyImporter.importSource(source)
        let second = try DesktopWorkflowLegacyImporter.importSource(source)
        let modelPreview = try model.previewLegacyWorkflowAsV2(definitionID: source.definition.id)
        let committedGolden = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Fixtures/workflow-v2/legacy-import-terminal-v1.json"
            ),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(first == second)
        #expect(first == modelPreview)
        #expect(first.canonicalSource == committedGolden)
        #expect(first.isLossless)
        #expect(first.losses.isEmpty)
        #expect(try DesktopWorkflowCanonicalJSON.encode(source) == sourceBefore)
        #expect(try DesktopWorkflowCanonicalJSON.encode(model.snapshot) == snapshotBefore)

        let decoded = try JSONDecoder().decode(
            DesktopWorkflowV1Document.self,
            from: Data(first.canonicalSource.utf8)
        )
        let decodedLayout = try JSONDecoder().decode(
            DesktopWorkflowV1LayoutDocument.self,
            from: Data(first.canonicalLayoutSource.utf8)
        )
        #expect(decoded == first.workflow)
        #expect(decodedLayout == first.layout)
        #expect(decoded.graph.nodes.map(\.id).sorted() == decodedLayout.nodes.map(\.nodeId).sorted())
        #expect(decoded.graph.nodes.map(\.type).sorted() == ["terminal.complete", "trigger.manual"])
        #expect(decoded.graph.edges.count == 1)
        #expect(isUUIDv7(decoded.workflowId))
        #expect(decoded.graph.nodes.allSatisfy { isUUIDv7($0.id) })
        #expect(decoded.graph.entrypoints.allSatisfy { isUUIDv7($0.id) })
        #expect(decoded.graph.edges.allSatisfy { isUUIDv7($0.id) && isUUIDv7($0.mappingId) })
        #expect(decoded.graph.nodes.allSatisfy { node in
            node.key.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
        })
    }

    @Test
    func decisionImportExposesFixedYesNoPortsAndACompleteSanitizedLossReport() throws {
        var (_, source) = try installedSource()
        source.definition.triggerKinds = [.email, .manual]
        source.revision.permissions = .init(
            permissions: [.emailRead],
            accountIDs: ["private-account-token"]
        )
        source.revision.steps = [
            .init(
                id: "route-日本語", name: "Route reply", kind: .branch,
                transitions: [
                    .init(
                        outcome: .matched,
                        targetStepID: "accepted",
                        predicates: [.init(pointer: "/score", operation: .equals, value: "5")]
                    ),
                    .init(outcome: .always, targetStepID: "otherwise"),
                ]
            ),
            .init(id: "accepted", name: "Accepted", kind: .complete),
            .init(id: "otherwise", name: "Otherwise", kind: .complete),
        ]

        let first = try DesktopWorkflowLegacyImporter.importSource(source)
        let second = try DesktopWorkflowLegacyImporter.importSource(source)
        let codes = Set(first.losses.map(\.code))

        #expect(first == second)
        #expect(!first.isLossless)
        #expect(codes.contains("legacy.authority.requires-rebinding"))
        #expect(codes.contains("legacy.predicate.coercion"))
        #expect(!first.canonicalSource.contains("private-account-token"))
        #expect(!first.canonicalLayoutSource.contains("private-account-token"))
        #expect(first.workflow.graph.nodes.filter { $0.type.hasPrefix("trigger.") }.count == 2)

        let decision = try #require(first.workflow.graph.nodes.first { $0.type == "control.decision" })
        let routedPorts = Set(first.workflow.graph.edges.compactMap { edge in
            edge.from.nodeId == decision.id ? edge.from.portId : nil
        })
        #expect(routedPorts == ["matched", "not-matched"])
        #expect(decision.key.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil)
        #expect(!decision.key.contains("日"))
    }

    @Test
    func matchImportExposesStableOrderedCasePorts() throws {
        var (_, source) = try installedSource()
        source.revision.steps = [
            .init(
                id: "switch", name: "Switch route", kind: .match,
                transitions: [
                    .init(
                        routeID: "vip", label: "VIP", outcome: .selected, targetStepID: "priority",
                        predicates: [.init(pointer: "/tier", operation: .equals, value: "vip")]
                    ),
                    .init(
                        routeID: "otherwise", label: "Otherwise", outcome: .notMatched,
                        targetStepID: "ordinary"
                    ),
                ]
            ),
            .init(id: "priority", name: "Priority", kind: .complete),
            .init(id: "ordinary", name: "Ordinary", kind: .complete),
        ]

        let first = try DesktopWorkflowLegacyImporter.importSource(source)
        let second = try DesktopWorkflowLegacyImporter.importSource(source)
        let match = try #require(first.workflow.graph.nodes.first { $0.type == "control.match" })
        let configuredCaseIDs = matchCaseIDs(match.config)
        let routedCaseIDs = Set(first.workflow.graph.edges.compactMap { edge -> String? in
            guard edge.from.nodeId == match.id, edge.from.portId.hasPrefix("case-") else { return nil }
            return String(edge.from.portId.dropFirst("case-".count))
        })

        #expect(first == second)
        #expect(configuredCaseIDs.count == 2)
        #expect(routedCaseIDs == configuredCaseIDs)
        #expect(first.losses.map(\.code).contains("legacy.match.routing-contract"))
    }

    @Test
    func everyOpaqueLegacyStepKindProducesAnExplicitBlockingLoss() throws {
        let (_, baseline) = try installedSource()
        for kind in DesktopWorkflowStepKind.allCases where kind != .complete {
            var source = baseline
            source.revision.steps = [
                .init(
                    id: "legacy-step", name: kind.label, kind: kind,
                    transitions: [.init(outcome: .succeeded, targetStepID: "complete")]
                ),
                .init(id: "complete", name: "Complete", kind: .complete),
            ]

            let result = try DesktopWorkflowLegacyImporter.importSource(source)
            let stepLosses = result.losses.filter {
                $0.severity == .blocking && $0.pointer.hasPrefix("/graph/nodes/0")
            }
            #expect(!stepLosses.isEmpty, "\(kind.rawValue) must never be presented as a lossless import")
        }
    }

    @Test
    func missingTargetsDuplicateIdentitiesAndImplicitFanoutAreBlocking() throws {
        var (_, source) = try installedSource()
        source.revision.steps = [
            .init(
                id: "duplicate", name: "First", kind: .validate,
                transitions: [
                    .init(outcome: .succeeded, targetStepID: "complete"),
                    .init(outcome: .always, targetStepID: "missing"),
                ]
            ),
            .init(id: "duplicate", name: "Second", kind: .complete),
            .init(id: "complete", name: "Complete", kind: .complete),
        ]

        let result = try DesktopWorkflowLegacyImporter.importSource(source)
        let codes = Set(result.losses.map(\.code))
        #expect(codes.contains("legacy.step.identity-duplicate"))
        #expect(codes.contains("legacy.transition.target-missing"))
        #expect(codes.contains("legacy.transition.output-fanout"))
        #expect(Set(result.workflow.graph.nodes.map(\.id)).count == result.workflow.graph.nodes.count)
        #expect(Set(result.layout.nodes.map(\.nodeId)).count == result.layout.nodes.count)
    }

    @Test
    func duplicateTriggersCollapseDeterministicallyWithAnExplicitLoss() throws {
        var (_, source) = try installedSource()
        source.definition.triggerKinds = [.manual, .manual, .email]

        let result = try DesktopWorkflowLegacyImporter.importSource(source)

        #expect(result.losses.map(\.code).contains("legacy.trigger.identity-duplicate"))
        #expect(result.workflow.graph.entrypoints.count == 2)
        #expect(Set(result.workflow.graph.entrypoints.map(\.nodeId)).count == 2)
    }

    private func installedSource() throws -> (DesktopAppModel, DesktopWorkflowLegacyImportSource) {
        let model = DesktopAppModel(store: LegacyImporterMemoryStore(), now: { 10_000 })
        let manifest = DesktopWorkflowPackageManifest(
            schemaVersion: 2,
            id: "org.example.legacy-portable",
            name: "Portable legacy workflow",
            summary: "A synthetic import fixture.",
            icon: "point.3.connected.trianglepath.dotted",
            version: "1.0.0",
            source: "Synthetic",
            license: "MIT",
            triggers: [.manual],
            steps: [.init(id: "complete", name: "Complete", kind: .complete)],
            permissions: .init(),
            correlationSummary: "Synthetic correlation",
            contextSummary: "Synthetic context",
            completionSummary: "Synthetic completion"
        )
        _ = try model.installWorkflowPackage(
            manifestData: DesktopWorkflowPackageCodec.canonicalData(manifest),
            registeredCapabilityIDs: DesktopWorkflowBuiltinCapabilities.identifiers
        )
        let definition = try #require(model.snapshot.operations.workflows.definitions.first)
        let revision = try #require(model.snapshot.operations.workflows.revisions.first)
        return (model, .init(definition: definition, revision: revision))
    }

    private func isUUIDv7(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private func matchCaseIDs(_ configuration: DesktopWorkflowJSONValue) -> Set<String> {
        guard case let .object(config) = configuration else { return [] }
        var values: [DesktopWorkflowJSONValue] = []
        if case let .array(cases)? = config["cases"] { values.append(contentsOf: cases) }
        if let otherwise = config["otherwise"] { values.append(otherwise) }
        return Set(values.compactMap { value in
            guard case let .object(object) = value,
                  case let .string(identifier)? = object["id"] else { return nil }
            return identifier
        })
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class LegacyImporterMemoryStore: DesktopStateStoring {
    private var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}
