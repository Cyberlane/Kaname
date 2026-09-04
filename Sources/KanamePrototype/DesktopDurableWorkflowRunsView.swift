import Foundation
import KanameConnectivity
import KanameDesktop
import KanameLocalCore
import KanamePrototypeUI
import SwiftUI
import KanameDesignSystem

@MainActor
final class DesktopDurableWorkflowRunsViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(DesktopWorkflowRunHistorySnapshot)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var runnableWorkflows: [DesktopWorkflowV2PortfolioItem] = []
    @Published private(set) var startMessage: String?
    @Published private(set) var isStarting = false
    private let loader: DesktopWorkflowRunHistoryLoader?
    private let purgeClient: DesktopWorkflowRunPurgeClient?
    private let runner: LocalCoreRunner?
    private let library: DesktopWorkflowV2LibraryClient?

    init(runner: LocalCoreRunner) {
        self.runner = runner
        purgeClient = DesktopWorkflowRunPurgeClient(transport: runner)
        let library = DesktopWorkflowV2LibraryClient(transport: runner)
        self.library = library
        loader = DesktopWorkflowRunHistoryLoader(
            inspection: DesktopWorkflowRunInspectionClient(transport: runner),
            library: library
        )
    }

    init(snapshot: DesktopWorkflowRunHistorySnapshot) {
        state = .loaded(snapshot)
        loader = nil
        purgeClient = nil
        runner = nil
        library = nil
    }

    /// Active revisions the Rust executor can run right now.
    func loadRunnableWorkflows() async {
        guard let library else { return }
        let items = try? await library.portfolio(requestID: "workflow-runnable:\(UUID().uuidString.lowercased())")
        runnableWorkflows = (items ?? []).filter { $0.activeRevisionID != nil }
        loadSchedules()
    }

    // MARK: Sample workflow

    /// A tiny executable workflow: manual trigger, validate `{"route": n}`,
    /// route 5 to one terminal and everything else to another. Lets the Rust
    /// executor be exercised end to end before any real workflow exists.
    static let sampleWorkflowID = "018f5000-0001-7000-8000-000000000001"

    static let sampleSchemaBundleJSON = """
    {"bundleVersion":1,"schemas":[{"id":"dev.kaname.sample-input/v1","schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","required":["route"],"properties":{"route":{"type":["number","string"]}},"additionalProperties":false}}]}
    """

    static let sampleWorkflowJSON = """
    {"formatVersion":1,"workflowId":"018f5000-0001-7000-8000-000000000001","packageId":"dev.kaname.sample-route","name":"Sample: route a number","summary":"Manual trigger, validate the input, route 5 to one terminal and everything else to another.","graph":{"entrypoints":[{"id":"018f5000-0011-7000-8000-000000000011","nodeId":"018f5000-0101-7000-8000-000000000101"}],"nodes":[{"id":"018f5000-0101-7000-8000-000000000101","key":"manual","name":"manual","type":"trigger.manual","typeVersion":1,"config":{}},{"id":"018f5000-0102-7000-8000-000000000102","key":"validate","name":"validate","type":"data.validate","typeVersion":1,"config":{"schemaRef":"dev.kaname.sample-input/v1"}},{"id":"018f5000-0103-7000-8000-000000000103","key":"match","name":"match","type":"control.match","typeVersion":1,"config":{"value":{"root":"input","pointer":""},"hitPolicy":"first","cases":[{"id":"018f5000-0201-7000-8000-000000000201","key":"five","label":"Route five","when":{"compare":{"left":{"root":"value","pointer":"/route"},"operator":"equal","right":{"literal":{"type":"number","value":5}}}}}],"otherwise":{"id":"018f5000-0202-7000-8000-000000000202","key":"otherwise","label":"Otherwise"}}},{"id":"018f5000-0104-7000-8000-000000000104","key":"complete-five","name":"complete-five","type":"terminal.complete","typeVersion":1,"config":{}},{"id":"018f5000-0105-7000-8000-000000000105","key":"complete-otherwise","name":"complete-otherwise","type":"terminal.complete","typeVersion":1,"config":{}},{"id":"018f5000-0106-7000-8000-000000000106","key":"fail-validation","name":"fail-validation","type":"terminal.fail","typeVersion":1,"config":{"error":{"whole":true}}},{"id":"018f5000-0107-7000-8000-000000000107","key":"fail-match","name":"fail-match","type":"terminal.fail","typeVersion":1,"config":{"error":{"whole":true}}}],"edges":[{"id":"018f5100-0001-7000-8000-000000000001","from":{"nodeId":"018f5000-0101-7000-8000-000000000101","portId":"success"},"to":{"nodeId":"018f5000-0102-7000-8000-000000000102","portId":"input"},"mappingId":"018f5200-0001-7000-8000-000000000001","mapping":{"whole":true}},{"id":"018f5100-0002-7000-8000-000000000002","from":{"nodeId":"018f5000-0102-7000-8000-000000000102","portId":"success"},"to":{"nodeId":"018f5000-0103-7000-8000-000000000103","portId":"input"},"mappingId":"018f5200-0002-7000-8000-000000000002","mapping":{"whole":true}},{"id":"018f5100-0003-7000-8000-000000000003","from":{"nodeId":"018f5000-0102-7000-8000-000000000102","portId":"error"},"to":{"nodeId":"018f5000-0106-7000-8000-000000000106","portId":"input"},"mappingId":"018f5200-0003-7000-8000-000000000003","mapping":{"whole":true}},{"id":"018f5100-0004-7000-8000-000000000004","from":{"nodeId":"018f5000-0103-7000-8000-000000000103","portId":"case-018f5000-0201-7000-8000-000000000201"},"to":{"nodeId":"018f5000-0104-7000-8000-000000000104","portId":"input"},"mappingId":"018f5200-0004-7000-8000-000000000004","mapping":{"whole":true}},{"id":"018f5100-0005-7000-8000-000000000005","from":{"nodeId":"018f5000-0103-7000-8000-000000000103","portId":"case-018f5000-0202-7000-8000-000000000202"},"to":{"nodeId":"018f5000-0105-7000-8000-000000000105","portId":"input"},"mappingId":"018f5200-0005-7000-8000-000000000005","mapping":{"whole":true}},{"id":"018f5100-0006-7000-8000-000000000006","from":{"nodeId":"018f5000-0103-7000-8000-000000000103","portId":"error"},"to":{"nodeId":"018f5000-0107-7000-8000-000000000107","portId":"input"},"mappingId":"018f5200-0006-7000-8000-000000000006","mapping":{"whole":true}}]},"interfaces":{},"resources":{},"policies":{},"storage":{},"metadata":{}}
    """

    func installSampleWorkflow() async {
        guard let runner, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let result = try await runner.publishWorkflow(
                workflowID: Self.sampleWorkflowID,
                packageID: "dev.kaname.sample-route",
                name: "Sample: route a number",
                summary: "Manual trigger, validate, match, terminal.",
                workflowJSON: Self.sampleWorkflowJSON,
                schemaBundleJSON: Self.sampleSchemaBundleJSON,
                activate: true
            )
            startMessage = "Sample published as revision \(result.revisionID.suffix(8)) (\(result.executionSupport))\(result.activated ? ", active" : ""). Run it with input {\"route\": 5}."
            runInputJSON = "{\"route\": 5}"
        } catch {
            startMessage = "Sample install failed: \(error.localizedDescription)"
        }
        await loadRunnableWorkflows()
        await reload()
    }

    // MARK: Interval schedules (host state read by the control service's tick)

    @Published private(set) var scheduleSeconds: [String: Int] = [:]

    static let scheduleChoices: [(label: String, seconds: Int)] = [
        ("Off", 0), ("Every 15 minutes", 900), ("Every hour", 3_600), ("Every 6 hours", 21_600), ("Daily", 86_400),
    ]

    private var schedulesURL: URL {
        KanameDesktopEnvironment.current.applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("schedules.json")
    }

    func loadSchedules() {
        guard let data = try? Data(contentsOf: schedulesURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["schedules"] as? [[String: Any]] else {
            scheduleSeconds = [:]
            return
        }
        var seconds: [String: Int] = [:]
        for entry in entries {
            guard let id = entry["workflowId"] as? String, (entry["enabled"] as? Bool) ?? true else { continue }
            seconds[id] = (entry["intervalSeconds"] as? Int) ?? 0
        }
        scheduleSeconds = seconds
    }

    func setSchedule(_ item: DesktopWorkflowV2PortfolioItem, seconds: Int) {
        var entries: [[String: Any]] = []
        if let data = try? Data(contentsOf: schedulesURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = object["schedules"] as? [[String: Any]] {
            entries = existing.filter { ($0["workflowId"] as? String) != item.workflowID }
        }
        if seconds > 0 {
            entries.append([
                "workflowId": item.workflowID,
                "intervalSeconds": seconds,
                "enabled": true,
                "lastScheduledForUnixMillis": 0,
            ])
        }
        let directory = schedulesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: ["schedules": entries], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: schedulesURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schedulesURL.path)
        }
        loadSchedules()
        startMessage = seconds > 0
            ? "\(item.name) runs every \(seconds / 60) minutes while the Kaname service is running, even with the app closed."
            : "\(item.name) schedule removed."
    }

    /// Records the owner's decision for a proposed effect, then continues the
    /// run so the executor can dispatch (or settle the rejection).
    func decideEffect(_ effect: DesktopWorkflowProjectedEffectAuthority, run: DesktopDurableWorkflowRun, approve: Bool) async {
        guard let runner, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let decision = try await runner.authorizeWorkflowEffect(
                effectID: effect.effectID,
                approvalID: effect.approvalID,
                approvalFingerprint: effect.approvalFingerprint,
                approve: approve
            )
            let continued = try await runner.startWorkflowRun(
                workflowID: run.workflowID,
                revisionID: run.revisionID,
                runID: run.runID
            )
            startMessage = "Effect \(effect.effectID.suffix(8)) \(decision.status); run \(continued.outcome) after \(continued.eventCount) events."
        } catch {
            startMessage = "Effect decision failed: \(error.localizedDescription)"
        }
        await reload()
    }

    /// Re-issues the run command so a waiting or retrying run advances.
    func continueRun(_ run: DesktopDurableWorkflowRun) async {
        guard let runner, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let continued = try await runner.startWorkflowRun(workflowID: run.workflowID, revisionID: run.revisionID, runID: run.runID)
            startMessage = "Run \(run.runID.suffix(8)) \(continued.outcome) after \(continued.eventCount) events."
        } catch {
            startMessage = "Continue failed: \(error.localizedDescription)"
        }
        await reload()
    }

    /// Optional JSON for the entrypoint's `input` port when running manually.
    @Published var runInputJSON = ""

    /// Starts a manual run on the Rust executor and refreshes history.
    func startRun(_ item: DesktopWorkflowV2PortfolioItem) async {
        guard let runner, let revisionID = item.activeRevisionID, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        var inputs: [String: Any] = [:]
        let trimmed = runInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                startMessage = "Run input must be valid JSON."
                return
            }
            inputs["input"] = value
        }
        do {
            let result = try await runner.startWorkflowRun(workflowID: item.workflowID, revisionID: revisionID, inputs: inputs)
            if result.outcome == "waiting" {
                DesktopCodingNotifier.notify(kind: .effectProposed, threadTitle: item.name, hideDetails: false)
            }
            startMessage = "\(item.name): run \(result.runID.suffix(8)) \(result.outcome) after \(result.eventCount) events."
        } catch {
            startMessage = "\(item.name) did not start: \(error.localizedDescription)"
        }
        await reload()
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
        .task {
            await viewModel.load()
            await viewModel.loadRunnableWorkflows()
        }
    }

    @ViewBuilder
    private func loaded(_ history: DesktopWorkflowRunHistorySnapshot) -> some View {
        if history.runs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.largeTitle).foregroundStyle(KanameColor.accent)
                Text("No durable workflow runs yet").font(.headline)
                Text(history.absenceReason == "not_found_or_purged"
                    ? "This run was not found or its retained history has been purged."
                    : "Published workflows will appear here after their first local run.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    runWorkflowMenu
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await viewModel.reload() } }
                }
                if let message = viewModel.startMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
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

    /// Manual trigger for any active, executable revision on the Rust executor.
    @ViewBuilder private var runWorkflowMenu: some View {
        if viewModel.runnableWorkflows.isEmpty {
            Button("Install sample workflow", systemImage: "square.and.arrow.down") {
                Task { await viewModel.installSampleWorkflow() }
            }
            .disabled(viewModel.isStarting)
            .help("Publishes a small manual workflow into the Rust library so runs can be tried")
        } else {
            TextField("Run input JSON, e.g. {\"route\": 5}", text: $viewModel.runInputJSON)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 260)
            Menu {
                Section("Run now") {
                    ForEach(viewModel.runnableWorkflows) { item in
                        Button(item.name) { Task { await viewModel.startRun(item) } }
                    }
                }
                Section("Schedule") {
                    ForEach(viewModel.runnableWorkflows) { item in
                        Menu(scheduleLabel(item)) {
                            ForEach(DesktopDurableWorkflowRunsViewModel.scheduleChoices, id: \.seconds) { choice in
                                Button {
                                    viewModel.setSchedule(item, seconds: choice.seconds)
                                } label: {
                                    if (viewModel.scheduleSeconds[item.workflowID] ?? 0) == choice.seconds {
                                        Label(choice.label, systemImage: "checkmark")
                                    } else {
                                        Text(choice.label)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(viewModel.isStarting ? "Starting…" : "Run workflow", systemImage: "play.fill")
            }
            .disabled(viewModel.isStarting)
        }
    }

    private func scheduleLabel(_ item: DesktopWorkflowV2PortfolioItem) -> String {
        let seconds = viewModel.scheduleSeconds[item.workflowID] ?? 0
        let choice = DesktopDurableWorkflowRunsViewModel.scheduleChoices.first { $0.seconds == seconds }?.label ?? "Every \(seconds / 60) min"
        return seconds > 0 ? "\(item.name) · \(choice)" : item.name
    }

    private func runList(_ history: DesktopWorkflowRunHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = viewModel.startMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                runWorkflowMenu
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
                    .background(selectedRunID == snapshot.id ? KanameColor.accent.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
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
                        if let duration = snapshot.run.durationMilliseconds {
                            Label(DesktopWorkflowDurationPresentation.text(milliseconds: duration), systemImage: "timer")
                        }
                        Label("Historical snapshot", systemImage: "lock.doc")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            failureSummary(snapshot)
            effectLifecycleSummary(snapshot.run.effectAuthorities, compact: effectCompact)
            retentionCard(snapshot.run)
            if let reason = snapshot.revisionAbsenceReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning).panelStyle()
            } else if let graph = snapshot.graph {
                canvas(graph, run: snapshot.run)
                    .frame(height: qualificationFixture ? 220 : nil)
                    .frame(minHeight: qualificationFixture ? nil : 390)
                inspector(snapshot, graph: graph)
            } else {
                Label("The revision exists, but its historical graph could not be decoded. No empty diagram is shown.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning).panelStyle()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KanameColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func failureSummary(_ snapshot: DesktopWorkflowRunSnapshot) -> some View {
        if let failure = snapshot.run.failurePoint {
            let nodeName = failure.nodeID.flatMap { id in snapshot.graph?.nodes.first { $0.id == id }?.name }
            Button {
                if let nodeID = failure.nodeID {
                    selectedNodeID = nodeID
                    inspectorGroup = .error
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(KanameColor.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(nodeName.map { "Failed at \($0)" } ?? "Run failed")
                                .font(.caption.weight(.bold))
                            Text(failure.failureClass.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(KanameColor.danger.opacity(0.14), in: Capsule())
                                .foregroundStyle(KanameColor.danger)
                            Text(failure.errorCode)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Text(failure.failureClass.explanation).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if failure.nodeID != nil {
                        Label("Open error", systemImage: "arrow.right.circle").font(.caption2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
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
                        .font(.caption.weight(.semibold)).foregroundStyle(KanameColor.accent)
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
                                ? KanameColor.warning : .secondary
                        )
                    }
                    .padding(9)
                    .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
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
                        .font(.caption2).foregroundStyle(KanameColor.warning)
                } else if preview.automaticEligible {
                    Text("Eligible now").font(.caption2).foregroundStyle(KanameColor.success)
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
                            .font(.caption2).foregroundStyle(KanameColor.success)
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
                    .tint(KanameColor.danger)
                    .disabled(!preview.manualEligible)
                }
                .padding(9)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
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
                    .font(.caption.weight(.semibold)).foregroundStyle(KanameColor.accent)
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
                            context.stroke(path, with: .color(admitted ? KanameColor.success : KanameColor.separator),
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
                                    if let duration = run.nodes.first(where: { $0.nodeID == node.id })?.durationMilliseconds {
                                        Text("·").foregroundStyle(.secondary)
                                        Text(DesktopWorkflowDurationPresentation.text(milliseconds: duration))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let failureClass = run.attempt(for: node.id)?.failureClass {
                                        Text("·").foregroundStyle(.secondary)
                                        Text(failureClass.label).foregroundStyle(KanameColor.danger).lineLimit(1)
                                    } else if let effect {
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
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).stroke(
                                selectedNodeID == node.id ? KanameColor.accent : statusTint(state).opacity(0.45),
                                lineWidth: selectedNodeID == node.id ? 2 : 1
                            ) }
                        }
                        .buttonStyle(.plain)
                        .position(x: (node.x + 110) * zoom, y: (node.y + 45) * zoom)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 10))
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
                                inspectorGroup == group ? KanameColor.accent.opacity(0.22) : KanameColor.canvas,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    inspectorGroup == group ? KanameColor.accent : KanameColor.separator,
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
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func inspectorContent(_ snapshot: DesktopWorkflowRunSnapshot, node: DesktopWorkflowHistoricalNode) -> some View {
        let run = snapshot.run
        switch inspectorGroup {
        case .inputs:
            let admitted = run.inputs(for: node.id)
            let entry = run.entryInputs(for: node.id)
            if admitted.isEmpty, !entry.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Entry input from the trigger that started this run.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(Array(entry.enumerated()), id: \.offset) { _, binding in
                        evidenceCard(title: binding.portID, detail: valueText(binding.value))
                    }
                }
            } else {
                valueList(admitted, empty: "This node has no admitted input checkpoint.")
            }
        case .output:
            valueList(run.outputs(for: node.id), empty: "This node produced no output emission.")
        case .error:
            if let attempt = run.attempt(for: node.id), let code = attempt.errorCode {
                let failureClass = DesktopWorkflowFailureClass(errorCode: code)
                VStack(alignment: .leading, spacing: 7) {
                    evidenceCard(title: "\(failureClass.label) · \(code)", detail: failureClass.explanation)
                    evidenceCard(
                        title: "Error payload",
                        detail: attempt.error.flatMap(valueText) ?? "No error payload was retained."
                    )
                }
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
            effectInspector(run.effects(for: node.id), run: run)
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
            let nodeAttempts = run.attempts.filter { $0.nodeID == node.id }.sorted { $0.number < $1.number }
            if nodeAttempts.isEmpty {
                explainedEmpty("This node has no recorded attempt timing.")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(nodeAttempts) { attempt in
                        let duration = attempt.durationMilliseconds
                            .map(DesktopWorkflowDurationPresentation.text(milliseconds:)) ?? "still running"
                        let settled = attempt.settledAtUnixMillis
                            .map(DesktopWorkflowDurationPresentation.timestamp) ?? "not settled"
                        evidenceCard(
                            title: "Attempt \(attempt.number) · \(attempt.status) · \(duration)",
                            detail: "Started \(DesktopWorkflowDurationPresentation.timestamp(attempt.startedAtUnixMillis))\nSettled \(settled)\nJournal \(attempt.startedStorePosition)…\(attempt.settledStorePosition.map(String.init) ?? "—")"
                        )
                    }
                    ForEach(run.capabilities(for: node.id)) { capability in
                        if let elapsed = capability.elapsedMilliseconds {
                            evidenceCard(
                                title: "Capability host · \(DesktopWorkflowDurationPresentation.text(milliseconds: Int64(elapsed)))",
                                detail: "Time inside the capability process for this attempt."
                            )
                        }
                    }
                    ForEach(run.llmAttempts(for: node.id)) { llm in
                        if let elapsed = llm.elapsedMilliseconds {
                            evidenceCard(
                                title: "Model host · \(DesktopWorkflowDurationPresentation.text(milliseconds: Int64(elapsed)))",
                                detail: "Time inside the model host for this attempt."
                            )
                        }
                    }
                }
            }
        case .raw:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.events) { event in
                    HStack {
                        Text("#\(event.storePosition)").font(.system(.caption2, design: .monospaced)).foregroundStyle(KanameColor.accent)
                        Text(event.kind).font(.caption2)
                        Spacer()
                        Text(event.eventID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func effectInspector(_ effects: [DesktopWorkflowProjectedEffectAuthority], run: DesktopDurableWorkflowRun) -> some View {
        if effects.isEmpty {
            explainedEmpty("This node has no proposed or executed effect evidence.")
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(effects) { effect in
                    evidenceCard(
                        title: DesktopWorkflowEffectLifecyclePresentation.title(for: effect.status),
                        detail: "Effect \(effect.effectID)\nAction \(effect.action) · connector \(effect.connectorClass)\nNext action: \(DesktopWorkflowEffectLifecyclePresentation.nextAction(for: effect.status))"
                    )
                    if effect.status == "proposed" {
                        HStack(spacing: 8) {
                            Button("Approve and dispatch", systemImage: "checkmark.shield") {
                                Task { await viewModel.decideEffect(effect, run: run, approve: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Reject", role: .destructive) {
                                Task { await viewModel.decideEffect(effect, run: run, approve: false) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .disabled(viewModel.isStarting)
                    } else if ["authorized", "dispatching", "outcome_unknown"].contains(effect.status) {
                        Button("Continue run", systemImage: "play.fill") {
                            Task { await viewModel.continueRun(run) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isStarting)
                    }
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
                            .font(.caption.weight(.semibold)).foregroundStyle(KanameColor.warning)
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(KanameColor.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
            Text(title).font(.caption.weight(.bold)).foregroundStyle(KanameColor.accent)
        }
        .padding(9)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
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
                    .font(.caption.weight(.bold)).foregroundStyle(KanameColor.accent)
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
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
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
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func evidenceCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(KanameColor.accent)
            Text(detail).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func explainedEmpty(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Label("Workflow run history unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(KanameColor.warning)
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
        case "succeeded", "reconciled_applied": KanameColor.success
        case "rejected": KanameColor.danger
        case "proposed", "dispatching", "outcome_unknown": KanameColor.warning
        case "authorized": KanameColor.accent
        case "not_sent", "reconciled_not_applied": .secondary
        default: KanameColor.danger
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
        case .complete: KanameColor.success
        case .current: KanameColor.accent
        case .attention: KanameColor.warning
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
        case "succeeded": KanameColor.success
        case "failed": KanameColor.danger
        case "cancelled": KanameColor.warning
        case "running", "cancelling": KanameColor.accent
        default: .secondary
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
