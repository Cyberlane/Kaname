import KanameProtocol
import Testing
@testable import KanameDesktop

struct DesktopWorkflowDiagnosticsTests {
    @Test
    func protobufDiagnosticsBecomeStableMaskedPresentationRows() throws {
        let source = diagnostic(
            code: "graph.entrypoint.missing",
            severity: .error,
            summary: "Choose one entry node.",
            pointer: "/graph/entryNodeID",
            sourceID: "workflow.json",
            byteOffset: 48
        )
        let warning = diagnostic(
            code: "graph.node.unreachable",
            severity: .warning,
            summary: "Node is unreachable.",
            pointer: "/graph/nodes/3",
            sourceID: "workflow.json",
            byteOffset: 212
        )
        var response = Kaname_V1_CompileWorkflowResponse()
        response.diagnostics = [warning, source]
        let routeKey = DesktopWorkflowDiagnosticRouteKey(
            code: warning.code,
            instancePointer: warning.instancePointer
        )

        let first = DesktopWorkflowDiagnosticMapper.presentations(
            response: response,
            routes: [routeKey: .canvas(nodeID: "interpret")],
            fixes: [routeKey: .init(
                id: "connect-unreachable-node",
                title: "Connect node",
                explanation: "Preview a compatible incoming connection."
            )]
        )
        let second = DesktopWorkflowDiagnosticMapper.presentations(
            response: response,
            routes: [routeKey: .canvas(nodeID: "interpret")],
            fixes: [routeKey: .init(
                id: "connect-unreachable-node",
                title: "Connect node",
                explanation: "Preview a compatible incoming connection."
            )]
        )

        #expect(first == second)
        #expect(first.map(\.code) == ["graph.entrypoint.missing", "graph.node.unreachable"])
        #expect(first[0].focusTarget.projection == .source)
        #expect(first[0].focusTarget.sourceRange?.start.byteOffset == 48)
        #expect(first[1].focusTarget.nodeID == "interpret")
        #expect(first[1].fix?.id == "connect-unreachable-node")
        #expect(first[1].accessibilityLabel.contains("Warning, graph.node.unreachable"))
    }

    @Test
    func navigationFocusesExactTargetsAndNeverFallsBackWhenMissing() throws {
        var response = Kaname_V1_CompileWorkflowResponse()
        let edgeDiagnostic = diagnostic(
            code: "graph.cycle.unbounded",
            severity: .error,
            summary: "Cycle needs a bound.",
            pointer: "/graph/edges/4",
            sourceID: "workflow.json",
            byteOffset: 300
        )
        response.diagnostics = [edgeDiagnostic]
        let key = DesktopWorkflowDiagnosticRouteKey(
            code: edgeDiagnostic.code,
            instancePointer: edgeDiagnostic.instancePointer
        )
        let item = try #require(DesktopWorkflowDiagnosticMapper.presentations(
            response: response,
            routes: [key: .canvas(
                nodeID: "interpret",
                edgeID: "interpret:correction:append"
            )]
        ).first)
        var state = DesktopWorkflowDiagnosticNavigationState(projection: .outline)

        #expect(state.focus(
            item,
            availableNodeIDs: ["interpret"],
            availableEdgeIDs: ["interpret:correction:append"]
        ) == .focused(item.focusTarget))
        #expect(state.projection == .canvas)
        #expect(state.selectedNodeID == "interpret")
        #expect(state.selectedEdgeID == "interpret:correction:append")

        var missingState = DesktopWorkflowDiagnosticNavigationState(projection: .outline)
        #expect(missingState.focus(
            item,
            availableNodeIDs: ["other"],
            availableEdgeIDs: []
        ) == .targetUnavailable)
        #expect(missingState.projection == .outline)
        #expect(missingState.selectedNodeID == nil)
        #expect(missingState.unresolvedDiagnosticID == item.id)
    }

    private func diagnostic(
        code: String,
        severity: Kaname_V1_WorkflowDiagnosticSeverity,
        summary: String,
        pointer: String,
        sourceID: String,
        byteOffset: UInt64
    ) -> Kaname_V1_WorkflowDiagnostic {
        var value = Kaname_V1_WorkflowDiagnostic()
        value.code = code
        value.severity = severity
        value.summary = summary
        value.instancePointer = pointer
        value.schemaPointer = "/schema"
        value.location = sourceLocation(pointer: pointer, sourceID: sourceID, byteOffset: byteOffset)
        return value
    }

    private func sourceLocation(
        pointer: String,
        sourceID: String,
        byteOffset: UInt64
    ) -> Kaname_V1_WorkflowSourceLocation {
        var start = Kaname_V1_WorkflowSourcePosition()
        start.byteOffset = byteOffset
        start.line = UInt32(byteOffset / 40)
        start.column = UInt32(byteOffset % 40)
        var end = start
        end.byteOffset += 12
        end.column += 12
        var location = Kaname_V1_WorkflowSourceLocation()
        location.sourceID = sourceID
        location.jsonPointer = pointer
        location.start = start
        location.end = end
        return location
    }
}
