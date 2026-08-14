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
        case storage = "Storage"
        case tokens = "Tokens"
        case control = "Control flow"
        case subflow = "Child workflow"
        case caseContext = "Case context"
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
                            inspectorGroup = node.type.hasPrefix("storage.")
                                ? .storage
                                : (node.type == "data.case-context" ? .caseContext
                                : (node.type == "control.subflow" ? .subflow
                                : (run.attempt(for: node.id)?.errorCode == nil ? .inputs : .error)
                                )
                                )
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(InspectorGroup.allCases) { group in
                        Button(group.rawValue) { inspectorGroup = group }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                inspectorGroup == group ? Nord.frost1.opacity(0.22) : Nord.polarNight0,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    inspectorGroup == group ? Nord.frost1 : Nord.polarNight3,
                                    lineWidth: 1
                                )
                            }
                    }
                }
            }
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
        case .storage:
            let values = (run.inputs(for: node.id) + run.outputs(for: node.id))
                .compactMap { emission -> (String, DesktopWorkflowStorageValueMetadata)? in
                    emission.value.storage.map { (emission.portID, $0) }
                }
            if values.isEmpty {
                explainedEmpty("This node did not use a scoped storage handle.")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                        storageCard(port: item.0, metadata: item.1)
                    }
                }
            }
        case .tokens:
            let attemptTokenIDs = Set(run.attempts.filter { $0.nodeID == node.id }.compactMap(\.executionTokenID))
            let tokens = run.executionTokens.filter {
                attemptTokenIDs.contains($0.executionTokenID)
                    || $0.forkNodeID == node.id
                    || $0.joinNodeID == node.id
                    || $0.iterationNodeID == node.id
                    || $0.resumeNodeID == node.id
                    || $0.terminalNodeID == node.id
            }
            let joins = run.joins.filter { $0.forkNodeID == node.id || $0.joinNodeID == node.id }
            if tokens.isEmpty, joins.isEmpty {
                explainedEmpty("This node did not create, consume, resume, or settle an execution token.")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tokens) { token in
                        evidenceCard(
                            title: "\(token.status.capitalized) · \(token.branchPortID ?? "execution path")",
                            detail: "Token \(token.executionTokenID)\nParent \(token.parentExecutionTokenID ?? "root")\nFork \(token.forkNodeID ?? "—") · Join \(token.joinNodeID ?? "—")\nIteration \(token.iterationNodeID ?? "—") \(token.iterationIndex.map { "item \($0 + 1)/\(token.iterationCount ?? 0)" } ?? "")\nResume \(token.resumeNodeID ?? "—") \(token.resumeReason ?? "")\nJournal \(token.createdStorePosition)…\(token.settledStorePosition.map(String.init) ?? "active")"
                        )
                    }
                    ForEach(joins) { join in
                        evidenceCard(
                            title: "Join \(join.decision) · \(join.policy) \(join.threshold)/\(join.expectedExecutionTokenIDs.count)",
                            detail: "Arrived \(join.arrivedExecutionTokenIDs.count) · failed \(join.failedExecutionTokenIDs.count) · pending at decision \(join.pendingExecutionTokenIDs.count)\nResume \(join.resumedExecutionTokenID)\nCancel remaining: \(join.cancelRemaining ? "yes" : "no")"
                        )
                    }
                }
            }
        case .control:
            let iterations = run.iterations.filter { $0.iterationNodeID == node.id }
            let retries = run.retries.filter {
                $0.retryNodeID == node.id || $0.targetNodeID == node.id
            }
            let waits = run.waits.filter { $0.waitNodeID == node.id }
            if iterations.isEmpty, retries.isEmpty, waits.isEmpty {
                explainedEmpty("This node has no iteration, retry, or durable wait evidence.")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(iterations) { iteration in
                        evidenceCard(
                            title: "Iteration \(iteration.decision ?? "running") · \(iteration.failurePolicy)",
                            detail: "Items \(iteration.itemCount)/\(iteration.maximumItems) · concurrency \(iteration.maximumConcurrency)\nSucceeded \(iteration.succeededExecutionTokenIDs.count) · failed \(iteration.failedExecutionTokenIDs.count) · pending at decision \(iteration.pendingExecutionTokenIDs.count)\nResume \(iteration.resumedExecutionTokenID ?? "not yet")\nJournal \(iteration.plannedStorePosition)…\(iteration.evaluatedStorePosition.map(String.init) ?? "active")"
                        )
                    }
                    ForEach(retries) { retry in
                        evidenceCard(
                            title: "Retry \(retry.decision) · attempt \(retry.nextAttemptNumber)/\(retry.maximumAttempts)",
                            detail: "Target \(retry.targetNodeID)\nError \(retry.errorCode)\nDelay \(retry.delayMilliseconds) ms · eligible \(retry.eligibleAtUnixMillis.map(String.init) ?? "not scheduled")\nJournal \(retry.storePosition)"
                        )
                    }
                    ForEach(waits) { wait in
                        let correlation = wait.correlation
                            .map { "\($0.key)=\($0.sha256.prefix(12))…" }
                            .joined(separator: "\n")
                        let signal = wait.resolvingSignalID.flatMap { signalID in
                            run.waitSignals.first { $0.signalID == signalID }
                        }
                        let observed = run.waitSignals.filter {
                            $0.kind == wait.kind
                                && $0.ownerKind == wait.ownerKind
                                && $0.ownerID == wait.ownerID
                        }.map {
                            let match = $0.correlation == wait.correlation ? "exact" : "correlation mismatch"
                            return "\($0.signalID) · \(match) · journal \($0.storePosition)"
                        }.joined(separator: "\n")
                        evidenceCard(
                            title: "\(wait.kind.capitalized) wait · \(wait.status)",
                            detail: "Subscription \(wait.subscriptionID)\nOwner \(wait.ownerKind):\(wait.ownerID)\nCorrelation\n\(correlation)\nExpires \(wait.expiresAtUnixMillis)\nSignal \(wait.resolvingSignalID ?? "not received")\(signal.map { " at journal \($0.storePosition)" } ?? "")\nObserved signals\n\(observed.nilIfBlank ?? "none")\nPinned revision \(wait.revisionID)\nJournal \(wait.subscribedStorePosition)…\(wait.resolvedStorePosition.map(String.init) ?? "active")"
                        )
                    }
                }
            }
        case .subflow:
            subflowInspector(run.subflows.filter { $0.nodeID == node.id })
        case .caseContext:
            caseContextInspector(run.episode)
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
    private func subflowInspector(_ subflows: [DesktopWorkflowProjectedSubflow]) -> some View {
        if subflows.isEmpty {
            explainedEmpty("This node has no recorded child-workflow invocation.")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(subflows) { subflow in
                    subflowEvidence(subflow)
                }
            }
        }
    }

    @ViewBuilder
    private func subflowEvidence(_ subflow: DesktopWorkflowProjectedSubflow) -> some View {
        let settledPosition = subflow.settledStorePosition.map(String.init) ?? "active"
        let settledTime = subflow.settledAtUnixMillis.map(String.init) ?? "active"
        let identity = """
        Child run \(subflow.childRunID)
        Child command \(subflow.childCommandID)
        Workflow \(subflow.childWorkflowID)
        Revision \(subflow.childRevisionID)
        Package \(subflow.childPackageID)
        Digest \(subflow.childPackageDigest)
        Entrypoint \(subflow.entrypoint)
        Called at \(subflow.calledAtUnixMillis)
        Settled at \(settledTime)
        Journal \(subflow.calledStorePosition)…\(settledPosition)
        """
        evidenceCard(
            title: "\(subflow.status.capitalized) · \(subflow.outcome?.capitalized ?? "waiting")",
            detail: identity
        )
        evidenceCard(title: "Input", detail: valueText(subflow.input))
        if let output = subflow.output {
            evidenceCard(
                title: "Output · \(subflow.childFinalEmissionIDs.count) child emission(s)",
                detail: valueText(output)
            )
        }
        if let error = subflow.error {
            evidenceCard(
                title: subflow.errorCode ?? "Child workflow error",
                detail: valueText(error)
            )
        }
    }

    @ViewBuilder
    private func caseContextInspector(_ episode: DesktopWorkflowProjectedCaseEpisode?) -> some View {
        if let episode {
            let sourceSummary = "Sources " + String(episode.sourceEpisodeIDs.count)
                + " episodes · " + String(episode.sourceEventIDs.count) + " journal facts"
            let detail = [
                "Case " + episode.caseID,
                "Episode " + episode.episodeID,
                "Prior " + (episode.priorEpisodeID ?? "none"),
                "Trigger " + episode.triggerKind + " · " + (episode.triggerEventID ?? "no native event"),
                sourceSummary,
                "Journal " + String(episode.startedStorePosition),
            ].joined(separator: "\n")
            VStack(alignment: .leading, spacing: 7) {
                evidenceCard(
                    title: "Episode " + String(episode.ordinal) + " · " + episode.kind.capitalized,
                    detail: detail
                )
                ForEach(Array(episode.inputs.enumerated()), id: \.offset) { _, input in
                    evidenceCard(
                        title: "Current input · " + input.portID,
                        detail: valueText(input.value)
                    )
                }
                evidenceCard(
                    title: "Compiled context · " + String(episode.compiledContext.byteCount) + " bytes",
                    detail: valueText(episode.compiledContext)
                )
            }
        } else {
            explainedEmpty("This run is not attached to a durable case episode.")
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

    private func storageCard(
        port: String,
        metadata: DesktopWorkflowStorageValueMetadata
    ) -> some View {
        let version = metadata.revision.map { "r\($0) · \(metadata.versionID ?? "—")" } ?? "No single version"
        let lineage = metadata.previousVersionID ?? "First version"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(metadata.result.capitalized, systemImage: "externaldrive.badge.checkmark")
                    .font(.caption.weight(.bold)).foregroundStyle(Nord.frost1)
                Spacer()
                Text(port).font(.caption2).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                storageRow("Scope", metadata.scope.capitalized)
                storageRow("Key", metadata.logicalKey)
                storageRow("Version", version)
                storageRow("Lineage", lineage)
                if let sourceVersionID = metadata.sourceVersionID {
                    storageRow("Promoted from", sourceVersionID)
                }
                storageRow("Bytes", String(metadata.byteCount))
                storageRow("Handle", metadata.handleID ?? "Summary only")
            }
        }
        .padding(9)
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
    }

    private func storageRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }
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
