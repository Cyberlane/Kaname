import Foundation
import Testing
@testable import KanameDesktop

struct DesktopWorkflowGraphDomainTests {
    @Test
    func semanticIdentityIgnoresLayoutKeyAndCollectionOrderButDetectsBehaviorChange() throws {
        let original = try fixture()
        var reorderedGraph = original.graph
        reorderedGraph.nodes.reverse()
        reorderedGraph.ports.reverse()
        reorderedGraph.caseOutputs.reverse()
        reorderedGraph.mappings.reverse()
        reorderedGraph.edges.reverse()
        let reordered = DesktopWorkflowGraphDomainSnapshot.assemble(
            graph: reorderedGraph,
            layout: original.layout.reversed().map {
                .place(nodeID: $0.nodeID, x: $0.x + 240, y: $0.y - 80)
            }
        )

        #expect(try original.semanticIdentityData() == reordered.semanticIdentityData())
        #expect(try original.semanticIdentityDigest() == reordered.semanticIdentityDigest())
        #expect(try original.layoutIdentityData() != reordered.layoutIdentityData())

        var changedGraph = original.graph
        changedGraph.nodes[1].configuration = .object([
            "z": .string("behavior changed"),
            "a": .boolean(true),
        ])
        let changed = DesktopWorkflowGraphDomainSnapshot.assemble(
            graph: changedGraph,
            layout: original.layout
        )
        #expect(try changed.semanticIdentityDigest() != original.semanticIdentityDigest())
    }

    @Test
    func duplicateAndUnstableIdentitiesAreBlockingDiagnostics() throws {
        var graph = try fixture().graph
        graph.nodes.append(graph.nodes[0])
        let diagnostics = DesktopWorkflowGraphIdentityValidation.diagnostics(graph)

        #expect(diagnostics.contains { $0.code == "identity.node.duplicate" })
        #expect(diagnostics.contains { $0.code == "identity.node-key.duplicate" })
        #expect(throws: DesktopWorkflowGraphIdentityError.self) {
            try DesktopWorkflowGraphIdentityCodec.canonicalSemanticData(graph)
        }
        #expect(throws: DesktopWorkflowGraphIdentityError.self) {
            _ = try DesktopWorkflowNodeID("node-0")
        }
        #expect(
            DesktopWorkflowGraphIdentityValidation.unstableIdentityDiagnostic(
                kind: "node",
                value: "node-0",
                pointer: "/nodes/0/id"
            )?.code == "identity.node.unstable"
        )
    }

    @Test
    func referencesUseExactScopedIdentitiesAndDynamicCasePortsStayStable() throws {
        var graph = try fixture().graph
        let caseOutput = try #require(graph.caseOutputs.first)
        #expect(caseOutput.portID == (try DesktopWorkflowPortID.matchCase(caseOutput.id)))

        graph.edges[0].mappingID = try DesktopWorkflowMappingID(
            "018f0000-0099-7000-8000-000000000099"
        )
        graph.edges[0].to.portID = try DesktopWorkflowPortID("missing")
        let diagnostics = DesktopWorkflowGraphIdentityValidation.diagnostics(graph)
        #expect(diagnostics.map(\.code).contains("identity.edge.mapping-missing"))
        #expect(diagnostics.map(\.code).contains("identity.edge.port-missing"))
    }

    private func fixture() throws -> DesktopWorkflowGraphDomainSnapshot {
        let workflowID = try DesktopWorkflowID("018f0000-0001-7000-8000-000000000001")
        let triggerID = try DesktopWorkflowNodeID("018f0000-0002-7000-8000-000000000002")
        let matchID = try DesktopWorkflowNodeID("018f0000-0003-7000-8000-000000000003")
        let caseID = try DesktopWorkflowCaseOutputID("018f0000-0004-7000-8000-000000000004")
        let entrypointID = try DesktopWorkflowEntrypointID("018f0000-0005-7000-8000-000000000005")
        let mappingID = try DesktopWorkflowMappingID("018f0000-0006-7000-8000-000000000006")
        let edgeID = try DesktopWorkflowEdgeID("018f0000-0007-7000-8000-000000000007")
        let success = try DesktopWorkflowPortID("success")
        let input = try DesktopWorkflowPortID("input")
        let casePort = try DesktopWorkflowPortID.matchCase(caseID)

        let trigger = DesktopWorkflowGraphNodeIdentity.define(
            id: triggerID,
            key: "reply-received",
            type: "trigger.event",
            typeVersion: 1,
            configuration: .object(["eventContract": .string("email.reply.received.v1")])
        )
        let match = DesktopWorkflowGraphNodeIdentity.define(
            id: matchID,
            key: "route-reply",
            type: "control.match",
            typeVersion: 1,
            configuration: .object([
                "z": .string("same value"),
                "a": .boolean(true),
            ])
        )
        let mapping = DesktopWorkflowGraphMappingIdentity.define(
            id: mappingID,
            expression: .object(["whole": .boolean(true)])
        )
        let graph = DesktopWorkflowGraphIdentityDocument.define(
            workflowID: workflowID,
            entrypoints: [.define(id: entrypointID, nodeID: triggerID, key: "email")],
            nodes: [trigger, match],
            ports: [
                .define(nodeID: triggerID, id: success, direction: .output, schemaRef: "dev.kaname.email/v1"),
                .define(nodeID: matchID, id: input, direction: .input, schemaRef: "dev.kaname.email/v1"),
                .define(nodeID: matchID, id: casePort, direction: .output, schemaRef: "dev.kaname.route/v1"),
            ],
            caseOutputs: [try .define(id: caseID, nodeID: matchID, key: "correction", label: "Correction")],
            mappings: [mapping],
            edges: [
                .define(
                    id: edgeID,
                    from: .define(nodeID: triggerID, portID: success),
                    to: .define(nodeID: matchID, portID: input),
                    mappingID: mappingID
                ),
            ]
        )
        return .assemble(
            graph: graph,
            layout: [
                .place(nodeID: triggerID, x: 40, y: 100),
                .place(nodeID: matchID, x: 360, y: 100),
            ]
        )
    }
}
