import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

private enum AutomationRunRetention: String, CaseIterable {
    case thirtyDays = "30 days"
    case deleteAfterSuccess = "Delete after success"
    case forever = "Keep forever"
}

private struct AutomationRunFixture: Identifiable {
    let id: Int
    let workflow: String
    let version: Int
    let detail: String
    let state: AutomationPreviewState
    let pattern: AutomationCanvasPattern
    let expiry: String
}

private enum AutomationRunInspectorTab: String, CaseIterable {
    case data = "Data"
    case storage = "Storage"
    case logs = "Logs"
    case configuration = "Config"
    case evidence = "Evidence"
}

private enum AutomationRunDataView: String, CaseIterable {
    case table = "Table"
    case json = "JSON"
    case schema = "Schema"
}

private enum AutomationStepInspectorSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inputs = "Inputs"
    case context = "Context"
    case messages = "Messages"
    case tools = "Tools"
    case outputs = "Output"
    case errors = "Errors"
    case usage = "Usage"
    case storage = "Storage"
    case logs = "Logs"
    case raw = "Raw evidence"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .inputs: "arrow.down.doc"
        case .context: "text.append"
        case .messages: "bubble.left.and.bubble.right"
        case .tools: "wrench.and.screwdriver"
        case .outputs: "arrow.up.doc"
        case .errors: "exclamationmark.triangle"
        case .usage: "gauge.with.dots.needle.67percent"
        case .storage: "shippingbox"
        case .logs: "text.alignleft"
        case .raw: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private enum AutomationRunStepInspectorPreview {
    case automatic
    case inputs
    case error
    case llmContext
    case llmMessages
    case llmTools

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-run-step-detail") { self = .inputs }
        else if arguments.contains("--desktop-automation-run-step-error") { self = .error }
        else if arguments.contains("--desktop-automation-run-llm-context") { self = .llmContext }
        else if arguments.contains("--desktop-automation-run-llm-messages") { self = .llmMessages }
        else if arguments.contains("--desktop-automation-run-llm-tools") { self = .llmTools }
        else { self = .automatic }
    }
}

struct AutomationRunsPreview: View {
    private let showsJobStorageDesign: Bool
    @State private var selectedRunID = 184
    @State private var retention = AutomationRunRetention.thirtyDays
    @State private var search = ""
    @State private var showsRetentionSettings = false
    @State private var compactShowsDetail = false
    @State private var selectedRunStepID = "context"
    @State private var selectedRunEdgeID: String?
    @State private var inspectorTab = AutomationRunInspectorTab.data
    @State private var dataView = AutomationRunDataView.table
    @State private var stepInspectorSection = AutomationStepInspectorSection.inputs
    @State private var showsDeleteJobConfirmation = false

    private let runs: [AutomationRunFixture] = [
        .init(id: 184, workflow: "Reply-driven reporting", version: 6, detail: "Waiting for reply · 12 min", state: .waiting, pattern: .feedback, expiry: "Deletes 12 Sep"),
        .init(id: 183, workflow: "Reply-driven reporting", version: 6, detail: "Passed · 1 h ago", state: .complete, pattern: .feedback, expiry: "Deletes 12 Sep"),
        .init(id: 182, workflow: "Reply-driven reporting", version: 5, detail: "Passed · yesterday", state: .complete, pattern: .feedback, expiry: "Deletes 11 Sep"),
        .init(id: 181, workflow: "Mailbox review", version: 4, detail: "Failed · yesterday", state: .blocked, pattern: .decision, expiry: "Deletes 11 Sep"),
        .init(id: 180, workflow: "Approved cleanup", version: 3, detail: "Passed · 3 d ago", state: .complete, pattern: .approval, expiry: "Deletes 9 Sep"),
        .init(id: 179, workflow: "Mailbox digest", version: 3, detail: "Passed · 4 d ago", state: .complete, pattern: .parallel, expiry: "Deletes 8 Sep"),
        .init(id: 178, workflow: "Approved cleanup", version: 3, detail: "Failed · 5 d ago", state: .blocked, pattern: .recovery, expiry: "Deletes 7 Sep"),
    ]

    init() {
        let arguments = CommandLine.arguments
        let requestedStepInspector = AutomationRunStepInspectorPreview(arguments: arguments)
        let startsWithDeletePreview = arguments.contains("--desktop-automation-run-storage-delete")
        showsJobStorageDesign = arguments.contains("--desktop-automation-run-storage") || startsWithDeletePreview
        if arguments.contains("--desktop-automation-run-edge") {
            _selectedRunEdgeID = State(initialValue: "context-execute-episode 3")
        }
        if showsJobStorageDesign {
            _inspectorTab = State(initialValue: .storage)
        }
        if startsWithDeletePreview {
            _selectedRunID = State(initialValue: 183)
            _showsDeleteJobConfirmation = State(initialValue: true)
        }
        switch requestedStepInspector {
        case .inputs:
            _selectedRunID = State(initialValue: 184)
            _selectedRunStepID = State(initialValue: "context")
            _stepInspectorSection = State(initialValue: .inputs)
        case .error:
            _selectedRunID = State(initialValue: 178)
            _selectedRunStepID = State(initialValue: "unknown")
            _stepInspectorSection = State(initialValue: .errors)
        case .llmContext:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .context)
        case .llmMessages:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .messages)
        case .llmTools:
            _selectedRunID = State(initialValue: 179)
            _selectedRunStepID = State(initialValue: "summarize")
            _stepInspectorSection = State(initialValue: .tools)
        case .automatic:
            break
        }
    }

    private var selectedRun: AutomationRunFixture {
        runs.first(where: { $0.id == selectedRunID }) ?? runs[0]
    }

    private var visibleRuns: [AutomationRunFixture] {
        runs.filter { search.isEmpty || $0.workflow.localizedCaseInsensitiveContains(search) || String($0.id).contains(search) }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_050
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(showsRetentionSettings ? "History settings" : "Run history")
                            .font(.title3.weight(.bold))
                        Text(showsRetentionSettings
                            ? "Choose how long settled run data remains available"
                            : "Every run is pinned to the exact workflow version and evidence it used")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !showsRetentionSettings {
                        TextField("Search runs", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: isCompact ? 180 : 220)
                    }
                    Button(
                        showsRetentionSettings ? "Back to runs" : "History settings",
                        systemImage: showsRetentionSettings ? "chevron.left" : "gearshape"
                    ) {
                        showsRetentionSettings.toggle()
                    }
                    .buttonStyle(.bordered)
                }

                if showsRetentionSettings {
                    retentionSettings
                } else if isCompact {
                    if compactShowsDetail {
                        runDetail(isCompact: true)
                    } else {
                        runList
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        runList
                            .frame(width: 290)
                        runDetail(isCompact: false)
                    }
                }
            }
        }
        .frame(minHeight: 630)
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent runs").font(.headline)
                Spacer()
                Text("\(visibleRuns.count)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            ForEach(visibleRuns) { run in
                Button {
                    selectedRunID = run.id
                    selectedRunStepID = run.pattern.graph.defaultSelectedID
                    selectedRunEdgeID = nil
                    let defaultStep = run.pattern.graph.steps.first(where: { $0.id == run.pattern.graph.defaultSelectedID })
                        ?? run.pattern.graph.steps[0]
                    stepInspectorSection = defaultStepInspectorSection(for: defaultStep, run: run)
                    compactShowsDetail = true
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: run.state.symbol).foregroundStyle(run.state.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text("#\(run.id)").font(.system(.caption, design: .monospaced).weight(.bold))
                                Text("v\(run.version)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(KanameColor.accent)
                            }
                            Text(run.workflow).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(run.detail).font(.caption2).foregroundStyle(.secondary)
                            Text(run.expiry).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Open run details")
                    }
                    .padding(9)
                    .background(selectedRunID == run.id ? KanameColor.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Divider()
            Label("History is local and manually deletable", systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 590, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func runDetail(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isCompact {
                    Button("All runs", systemImage: "chevron.left") {
                        compactShowsDetail = false
                    }
                    .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedRun.workflow) #\(selectedRun.id)").font(.headline)
                    HStack(spacing: 8) {
                        Label(selectedRun.state.label, systemImage: selectedRun.state.symbol).foregroundStyle(selectedRun.state.tint)
                        Text("Workflow v\(selectedRun.version)")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(KanameColor.accent)
                        Label("Historical snapshot", systemImage: "lock.doc")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Delete job", systemImage: "trash", role: .destructive) {
                    showsDeleteJobConfirmation = true
                }
                    .buttonStyle(.bordered)
                    .disabled(!showsJobStorageDesign)
            }

            HStack {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(KanameColor.accent)
                Label("Settings v\(selectedRun.version)", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
                Label("Evidence", systemImage: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                Spacer()
                Text("Read-only").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.caption)

            AutomationNodeCanvas(
                graph: selectedRun.pattern.graph,
                selectedStepID: $selectedRunStepID,
                isSimulating: selectedRun.state == .running || selectedRun.state == .waiting,
                viewportPreset: showsJobStorageDesign || usesDetailedStepInspector ? .readable : .standard,
                selectedEdgeID: $selectedRunEdgeID
            )
            .frame(minHeight: 315)
            .onChange(of: selectedRunStepID) { _ in
                selectedRunEdgeID = nil
                stepInspectorSection = defaultStepInspectorSection(for: selectedRunStep, run: selectedRun)
            }

            runDataInspector
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 590, alignment: .topLeading)
        .background(KanameColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if showsDeleteJobConfirmation {
                ZStack {
                    KanameColor.canvas.opacity(0.74)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    deleteJobConfirmation
                        .frame(width: 450)
                }
            }
        }
    }

    private var selectedRunStep: AutomationCanvasStep {
        selectedRun.pattern.graph.steps.first(where: { $0.id == selectedRunStepID })
            ?? selectedRun.pattern.graph.steps[0]
    }

    private var selectedRunEdge: AutomationCanvasEdge? {
        selectedRun.pattern.graph.edges.first(where: { $0.id == selectedRunEdgeID })
    }

    private var usesDetailedStepInspector: Bool {
        !showsJobStorageDesign && selectedRunEdge == nil
    }

    @ViewBuilder
    private var runDataInspector: some View {
        if usesDetailedStepInspector {
            detailedStepInspector
        } else {
            legacyRunDataInspector
        }
    }

    private var legacyRunDataInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: selectedRunEdge == nil ? selectedRunStep.symbol : "arrow.right.circle.fill")
                    .foregroundStyle(selectedRunEdge?.kind.tint ?? selectedRunStep.kind.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedRunEdge.map { "Checkpoint · \($0.label)" } ?? selectedRunStep.title)
                        .font(.headline)
                    Text(selectedRunEdge.map { edgeEndpointLabel($0) } ?? "Node attempt · received → produced")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Inspector", selection: $inspectorTab) {
                    ForEach(AutomationRunInspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            Divider()
            runInspectorContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var detailedStepInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: selectedRunStep.symbol)
                    .foregroundStyle(selectedRunStep.kind.tint)
                    .frame(width: 30, height: 30)
                    .background(selectedRunStep.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(selectedRunStep.title).font(.headline)
                        Text("Attempt 1")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(stepInspectorSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                inspectorStatusFact("Status", value: selectedRun.state == .blocked ? "Failed" : "Succeeded", tint: selectedRun.state.tint)
                inspectorStatusFact("Duration", value: stepIsLLM ? "1.8 s" : "16 ms", tint: KanameColor.accent)
                inspectorStatusFact("Started", value: "22:31:04", tint: .secondary)
                Label("Read-only trace", systemImage: "lock.doc")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 3) {
                    ForEach(stepInspectorSections) { section in
                        stepInspectorNavigationItem(section)
                    }
                }
                .frame(width: 146)

                Divider()

                detailedStepInspectorContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 286, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var stepInspectorSubtitle: String {
        if stepIsLLM {
            return "LLM execution · context, messages, tools, output, and provider metadata"
        }
        if selectedRun.state == .blocked {
            return "Failed node attempt · preserved input checkpoint and diagnostic evidence"
        }
        return "Node execution · exact input boundary → produced output boundary"
    }

    private var stepIsLLM: Bool {
        if case .ai = selectedRunStep.kind { return true }
        return false
    }

    private var stepInspectorSections: [AutomationStepInspectorSection] {
        if stepIsLLM {
            return [.overview, .inputs, .context, .messages, .tools, .outputs, .errors, .usage, .raw]
        }
        return [.overview, .inputs, .outputs, .errors, .storage, .logs, .raw]
    }

    private func defaultStepInspectorSection(
        for step: AutomationCanvasStep,
        run: AutomationRunFixture
    ) -> AutomationStepInspectorSection {
        if case .ai = step.kind { return .context }
        if run.state == .blocked { return .errors }
        return .inputs
    }

    private func stepInspectorNavigationItem(_ section: AutomationStepInspectorSection) -> some View {
        Button {
            stepInspectorSection = section
        } label: {
            HStack(spacing: 7) {
                Image(systemName: section.symbol).frame(width: 15)
                Text(section.rawValue).lineLimit(1)
                Spacer(minLength: 4)
                if let count = stepInspectorCount(for: section) {
                    Text(count)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(section == .errors && count != "0" ? KanameColor.danger : .secondary)
                }
            }
            .font(.caption.weight(stepInspectorSection == section ? .semibold : .regular))
            .foregroundStyle(stepInspectorSection == section ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                stepInspectorSection == section ? selectedRunStep.kind.tint.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepInspectorCount(for section: AutomationStepInspectorSection) -> String? {
        switch section {
        case .inputs: stepIsLLM ? "4" : "3"
        case .context: "5"
        case .messages: "4"
        case .tools: "2"
        case .outputs: stepIsLLM ? "2" : "4"
        case .errors: selectedRun.state == .blocked ? "1" : "0"
        case .storage: "2"
        default: nil
        }
    }

    @ViewBuilder
    private var detailedStepInspectorContent: some View {
        switch stepInspectorSection {
        case .overview:
            stepOverviewContent
        case .inputs:
            stepInputsAndOutputsContent
        case .context:
            llmContextContent
        case .messages:
            llmMessagesContent
        case .tools:
            llmToolsAndUsageContent
        case .outputs:
            stepOutputContent
        case .errors:
            stepErrorsContent
        case .usage:
            llmUsageContent
        case .storage:
            jobStorageInspector
        case .logs:
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("Structured logs", detail: "Four events · node-local timestamps")
                runLogLine("22:31:04.218", "Loaded immutable input checkpoint", KanameColor.separator)
                runLogLine("22:31:04.231", "Validated input schema case-context.v3", KanameColor.success)
                runLogLine("22:31:04.247", "Committed output checkpoint 7d91…a8c2", KanameColor.accent)
                runLogLine("22:31:04.251", "Released job-storage write lease", KanameColor.blocked)
            }
        case .raw:
            rawStepEvidenceContent
        }
    }

    private var stepOverviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("What happened", detail: "A concise summary before opening the underlying records")
            HStack(spacing: 10) {
                overviewTile("Input", value: "3 variables · 2.4 KB", symbol: "arrow.down.doc", tint: KanameColor.accent)
                overviewTile("Output", value: selectedRun.state == .blocked ? "No output committed" : "4 values · 6.8 KB", symbol: "arrow.up.doc", tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success)
                overviewTile("Storage", value: "2 job values changed", symbol: "shippingbox", tint: KanameColor.blocked)
                overviewTile("Evidence", value: "Input + output digests", symbol: "checkmark.seal", tint: KanameColor.warning)
            }
            Label(
                selectedRun.state == .blocked
                    ? "The failed attempt preserved its input checkpoint. No partial output became visible downstream."
                    : "Downstream nodes received only the committed output checkpoint shown here.",
                systemImage: selectedRun.state == .blocked ? "exclamationmark.shield" : "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success)
        }
    }

    private var stepInputsAndOutputsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Variables at this node", detail: "Value, type, and provenance are kept together")
            HStack(alignment: .top, spacing: 10) {
                executionDataPanel(
                    "Variables passed in",
                    subtitle: "Immutable input checkpoint · b840…19fc",
                    tint: KanameColor.accent,
                    rows: [
                        ("case_id", "String", "CASE-184", "Correlate case"),
                        ("episode", "Integer", "3", "Job storage"),
                        ("current_reply", "String", "Change the totals…", "Inbound email"),
                    ]
                )
                executionDataPanel(
                    "Output produced",
                    subtitle: selectedRun.state == .blocked ? "No checkpoint committed" : "Committed checkpoint · 7d91…a8c2",
                    tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success,
                    rows: selectedRun.state == .blocked ? [
                        ("—", "—", "No output", "Attempt failed"),
                    ] : [
                        ("context_pack", "Object", "5 grouped sections", "This node"),
                        ("message_count", "Integer", "4", "This node"),
                        ("artifact_ref", "File", "report-v2.xlsx", "Job storage"),
                    ]
                )
            }
        }
    }

    private var stepOutputContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Committed output", detail: "Only this checkpoint became visible to downstream nodes")
            executionDataPanel(
                stepIsLLM ? "Assistant result" : "Produced values",
                subtitle: selectedRun.state == .blocked ? "No checkpoint committed" : "Schema-valid · digest 7d91…a8c2",
                tint: selectedRun.state == .blocked ? KanameColor.danger : KanameColor.success,
                rows: selectedRun.state == .blocked ? [
                    ("—", "—", "No output", "Attempt failed"),
                ] : stepIsLLM ? [
                    ("summary", "String", "12 mailbox themes…", "Model response"),
                    ("citations", "Array", "2 source references", "Validated output"),
                ] : [
                    ("context_pack", "Object", "5 grouped sections", "This node"),
                    ("message_count", "Integer", "4", "This node"),
                    ("artifact_ref", "File", "report-v2.xlsx", "Job storage"),
                    ("redactions", "Integer", "2", "Privacy policy"),
                ]
            )
        }
    }

    @ViewBuilder
    private var stepErrorsContent: some View {
        if selectedRun.state == .blocked {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(KanameColor.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Provider outcome could not be proven").font(.caption.weight(.bold))
                        Text("The effect may have completed, so Kaname will not retry it automatically.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("UNKNOWN_OUTCOME")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(KanameColor.danger)
                }
                .padding(9)
                .background(KanameColor.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .top, spacing: 10) {
                    diagnosticPanel(
                        "What failed",
                        rows: [
                            ("Stage", "Post-effect reconciliation"),
                            ("Safe message", "Provider response timed out"),
                            ("Technical cause", "Transport closed before receipt"),
                            ("Error ID", "err_01J8…M4Q"),
                        ],
                        tint: KanameColor.danger
                    )
                    diagnosticPanel(
                        "What happens next",
                        rows: [
                            ("Retry", "Blocked — outcome is ambiguous"),
                            ("Input", "Checkpoint retained"),
                            ("Output", "Nothing committed downstream"),
                            ("Recovery", "Human reconcile with provider"),
                        ],
                        tint: KanameColor.warning
                    )
                }
                HStack {
                    Label("Stack trace and provider payload are available under Technical detail", systemImage: "chevron.right")
                    Spacer()
                    Button("Open technical detail") {}
                        .buttonStyle(.borderless)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Errors", detail: "No warnings or failures were recorded for this attempt")
                Label("Succeeded without retries", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.success)
            }
        }
    }

    private var llmContextContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Context envelope sent to the model", detail: "Five named groups · 6,240 tokens · two protected fields redacted")
            HStack(alignment: .top, spacing: 8) {
                contextEnvelopeCard(
                    "System policy",
                    detail: "Mailbox summarizer · no external effects",
                    provenance: "Kaname policy · 620 tokens",
                    symbol: "shield.fill",
                    tint: KanameColor.warning
                )
                contextEnvelopeCard(
                    "Workflow instructions",
                    detail: "Summarize only the declared projection",
                    provenance: "Workflow v3 · 580 tokens",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: KanameColor.blocked
                )
                contextEnvelopeCard(
                    "Current input",
                    detail: "184 messages · allowed fields only",
                    provenance: "Fan out · 3,820 tokens",
                    symbol: "arrow.down.doc",
                    tint: KanameColor.accent
                )
            }
            HStack(alignment: .top, spacing: 8) {
                contextEnvelopeCard(
                    "Conversation history",
                    detail: "3 prior messages · role-separated",
                    provenance: "Case thread · 1,140 tokens",
                    symbol: "bubble.left.and.bubble.right",
                    tint: KanameColor.active
                )
                contextEnvelopeCard(
                    "Attachments & sources",
                    detail: "2 retrieved excerpts · content digests retained",
                    provenance: "Job storage · 80 tokens",
                    symbol: "paperclip",
                    tint: KanameColor.success
                )
                Label("Hidden chain-of-thought is not exposed. Configured reasoning effort and provider-supplied summaries live under Usage.", systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                    .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmMessagesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Messages", detail: "Role-separated summaries · expand one record at a time")
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 5) {
                    messageRecord("System", index: "01", summary: "Policy and output contract", detail: "1,200 tokens", tint: KanameColor.warning)
                    messageRecord("User", index: "02", summary: "Mailbox projection and requested digest", detail: "3,820 tokens", tint: KanameColor.accent)
                    messageRecord("Assistant", index: "03", summary: "Requested two read-only tools", detail: "146 tokens", tint: KanameColor.blocked)
                    messageRecord("Tool", index: "04", summary: "Two linked results · both succeeded", detail: "1,074 tokens", tint: KanameColor.success)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Label("Selected · User 02", systemImage: "bubble.left.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(KanameColor.accent)
                    Text("Summarize this frozen mailbox batch using only sender domain, subject category, received date, and the approved excerpt.")
                        .font(.caption)
                        .textSelection(.enabled)
                    Divider()
                    HStack {
                        evidenceFact("Origin", value: "Fan out")
                        Spacer()
                        evidenceFact("Content", value: "3,820 tokens")
                        Spacer()
                        evidenceFact("Redaction", value: "2 fields")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmToolsAndUsageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Tool calls", detail: "Inputs, results, and the messages they belong to remain linked")
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    toolCallRecord(
                        "lookup_sender_policy",
                        callID: "call_7K2",
                        input: "domain: example.co.jp",
                        result: "matched · protected_sender = false",
                        duration: "34 ms"
                    )
                    toolCallRecord(
                        "read_job_value",
                        callID: "call_8F1",
                        input: "key: digest.allowed_categories",
                        result: "6 categories · checkpoint 3c91…",
                        duration: "8 ms"
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Model & usage").font(.caption.weight(.bold))
                    usageRow("Configured model", value: "Pinned by workflow v3")
                    usageRow("Reasoning effort", value: "Medium · configured")
                    usageRow("Tokens", value: "6,240 in · 842 out")
                    usageRow("Tool calls", value: "2 / 2 succeeded")
                    usageRow("Provider summary", value: "Not supplied")
                    usageRow("Cost", value: "Shown when provider reports it")
                }
                .padding(10)
                .frame(width: 260, alignment: .topLeading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var llmUsageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Model & usage", detail: "Configured values are separated from provider-reported values")
            HStack(alignment: .top, spacing: 10) {
                diagnosticPanel(
                    "Configuration",
                    rows: [
                        ("Model", "Pinned by workflow v3"),
                        ("Reasoning effort", "Medium"),
                        ("Temperature", "Workflow default"),
                        ("Tool policy", "Two read-only tools"),
                    ],
                    tint: KanameColor.blocked
                )
                diagnosticPanel(
                    "Provider report",
                    rows: [
                        ("Input tokens", "6,240"),
                        ("Output tokens", "842"),
                        ("Latency", "1.8 s"),
                        ("Reasoning summary", "Not supplied"),
                    ],
                    tint: KanameColor.accent
                )
            }
        }
    }

    private var rawStepEvidenceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Raw evidence", detail: "Complete records remain available for export and exact replay diagnostics")
            codePayload("Execution envelope", text: rawStepEnvelope)
            Label("Raw evidence is never the default view and retains explicit redaction markers.", systemImage: "eye.slash.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var rawStepEnvelope: String {
        "{ \"run_id\": \(selectedRun.id), \"node_id\": \"\(selectedRunStep.id)\", \"attempt\": 1, \"input_digest\": \"b840…19fc\", \"output_digest\": \"7d91…a8c2\" }"
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption.weight(.bold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func inspectorStatusFact(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
    }

    private func overviewTile(_ title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.semibold)).lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func executionDataPanel(
        _ title: String,
        subtitle: String,
        tint: Color,
        rows: [(String, String, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption.weight(.bold))
                Spacer()
                Text(subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(.system(.caption2, design: .monospaced).weight(.semibold))
                        Text(row.3).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(width: 106, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                        .frame(width: 58, alignment: .leading)
                    Text(row.2).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25), lineWidth: 1) }
    }

    private func diagnosticPanel(
        _ title: String,
        rows: [(String, String)],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(tint)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1).multilineTextAlignment(.trailing)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.24), lineWidth: 1) }
    }

    private func contextEnvelopeCard(
        _ title: String,
        detail: String,
        provenance: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(detail).font(.caption2).lineLimit(2)
            Text(provenance).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func messageRecord(
        _ role: String,
        index: String,
        summary: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text(index)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(role).font(.caption2.weight(.bold)).frame(width: 52, alignment: .leading)
            Text(summary).font(.caption2).lineLimit(1)
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .padding(7)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }

    private func toolCallRecord(
        _ name: String,
        callID: String,
        input: String,
        result: String,
        duration: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(name, systemImage: "wrench.and.screwdriver.fill")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(KanameColor.blocked)
                Text(callID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Label("Succeeded", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(KanameColor.success)
                Text(duration).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("INPUT").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(input).font(.system(.caption2, design: .monospaced)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("RESULT").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(result).font(.system(.caption2, design: .monospaced)).lineLimit(1)
            }
        }
        .padding(9)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.blocked.opacity(0.22), lineWidth: 1) }
    }

    private func usageRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var runInspectorContent: some View {
        switch inspectorTab {
        case .data:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(selectedRunEdge == nil ? "Attempt data" : "Data at this boundary")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Picker("Data rendering", selection: $dataView) {
                        ForEach(AutomationRunDataView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    Text("1 item · 2.4 KB").font(.caption2).foregroundStyle(.secondary)
                }
                dataPayload
            }
        case .storage:
            jobStorageInspector
        case .logs:
            runLogLine("22:31:04.218", "Loaded immutable input checkpoint", KanameColor.separator)
            runLogLine("22:31:04.231", "Validated schema case-context.v3", KanameColor.success)
            runLogLine("22:31:04.247", "Produced 1 item · digest 7d91…a8c2", KanameColor.accent)
        case .configuration:
            HStack(spacing: 28) {
                evidenceFact("Definition", value: "Workflow v\(selectedRun.version)")
                evidenceFact("Node", value: selectedRunEdge?.sourceID ?? selectedRunStep.id)
                evidenceFact("Retry", value: "Attempt 1 of 3")
                evidenceFact("Authority", value: selectedRunStep.authority)
                evidenceFact("Runtime", value: "Private local capability")
            }
        case .evidence:
            HStack(spacing: 28) {
                evidenceFact("Input digest", value: "b840…19fc")
                evidenceFact("Output digest", value: "7d91…a8c2")
                evidenceFact("Artifact", value: "context-snapshot.json")
                evidenceFact("Retention", value: selectedRun.expiry)
                evidenceFact("Redaction", value: "2 protected fields")
            }
        }
    }

    private var jobStorageInspector: some View {
        HStack(alignment: .top, spacing: 10) {
            storageInspectorColumn(
                "Job storage · #\(selectedRun.id)",
                subtitle: "Private to this job",
                symbol: "shippingbox.fill",
                tint: KanameColor.accent,
                rows: [
                    ("Values", "7 · 182 KB"),
                    ("Files", "3 · 48.0 MB"),
                    ("Lifetime", selectedRun.expiry),
                ]
            )
            storageInspectorColumn(
                "Recent changes",
                subtitle: "Committed by nodes",
                symbol: "arrow.triangle.2.circlepath",
                tint: KanameColor.success,
                rows: [
                    ("Run work type", "+ report-v3.xlsx"),
                    ("Compile context", "~ episode = 3"),
                    ("Verify all", "+ validation.json"),
                ]
            )
            storageInspectorColumn(
                "Workflow storage",
                subtitle: "Not deleted with this job",
                symbol: "externaldrive.fill",
                tint: KanameColor.blocked,
                rows: [
                    ("Durable values", "12"),
                    ("Promoted files", "4 · 86 MB"),
                    ("Scope", "All workflow versions"),
                ]
            )
        }
    }

    private func storageInspectorColumn(
        _ title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).fontWeight(.semibold).multilineTextAlignment(.trailing)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.24), lineWidth: 1) }
    }

    @ViewBuilder
    private var dataPayload: some View {
        if selectedRunEdge == nil {
            nodeDataComparison
        } else {
            checkpointDataPayload
        }
    }

    @ViewBuilder
    private var nodeDataComparison: some View {
        switch dataView {
        case .table:
            HStack(alignment: .top, spacing: 10) {
                comparisonPanel("Received", tint: KanameColor.separator) {
                    comparisonRow("episodes", value: "2")
                    comparisonRow("artifact", value: "report-v2.xlsx")
                    comparisonRow("instruction", value: "Use monthly totals")
                }
                comparisonPanel("Produced", tint: KanameColor.success) {
                    comparisonRow("episodes", value: "3", changed: true)
                    comparisonRow("artifact", value: "report-v3.xlsx", changed: true)
                    comparisonRow("current_intent", value: "correction", changed: true)
                }
            }
        case .json:
            HStack(alignment: .top, spacing: 10) {
                codePayload("Received", text: "{ \"episodes\": 2, \"artifact\": \"report-v2.xlsx\" }")
                codePayload("Produced", text: "{ \"episodes\": 3, \"artifact\": \"report-v3.xlsx\", \"current_intent\": \"correction\" }")
            }
        case .schema:
            HStack(alignment: .top, spacing: 10) {
                codePayload("Input schema", text: "episodes: [episode]\nartifact: file_reference")
                codePayload("Output schema", text: "episodes: [episode]\nartifact: file_reference\ncurrent_intent: enum")
            }
        }
    }

    @ViewBuilder
    private var checkpointDataPayload: some View {
        switch dataView {
        case .table:
            HStack(spacing: 0) {
                dataCell("case_id", value: "CASE-184")
                dataCell("episode", value: "3")
                dataCell("intent", value: "correction")
                dataCell("artifact", value: "report-v3.xlsx")
                dataCell("status", value: "verified")
            }
        case .json:
            codePayload("Checkpoint JSON", text: "{ \"case_id\": \"CASE-184\", \"episode\": 3, \"intent\": \"correction\", \"artifact\": \"report-v3.xlsx\", \"status\": \"verified\" }")
        case .schema:
            codePayload("Checkpoint schema", text: "case_id: string · episode: integer · intent: enum · artifact: file_reference · status: enum")
        }
    }

    private func comparisonPanel<Content: View>(
        _ title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func comparisonRow(_ field: String, value: String, changed: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(field).foregroundStyle(.secondary)
            Spacer()
            if changed {
                Image(systemName: "plus.circle.fill").foregroundStyle(KanameColor.success)
            }
            Text(value).lineLimit(1)
        }
        .font(.system(.caption2, design: .monospaced))
    }

    private func codePayload(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(KanameColor.accent)
                .textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private func dataCell(_ field: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.canvas)
        .overlay { Rectangle().stroke(KanameColor.separator.opacity(0.8), lineWidth: 0.5) }
    }

    private func runLogLine(_ time: String, _ message: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(time).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(message).font(.system(.caption, design: .monospaced))
        }
    }

    private func edgeEndpointLabel(_ edge: AutomationCanvasEdge) -> String {
        let graph = selectedRun.pattern.graph
        let source = graph.steps.first(where: { $0.id == edge.sourceID })?.title ?? edge.sourceID
        let target = graph.steps.first(where: { $0.id == edge.targetID })?.title ?? edge.targetID
        return "\(source) → \(target) · immutable checkpoint"
    }

    private var retentionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("History retention", systemImage: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
            Text("Default for new runs of this workflow")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Retention", selection: $retention) {
                ForEach(AutomationRunRetention.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            retentionExplanation
            Divider()
            Label("Unresolved runs are protected", systemImage: "shield.fill")
                .foregroundStyle(KanameColor.warning)
            Text("Waiting, failed, or unknown outcomes remain until resolved or manually deleted, even when successful runs are removed immediately.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text("Storage estimate").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("18 runs · 42 MB").font(.caption.weight(.semibold))
            Button("Delete selected…", systemImage: "trash", role: .destructive) {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
        .padding(20)
        .frame(maxWidth: 720, minHeight: 520, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var retentionExplanation: some View {
        switch retention {
        case .thirtyDays:
            Text("Successful and settled runs are deleted 30 days after completion.")
        case .deleteAfterSuccess:
            Text("Successful run detail is deleted after its final receipt is reconciled.")
        case .forever:
            Text("Run history remains until you delete it manually.")
        }
    }

    private var deleteJobConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(KanameColor.danger)
                    .frame(width: 34, height: 34)
                    .background(KanameColor.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete job #\(selectedRun.id)?").font(.title3.weight(.bold))
                    Text("This cannot be undone").font(.caption).foregroundStyle(KanameColor.danger)
                }
                Spacer()
                Button("Close", systemImage: "xmark") {
                    showsDeleteJobConfirmation = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }

            Text("The job record and everything isolated inside its storage boundary will be removed together.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                deletionRow("Run history and trace", value: "1 job", deleted: true)
                Divider()
                deletionRow("Job values", value: "7 · 182 KB", deleted: true)
                Divider()
                deletionRow("Job files", value: "3 · 48.0 MB", deleted: true)
                Divider()
                deletionRow("Workflow storage", value: "4 files · 86 MB", deleted: false)
            }
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 9))

            Label(
                "Promoted files and long-term values remain in workflow storage.",
                systemImage: "externaldrive.fill.badge.checkmark"
            )
            .font(.caption)
            .foregroundStyle(KanameColor.blocked)

            HStack {
                Spacer()
                Button("Cancel") {
                    showsDeleteJobConfirmation = false
                }
                .buttonStyle(.bordered)
                Button("Delete job and job storage", role: .destructive) {}
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(KanameColor.danger.opacity(0.45), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private func deletionRow(_ label: String, value: String, deleted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: deleted ? "trash" : "lock.shield.fill")
                .foregroundStyle(deleted ? KanameColor.danger : KanameColor.blocked)
                .frame(width: 18)
            Text(label).font(.caption.weight(.semibold))
            Spacer()
            Text(deleted ? "Delete · \(value)" : "Keep · \(value)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(deleted ? KanameColor.danger : KanameColor.blocked)
        }
        .padding(10)
    }

    private func evidenceFact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }
}
