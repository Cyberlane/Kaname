import KanameDesktop
import SwiftUI

struct WorkflowV2ReadOnlyPreviewSheet: View {
    let preview: DesktopWorkflowLegacyImportResult

    @Environment(\.dismiss) private var dismiss
    @State private var mode = WorkflowV2PreviewMode.commandLineDefault
    @State private var selectedNodeID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch mode {
                case .canvas:
                    WorkflowV2CanvasPreview(
                        preview: preview,
                        selectedNodeID: $selectedNodeID
                    )
                case .outline:
                    WorkflowV2OutlinePreview(
                        preview: preview,
                        selectedNodeID: $selectedNodeID
                    )
                case .source:
                    WorkflowV2SourcePreview(preview: preview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            WorkflowV2ImportProblems(preview: preview)
        }
        .frame(minWidth: 920, idealWidth: 1_280, minHeight: 680, idealHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(preview.workflow.name).font(.title3.weight(.semibold))
                    Text("READ-ONLY V2 DRAFT")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(.white)
                        .background(Color.indigo, in: Capsule())
                }
                Text(preview.isLossless
                    ? "The legacy snapshot converted without a known semantic loss."
                    : "Review \(preview.losses.count) blocking import item\(preview.losses.count == 1 ? "" : "s") before this draft can be published.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("View", selection: $mode) {
                ForEach(WorkflowV2PreviewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 320)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

private enum WorkflowV2PreviewMode: String, CaseIterable, Identifiable {
    case outline
    case canvas
    case source

    var id: Self { self }
    static var commandLineDefault: Self {
        if CommandLine.arguments.contains("--desktop-workflow-legacy-import-source") { return .source }
        if CommandLine.arguments.contains("--desktop-workflow-legacy-import-outline") { return .outline }
        return .canvas
    }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .canvas: "point.3.connected.trianglepath.dotted"
        case .source: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct WorkflowV2CanvasPreview: View {
    let preview: DesktopWorkflowLegacyImportResult
    @Binding var selectedNodeID: String?
    @State private var zoom = 1.0

    private let nodeSize = CGSize(width: 236, height: 94)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Scrollable canvas", systemImage: "move.3d")
                    .font(.caption.weight(.semibold))
                Text("The graph keeps its own size; resizing the window reveals scrollbars instead of compressing nodes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { zoom = max(0.65, zoom - 0.1) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 42)
                Button { zoom = min(1.5, zoom + 0.1) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button("100%") { zoom = 1 }
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    WorkflowV2EdgeLayer(
                        edges: preview.workflow.graph.edges,
                        positions: positions,
                        nodeSize: nodeSize,
                        zoom: zoom
                    )
                    ForEach(preview.workflow.graph.nodes) { node in
                        if let point = positions[node.id] {
                            WorkflowV2NodeCard(
                                node: node,
                                selected: selectedNodeID == node.id
                            )
                            .frame(width: nodeSize.width, height: nodeSize.height)
                            .scaleEffect(zoom)
                            .position(
                                x: (point.x + nodeSize.width / 2) * zoom,
                                y: (point.y + nodeSize.height / 2) * zoom
                            )
                            .onTapGesture { selectedNodeID = node.id }
                        }
                    }
                }
                .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
                .background(
                    Canvas { context, size in
                        let spacing = 24.0 * zoom
                        var path = Path()
                        for axis in 0...1 {
                            let extent = axis == 0 ? size.width : size.height
                            stride(from: 0.0, through: extent, by: spacing).forEach { offset in
                                let start = axis == 0
                                    ? CGPoint(x: offset, y: 0)
                                    : CGPoint(x: 0, y: offset)
                                let end = axis == 0
                                    ? CGPoint(x: offset, y: size.height)
                                    : CGPoint(x: size.width, y: offset)
                                path.move(to: start)
                                path.addLine(to: end)
                            }
                        }
                        context.stroke(path, with: .color(.secondary.opacity(0.08)), lineWidth: 1)
                    }
                )
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }
    }

    private var positions: [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: preview.layout.nodes.map {
            ($0.nodeId, CGPoint(x: $0.x, y: $0.y))
        })
    }

    private var canvasSize: CGSize {
        CGSize(
            width: max(1_180, (preview.layout.nodes.map(\.x).max() ?? 0) + nodeSize.width + 180),
            height: max(680, (preview.layout.nodes.map(\.y).max() ?? 0) + nodeSize.height + 180)
        )
    }
}

private struct WorkflowV2EdgeLayer: View {
    let edges: [DesktopWorkflowV1EdgeDocument]
    let positions: [String: CGPoint]
    let nodeSize: CGSize
    let zoom: Double

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let from = positions[edge.from.nodeId], let to = positions[edge.to.nodeId] else { continue }
                let start = CGPoint(
                    x: (from.x + nodeSize.width) * zoom,
                    y: (from.y + nodeSize.height / 2) * zoom
                )
                let end = CGPoint(x: to.x * zoom, y: (to.y + nodeSize.height / 2) * zoom)
                let bend = max(60 * zoom, abs(end.x - start.x) * 0.42)
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + bend, y: start.y),
                    control2: CGPoint(x: end.x - bend, y: end.y)
                )
                context.stroke(
                    path,
                    with: .color(routeColor(edge.from.portId).opacity(0.9)),
                    style: StrokeStyle(lineWidth: max(1.5, 2 * zoom), lineCap: .round)
                )
                let arrow = Path { arrow in
                    arrow.move(to: end)
                    arrow.addLine(to: CGPoint(x: end.x - 9 * zoom, y: end.y - 5 * zoom))
                    arrow.addLine(to: CGPoint(x: end.x - 9 * zoom, y: end.y + 5 * zoom))
                    arrow.closeSubpath()
                }
                context.fill(arrow, with: .color(routeColor(edge.from.portId)))
            }
        }
        .allowsHitTesting(false)
    }

    private func routeColor(_ port: String) -> Color {
        if port == "error" || port == "expired" { return .red }
        if port.hasPrefix("case-") { return .indigo }
        return .blue
    }
}

private struct WorkflowV2NodeCard: View {
    let node: DesktopWorkflowV1NodeDocument
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(node.type).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(String(node.id.prefix(13)) + "…")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? tint : Color.secondary.opacity(0.24), lineWidth: selected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.09), radius: 8, y: 3)
    }

    private var tint: Color {
        if node.type.hasPrefix("trigger.") { return .green }
        if node.type.hasPrefix("control.") { return .indigo }
        if node.type.hasPrefix("effect.") { return .orange }
        if node.type.hasPrefix("terminal.") { return .mint }
        return .blue
    }

    private var symbol: String {
        if node.type.hasPrefix("trigger.") { return "bolt.fill" }
        if node.type == "control.match" { return "arrow.triangle.branch" }
        if node.type.hasPrefix("control.") { return "point.3.connected.trianglepath.dotted" }
        if node.type.hasPrefix("effect.") { return "externaldrive.badge.checkmark" }
        if node.type.hasPrefix("terminal.") { return "checkmark.circle.fill" }
        return "square.stack.3d.up.fill"
    }
}

private struct WorkflowV2OutlinePreview: View {
    let preview: DesktopWorkflowLegacyImportResult
    @Binding var selectedNodeID: String?

    var body: some View {
        HSplitView {
            List(selection: $selectedNodeID) {
                Section("Entrypoints") {
                    ForEach(preview.workflow.graph.entrypoints) { entrypoint in
                        Label(entrypoint.key ?? "Entrypoint", systemImage: "bolt.fill")
                            .tag(entrypoint.nodeId)
                    }
                }
                Section("Nodes") {
                    ForEach(orderedNodes) { node in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name).font(.callout.weight(.semibold))
                            Text(node.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                            let outgoing = preview.workflow.graph.edges.filter { $0.from.nodeId == node.id }
                            if !outgoing.isEmpty {
                                Text(outgoing.map { "\($0.from.portId) → \(nodeName($0.to.nodeId))" }.joined(separator: "  ·  "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(node.id)
                    }
                }
            }
            .frame(minWidth: 380, idealWidth: 480)
            WorkflowV2NodeInspector(node: selectedNode)
                .frame(minWidth: 360, idealWidth: 520)
        }
    }

    private var orderedNodes: [DesktopWorkflowV1NodeDocument] {
        let positions = Dictionary(uniqueKeysWithValues: preview.layout.nodes.map { ($0.nodeId, ($0.x, $0.y)) })
        return preview.workflow.graph.nodes.sorted {
            let lhs = positions[$0.id] ?? (.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            let rhs = positions[$1.id] ?? (.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
    }

    private var selectedNode: DesktopWorkflowV1NodeDocument? {
        guard let selectedNodeID else { return orderedNodes.first }
        return preview.workflow.graph.nodes.first { $0.id == selectedNodeID }
    }

    private func nodeName(_ id: String) -> String {
        preview.workflow.graph.nodes.first { $0.id == id }?.name ?? String(id.prefix(8))
    }
}

private struct WorkflowV2NodeInspector: View {
    let node: DesktopWorkflowV1NodeDocument?

    var body: some View {
        ScrollView {
            if let node {
                VStack(alignment: .leading, spacing: 14) {
                    Text(node.name).font(.title3.weight(.semibold))
                    LabeledContent("Type", value: "\(node.type) · v\(node.typeVersion)")
                    LabeledContent("Stable key", value: node.key)
                    LabeledContent("Node ID", value: node.id)
                    Divider()
                    Text("Configuration").font(.headline)
                    Text(prettyJSON(node.config))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Select a node").font(.headline)
                    Text("Its stable identity and imported configuration will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
    }
}

private struct WorkflowV2SourcePreview: View {
    let preview: DesktopWorkflowLegacyImportResult

    var body: some View {
        HSplitView {
            sourcePanel(title: "workflow.json", contents: prettyJSONSource(preview.canonicalSource))
            sourcePanel(title: "layout.json", contents: prettyJSONSource(preview.canonicalLayoutSource))
        }
    }

    private func sourcePanel(title: String, contents: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(contents)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
        }
        .frame(minWidth: 420)
    }
}

private struct WorkflowV2ImportProblems: View {
    let preview: DesktopWorkflowLegacyImportResult
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if preview.losses.isEmpty {
                Label("No known semantic loss was found in this import.", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.losses) { loss in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loss.summary).font(.caption.weight(.semibold))
                                    Text("\(loss.code) · \(loss.pointer)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(.top, 8)
            }
        } label: {
            HStack {
                Label(
                    preview.losses.isEmpty ? "Import report · clear" : "Import report · \(preview.losses.count) blocking",
                    systemImage: preview.losses.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                Spacer()
                Text(preview.sourceDigest).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

private func prettyJSON(_ value: DesktopWorkflowJSONValue) -> String {
    guard let data = try? JSONEncoder.prettyWorkflowPreview.encode(value) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func prettyJSONSource(_ source: String) -> String {
    guard let data = source.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return source
    }
    return String(data: formatted, encoding: .utf8) ?? source
}

private extension JSONEncoder {
    static var prettyWorkflowPreview: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
