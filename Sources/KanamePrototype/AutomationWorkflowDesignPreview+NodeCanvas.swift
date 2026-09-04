import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

enum AutomationCanvasNodeKind {
    case trigger
    case data
    case policy
    case decision
    case parallel
    case join
    case loop
    case ai
    case context
    case human
    case wait
    case effect
    case error
    case subflow
    case receipt

    var label: String {
        switch self {
        case .trigger: "TRIGGER"
        case .data: "DATA"
        case .policy: "POLICY"
        case .decision: "DECISION"
        case .parallel: "PARALLEL"
        case .join: "JOIN"
        case .loop: "LOOP"
        case .ai: "AI"
        case .context: "CONTEXT"
        case .human: "HUMAN"
        case .wait: "WAIT"
        case .effect: "EFFECT"
        case .error: "ERROR"
        case .subflow: "SUBFLOW"
        case .receipt: "RECEIPT"
        }
    }

    var tint: Color {
        switch self {
        case .trigger, .data, .policy, .receipt: KanameColor.accent
        case .context: KanameColor.active
        case .decision, .human, .wait: KanameColor.warning
        case .parallel, .join, .loop, .subflow: KanameColor.blocked
        case .ai: KanameColor.active
        case .effect, .error: KanameColor.danger
        }
    }
}

struct AutomationCanvasStep: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let kind: AutomationCanvasNodeKind
    let x: CGFloat
    let y: CGFloat
    let state: AutomationPreviewState
    let input: String
    let output: String
    let authority: String
    /// Why the compiler keeps this node schema-only, in plain language.
    var availabilityReason: String? = nil
}

struct AutomationCanvasEdge: Identifiable {
    enum Kind {
        case data
        case conditional
        case success
        case parallel
        case error
        case loop

        var tint: Color {
            switch self {
            case .data: KanameColor.accent
            case .conditional: KanameColor.warning
            case .success: KanameColor.success
            case .parallel: KanameColor.blocked
            case .error: KanameColor.danger
            case .loop: KanameColor.external
            }
        }
    }

    let id: String
    let sourceID: String
    let targetID: String
    let label: String
    let kind: Kind
    let active: Bool

    init(_ sourceID: String, _ targetID: String, label: String, kind: Kind, active: Bool) {
        id = "\(sourceID)-\(targetID)-\(label)"
        self.sourceID = sourceID
        self.targetID = targetID
        self.label = label
        self.kind = kind
        self.active = active
    }
}

struct AutomationCanvasGroup: Identifiable {
    let id: String
    let title: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let tint: Color
}

struct AutomationCanvasGraph {
    let defaultSelectedID: String
    let groups: [AutomationCanvasGroup]
    let steps: [AutomationCanvasStep]
    let edges: [AutomationCanvasEdge]

    static func live(
        revision: DesktopWorkflowRevisionRecord,
        availability: [String: LocalCoreRunner.WorkflowNodeAvailabilityDecision] = [:]
    ) -> Self {
        let definitions = revision.steps
        guard !definitions.isEmpty else {
            let empty = AutomationCanvasStep(
                id: "empty", title: "No nodes", subtitle: "Edit this workflow to add its first node",
                symbol: "plus.circle", kind: .data, x: 0.5, y: 0.5, state: .planned,
                input: "No input", output: "No output", authority: "No authority"
            )
            return Self(defaultSelectedID: empty.id, groups: [], steps: [empty], edges: [])
        }

        let ids = Set(definitions.map(\.id))
        var levelByID: [String: Int] = [:]
        let incoming = Dictionary(grouping: definitions.flatMap { step in
            (step.transitions ?? []).map(\.targetStepID).filter { ids.contains($0) }
        }, by: { $0 })
        var queue = definitions.filter { incoming[$0.id] == nil }.map(\.id)
        if queue.isEmpty, let first = definitions.first?.id { queue = [first] }
        for root in queue { levelByID[root] = 0 }
        var cursor = 0
        while cursor < queue.count {
            let sourceID = queue[cursor]
            cursor += 1
            guard let source = definitions.first(where: { $0.id == sourceID }) else { continue }
            let nextLevel = (levelByID[sourceID] ?? 0) + 1
            for target in (source.transitions ?? []).map(\.targetStepID) where ids.contains(target) {
                guard levelByID[target] == nil else { continue }
                levelByID[target] = nextLevel
                queue.append(target)
            }
        }
        var fallbackLevel = (levelByID.values.max() ?? -1) + 1
        for step in definitions where levelByID[step.id] == nil {
            levelByID[step.id] = fallbackLevel
            fallbackLevel += 1
        }
        let maximumLevel = max(1, levelByID.values.max() ?? 1)
        let byLevel = Dictionary(grouping: definitions, by: { levelByID[$0.id] ?? 0 })
        let nodes = definitions.map { step -> AutomationCanvasStep in
            let level = levelByID[step.id] ?? 0
            let peers = byLevel[level] ?? [step]
            let row = peers.firstIndex(where: { $0.id == step.id }) ?? 0
            let y = peers.count == 1 ? 0.5 : 0.14 + (0.72 * CGFloat(row) / CGFloat(peers.count - 1))
            return AutomationCanvasStep(
                id: step.id,
                title: step.name,
                subtitle: step.kind.label,
                symbol: step.kind.automationSymbol,
                kind: step.kind.automationKind,
                x: 0.08 + (0.84 * CGFloat(level) / CGFloat(maximumLevel)),
                y: y,
                state: availability[step.id].map { $0.isExecutable ? .executable : .schemaOnly } ?? .planned,
                input: step.inputSchemaReference ?? "\(step.inputMappings?.count ?? 0) mapped inputs",
                output: step.outputSchemaReference ?? "Typed output",
                authority: step.automationAuthority,
                availabilityReason: availability[step.id].flatMap(\.downgradeCondition)
                    .map(DesktopWorkflowDowngradeConditionPresentation.text(for:))
            )
        }
        var connections = definitions.flatMap { source in
            (source.transitions ?? []).filter { ids.contains($0.targetStepID) }.map { transition in
                AutomationCanvasEdge(
                    source.id,
                    transition.targetStepID,
                    label: transition.outcome.rawValue,
                    kind: transition.outcome.automationEdgeKind,
                    active: false
                )
            }
        }
        if connections.isEmpty, definitions.count > 1 {
            connections = zip(definitions, definitions.dropFirst()).map { source, target in
                AutomationCanvasEdge(source.id, target.id, label: "next", kind: .data, active: false)
            }
        }
        return Self(
            defaultSelectedID: definitions[0].id,
            groups: [
                .init(
                    id: "published", title: "PUBLISHED REVISION \(revision.version)",
                    x: 0.015, y: 0.05, width: 0.97, height: 0.90, tint: KanameColor.accent
                ),
            ],
            steps: nodes,
            edges: connections
        )
    }

    func sourceLines(workflow: AutomationWorkflowPreview) -> [String] {
        let escapedName = workflow.name.replacingOccurrences(of: "\"", with: "\\\"")
        var result = [
            "{",
            "  \"id\": \"\(workflow.id)\",",
            "  \"name\": \"\(escapedName)\",",
            "  \"version\": \"\(workflow.version)\",",
            "  \"nodes\": [",
        ]
        for (index, step) in steps.enumerated() {
            let suffix = index == steps.count - 1 ? "" : ","
            result.append("    { \"id\": \"\(step.id)\", \"type\": \"\(step.kind.label.lowercased())\" }\(suffix)")
        }
        result += ["  ],", "  \"connections\": \(edges.count)", "}"]
        return result
    }

}

private extension DesktopWorkflowStepKind {
    var automationKind: AutomationCanvasNodeKind {
        switch self {
        case .classifyEvent: .trigger
        case .correlateWork, .branch, .match: .decision
        case .compileContext: .context
        case .structuredModel, .agent: .ai
        case .invokeTool: .subflow
        case .registerArtifact: .data
        case .validate: .policy
        case .forEach: .loop
        case .effect, .sendEmail: .effect
        case .humanReview, .requestApproval: .human
        case .createEmailDraft: .data
        case .waitForEmail: .wait
        case .complete: .receipt
        }
    }

    var automationSymbol: String {
        switch self {
        case .classifyEvent: "bolt.fill"
        case .correlateWork: "link"
        case .compileContext: "text.append"
        case .structuredModel: "sparkles"
        case .invokeTool: "wrench.and.screwdriver"
        case .registerArtifact: "doc.badge.plus"
        case .validate: "checkmark.seal"
        case .branch: "arrow.triangle.branch"
        case .match: "arrow.triangle.swap"
        case .forEach: "repeat"
        case .agent: "cpu"
        case .effect: "checkmark.shield"
        case .humanReview: "person.crop.circle"
        case .requestApproval: "person.crop.circle.badge.checkmark"
        case .createEmailDraft: "square.and.pencil"
        case .sendEmail: "paperplane.fill"
        case .waitForEmail: "clock.badge"
        case .complete: "checkmark.circle.fill"
        }
    }
}

private extension DesktopWorkflowStepDefinition {
    var automationAuthority: String {
        switch kind {
        case .effect: "Trusted connector approval"
        case .sendEmail: "Exact send approval"
        case .createEmailDraft: "Draft only"
        case .humanReview, .requestApproval: "Human decision"
        case .waitForEmail, .classifyEvent: "Observe only"
        case .structuredModel, .agent: "Declared model egress"
        default: "No external effect"
        }
    }
}

private extension DesktopWorkflowTransitionOutcome {
    var automationEdgeKind: AutomationCanvasEdge.Kind {
        switch self {
        case .matched, .approved, .selected, .acknowledged, .succeeded: .success
        case .notMatched, .rejected, .edited, .timedOut, .cancelled: .conditional
        case .failed: .error
        case .always: .data
        }
    }
}

struct AutomationNodeCanvas: View {
    let graph: AutomationCanvasGraph
    @Binding var selectedStepID: String
    let isSimulating: Bool
    var viewportPreset: AutomationCanvasViewportPreset = .standard
    var selectedEdgeID: Binding<String?>? = nil
    var isEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let worldSize = CGSize(width: 1_320, height: 620)

    private struct ViewportLayout {
        let scale: CGFloat
        let offset: CGPoint
        let semanticOverview: Bool
        let showsMinimap: Bool

        func position(x: CGFloat, y: CGFloat, worldSize: CGSize) -> CGPoint {
            CGPoint(
                x: x * worldSize.width * scale + offset.x,
                y: y * worldSize.height * scale + offset.y
            )
        }

        func visibleWorldRect(viewportSize: CGSize, worldSize: CGSize) -> CGRect {
            CGRect(
                x: -offset.x / scale,
                y: -offset.y / scale,
                width: viewportSize.width / scale,
                height: viewportSize.height / scale
            )
            .intersection(CGRect(origin: .zero, size: worldSize))
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = viewportLayout(in: proxy.size)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isSimulating)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                ZStack {
                    ForEach(graph.groups) { group in
                        AutomationCanvasGroupView(group: group)
                            .frame(
                                width: group.width * worldSize.width * layout.scale,
                                height: group.height * worldSize.height * layout.scale
                            )
                            .position(layout.position(
                                x: group.x + group.width / 2,
                                y: group.y + group.height / 2,
                                worldSize: worldSize
                            ))
                    }

                    Canvas { context, size in
                        drawEdges(context: &context, size: size, phase: phase, layout: layout)
                    }

                    ForEach(graph.edges) { edge in
                        if let position = edgeLabelPosition(edge, size: proxy.size, layout: layout) {
                            if let selectedEdgeID {
                                Button {
                                    selectedEdgeID.wrappedValue = edge.id
                                } label: {
                                    edgeLabel(edge, selected: selectedEdgeID.wrappedValue == edge.id)
                                }
                                .buttonStyle(.plain)
                                .position(position)
                            } else {
                                edgeLabel(edge, selected: false)
                                    .position(position)
                            }
                        }
                    }

                    ForEach(graph.steps) { step in
                        Button {
                            selectedStepID = step.id
                            selectedEdgeID?.wrappedValue = nil
                        } label: {
                            if layout.semanticOverview {
                                AutomationSemanticNodeCard(
                                    step: step,
                                    selected: selectedStepID == step.id
                                )
                            } else {
                                AutomationNodeCard(
                                    step: step,
                                    selected: selectedStepID == step.id,
                                    animated: isSimulating && step.state == .running && !reduceMotion,
                                    phase: phase,
                                    collapsedSubflow: viewportPreset == .feedbackFocus && step.id == "execute"
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .position(layout.position(x: step.x, y: step.y, worldSize: worldSize))
                    }

                    if isEditing, let firstEdge = graph.edges.first,
                       let position = edgeLabelPosition(firstEdge, size: proxy.size, layout: layout) {
                        Button {
                            selectedEdgeID?.wrappedValue = firstEdge.id
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(KanameColor.canvas)
                                .frame(width: 20, height: 20)
                                .background(KanameColor.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Insert a compatible node on this connection")
                        .position(x: position.x, y: position.y + 24)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Label(viewportPreset.title, systemImage: viewportSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(KanameColor.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(KanameColor.canvas.opacity(0.94), in: Capsule())
                    .overlay { Capsule().stroke(KanameColor.accent.opacity(0.35), lineWidth: 1) }
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if layout.showsMinimap {
                    AutomationCanvasMinimap(
                        graph: graph,
                        worldSize: worldSize,
                        visibleWorldRect: layout.visibleWorldRect(
                            viewportSize: proxy.size,
                            worldSize: worldSize
                        )
                    )
                    .padding(10)
                }
            }
        }
        .background { AutomationDotGrid() }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private var viewportSymbol: String {
        switch viewportPreset {
        case .standard: "viewfinder"
        case .readable: "text.magnifyingglass"
        case .semanticOverview: "arrow.down.right.and.arrow.up.left"
        case .feedbackFocus: "scope"
        }
    }

    private func viewportLayout(in size: CGSize) -> ViewportLayout {
        let fittedScale = min(
            (size.width - 44) / worldSize.width,
            (size.height - 40) / worldSize.height
        )

        switch viewportPreset {
        case .standard:
            let scale = min(1, fittedScale)
            return centeredLayout(scale: scale, size: size, semanticOverview: false, showsMinimap: false)
        case .semanticOverview:
            return centeredLayout(
                scale: min(1, fittedScale),
                size: size,
                semanticOverview: true,
                showsMinimap: false
            )
        case .readable:
            let scale: CGFloat = 1
            let selectedStep = graph.steps.first(where: { $0.id == selectedStepID })
                ?? graph.steps.first(where: { $0.id == graph.defaultSelectedID })
            let focusX = graph.defaultSelectedID == "fanout" && selectedStepID == "fanout"
                ? 0.52
                : (selectedStep?.x ?? 0.5)
            let target = CGPoint(
                x: focusX * worldSize.width,
                y: (selectedStep?.y ?? 0.5) * worldSize.height
            )
            return ViewportLayout(
                scale: scale,
                offset: CGPoint(x: size.width / 2 - target.x, y: size.height / 2 - target.y),
                semanticOverview: false,
                showsMinimap: true
            )
        case .feedbackFocus:
            let focusRect = CGRect(
                x: worldSize.width * 0.32,
                y: worldSize.height * 0.16,
                width: worldSize.width * 0.66,
                height: worldSize.height * 0.78
            )
            let scale = min(
                (size.width - 54) / focusRect.width,
                (size.height - 46) / focusRect.height,
                1
            )
            return ViewportLayout(
                scale: scale,
                offset: CGPoint(
                    x: size.width / 2 - focusRect.midX * scale - 78,
                    y: size.height / 2 - focusRect.midY * scale
                ),
                semanticOverview: false,
                showsMinimap: true
            )
        }
    }

    private func centeredLayout(
        scale: CGFloat,
        size: CGSize,
        semanticOverview: Bool,
        showsMinimap: Bool
    ) -> ViewportLayout {
        ViewportLayout(
            scale: scale,
            offset: CGPoint(
                x: (size.width - worldSize.width * scale) / 2,
                y: (size.height - worldSize.height * scale) / 2
            ),
            semanticOverview: semanticOverview,
            showsMinimap: showsMinimap
        )
    }

    private func edgeLabel(_ edge: AutomationCanvasEdge, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(edge.kind.tint).frame(width: 5, height: 5)
            Text(edge.label)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(edge.kind.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? edge.kind.tint.opacity(0.22) : KanameColor.canvas.opacity(0.94), in: Capsule())
        .overlay {
            if selected { Capsule().stroke(edge.kind.tint, lineWidth: 1.5) }
        }
        .help("Inspect data checkpoint")
    }

    private func drawEdges(
        context: inout GraphicsContext,
        size: CGSize,
        phase: Double,
        layout: ViewportLayout
    ) {
        for edge in graph.edges {
            guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
                  let target = graph.steps.first(where: { $0.id == edge.targetID }) else { continue }
            let route = edgeRoute(edge: edge, source: source, target: target, size: size, layout: layout)
            let selected = selectedEdgeID?.wrappedValue == edge.id
            let tint = selected || edge.active ? edge.kind.tint : KanameColor.separator
            context.stroke(
                route.path,
                with: .color(tint),
                style: StrokeStyle(
                    lineWidth: selected ? 4 : (edge.active ? 2.5 : 1.5),
                    dash: edge.active ? [7, 6] : [],
                    dashPhase: edge.active && isSimulating && !reduceMotion ? -phase * 28 : 0
                )
            )
            drawArrowhead(context: &context, tip: route.end, tangentFrom: route.control2, tint: tint)
        }
    }

    private func edgeRoute(
        edge: AutomationCanvasEdge,
        source: AutomationCanvasStep,
        target: AutomationCanvasStep,
        size: CGSize,
        layout: ViewportLayout
    ) -> (path: Path, end: CGPoint, control2: CGPoint) {
        let sourceCenter = layout.position(x: source.x, y: source.y, worldSize: worldSize)
        let targetCenter = layout.position(x: target.x, y: target.y, worldSize: worldSize)
        let deltaX = targetCenter.x - sourceCenter.x
        let deltaY = targetCenter.y - sourceCenter.y
        let nodeHalfWidth: CGFloat = layout.semanticOverview ? 52 : 77
        let nodeHalfHeight: CGFloat = layout.semanticOverview ? 25 : 36
        var path = Path()

        if edge.kind == .loop {
            if abs(deltaX) < 44 {
                let start = CGPoint(x: sourceCenter.x - nodeHalfWidth, y: sourceCenter.y)
                let end = CGPoint(x: targetCenter.x - nodeHalfWidth, y: targetCenter.y)
                let loopX = max(14, min(start.x, end.x) - 64)
                let control1 = CGPoint(x: loopX, y: start.y)
                let control2 = CGPoint(x: loopX, y: end.y)
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
                return (path, end, control2)
            }

            let start = CGPoint(x: sourceCenter.x + nodeHalfWidth, y: sourceCenter.y)
            let end = CGPoint(x: targetCenter.x - nodeHalfWidth, y: targetCenter.y)
            let loopY = min(size.height - 12, max(start.y, end.y) + 72)
            let control1 = CGPoint(x: start.x + 46, y: loopY)
            let control2 = CGPoint(x: end.x - 46, y: loopY)
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return (path, end, control2)
        }

        if abs(deltaX) >= abs(deltaY) {
            let direction: CGFloat = deltaX >= 0 ? 1 : -1
            let start = CGPoint(x: sourceCenter.x + direction * nodeHalfWidth, y: sourceCenter.y)
            let end = CGPoint(x: targetCenter.x - direction * nodeHalfWidth, y: targetCenter.y)
            let bend = max(22, abs(end.x - start.x) * 0.45)
            let control1 = CGPoint(x: start.x + direction * bend, y: start.y)
            let control2 = CGPoint(x: end.x - direction * bend, y: end.y)
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return (path, end, control2)
        }

        let direction: CGFloat = deltaY >= 0 ? 1 : -1
        let start = CGPoint(x: sourceCenter.x, y: sourceCenter.y + direction * nodeHalfHeight)
        let end = CGPoint(x: targetCenter.x, y: targetCenter.y - direction * nodeHalfHeight)
        let bend = max(18, abs(end.y - start.y) * 0.45)
        let control1 = CGPoint(x: start.x, y: start.y + direction * bend)
        let control2 = CGPoint(x: end.x, y: end.y - direction * bend)
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return (path, end, control2)
    }

    private func drawArrowhead(
        context: inout GraphicsContext,
        tip: CGPoint,
        tangentFrom: CGPoint,
        tint: Color
    ) {
        let angle = atan2(tip.y - tangentFrom.y, tip.x - tangentFrom.x)
        let length: CGFloat = 8
        let width: CGFloat = 4.5
        let base = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let perpendicular = CGPoint(x: -sin(angle) * width, y: cos(angle) * width)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: base.x + perpendicular.x, y: base.y + perpendicular.y))
        arrow.addLine(to: CGPoint(x: base.x - perpendicular.x, y: base.y - perpendicular.y))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(tint))
    }

    private func edgeLabelPosition(
        _ edge: AutomationCanvasEdge,
        size: CGSize,
        layout: ViewportLayout
    ) -> CGPoint? {
        guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
              let target = graph.steps.first(where: { $0.id == edge.targetID }) else { return nil }
        let sourcePosition = layout.position(x: source.x, y: source.y, worldSize: worldSize)
        let targetPosition = layout.position(x: target.x, y: target.y, worldSize: worldSize)
        if edge.kind == .loop, abs(target.x - source.x) < 0.06 {
            return CGPoint(
                x: max(54, sourcePosition.x - 92),
                y: (sourcePosition.y + targetPosition.y) * 0.5
            )
        }
        if edge.kind == .loop || target.x < source.x {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5,
                y: min(size.height - 16, max(sourcePosition.y, targetPosition.y) + 34)
            )
        }
        if abs(target.y - source.y) < 0.05 {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5,
                y: sourcePosition.y - 48
            )
        }
        if abs(target.y - source.y) > abs(target.x - source.x) {
            return CGPoint(
                x: (sourcePosition.x + targetPosition.x) * 0.5 + 18,
                y: (sourcePosition.y + targetPosition.y) * 0.5
            )
        }
        return CGPoint(
            x: (sourcePosition.x + targetPosition.x) * 0.5,
            y: (sourcePosition.y + targetPosition.y) * 0.5 - 10
        )
    }
}

private struct AutomationCanvasMinimap: View {
    let graph: AutomationCanvasGraph
    let worldSize: CGSize
    let visibleWorldRect: CGRect

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Map", systemImage: "map")
                Spacer()
                Text("drag viewport")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 9, weight: .bold))

            Canvas { context, size in
                let scaleX = size.width / worldSize.width
                let scaleY = size.height / worldSize.height
                for edge in graph.edges {
                    guard let source = graph.steps.first(where: { $0.id == edge.sourceID }),
                          let target = graph.steps.first(where: { $0.id == edge.targetID }) else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: source.x * size.width, y: source.y * size.height))
                    path.addLine(to: CGPoint(x: target.x * size.width, y: target.y * size.height))
                    context.stroke(path, with: .color(edge.kind.tint.opacity(0.45)), lineWidth: 1)
                }
                for step in graph.steps {
                    let rect = CGRect(
                        x: step.x * size.width - 3,
                        y: step.y * size.height - 2,
                        width: 6,
                        height: 4
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(step.kind.tint))
                }
                let viewportRect = CGRect(
                    x: visibleWorldRect.minX * scaleX,
                    y: visibleWorldRect.minY * scaleY,
                    width: visibleWorldRect.width * scaleX,
                    height: visibleWorldRect.height * scaleY
                )
                context.fill(Path(viewportRect), with: .color(KanameColor.accent.opacity(0.12)))
                context.stroke(Path(viewportRect), with: .color(KanameColor.accent), lineWidth: 1.5)
            }
            .frame(height: 64)
            .background(KanameColor.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .frame(width: 170)
        .background(KanameColor.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(KanameColor.separator, lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct AutomationSemanticNodeCard: View {
    let step: AutomationCanvasStep
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: step.symbol)
                .foregroundStyle(step.kind.tint)
            Text(step.title)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Circle().fill(step.state.tint).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8)
        .frame(width: 104, height: 50, alignment: .leading)
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? KanameColor.accent : step.kind.tint.opacity(0.45), lineWidth: selected ? 2 : 1)
        }
    }
}

private struct AutomationCanvasGroupView: View {
    let group: AutomationCanvasGroup

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(group.tint.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(group.tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .overlay(alignment: .topLeading) {
                Text(group.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(group.tint.opacity(0.85))
                    .padding(8)
            }
    }
}

struct AutomationDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            for x in stride(from: spacing, to: size.width, by: spacing) {
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    let rect = CGRect(x: x, y: y, width: 1.4, height: 1.4)
                    context.fill(Path(ellipseIn: rect), with: .color(KanameColor.separator.opacity(0.7)))
                }
            }
        }
        .background(KanameColor.canvas.opacity(0.55))
    }
}

private struct AutomationNodeCard: View {
    let step: AutomationCanvasStep
    let selected: Bool
    let animated: Bool
    let phase: Double
    var collapsedSubflow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.kind.label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(step.kind.tint)
            HStack(spacing: 7) {
                Image(systemName: step.symbol).foregroundStyle(step.kind.tint)
                Text(step.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(step.state.tint).frame(width: 6, height: 6)
            }
            Text(step.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if collapsedSubflow {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack")
                    Text("5 internal steps collapsed")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(KanameColor.blocked)
            }
        }
        .padding(10)
        .frame(width: 154, alignment: .leading)
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    selected ? KanameColor.accent : step.kind.tint.opacity(step.state == .running ? 0.9 : 0.30),
                    lineWidth: selected || step.state == .running ? 2 : 1
                )
        }
        .shadow(color: step.kind.tint.opacity(animated ? 0.16 + sin(phase * .pi * 2) * 0.10 : 0), radius: 8)
    }
}
