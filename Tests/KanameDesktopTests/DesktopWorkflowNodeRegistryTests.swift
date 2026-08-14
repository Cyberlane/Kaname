import Foundation
import Testing
@testable import KanameDesktop

struct DesktopWorkflowNodeRegistryTests {
    @Test
    func builtInRegistryMatchesSchemaInventoryAndResolvesContracts() throws {
        let registry = try DesktopWorkflowNodeRegistry.builtInSchemaOnlyV1()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Schema/Workflow/v1/registry.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(manifest["nodeTypes"] as? [[String: Any]])
        let schemaTypes = Set(records.compactMap { $0["type"] as? String })

        #expect(registry.registrations.count == 25)
        #expect(Set(registry.registrations.map(\.type)) == schemaTypes)
        #expect(registry.registrations.allSatisfy {
            $0.typeVersion == 1 && $0.availability == .schemaOnly
                && $0.configurationSchemaRef.hasPrefix("node-config.schema.json#/$defs/")
                && $0.migrations.isEmpty
        })
        #expect(throws: DesktopWorkflowNodeRegistryError.self) {
            _ = try registry.registration(type: "control.match", version: 2)
        }
    }

    @Test
    func dynamicMatchAndParallelPortsUseImmutableCaseIdentities() throws {
        let registry = try DesktopWorkflowNodeRegistry.builtInSchemaOnlyV1()
        let nodeID = try DesktopWorkflowNodeID("018f0000-0001-7000-8000-000000000001")
        let firstCase = "018f0000-0002-7000-8000-000000000002"
        let otherwise = "018f0000-0003-7000-8000-000000000003"
        let secondBranch = "018f0000-0004-7000-8000-000000000004"
        let match = DesktopWorkflowGraphNodeIdentity.define(
            id: nodeID,
            key: "route",
            type: "control.match",
            typeVersion: 1,
            configuration: .object([
                "cases": .array([.object(["id": .string(firstCase)])]),
                "otherwise": .object(["id": .string(otherwise)]),
            ])
        )
        let matchPorts = try registry.ports(for: match)
        #expect(matchPorts.map(\.id.rawValue).contains("case-\(firstCase)"))
        #expect(matchPorts.map(\.id.rawValue).contains("case-\(otherwise)"))
        #expect(matchPorts.contains { $0.id.rawValue == "error" && !$0.required })

        let parallel = DesktopWorkflowGraphNodeIdentity.define(
            id: nodeID,
            key: "fork",
            type: "control.parallel",
            typeVersion: 1,
            configuration: .object([
                "branches": .array([
                    .object(["id": .string(firstCase)]),
                    .object(["id": .string(secondBranch)]),
                ]),
            ])
        )
        let parallelPorts = try registry.ports(for: parallel).map(\.id.rawValue)
        #expect(parallelPorts.contains("case-\(firstCase)"))
        #expect(parallelPorts.contains("case-\(secondBranch)"))
    }

    @Test
    func compatibleGraphPassesWhileMissingOrphanAndIllegalPortsBlock() throws {
        let registry = try DesktopWorkflowNodeRegistry.builtInSchemaOnlyV1()
        let valid = try graph(registry: registry)
        #expect(DesktopWorkflowNodeRegistryValidation.diagnostics(graph: valid, registry: registry).isEmpty)

        var missingInput = valid
        missingInput.edges = []
        #expect(DesktopWorkflowNodeRegistryValidation.diagnostics(
            graph: missingInput,
            registry: registry
        ).contains { $0.code == "registry.input.required-missing" })

        var orphan = valid
        orphan.ports.append(.define(
            nodeID: orphan.nodes[0].id,
            id: try DesktopWorkflowPortID("invented"),
            direction: .output,
            schemaRef: DesktopWorkflowNodeRegistry.dataSchemaRef
        ))
        #expect(DesktopWorkflowNodeRegistryValidation.diagnostics(
            graph: orphan,
            registry: registry
        ).contains { $0.code == "registry.port.orphan" })

        var incompatible = valid
        incompatible.ports[1].schemaRef = "dev.kaname.unrelated/v1"
        let incompatibleCodes = DesktopWorkflowNodeRegistryValidation.diagnostics(
            graph: incompatible,
            registry: registry
        ).map(\.code)
        #expect(incompatibleCodes.contains("registry.port.contract-mismatch"))
        #expect(incompatibleCodes.contains("registry.mapping.illegal-coercion"))
    }

    private func graph(
        registry: DesktopWorkflowNodeRegistry
    ) throws -> DesktopWorkflowGraphIdentityDocument {
        let workflowID = try DesktopWorkflowID("018f0000-0010-7000-8000-000000000010")
        let sourceID = try DesktopWorkflowNodeID("018f0000-0011-7000-8000-000000000011")
        let sinkID = try DesktopWorkflowNodeID("018f0000-0012-7000-8000-000000000012")
        let mappingID = try DesktopWorkflowMappingID("018f0000-0013-7000-8000-000000000013")
        let source = DesktopWorkflowGraphNodeIdentity.define(
            id: sourceID,
            key: "start",
            type: "trigger.manual",
            typeVersion: 1,
            configuration: .object([:])
        )
        let sink = DesktopWorkflowGraphNodeIdentity.define(
            id: sinkID,
            key: "complete",
            type: "terminal.complete",
            typeVersion: 1,
            configuration: .object([:])
        )
        return .define(
            workflowID: workflowID,
            entrypoints: [.define(
                id: try DesktopWorkflowEntrypointID("018f0000-0014-7000-8000-000000000014"),
                nodeID: sourceID
            )],
            nodes: [source, sink],
            ports: try registry.ports(for: source) + registry.ports(for: sink),
            caseOutputs: [],
            mappings: [.define(
                id: mappingID,
                expression: .object(["whole": .boolean(true)])
            )],
            edges: [.define(
                id: try DesktopWorkflowEdgeID("018f0000-0015-7000-8000-000000000015"),
                from: .define(nodeID: sourceID, portID: try DesktopWorkflowPortID("success")),
                to: .define(nodeID: sinkID, portID: try DesktopWorkflowPortID("input")),
                mappingID: mappingID
            )]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
