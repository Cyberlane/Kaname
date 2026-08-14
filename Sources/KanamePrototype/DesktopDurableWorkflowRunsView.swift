import Foundation
import KanameDesktop
import KanameLocalCore
import KanamePrototypeUI
import SwiftUI

@MainActor
final class DesktopDurableWorkflowRunsViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(DesktopWorkflowRunHistorySnapshot)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let loader: DesktopWorkflowRunHistoryLoader

    init(runner: LocalCoreRunner) {
        loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: runner),
            library: DesktopWorkflowV2LibraryClient(transport: runner)
        )
    }

    func load() async {
        guard state == .idle else { return }
        state = .loading
        do {
            state = .loaded(try await loader.load(
                requestID: "workflow-runs:\(UUID().uuidString.lowercased())"
            ))
        } catch {
            state = .failed("Run history is temporarily unavailable. Durable evidence was not treated as empty or successful.")
        }
    }

    func reload() async {
        state = .idle
        await load()
    }
}

struct DesktopDurableWorkflowRunsView: View {
    private enum InspectorGroup: String, CaseIterable, Identifiable {
        case inputs = "Inputs"
        case output = "Output"
        case error = "Error"
        case configuration = "Configuration"
        case matchTrace = "Match trace"
        case timing = "Timing"
        case raw = "Raw events"
        var id: String { rawValue }
    }

    @StateObject private var viewModel: DesktopDurableWorkflowRunsViewModel
    @State private var selectedRunID: String?
    @State private var selectedNodeID: String?
    @State private var inspectorGroup: InspectorGroup = .inputs
    @State private var compactShowsDetail = false
    @State private var zoom = 1.0

    init(runner: LocalCoreRunner) {
        _viewModel = StateObject(wrappedValue: DesktopDurableWorkflowRunsViewModel(runner: runner))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading durable workflow runs…")
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .panelStyle()
            case let .failed(message):
                unavailable(message)
            case let .loaded(snapshot):
                loaded(snapshot)
            }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func loaded(_ history: DesktopWorkflowRunHistorySnapshot) -> some View {
        if history.runs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.largeTitle).foregroundStyle(Nord.frost1)
                Text("No durable workflow runs yet").font(.headline)
                Text(history.absenceReason == "not_found_or_purged"
                    ? "This run was not found or its retained history has been purged."
                    : "Published workflows will appear here after their first local run.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await viewModel.reload() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .panelStyle()
        } else {
            GeometryReader { proxy in
                let compact = proxy.size.width < 1_050
                Group {
                    if compact {
                        if compactShowsDetail, let run = selectedRun(in: history) {
                            runDetail(run, compact: true)
                        } else {
                            runList(history)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            runList(history).frame(width: 290)
                            if let run = selectedRun(in: history) {
                                runDetail(run, compact: false)
                            }
                        }
                    }
                }
                .onAppear { selectInitialRun(in: history) }
            }
            .frame(minHeight: 760)
        }
    }

    private func runList(_ history: DesktopWorkflowRunHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workflow run history").font(.headline)
                    Text("Journal position \(history.projectionHighWaterMark)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await viewModel.reload() } }
                    .labelStyle(.iconOnly)
            }
            ForEach(history.runs) { snapshot in
                Button {
                    select(snapshot)
                    compactShowsDetail = true
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: statusSymbol(snapshot.run.status))
                            .foregroundStyle(statusTint(snapshot.run.status)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.graph?.name ?? snapshot.run.workflowID)
                                .font(.caption.weight(.semibold)).lineLimit(1)
                            Text(snapshot.run.runID)
                                .font(.system(size: 9, design: .monospaced)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(snapshot.run.status.capitalized)
                                if let number = snapshot.revision?.summary.revisionNumber {
                                    Text("v\(number)")
                                } else {
                                    Text("revision unavailable")
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(selectedRunID == snapshot.id ? Nord.frost1.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 14))
    }

    private func runDetail(_ snapshot: DesktopWorkflowRunSnapshot, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if compact {
                    Button("All runs", systemImage: "chevron.left") { compactShowsDetail = false }
                        .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.graph?.name ?? snapshot.run.workflowID).font(.headline)
                    HStack(spacing: 8) {
                        Label(snapshot.run.status.capitalized, systemImage: statusSymbol(snapshot.run.status))
                            .foregroundStyle(statusTint(snapshot.run.status))
                        if let revision = snapshot.revision {
                            Text("Workflow v\(revision.summary.revisionNumber)")
                            Text(revision.summary.revisionID).lineLimit(1)
                        }
                        Label("Historical snapshot", systemImage: "lock.doc")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let reason = snapshot.revisionAbsenceReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow).panelStyle()
            } else if let graph = snapshot.graph {
                canvas(graph, run: snapshot.run)
                    .frame(minHeight: 390)
                inspector(snapshot, graph: graph)
            } else {
                Label("The revision exists, but its historical graph could not be decoded. No empty diagram is shown.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow).panelStyle()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Nord.polarNight1.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func canvas(_ graph: DesktopWorkflowHistoricalGraph, run: DesktopDurableWorkflowRun) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label("Run graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold)).foregroundStyle(Nord.frost1)
                Spacer()
                Button { zoom = max(0.65, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%").font(.system(size: 9, design: .monospaced)).frame(width: 38)
                Button { zoom = min(1.6, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button("Reset zoom") { zoom = 1 }.font(.caption2)
            }
            ScrollView([.horizontal, .vertical]) {
                let size = CGSize(width: 1_260 * zoom, height: 620 * zoom)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in graph.edges {
                            guard let source = graph.nodes.first(where: { $0.id == edge.sourceNodeID }),
                                  let target = graph.nodes.first(where: { $0.id == edge.targetNodeID }) else { continue }
                            var path = Path()
                            path.move(to: CGPoint(x: (source.x + 220) * zoom, y: (source.y + 45) * zoom))
                            path.addCurve(
                                to: CGPoint(x: target.x * zoom, y: (target.y + 45) * zoom),
                                control1: CGPoint(x: (source.x + 290) * zoom, y: (source.y + 45) * zoom),
                                control2: CGPoint(x: (target.x - 70) * zoom, y: (target.y + 45) * zoom)
                            )
                            let admitted = run.edges.contains { $0.edgeID == edge.id && $0.state == "admitted" }
                            context.stroke(path, with: .color(admitted ? Nord.auroraGreen : Nord.polarNight3),
                                           style: StrokeStyle(lineWidth: admitted ? 3 : 1.5, dash: admitted ? [] : [5, 5]))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    ForEach(graph.nodes) { node in
                        let state = run.nodes.first { $0.nodeID == node.id }?.status ?? "not-run"
                        Button {
                            selectedNodeID = node.id
                            inspectorGroup = run.attempt(for: node.id)?.errorCode == nil ? .inputs : .error
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: statusSymbol(state)).foregroundStyle(statusTint(state))
                                    Text(node.name).font(.caption.weight(.bold)).lineLimit(1)
                                }
                                Text(node.type).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                Text(state.capitalized).font(.caption2).foregroundStyle(statusTint(state))
                            }
                            .padding(11)
                            .frame(width: 220 * zoom, height: 90 * zoom, alignment: .leading)
                            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).stroke(
                                selectedNodeID == node.id ? Nord.frost1 : statusTint(state).opacity(0.45),
                                lineWidth: selectedNodeID == node.id ? 2 : 1
                            ) }
                        }
                        .buttonStyle(.plain)
                        .position(x: (node.x + 110) * zoom, y: (node.y + 45) * zoom)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Text("Pan by scrolling · canvas keeps its world size")
                    .font(.system(size: 9)).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private func inspector(_ snapshot: DesktopWorkflowRunSnapshot, graph: DesktopWorkflowHistoricalGraph) -> some View {
        let node = graph.nodes.first { $0.id == selectedNodeID } ?? graph.nodes.first!
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.headline)
                    Text(node.type).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Read-only trace").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Picker("Inspector group", selection: $inspectorGroup) {
                ForEach(InspectorGroup.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            inspectorContent(snapshot, node: node)
                .frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
        }
        .padding(12)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func inspectorContent(_ snapshot: DesktopWorkflowRunSnapshot, node: DesktopWorkflowHistoricalNode) -> some View {
        let run = snapshot.run
        switch inspectorGroup {
        case .inputs:
            valueList(run.inputs(for: node.id), empty: "This node has no admitted input checkpoint.")
        case .output:
            valueList(run.outputs(for: node.id), empty: "This node produced no output emission.")
        case .error:
            if let attempt = run.attempt(for: node.id), let code = attempt.errorCode {
                evidenceCard(title: code, detail: attempt.error.flatMap(valueText) ?? "No error payload was retained.")
            } else {
                explainedEmpty("This attempt did not report an error.")
            }
        case .configuration:
            codeBlock(String(decoding: node.configurationJSON, as: UTF8.self))
        case .matchTrace:
            let traces = run.traces(for: node.id)
            if traces.isEmpty { explainedEmpty("This node did not record a Match evaluation trace.") }
            else {
                ForEach(traces) { trace in
                    evidenceCard(
                        title: "Matched: \(trace.matchedCaseIDs.joined(separator: ", ").nilIfBlank ?? "none")",
                        detail: valueText(trace.trace)
                    )
                }
            }
        case .timing:
            if let attempt = run.attempt(for: node.id) {
                evidenceCard(
                    title: "Attempt \(attempt.number) · \(attempt.status)",
                    detail: "Started \(attempt.startedAtUnixMillis) · settled \(attempt.settledAtUnixMillis.map(String.init) ?? "not settled") · journal \(attempt.startedStorePosition)…\(attempt.settledStorePosition.map(String.init) ?? "—")"
                )
            } else { explainedEmpty("This node has no recorded attempt timing.") }
        case .raw:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.events) { event in
                    HStack {
                        Text("#\(event.storePosition)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Nord.frost1)
                        Text(event.kind).font(.caption2)
                        Spacer()
                        Text(event.eventID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func valueList(_ emissions: [DesktopWorkflowProjectedEmission], empty: String) -> some View {
        if emissions.isEmpty { explainedEmpty(empty) }
        else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(emissions) { emission in
                    evidenceCard(title: emission.portID, detail: valueText(emission.value))
                }
            }
        }
    }

    private func valueText(_ value: DesktopWorkflowProjectedValue) -> String {
        value.inlineCanonicalJSON.map { String(decoding: $0, as: UTF8.self) }
            ?? value.absenceExplanation
            ?? "Value content unavailable."
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
    }

    private func evidenceCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Nord.frost1)
            Text(detail).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
    }

    private func explainedEmpty(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Label("Workflow run history unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(Nord.auroraYellow)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await viewModel.reload() } }
        }
        .frame(maxWidth: .infinity, minHeight: 220).panelStyle()
    }

    private func selectedRun(in history: DesktopWorkflowRunHistorySnapshot) -> DesktopWorkflowRunSnapshot? {
        history.runs.first { $0.id == selectedRunID } ?? history.runs.first
    }

    private func selectInitialRun(in history: DesktopWorkflowRunHistorySnapshot) {
        guard selectedRunID == nil, let first = history.runs.first else { return }
        select(first)
    }

    private func select(_ snapshot: DesktopWorkflowRunSnapshot) {
        selectedRunID = snapshot.id
        selectedNodeID = snapshot.graph?.nodes.first?.id
        inspectorGroup = .inputs
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle.fill"
        case "running", "cancelling": "arrow.triangle.2.circlepath"
        default: "circle.dashed"
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "succeeded": Nord.auroraGreen
        case "failed": Nord.auroraRed
        case "cancelled": Nord.auroraYellow
        case "running", "cancelling": Nord.frost1
        default: .secondary
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
