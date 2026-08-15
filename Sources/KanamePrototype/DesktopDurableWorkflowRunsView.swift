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
    private let loader: DesktopWorkflowRunHistoryLoader?
    private let purgeClient: DesktopWorkflowRunPurgeClient?

    init(runner: LocalCoreRunner) {
        purgeClient = DesktopWorkflowRunPurgeClient(transport: runner)
        loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: runner),
            library: DesktopWorkflowV2LibraryClient(transport: runner)
        )
    }

    init(snapshot: DesktopWorkflowRunHistorySnapshot) {
        state = .loaded(snapshot)
        loader = nil
        purgeClient = nil
    }

    func load() async {
        guard state == .idle else { return }
        state = .loading
        do {
            guard let loader else { return }
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

    func purge(_ run: DesktopDurableWorkflowRun) async {
        guard run.purgePreview.manualEligible, let purgeClient else { return }
        state = .loading
        do {
            _ = try await purgeClient.purge(
                run,
                requestID: "workflow-purge:\(UUID().uuidString.lowercased())"
            )
            state = .idle
            await load()
        } catch {
            state = .failed("The purge did not complete. Its durable tombstone and cleanup state will be recovered safely on retry.")
        }
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
        case effect = "Effect"
        case capability = "Capability"
        case llm = "LLM"
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
    @State private var llmSearchText = ""
    @State private var expandedLlmGroups: Set<String> = []
    @State private var showingPurgePreview = false
    @State private var showingPurgeConfirmation = false
    private let qualificationFixture: Bool

    init(runner: LocalCoreRunner) {
        qualificationFixture = false
        _viewModel = StateObject(wrappedValue: DesktopDurableWorkflowRunsViewModel(runner: runner))
    }

    init(snapshot: DesktopWorkflowRunHistorySnapshot, qualificationFixture: Bool = false) {
        self.qualificationFixture = qualificationFixture
        _viewModel = StateObject(wrappedValue: DesktopDurableWorkflowRunsViewModel(snapshot: snapshot))
        _compactShowsDetail = State(initialValue: true)
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
                let compact = DesktopWorkflowLlmInspectionPresentation.layout(
                    for: proxy.size.width
                ) == .compact
                let effectCompact = compact
                    || DesktopWorkflowEffectLifecyclePresentation.layout(
                        for: max(0, proxy.size.width - 302)
                    ) == .compact
                Group {
                    if compact {
                        if compactShowsDetail, let run = selectedRun(in: history) {
                            runDetail(run, compact: true, effectCompact: true)
                        } else {
                            runList(history)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            runList(history).frame(width: 290)
                            if let run = selectedRun(in: history) {
                                runDetail(run, compact: false, effectCompact: effectCompact)
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
                            if let effect = snapshot.run.effectAuthorities.last {
                                Label(
                                    DesktopWorkflowEffectLifecyclePresentation.title(for: effect.status),
                                    systemImage: effectStatusSymbol(effect.status)
                                )
                                .font(.caption2)
                                .foregroundStyle(effectStatusTint(effect.status))
                                .lineLimit(1)
                            }
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

    private func runDetail(
        _ snapshot: DesktopWorkflowRunSnapshot,
        compact: Bool,
        effectCompact: Bool
    ) -> some View {
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
            effectLifecycleSummary(snapshot.run.effectAuthorities, compact: effectCompact)
            retentionCard(snapshot.run)
            if let reason = snapshot.revisionAbsenceReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Nord.auroraYellow).panelStyle()
            } else if let graph = snapshot.graph {
                canvas(graph, run: snapshot.run)
                    .frame(height: qualificationFixture ? 220 : nil)
                    .frame(minHeight: qualificationFixture ? nil : 390)
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

    @ViewBuilder
    private func effectLifecycleSummary(
        _ effects: [DesktopWorkflowProjectedEffectAuthority],
        compact: Bool
    ) -> some View {
        if !effects.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Effect lifecycle", systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Nord.frost1)
                    Spacer()
                    Text("\(effects.count) exact effect\(effects.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(effects) { effect in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(effect.action) · \(effect.connectorClass)")
                                    .font(.caption.weight(.bold))
                                Text(effect.effectID)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Label(
                                DesktopWorkflowEffectLifecyclePresentation.title(for: effect.status),
                                systemImage: effectStatusSymbol(effect.status)
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(effectStatusTint(effect.status))
                        }
                        if compact {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(DesktopWorkflowEffectLifecyclePresentation.steps(for: effect.status)) {
                                    effectStep($0)
                                }
                            }
                        } else {
                            HStack(spacing: 5) {
                                ForEach(DesktopWorkflowEffectLifecyclePresentation.steps(for: effect.status)) {
                                    effectStep($0).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        Label(
                            DesktopWorkflowEffectLifecyclePresentation.nextAction(for: effect.status),
                            systemImage: DesktopWorkflowEffectLifecyclePresentation.requiresAttention(effect.status)
                                ? "hand.raised.fill" : "checkmark.shield.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            DesktopWorkflowEffectLifecyclePresentation.requiresAttention(effect.status)
                                ? Nord.auroraYellow : .secondary
                        )
                    }
                    .padding(9)
                    .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
            .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func effectStep(_ step: DesktopWorkflowEffectLifecycleStep) -> some View {
        Label(step.title, systemImage: effectStepSymbol(step.state))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(effectStepTint(step.state))
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(effectStepTint(step.state).opacity(0.11), in: Capsule())
    }

    private func retentionCard(_ run: DesktopDurableWorkflowRun) -> some View {
        let preview = run.purgePreview
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Label(run.retentionPolicy.summary, systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let reason = preview.protectedReason {
                    Label(retentionProtectionLabel(reason), systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(Nord.auroraYellow)
                } else if preview.automaticEligible {
                    Text("Eligible now").font(.caption2).foregroundStyle(Nord.auroraGreen)
                } else if let eligibleAt = preview.automaticEligibleAtUnixMillis {
                    Text(Date(timeIntervalSince1970: Double(eligibleAt) / 1_000), style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Review deletion…", systemImage: "trash") {
                    showingPurgePreview.toggle()
                }
                .buttonStyle(.bordered)
            }
            if showingPurgePreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deletion preview").font(.caption.weight(.semibold))
                    Text("\(preview.affectedAttemptIDs.count) attempts · \(preview.affectedEffectIDs.count) effect grants · \(preview.affectedValueIDs.count) values · \(preview.affectedFileHandleIDs.count) files · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: preview.affectedValueBytes), countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !preview.retainedPromotedHandleIDs.isEmpty {
                        Label("\(preview.retainedPromotedHandleIDs.count) promoted objects will be retained", systemImage: "archivebox.fill")
                            .font(.caption2).foregroundStyle(Nord.auroraGreen)
                    }
                    retentionIdentifiers("Attempts", preview.affectedAttemptIDs)
                    retentionIdentifiers("Values", preview.affectedValueIDs)
                    retentionIdentifiers("Files", preview.affectedFileHandleIDs)
                    retentionIdentifiers("Retained promoted", preview.retainedPromotedHandleIDs)
                    Text("Evidence \(preview.evidenceDigest)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                    Button("Delete retained run data", systemImage: "trash", role: .destructive) {
                        showingPurgeConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Nord.auroraRed)
                    .disabled(!preview.manualEligible)
                }
                .padding(9)
                .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            "Delete this run's retained data?",
            isPresented: $showingPurgeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete run data", role: .destructive) {
                Task { await viewModel.purge(run) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The workflow revision and promoted case or workflow objects remain. Detailed run events, job values, and job files will be removed behind an auditable tombstone.")
        }
    }

    @ViewBuilder
    private func retentionIdentifiers(_ title: String, _ identifiers: [String]) -> some View {
        if !identifiers.isEmpty {
            Text("\(title): \(identifiers.joined(separator: ", "))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }
    }

    private func retentionProtectionLabel(_ reason: String) -> String {
        switch reason {
        case "waiting": "Waiting run protected"
        case "approval_pending": "Approval-pending run protected"
        case "effect_authorized": "Authorized effect protected"
        case "unknown_outcome": "Unknown outcome protected"
        case "run_not_settled": "Active run protected"
        case "case_episode": "Case episode protected"
        default: "Run protected"
        }
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
                        let effect = run.effects(for: node.id).last
                        Button {
                            selectedNodeID = node.id
                            inspectorGroup = effect != nil
                                ? .effect
                                : (node.type.hasPrefix("storage.")
                                    ? .storage
                                    : (node.type == "data.case-context" ? .caseContext
                                    : (node.type == "control.subflow" ? .subflow
                                    : (run.attempt(for: node.id)?.errorCode == nil ? .inputs : .error)
                                    )
                                    ))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: statusSymbol(state)).foregroundStyle(statusTint(state))
                                    Text(node.name).font(.caption.weight(.bold)).lineLimit(1)
                                }
                                Text(node.type).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    Text(state.capitalized).foregroundStyle(statusTint(state))
                                    if let effect {
                                        Text("·").foregroundStyle(.secondary)
                                        Text(DesktopWorkflowEffectLifecyclePresentation.title(for: effect.status))
                                            .foregroundStyle(effectStatusTint(effect.status))
                                            .lineLimit(1)
                                    }
                                }
                                .font(.caption2)
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
        case .effect:
            effectInspector(run.effects(for: node.id))
        case .subflow:
            subflowInspector(run.subflows.filter { $0.nodeID == node.id })
        case .capability:
            capabilityInspector(run.capabilities(for: node.id))
        case .llm:
            llmInspector(run.llmAttempts(for: node.id))
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
    private func effectInspector(_ effects: [DesktopWorkflowProjectedEffectAuthority]) -> some View {
        if effects.isEmpty {
            explainedEmpty("This node has no proposed or executed effect evidence.")
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(effects) { effect in
                    evidenceCard(
                        title: DesktopWorkflowEffectLifecyclePresentation.title(for: effect.status),
                        detail: "Effect \(effect.effectID)\nAction \(effect.action) · connector \(effect.connectorClass)\nNext action: \(DesktopWorkflowEffectLifecyclePresentation.nextAction(for: effect.status))"
                    )
                    let dispatchEvidence = effect.dispatch?.receipt?.evidenceDigest ?? "no dispatch receipt"
                    let reconciliationEvidence = effect.reconciliation?.receipt.evidenceDigest
                        ?? "no reconciliation receipt"
                    evidenceCard(
                        title: "Intent / receipt comparison",
                        detail: "The journal bound every record below to the same effect, exact grant, dispatch, destination, and idempotency key.\nIntent \(effect.intentDigest)\nPreview \(effect.previewDigest)\nDestination \(effect.destinationFingerprint)\nDispatch evidence \(dispatchEvidence)\nReconciliation evidence \(reconciliationEvidence)"
                    )
                    evidenceCard(
                        title: "Exact intent and authority",
                        detail: "Consequence \(effect.consequence)\nReversible \(effect.reversible ? "yes" : "no")\nAccount binding \(effect.accountBindingID)\nDestination \(effect.destinationFingerprint)\nInput \(effect.inputDigest)\nIntent \(effect.intentDigest)\nPreview \(effect.previewDigest)\nIdempotency \(effect.idempotencyKey)\nApproval \(effect.approvalID) · expires \(effect.expiresAtUnixMillis)\nGrant \(effect.grantID ?? "awaiting exact approval")\nActor \(effect.actorID ?? "not granted") · device \(effect.deviceID ?? "not granted")\nJournal \(effect.proposedStorePosition)…\(effect.authorizedStorePosition.map(String.init) ?? "awaiting approval")"
                    )
                    if let dispatch = effect.dispatch {
                        evidenceCard(
                            title: "Installation-private dispatch binding",
                            detail: "Dispatch \(dispatch.dispatchID)\nConnector \(dispatch.registration.connectorClass) \(dispatch.registration.version)\nPackage \(dispatch.registration.packageDigest)\nBinding \(dispatch.registration.bindingID) · account \(dispatch.registration.accountBindingID)\nActions \(dispatch.registration.allowedActions.joined(separator: ", "))\nRegistration \(dispatch.registration.registrationDigest)\nDeadline \(dispatch.deadlineUnixMillis)\nStarted \(dispatch.startedAtUnixMillis) · journal \(dispatch.startedStorePosition)\nSettled \(dispatch.settledAtUnixMillis.map(String.init) ?? "outcome not recorded") · journal \(dispatch.settledStorePosition.map(String.init) ?? "open")\nElapsed \(dispatch.elapsedMilliseconds.map(String.init) ?? "unknown") ms\nError \(dispatch.errorCode ?? "none")"
                        )
                        if let receipt = dispatch.receipt {
                            effectReceiptCard("Dispatch receipt · \(receipt.outcome)", receipt)
                        } else {
                            explainedEmpty("No dispatch receipt is durable. Reconcile before any retry.")
                        }
                    } else {
                        explainedEmpty("Dispatch has not crossed the durable outbox boundary.")
                    }
                    if let reconciliation = effect.reconciliation {
                        evidenceCard(
                            title: "Reconciliation · \(reconciliation.outcome)",
                            detail: "Observation \(reconciliation.observationCount)\nReconciliation \(reconciliation.reconciliationID)\nElapsed \(reconciliation.elapsedMilliseconds) ms\nObserved \(reconciliation.reconciledAtUnixMillis) · journal \(reconciliation.storePosition)\nError \(reconciliation.errorCode ?? "none")"
                        )
                        effectReceiptCard(
                            "Reconciliation receipt · \(reconciliation.receipt.outcome)",
                            reconciliation.receipt
                        )
                    } else if ["dispatching", "outcome_unknown"].contains(effect.status) {
                        Label("Reconciliation is required. Retrying this effect is blocked.", systemImage: "exclamationmark.shield.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Nord.auroraYellow)
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Nord.auroraYellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func effectReceiptCard(
        _ title: String,
        _ receipt: DesktopWorkflowProjectedEffectReceipt
    ) -> some View {
        evidenceCard(
            title: title,
            detail: "Receipt \(receipt.receiptID)\nProvider reference \(receipt.providerReference ?? "none")\nEvidence \(receipt.evidenceDigest)"
        )
    }

    @ViewBuilder
    private func capabilityInspector(
        _ attempts: [DesktopWorkflowProjectedCapabilityAttempt]
    ) -> some View {
        if attempts.isEmpty {
            explainedEmpty("This node has no registered capability invocation evidence.")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(attempts) { attempt in
                    evidenceCard(
                        title: "\(attempt.capabilityID) · \(attempt.version)",
                        detail: "Package \(attempt.packageDigest)\nConfiguration contract \(attempt.configurationContractDigest)\nInput schema \(attempt.inputSchemaDigest)\nOutput \(attempt.outputSchemaRef) · \(attempt.outputSchemaDigest)"
                    )
                    evidenceCard(title: "Resolved configuration", detail: valueText(attempt.configuration))
                    evidenceCard(title: "Typed input", detail: valueText(attempt.input))
                    capabilityArtifacts(attempt.artifactInputs, title: "Artifact inputs")
                    if let output = attempt.output {
                        evidenceCard(title: "Typed output", detail: valueText(output))
                    }
                    capabilityArtifacts(attempt.artifactOutputs, title: "Artifact outputs")
                    if let error = attempt.error {
                        evidenceCard(
                            title: attempt.errorCode ?? "Capability error",
                            detail: valueText(error)
                        )
                    }
                    if attempt.logs.isEmpty {
                        explainedEmpty("No sanitized capability logs were retained.")
                    } else {
                        ForEach(attempt.logs) { log in
                            evidenceCard(
                                title: "\(log.level.capitalized) · +\(log.offsetMilliseconds) ms",
                                detail: log.message
                            )
                        }
                    }
                    evidenceCard(
                        title: "\(attempt.status.capitalized) · \(attempt.outcome?.replacingOccurrences(of: "_", with: " ").capitalized ?? "running")",
                        detail: "Invocation \(attempt.invocationID)\nIdempotency \(attempt.idempotencyKey ?? "not settled")\nReceipt \(attempt.receiptID ?? "none")\nHost run \(attempt.providerRunReference ?? "none")\nDeadline \(attempt.deadlineUnixMillis) · timeout \(attempt.timeoutMilliseconds) ms\nElapsed \(attempt.elapsedMilliseconds.map(String.init) ?? "active") ms\nJournal \(attempt.startedStorePosition)…\(attempt.settledStorePosition.map(String.init) ?? "active")"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func llmInspector(_ attempts: [DesktopWorkflowProjectedLlmAttempt]) -> some View {
        if attempts.isEmpty {
            explainedEmpty("This node has no recorded LLM invocation evidence.")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                TextField("Search tool calls and responses", text: $llmSearchText)
                    .textFieldStyle(.roundedBorder)
                ForEach(attempts) { attempt in
                    llmDisclosure(
                        key: "\(attempt.id):request",
                        title: "Request · model, context, and admitted tools"
                    ) {
                        evidenceCard(
                            title: "Model settings",
                            detail: "Class \(attempt.settings.modelClass)\nProvider \(attempt.settings.providerID)\nModel \(attempt.settings.modelID) · \(attempt.settings.modelRevision)\nReasoning \(attempt.settings.reasoningEffort) · temperature \(attempt.settings.temperatureMilli)‰\nContext limit \(attempt.settings.maximumContextBytes) bytes · output limit \(attempt.settings.maximumOutputTokens) tokens\nConversation scope \(attempt.settings.conversationScope)\nOutput \(attempt.outputSchemaRef) · \(attempt.outputSchemaDigest)"
                        )
                        let report = attempt.compilationReport
                        evidenceCard(
                            title: "Context compilation",
                            detail: "Digest \(attempt.contextDigest)\nGroups \(report.retainedGroupCount)/\(report.originalGroupCount) · bytes \(report.retainedByteCount)/\(report.originalByteCount)\nRedactions \(report.redactionCount) · \(report.redactionReasons.joined(separator: ", ").nilIfBlank ?? "none")\nTruncated \(report.truncatedGroupIDs.joined(separator: ", ").nilIfBlank ?? "none")\nDropped \(report.droppedGroupIDs.joined(separator: ", ").nilIfBlank ?? "none")"
                        )
                        evidenceCard(title: "Typed input", detail: valueText(attempt.input))
                        ForEach(attempt.toolDefinitions.filter(llmMatches)) { tool in
                            evidenceCard(
                                title: "Tool · \(tool.toolID) \(tool.version)",
                                detail: "\(tool.description)\nPackage \(tool.packageDigest)\nInput \(tool.inputSchemaRef) · \(tool.inputSchemaDigest)\nOutput \(tool.outputSchemaRef) · \(tool.outputSchemaDigest)"
                            )
                        }
                    }

                    llmDisclosure(
                        key: "\(attempt.id):calls",
                        title: "Tool calls · \(attempt.toolCalls.count)"
                    ) {
                        let calls = attempt.toolCalls.filter(llmMatches)
                        if calls.isEmpty {
                            explainedEmpty(llmSearchText.isEmpty
                                ? "The model made no tool calls."
                                : "No tool call matches this search.")
                        }
                        ForEach(calls) { call in
                            evidenceCard(
                                title: "Call \(call.sequence) · \(call.toolID) · \(call.status.capitalized)",
                                detail: "ID \(call.callID) · \(call.durationMilliseconds) ms\nInput\n\(valueText(call.input))"
                            )
                            if let output = call.output {
                                codeBlock(valueText(output))
                            }
                            if let error = call.error {
                                evidenceCard(
                                    title: call.errorCode ?? "Tool error",
                                    detail: valueText(error)
                                )
                            }
                        }
                    }

                    llmDisclosure(
                        key: "\(attempt.id):responses",
                        title: "Response messages · \(attempt.responseMessages.count)"
                    ) {
                        let messages = attempt.responseMessages.filter(llmMatches)
                        if messages.isEmpty {
                            explainedEmpty(llmSearchText.isEmpty
                                ? "No provider response messages were retained."
                                : "No response message matches this search.")
                        }
                        ForEach(messages) { message in
                            evidenceCard(
                                title: "\(message.sequence) · \(message.kind.replacingOccurrences(of: "_", with: " ").capitalized)",
                                detail: "\(message.role.capitalized) · \(message.summary)\nTool call \(message.toolCallID ?? "none")"
                            )
                            codeBlock(valueText(message.content))
                        }
                    }

                    llmDisclosure(
                        key: "\(attempt.id):validation",
                        title: "Usage, validation, and receipt"
                    ) {
                        if let usage = attempt.usage {
                            evidenceCard(
                                title: "Token and cost usage",
                                detail: "Input \(usage.inputTokens) · cached \(usage.cachedInputTokens)\nOutput \(usage.outputTokens) · reasoning \(usage.reasoningTokens)\nTotal \(usage.totalTokens) · tool calls \(usage.toolCallCount)\nCost \(usage.totalCostMicros) µ\(usage.costCurrency ?? "currency unspecified")"
                            )
                        }
                        if let validation = attempt.validation {
                            evidenceCard(
                                title: "Response validation · \(validation.status.replacingOccurrences(of: "_", with: " ").capitalized)",
                                detail: "\(validation.schemaRef) · \(validation.schemaDigest)\n\(validation.diagnostics.joined(separator: "\n").nilIfBlank ?? "No diagnostics")\(validation.diagnosticsTruncated ? "\nAdditional diagnostics truncated" : "")"
                            )
                        }
                        if let receipt = attempt.providerReceipt {
                            evidenceCard(
                                title: "Provider receipt",
                                detail: "Request \(receipt.requestID)\nResponse \(receipt.responseID)\nReceipt \(receipt.receiptID)\nProvider run \(receipt.providerRunReference ?? "none")\nMetadata \(receipt.metadataDigest)"
                            )
                        }
                    }

                    llmDisclosure(
                        key: "\(attempt.id):final",
                        title: "Final output and lifecycle"
                    ) {
                        if let output = attempt.output {
                            evidenceCard(title: "Validated model output", detail: valueText(output))
                        }
                        if let error = attempt.error {
                            evidenceCard(title: attempt.errorCode ?? "LLM error", detail: valueText(error))
                        }
                        evidenceCard(
                            title: "\(attempt.status.capitalized) · \(attempt.outcome?.replacingOccurrences(of: "_", with: " ").capitalized ?? "running")",
                            detail: "Invocation \(attempt.invocationID)\nIdempotency \(attempt.idempotencyKey ?? "not settled")\nReceipt \(attempt.receiptID ?? "none")\nProvider run \(attempt.providerRunReference ?? "none")\nDeadline \(attempt.deadlineUnixMillis) · timeout \(attempt.timeoutMilliseconds) ms\nElapsed \(attempt.elapsedMilliseconds.map(String.init) ?? "active") ms\nJournal \(attempt.startedStorePosition)…\(attempt.settledStorePosition.map(String.init) ?? "active")"
                        )
                    }
                }
            }
        }
    }

    private func llmDisclosure<Content: View>(
        key: String,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: {
                    DesktopWorkflowLlmInspectionPresentation.isGroupExpanded(
                        groupID: key,
                        explicitlyExpandedGroupIDs: expandedLlmGroups,
                        searchText: llmSearchText
                    )
                },
                set: { expanded in
                    if expanded { expandedLlmGroups.insert(key) }
                    else { expandedLlmGroups.remove(key) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 7) { content() }
                .padding(.top, 7)
        } label: {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Nord.frost1)
        }
        .padding(9)
        .background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
    }

    private func llmMatches(_ tool: DesktopWorkflowProjectedLlmToolDefinition) -> Bool {
        DesktopWorkflowLlmInspectionPresentation.includes(
            searchText: llmSearchText,
            fields: [tool.toolID, tool.version, tool.description,
                     tool.inputSchemaRef, tool.outputSchemaRef]
        )
    }

    private func llmMatches(_ call: DesktopWorkflowProjectedLlmToolCall) -> Bool {
        DesktopWorkflowLlmInspectionPresentation.includes(
            searchText: llmSearchText,
            fields: [call.callID, call.toolID, call.status,
                     call.errorCode ?? "", valueText(call.input),
                     call.output.map(valueText) ?? "", call.error.map(valueText) ?? ""]
        )
    }

    private func llmMatches(_ message: DesktopWorkflowProjectedLlmResponseMessage) -> Bool {
        DesktopWorkflowLlmInspectionPresentation.includes(
            searchText: llmSearchText,
            fields: [message.messageID, message.role, message.kind, message.summary,
                     message.toolCallID ?? "", valueText(message.content)]
        )
    }

    @ViewBuilder
    private func capabilityArtifacts(
        _ artifacts: [DesktopWorkflowProjectedCapabilityArtifact],
        title: String
    ) -> some View {
        if !artifacts.isEmpty {
            ForEach(artifacts) { artifact in
                evidenceCard(
                    title: "\(title) · \(artifact.role)",
                    detail: "Opaque handle \(artifact.handleID)\n\(valueText(artifact.value))"
                )
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
        DesktopWorkflowLlmInspectionPresentation.structuredText(value)
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
        inspectorGroup = selectedNodeID.map { !snapshot.run.effects(for: $0).isEmpty } == true
            ? .effect : .inputs
        showingPurgePreview = false
    }

    private func effectStatusSymbol(_ status: String) -> String {
        switch status {
        case "proposed": "person.badge.clock.fill"
        case "authorized": "checkmark.seal.fill"
        case "dispatching": "arrow.up.forward.circle.fill"
        case "succeeded": "checkmark.circle.fill"
        case "rejected": "xmark.octagon.fill"
        case "not_sent": "nosign"
        case "outcome_unknown": "questionmark.diamond.fill"
        case "reconciled_applied", "reconciled_not_applied": "checkmark.shield.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func effectStatusTint(_ status: String) -> Color {
        switch status {
        case "succeeded", "reconciled_applied": Nord.auroraGreen
        case "rejected": Nord.auroraRed
        case "proposed", "dispatching", "outcome_unknown": Nord.auroraYellow
        case "authorized": Nord.frost1
        case "not_sent", "reconciled_not_applied": .secondary
        default: Nord.auroraRed
        }
    }

    private func effectStepSymbol(_ state: DesktopWorkflowEffectLifecycleStepState) -> String {
        switch state {
        case .complete: "checkmark.circle.fill"
        case .current: "circle.inset.filled"
        case .attention: "exclamationmark.triangle.fill"
        case .pending: "circle.dashed"
        case .notApplicable: "minus.circle"
        }
    }

    private func effectStepTint(_ state: DesktopWorkflowEffectLifecycleStepState) -> Color {
        switch state {
        case .complete: Nord.auroraGreen
        case .current: Nord.frost1
        case .attention: Nord.auroraYellow
        case .pending, .notApplicable: .secondary
        }
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
