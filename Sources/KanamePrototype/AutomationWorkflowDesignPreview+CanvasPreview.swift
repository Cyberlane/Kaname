import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

enum AutomationCanvasPattern: String, CaseIterable, Identifiable {
    case decision = "Decision"
    case parallel = "Parallel"
    case approval = "Approval"
    case feedback = "Feedback"
    case recovery = "Recovery"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .decision: "Route one input by a deterministic outcome"
        case .parallel: "Fan out independent work and join its results"
        case .approval: "Pause, revise, wait, and resume durably"
        case .feedback: "Keep one case alive across replies, revisions, and attachments"
        case .recovery: "Separate retryable failures from unknown outcomes"
        }
    }

    var title: String {
        switch self {
        case .decision: "Mailbox review / Decision"
        case .parallel: "Mailbox review / Parallel work"
        case .approval: "Correspondence / Approval"
        case .feedback: "Reply-driven case / Episode 3"
        case .recovery: "Approved effect / Recovery"
        }
    }

    var graph: AutomationCanvasGraph {
        switch self {
        case .decision:
            AutomationCanvasGraph(
                defaultSelectedID: "classify",
                groups: [
                    .init(id: "read", title: "READ-ONLY", x: 0.02, y: 0.08, width: 0.67, height: 0.84, tint: KanameColor.accent),
                    .init(id: "routes", title: "ROUTED OUTPUTS", x: 0.71, y: 0.08, width: 0.27, height: 0.84, tint: KanameColor.warning),
                ],
                steps: [
                    .init(id: "trigger", title: "New mail", subtitle: "Account-scoped trigger", symbol: "envelope.badge", kind: .trigger, x: 0.10, y: 0.50, state: .complete, input: "Mail event", output: "Message reference", authority: "Observe only"),
                    .init(id: "freeze", title: "Freeze result", subtitle: "Complete pagination", symbol: "snowflake", kind: .data, x: 0.32, y: 0.50, state: .complete, input: "Search query", output: "Frozen batch", authority: "Read mail"),
                    .init(id: "classify", title: "Classify", subtitle: "Deterministic policy", symbol: "arrow.triangle.branch", kind: .decision, x: 0.57, y: 0.50, state: .running, input: "Frozen batch", output: "Three typed routes", authority: "No effect authority"),
                    .init(id: "protected", title: "Protected", subtitle: "Record exclusion", symbol: "shield.fill", kind: .policy, x: 0.84, y: 0.20, state: .complete, input: "Protected items", output: "Exclusion receipt", authority: "No effect"),
                    .init(id: "eligible", title: "Eligible", subtitle: "Continue subflow", symbol: "square.stack.3d.up", kind: .subflow, x: 0.84, y: 0.50, state: .waiting, input: "Eligible items", output: "Reviewed proposal", authority: "Inherited: none"),
                    .init(id: "uncertain", title: "Needs review", subtitle: "Human decision", symbol: "person.crop.circle.badge.questionmark", kind: .human, x: 0.84, y: 0.80, state: .waiting, input: "Uncertain items", output: "Reviewed route", authority: "Decision only"),
                ],
                edges: [
                    .init("trigger", "freeze", label: "message", kind: .data, active: true),
                    .init("freeze", "classify", label: "184 items", kind: .data, active: true),
                    .init("classify", "protected", label: "protected", kind: .conditional, active: false),
                    .init("classify", "eligible", label: "eligible", kind: .success, active: false),
                    .init("classify", "uncertain", label: "uncertain", kind: .conditional, active: true),
                ]
            )
        case .parallel:
            AutomationCanvasGraph(
                defaultSelectedID: "fanout",
                groups: [
                    .init(id: "parallel", title: "PARALLEL LANES", x: 0.34, y: 0.07, width: 0.42, height: 0.86, tint: KanameColor.blocked),
                ],
                steps: [
                    .init(id: "batch", title: "Frozen batch", subtitle: "184 messages", symbol: "shippingbox", kind: .data, x: 0.10, y: 0.50, state: .complete, input: "Query result", output: "Mail batch", authority: "Read only"),
                    .init(id: "fanout", title: "Fan out", subtitle: "Start 3 lanes", symbol: "arrow.triangle.branch", kind: .parallel, x: 0.30, y: 0.50, state: .running, input: "Mail batch", output: "Three streams", authority: "No effect"),
                    .init(id: "label", title: "Plan labels", subtitle: "Deterministic", symbol: "tag", kind: .data, x: 0.54, y: 0.20, state: .running, input: "Mail stream", output: "Label plan", authority: "Proposal only"),
                    .init(id: "extract", title: "Extract fields", subtitle: "Private capability", symbol: "tablecells", kind: .subflow, x: 0.54, y: 0.50, state: .running, input: "Mail stream", output: "Dataset rows", authority: "Private dataset"),
                    .init(id: "summarize", title: "Summarize", subtitle: "Minimum projection", symbol: "sparkles", kind: .ai, x: 0.54, y: 0.80, state: .running, input: "Allowed fields", output: "Short summary", authority: "Declared egress"),
                    .init(id: "join", title: "Join", subtitle: "Wait for all lanes", symbol: "arrow.triangle.merge", kind: .join, x: 0.74, y: 0.50, state: .waiting, input: "3 typed results", output: "Combined result", authority: "No effect"),
                    .init(id: "receipt", title: "Receipt", subtitle: "One evidence set", symbol: "doc.text.magnifyingglass", kind: .receipt, x: 0.91, y: 0.50, state: .planned, input: "Combined result", output: "Run evidence", authority: "Local write"),
                ],
                edges: [
                    .init("batch", "fanout", label: "batch", kind: .data, active: true),
                    .init("fanout", "label", label: "lane 1", kind: .parallel, active: true),
                    .init("fanout", "extract", label: "lane 2", kind: .parallel, active: true),
                    .init("fanout", "summarize", label: "lane 3", kind: .parallel, active: true),
                    .init("label", "join", label: "plan", kind: .parallel, active: true),
                    .init("extract", "join", label: "rows", kind: .parallel, active: true),
                    .init("summarize", "join", label: "summary", kind: .parallel, active: true),
                    .init("join", "receipt", label: "all complete", kind: .success, active: false),
                ]
            )
        case .approval:
            AutomationCanvasGraph(
                defaultSelectedID: "approval",
                groups: [
                    .init(id: "human", title: "HUMAN BOUNDARY", x: 0.25, y: 0.08, width: 0.34, height: 0.84, tint: KanameColor.warning),
                    .init(id: "effect", title: "APPROVED EFFECT", x: 0.61, y: 0.08, width: 0.37, height: 0.84, tint: KanameColor.danger),
                ],
                steps: [
                    .init(id: "draft", title: "Prepare draft", subtitle: "No send", symbol: "square.and.pencil", kind: .data, x: 0.10, y: 0.50, state: .complete, input: "Full thread", output: "Draft proposal", authority: "Draft only"),
                    .init(id: "approval", title: "Review", subtitle: "Recipients + content", symbol: "person.crop.circle.badge.checkmark", kind: .human, x: 0.40, y: 0.50, state: .waiting, input: "Draft proposal", output: "Approve or revise", authority: "Human decision"),
                    .init(id: "send", title: "Send", subtitle: "Idempotent effect", symbol: "paperplane.fill", kind: .effect, x: 0.69, y: 0.27, state: .planned, input: "Approved envelope", output: "Provider receipt", authority: "Exact send approval"),
                    .init(id: "revise", title: "Revise", subtitle: "Return to review", symbol: "arrow.uturn.backward", kind: .loop, x: 0.69, y: 0.73, state: .planned, input: "Review notes", output: "New draft revision", authority: "No send"),
                    .init(id: "wait", title: "Wait for reply", subtitle: "Durable resume", symbol: "clock.badge", kind: .wait, x: 0.89, y: 0.27, state: .planned, input: "Sent thread", output: "Reply event", authority: "Observe only"),
                ],
                edges: [
                    .init("draft", "approval", label: "proposal", kind: .data, active: true),
                    .init("approval", "send", label: "approve", kind: .success, active: false),
                    .init("approval", "revise", label: "changes", kind: .conditional, active: true),
                    .init("revise", "approval", label: "revision 2", kind: .loop, active: true),
                    .init("send", "wait", label: "reconciled", kind: .success, active: false),
                ]
            )
        case .feedback:
            AutomationCanvasGraph(
                defaultSelectedID: "context",
                groups: [
                    .init(id: "case", title: "CASE-184 · ONE DURABLE CONVERSATION", x: 0.02, y: 0.05, width: 0.96, height: 0.90, tint: KanameColor.accent),
                    .init(id: "effect-wait", title: "EFFECT + DURABLE WAIT", x: 0.80, y: 0.08, width: 0.18, height: 0.70, tint: KanameColor.danger),
                    .init(id: "episodes", title: "FEEDBACK EPISODES · ARTIFACT LINEAGE", x: 0.36, y: 0.68, width: 0.62, height: 0.27, tint: KanameColor.blocked),
                ],
                steps: [
                    .init(id: "inbound", title: "Inbound email", subtitle: "New message or reply", symbol: "envelope.badge", kind: .trigger, x: 0.09, y: 0.28, state: .complete, input: "Scoped mail event", output: "Thread + message refs", authority: "Observe only"),
                    .init(id: "correlate", title: "Correlate case", subtitle: "Thread + durable case ID", symbol: "link", kind: .decision, x: 0.27, y: 0.28, state: .complete, input: "Thread reference", output: "Existing or new case", authority: "No effect"),
                    .init(id: "context", title: "Compile context", subtitle: "Episodes + current facts", symbol: "text.append", kind: .context, x: 0.46, y: 0.28, state: .running, input: "Case history + artifacts", output: "Bounded context pack", authority: "Private case data"),
                    .init(id: "execute", title: "Run work type", subtitle: "Pinned private subflow", symbol: "square.stack.3d.up", kind: .subflow, x: 0.65, y: 0.28, state: .planned, input: "Context + current inputs", output: "Artifact revision", authority: "Subflow contract"),
                    .init(id: "verify", title: "Verify all", subtitle: "Whole-request checks", symbol: "checkmark.seal", kind: .policy, x: 0.83, y: 0.28, state: .planned, input: "Artifact + acceptance rules", output: "Verified revision", authority: "No send"),
                    .init(id: "reply", title: "Reply + attach", subtitle: "Same email thread", symbol: "paperplane.fill", kind: .effect, x: 0.90, y: 0.50, state: .planned, input: "Verified artifact v3", output: "Provider receipt", authority: "Exact send approval"),
                    .init(id: "wait", title: "Wait for reply", subtitle: "Sending is not completion", symbol: "clock.badge", kind: .wait, x: 0.90, y: 0.72, state: .waiting, input: "Thread checkpoint", output: "Reply event", authority: "Observe only"),
                    .init(id: "interpret", title: "Interpret reply", subtitle: "Accept, correct, clarify", symbol: "arrow.triangle.branch", kind: .decision, x: 0.70, y: 0.80, state: .running, input: "Reply + case context", output: "Typed response route", authority: "No effect"),
                    .init(id: "append", title: "Append episode", subtitle: "Supersede, never erase", symbol: "text.badge.plus", kind: .context, x: 0.46, y: 0.80, state: .planned, input: "Correction or new file", output: "Episode 4 + artifact refs", authority: "Private case write"),
                    .init(id: "close", title: "Close case", subtitle: "Accepted or manually closed", symbol: "checkmark.circle.fill", kind: .receipt, x: 0.90, y: 0.92, state: .planned, input: "Accepted outcome", output: "Case receipt", authority: "Local state only"),
                ],
                edges: [
                    .init("inbound", "correlate", label: "mail event", kind: .data, active: true),
                    .init("correlate", "context", label: "same case", kind: .success, active: true),
                    .init("context", "execute", label: "episode 3", kind: .data, active: true),
                    .init("execute", "verify", label: "artifact v3", kind: .data, active: false),
                    .init("verify", "reply", label: "all checks pass", kind: .success, active: false),
                    .init("reply", "wait", label: "sent + reconciled", kind: .success, active: false),
                    .init("wait", "interpret", label: "reply received", kind: .data, active: true),
                    .init("interpret", "close", label: "accepted", kind: .success, active: false),
                    .init("interpret", "append", label: "change / clarify / file", kind: .conditional, active: true),
                    .init("append", "context", label: "episode 4 · same case", kind: .loop, active: true),
                ]
            )
        case .recovery:
            AutomationCanvasGraph(
                defaultSelectedID: "effect",
                groups: [
                    .init(id: "effect", title: "EFFECT BOUNDARY", x: 0.20, y: 0.08, width: 0.27, height: 0.84, tint: KanameColor.danger),
                    .init(id: "recovery", title: "RECOVERY ROUTES", x: 0.49, y: 0.08, width: 0.49, height: 0.84, tint: KanameColor.external),
                ],
                steps: [
                    .init(id: "each", title: "For each item", subtitle: "Bounded batch", symbol: "repeat", kind: .loop, x: 0.09, y: 0.50, state: .complete, input: "Frozen targets", output: "One target", authority: "No effect"),
                    .init(id: "effect", title: "Apply action", subtitle: "Idempotency key", symbol: "checkmark.shield", kind: .effect, x: 0.33, y: 0.50, state: .running, input: "Exact target", output: "Effect outcome", authority: "Frozen batch approval"),
                    .init(id: "success", title: "Succeeded", subtitle: "Reconcile target", symbol: "checkmark.circle.fill", kind: .receipt, x: 0.60, y: 0.20, state: .complete, input: "Known success", output: "Verified receipt", authority: "Read back"),
                    .init(id: "retry", title: "Retry", subtitle: "Backoff + limit", symbol: "arrow.clockwise", kind: .loop, x: 0.60, y: 0.50, state: .waiting, input: "Known failure", output: "New attempt", authority: "Same approved target"),
                    .init(id: "unknown", title: "Unknown outcome", subtitle: "Never auto-retry", symbol: "questionmark.diamond.fill", kind: .error, x: 0.60, y: 0.80, state: .blocked, input: "Ambiguous result", output: "Attention item", authority: "Effects blocked"),
                    .init(id: "reconcile", title: "Human reconcile", subtitle: "Inspect provider", symbol: "person.crop.circle.badge.exclamationmark", kind: .human, x: 0.87, y: 0.80, state: .waiting, input: "Unknown outcome", output: "Resolved status", authority: "Decision only"),
                    .init(id: "receipt", title: "Batch receipt", subtitle: "Success / skip / fail", symbol: "doc.text.magnifyingglass", kind: .receipt, x: 0.87, y: 0.20, state: .planned, input: "Settled targets", output: "Audit evidence", authority: "Local write"),
                ],
                edges: [
                    .init("each", "effect", label: "target 38", kind: .data, active: true),
                    .init("effect", "success", label: "success", kind: .success, active: false),
                    .init("effect", "retry", label: "known failure", kind: .error, active: true),
                    .init("effect", "unknown", label: "ambiguous", kind: .error, active: false),
                    .init("retry", "effect", label: "attempt 2", kind: .loop, active: true),
                    .init("unknown", "reconcile", label: "needs you", kind: .error, active: false),
                    .init("success", "receipt", label: "verified", kind: .success, active: false),
                    .init("reconcile", "receipt", label: "settled", kind: .conditional, active: false),
                ]
            )
        }
    }
}

enum AutomationInspectorSection: String, CaseIterable {
    case configuration = "Config"
    case data = "Data"
    case history = "History"
    case safety = "Safety"
}

private enum AutomationEditorMode: String, CaseIterable {
    case canvas = "Canvas"
    case outline = "Outline"
    case source = "Source"
}

private enum AutomationBuilderDesignPanel {
    case standard
    case newWorkflow
    case condition
    case mapping
    case test
    case problems
    case publish
    case storage
    case storagePromotion

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-builder-new") { self = .newWorkflow }
        else if arguments.contains("--desktop-automation-builder-condition") { self = .condition }
        else if arguments.contains("--desktop-automation-builder-mapping") { self = .mapping }
        else if arguments.contains("--desktop-automation-builder-test") { self = .test }
        else if arguments.contains("--desktop-automation-builder-problems") { self = .problems }
        else if arguments.contains("--desktop-automation-builder-publish") { self = .publish }
        else if arguments.contains("--desktop-automation-builder-storage-promotion") { self = .storagePromotion }
        else if arguments.contains("--desktop-automation-builder-storage") { self = .storage }
        else { self = .standard }
    }
}

enum AutomationCanvasViewportPreset {
    case standard
    case readable
    case semanticOverview
    case feedbackFocus

    var title: String {
        switch self {
        case .standard: "Stable canvas"
        case .readable: "Readable 100%"
        case .semanticOverview: "Fit all · semantic overview"
        case .feedbackFocus: "Focus · Feedback & correction"
        }
    }

    var zoomLabel: String {
        switch self {
        case .standard: "Fit"
        case .readable: "100%"
        case .semanticOverview: "Fit"
        case .feedbackFocus: "Focus"
        }
    }
}

private enum AutomationCompactBuilderPanel: Equatable {
    case palette
    case inspector
}

struct AutomationCanvasPreview: View {
    private let workflowID: String
    private let viewportPreset: AutomationCanvasViewportPreset
    private let builderDesignPanel: AutomationBuilderDesignPanel
    private let liveWorkflow: AutomationWorkflowPreview?
    private let liveGraph: AutomationCanvasGraph?
    private let liveRevisions: [DesktopWorkflowRevisionRecord]
    private let liveSourceLines: [String]
    private let editAction: (() -> Void)?
    private let runAction: (() -> Void)?
    private let publishAction: (() -> Void)?
    @State private var pattern: AutomationCanvasPattern
    @State private var selectedStepID: String
    @State private var selectedEdgeID: String?
    @State private var inspectorSection = AutomationInspectorSection.configuration
    @State private var isSimulating = true
    @State private var editorMode: AutomationEditorMode
    @State private var isEditing = false
    @State private var showsVersionHistory = false
    @State private var selectedProblemID: String?
    @State private var diagnosticNavigation = DesktopWorkflowDiagnosticNavigationState()
    @State private var problemFocusMessage: String?
    @State private var problemsExpanded: Bool
    @State private var compactPanel: AutomationCompactBuilderPanel?

    init(workflowID: String) {
        self.workflowID = workflowID
        liveWorkflow = nil
        liveGraph = nil
        liveRevisions = []
        liveSourceLines = []
        editAction = nil
        runAction = nil
        publishAction = nil
        let arguments = CommandLine.arguments
        builderDesignPanel = AutomationBuilderDesignPanel(arguments: arguments)
        if arguments.contains("--desktop-automation-small-readable") {
            viewportPreset = .readable
        } else if arguments.contains("--desktop-automation-small-overview") {
            viewportPreset = .semanticOverview
        } else if arguments.contains("--desktop-automation-small-focus") {
            viewportPreset = .feedbackFocus
        } else if arguments.contains(where: { $0.hasPrefix("--desktop-automation-builder") }) {
            viewportPreset = .readable
        } else {
            viewportPreset = .standard
        }
        let initialPattern: AutomationCanvasPattern
        if arguments.contains("--desktop-automation-small-readable")
            || arguments.contains("--desktop-automation-small-overview")
            || arguments.contains("--desktop-automation-small-focus") {
            initialPattern = .feedback
        } else if arguments.contains("--desktop-automation-canvas-parallel") {
            initialPattern = .parallel
        } else if arguments.contains("--desktop-automation-canvas-approval") {
            initialPattern = .approval
        } else if arguments.contains("--desktop-automation-canvas-feedback") {
            initialPattern = .feedback
        } else if arguments.contains("--desktop-automation-canvas-recovery") {
            initialPattern = .recovery
        } else {
            switch workflowID {
            case "reply-driven": initialPattern = .feedback
            case "correspondence": initialPattern = .approval
            case "approved-cleanup", "filter-management": initialPattern = .recovery
            default: initialPattern = .decision
            }
        }
        _pattern = State(initialValue: initialPattern)
        let initialSelection: String
        switch builderDesignPanel {
        case .condition, .test, .problems: initialSelection = "interpret"
        case .mapping: initialSelection = "context"
        case .storage, .storagePromotion: initialSelection = "execute"
        default: initialSelection = viewportPreset == .feedbackFocus ? "interpret" : initialPattern.graph.defaultSelectedID
        }
        _selectedStepID = State(initialValue: initialSelection)
        _selectedEdgeID = State(initialValue: builderDesignPanel == .condition ? "interpret:correction:append" : nil)
        _inspectorSection = State(initialValue: initialPattern == .feedback ? .history : .configuration)
        if arguments.contains("--desktop-automation-builder-problems-source") {
            _editorMode = State(initialValue: .source)
        } else {
            _editorMode = State(initialValue: arguments.contains("--desktop-automation-outline") ? .outline : .canvas)
        }
        _isEditing = State(initialValue: arguments.contains("--desktop-automation-builder-editing"))
        _showsVersionHistory = State(
            initialValue: arguments.contains("--desktop-automation-builder-versions")
        )
        _selectedProblemID = State(
            initialValue: AutomationWorkflowDiagnosticFixture.presentations.first?.id
        )
        _problemsExpanded = State(
            initialValue: !arguments.contains("--desktop-automation-builder-problems-collapsed")
        )
        _compactPanel = State(initialValue: nil)
    }

    init(
        workflow: AutomationWorkflowPreview,
        graph: AutomationCanvasGraph,
        revisions: [DesktopWorkflowRevisionRecord],
        sourceLines: [String],
        edit: @escaping () -> Void,
        run: (() -> Void)?,
        publish: (() -> Void)? = nil
    ) {
        workflowID = workflow.id
        viewportPreset = .readable
        builderDesignPanel = .standard
        liveWorkflow = workflow
        liveGraph = graph
        liveRevisions = revisions
        liveSourceLines = sourceLines
        editAction = edit
        runAction = run
        publishAction = publish
        _pattern = State(initialValue: .decision)
        _selectedStepID = State(initialValue: graph.defaultSelectedID)
        _selectedEdgeID = State(initialValue: nil)
        _editorMode = State(initialValue: .canvas)
        _isEditing = State(initialValue: false)
        _showsVersionHistory = State(initialValue: false)
        _selectedProblemID = State(initialValue: nil)
        _problemsExpanded = State(initialValue: false)
        _isSimulating = State(initialValue: false)
        _compactPanel = State(initialValue: nil)
    }

    private var isLive: Bool { liveGraph != nil }
    private var graph: AutomationCanvasGraph { liveGraph ?? pattern.graph }
    private var workflow: AutomationWorkflowPreview {
        liveWorkflow
            ?? AutomationWorkflowPreview.portfolio.first(where: { $0.id == workflowID })
            ?? AutomationWorkflowPreview.portfolio[0]
    }
    private var numericVersion: Int { Int(workflow.version.split(separator: ".").first ?? "1") ?? 1 }
    private var nextVersionLabel: String { isLive ? "next version" : "v\(numericVersion + 1)" }
    private var selectedStep: AutomationCanvasStep {
        graph.steps.first(where: { $0.id == selectedStepID })
            ?? graph.steps.first(where: { $0.id == graph.defaultSelectedID })
            ?? graph.steps[0]
    }
    private var selectedDiagnostic: DesktopWorkflowDiagnosticPresentation? {
        AutomationWorkflowDiagnosticFixture.presentations.first { $0.id == selectedProblemID }
    }

    var body: some View {
        Group {
            if builderDesignPanel == .newWorkflow {
                AutomationNewWorkflowDesign()
            } else {
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 12) {
                        canvasHeader
                        fullCanvasWorkspace
                    }
                    .frame(minWidth: 1_050, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 12) {
                        compactCanvasHeader
                        compactCanvasWorkspace
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 510, alignment: .topLeading)
        .onChange(of: pattern) { newPattern in
            guard !isLive else { return }
            selectedStepID = newPattern.graph.defaultSelectedID
            inspectorSection = newPattern == .feedback ? .history : .configuration
        }
    }

    private var fullCanvasWorkspace: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 12) {
                AutomationNodePalette(isEditing: isEditing)
                    .frame(width: 178)
                canvasSurface(minimumHeight: builderDesignPanel == .problems ? 390 : 510, compact: false)
                builderInspector
                    .frame(width: 248)
            }
            if builderDesignPanel == .problems {
                problemsDrawer
                    .frame(height: problemsExpanded ? 194 : 46)
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private var builderInspector: some View {
        switch builderDesignPanel {
        case .condition:
            AutomationConditionDesignPanel()
        case .mapping:
            AutomationDataMappingDesignPanel()
        case .test:
            AutomationNodeTestDesignPanel()
        case .publish:
            AutomationPublishReviewDesignPanel(currentVersion: numericVersion)
        case .storage:
            AutomationStorageAccessDesignPanel()
        case .storagePromotion:
            AutomationStoragePromotionDesignPanel()
        case .standard, .problems, .newWorkflow:
            if showsVersionHistory {
                if isLive {
                    AutomationLiveVersionHistoryPanel(revisions: liveRevisions)
                } else {
                    AutomationVersionHistoryPanel(currentVersion: numericVersion)
                }
            } else {
                AutomationNodeInspector(
                    step: selectedStep,
                    section: $inspectorSection,
                    showsCaseHistory: !isLive && pattern == .feedback,
                    isLive: isLive
                )
            }
        }
    }

    private var compactCanvasWorkspace: some View {
        VStack(spacing: 8) {
            if let compactPanel {
                compactPanelContent(compactPanel)
            }
            ZStack(alignment: .bottom) {
                canvasSurface(minimumHeight: 350, compact: true)
                if builderDesignPanel == .problems {
                    problemsDrawer
                        .frame(height: problemsExpanded ? 184 : 46)
                        .padding(8)
                }
            }
            HStack(spacing: 12) {
                Label("Selected: \(selectedStep.title)", systemImage: selectedStep.symbol)
                    .foregroundStyle(selectedStep.kind.tint)
                Divider().frame(height: 16)
                Text("\(selectedStep.input) → \(selectedStep.output)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Label(selectedStep.authority, systemImage: "lock.shield")
                    .foregroundStyle(selectedStep.kind == .effect ? KanameColor.warning : .secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func compactPanelContent(_ panel: AutomationCompactBuilderPanel) -> some View {
        ZStack(alignment: .topTrailing) {
            switch panel {
            case .palette:
                AutomationNodePalette(isEditing: isEditing, showsHeader: false)
            case .inspector:
                builderInspector
            }
            Button {
                compactPanel = nil
            } label: {
                Label("Close panel", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func canvasSurface(minimumHeight: CGFloat, compact: Bool) -> some View {
        VStack(spacing: 8) {
            canvasToolbar(compact: compact)
            Group {
                switch editorMode {
                case .canvas:
                    if builderDesignPanel == .storage || builderDesignPanel == .storagePromotion {
                        AutomationStorageCanvasDesign(
                            mode: builderDesignPanel == .storagePromotion ? .promotion : .scopes
                        )
                    } else {
                        AutomationNodeCanvas(
                            graph: graph,
                            selectedStepID: $selectedStepID,
                            isSimulating: isSimulating,
                            viewportPreset: viewportPreset,
                            selectedEdgeID: $selectedEdgeID,
                            isEditing: isEditing
                        )
                    }
                case .outline:
                    AutomationOutlinePreview(graph: graph, selectedStepID: $selectedStepID)
                case .source:
                    AutomationSourceDiagnosticPreview(
                        diagnostic: selectedDiagnostic,
                        lines: isLive ? liveSourceLines : nil
                    )
                }
            }
            .frame(minHeight: minimumHeight)
            canvasLegend(compact: compact)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(KanameColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var problemsDrawer: some View {
        AutomationProblemsDrawer(
            diagnostics: AutomationWorkflowDiagnosticFixture.presentations,
            selectedID: $selectedProblemID,
            isExpanded: $problemsExpanded,
            focusMessage: problemFocusMessage,
            onFocus: focusDiagnostic
        )
    }

    private func focusDiagnostic(_ diagnostic: DesktopWorkflowDiagnosticPresentation) {
        var navigation = diagnosticNavigation
        let outcome = navigation.focus(
            diagnostic,
            availableNodeIDs: Set(graph.steps.map(\.id)),
            availableEdgeIDs: Set(graph.edges.map(\.id))
        )
        diagnosticNavigation = navigation
        selectedProblemID = diagnostic.id
        switch outcome {
        case let .focused(target):
            if let nodeID = target.nodeID { selectedStepID = nodeID }
            selectedEdgeID = target.edgeID
            switch target.projection {
            case .canvas: editorMode = .canvas
            case .outline: editorMode = .outline
            case .source: editorMode = .source
            }
            problemFocusMessage = "Focused \(target.projection.rawValue) at \(target.jsonPointer ?? target.nodeID ?? target.edgeID ?? "declared target")."
        case .targetUnavailable:
            problemFocusMessage = "The declared target is unavailable. The diagnostic remains selected without focusing a different item."
        }
    }

    private var canvasHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name).font(.title3.weight(.bold))
                HStack(spacing: 7) {
                    Text(isLive ? workflow.summary : pattern.title + " · " + pattern.summary)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(isEditing ? "DRAFT \(nextVersionLabel.uppercased())" : "PUBLISHED v\(workflow.version)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isEditing ? KanameColor.warning : KanameColor.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isEditing ? KanameColor.warning : KanameColor.success).opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            if !isLive {
                Picker("Canvas pattern", selection: $pattern) {
                    ForEach(AutomationCanvasPattern.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 390)
            }
            if let runAction {
                Button("Run…", systemImage: "play.fill", action: runAction)
                    .buttonStyle(.bordered)
            }
            if let publishAction {
                Button("Publish to library", systemImage: "cylinder.split.1x2", action: publishAction)
                    .buttonStyle(.bordered)
                    .help("Converts this workflow to the durable v1 graph and publishes an active revision on the Rust executor")
            }
            Button("Versions", systemImage: "clock.arrow.circlepath") {
                showsVersionHistory.toggle()
            }
            .buttonStyle(.bordered)
            Button(
                isEditing ? "Finish draft" : "Edit as \(nextVersionLabel)",
                systemImage: isEditing ? "checkmark" : "square.and.pencil"
            ) {
                if let editAction { editAction() }
                else {
                    isEditing.toggle()
                    showsVersionHistory = false
                    isSimulating = false
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var compactCanvasHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name).font(.headline.weight(.bold))
                Text(isEditing ? "DRAFT \(nextVersionLabel.uppercased())" : "PUBLISHED v\(workflow.version)")
                    .font(.caption)
                    .foregroundStyle(isEditing ? KanameColor.warning : .secondary)
            }
            Spacer()
            Button("Add", systemImage: "plus") {
                compactPanel = compactPanel == .palette ? nil : .palette
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Inspect", systemImage: "sidebar.right") {
                compactPanel = compactPanel == .inspector ? nil : .inspector
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !isEditing {
                Button("Edit", systemImage: "square.and.pencil") {
                    if let editAction { editAction() } else { isEditing = true }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func canvasToolbar(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Picker("Editor", selection: $editorMode) {
                ForEach(AutomationEditorMode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Divider().frame(height: 18)
            if isEditing {
                Button("Undo", systemImage: "arrow.uturn.backward") {}.buttonStyle(.plain)
                Button("Redo", systemImage: "arrow.uturn.forward") {}.buttonStyle(.plain).disabled(true)
                Label("Draft changes", systemImage: "circle.fill").foregroundStyle(KanameColor.warning)
            } else {
                Text("Preview only · no qualification receipt")
                    .foregroundStyle(KanameColor.warning)
            }
            if !compact {
                Text("\(graph.steps.count) nodes · \(graph.edges.count) connections")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isEditing {
                Button("Discard", role: .destructive) {}.buttonStyle(.plain)
                Button("Publish v7") {}.buttonStyle(.borderedProminent).controlSize(.small).disabled(true)
            } else {
                Button(isSimulating ? "Pause preview" : "Preview run", systemImage: isSimulating ? "pause.fill" : "play.fill") {
                    isSimulating.toggle()
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 7) {
                Image(systemName: "minus.magnifyingglass")
                Text(viewportPreset.zoomLabel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Image(systemName: "plus.magnifyingglass")
                Divider().frame(height: 14)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .help("Fit all")
                Image(systemName: "map")
                    .help("Toggle minimap")
            }
            .foregroundStyle(.secondary)
            if !compact {
                Label(isLive ? "Published" : "Autosaved", systemImage: "checkmark.circle")
                    .foregroundStyle(KanameColor.success)
            }
        }
        .font(.caption)
    }

    private func canvasLegend(compact: Bool) -> some View {
        HStack(spacing: 14) {
            Label("Data", systemImage: "circle.fill").foregroundStyle(KanameColor.accent)
            Label("Decision", systemImage: "circle.fill").foregroundStyle(KanameColor.warning)
            Label("Parallel", systemImage: "circle.fill").foregroundStyle(KanameColor.blocked)
            Label("Effect", systemImage: "circle.fill").foregroundStyle(KanameColor.danger)
            if !compact {
                Label("Error / retry", systemImage: "circle.fill").foregroundStyle(KanameColor.external)
            }
            Spacer()
            if !compact {
                Text(editorMode == .canvas
                    ? (isLive ? "Published graph · open a run to overlay its execution path" : "Animated dashes show the active fixture path")
                    : "Branches remain explicit in incoming and outgoing routes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

private struct AutomationOutlinePreview: View {
    let graph: AutomationCanvasGraph
    @Binding var selectedStepID: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Node").frame(width: 190, alignment: .leading)
                Text("Incoming").frame(maxWidth: .infinity, alignment: .leading)
                Text("Outgoing").frame(maxWidth: .infinity, alignment: .leading)
                Text("Authority").frame(width: 150, alignment: .leading)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(graph.steps) { step in
                        Button {
                            selectedStepID = step.id
                        } label: {
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: step.symbol)
                                        .foregroundStyle(step.kind.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.title).font(.caption.weight(.semibold))
                                        Text(step.kind.label).font(.system(size: 8, weight: .bold)).foregroundStyle(step.kind.tint)
                                    }
                                }
                                .frame(width: 190, alignment: .leading)
                                routeList(incomingEdges(for: step.id))
                                routeList(outgoingEdges(for: step.id))
                                Text(step.authority)
                                    .font(.caption2)
                                    .foregroundStyle(step.kind == .effect ? KanameColor.warning : .secondary)
                                    .frame(width: 150, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedStepID == step.id ? KanameColor.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .background(KanameColor.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private func incomingEdges(for stepID: String) -> [AutomationCanvasEdge] {
        graph.edges.filter { $0.targetID == stepID }
    }

    private func outgoingEdges(for stepID: String) -> [AutomationCanvasEdge] {
        graph.edges.filter { $0.sourceID == stepID }
    }

    private func routeList(_ edges: [AutomationCanvasEdge]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if edges.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                ForEach(edges) { edge in
                    HStack(spacing: 5) {
                        Circle().fill(edge.kind.tint).frame(width: 6, height: 6)
                        Text(edge.label).lineLimit(1)
                    }
                }
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutomationSourceDiagnosticPreview: View {
    let diagnostic: DesktopWorkflowDiagnosticPresentation?
    private let lines: [String]

    private static let fixtureLines = [
        "{",
        "  \"schemaVersion\": 1,",
        "  \"graph\": {",
        "    \"entryNodeID\": \"\",",
        "    \"nodes\": [",
        "      { \"id\": \"inbound\", \"type\": \"trigger.email\" },",
        "      { \"id\": \"interpret\", \"type\": \"control.match\" },",
        "      { \"id\": \"append\", \"type\": \"context.append\" },",
        "      { \"id\": \"reply\", \"type\": \"effect.email.reply\" }",
        "    ]",
        "  }",
        "}",
    ]

    init(diagnostic: DesktopWorkflowDiagnosticPresentation?, lines: [String]? = nil) {
        self.diagnostic = diagnostic
        self.lines = lines ?? Self.fixtureLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceHeader
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        sourceLine(index: index, text: line)
                    }
                }
            }
            .background(KanameColor.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(KanameColor.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private var sourceHeader: some View {
        HStack(spacing: 8) {
            Label("workflow.json", systemImage: "doc.text")
                .font(.caption.weight(.semibold))
            if let pointer = diagnostic?.focusTarget.jsonPointer {
                Text(pointer)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(KanameColor.accent)
            }
            Spacer()
            if let range = diagnostic?.focusTarget.sourceRange {
                Text("bytes \(range.start.byteOffset)–\(range.end.byteOffset)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceLine(index: Int, text: String) -> some View {
        let selected = isSelected(index)
        return HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Text(text)
                .foregroundStyle(selected ? KanameColor.textPrimary : Color.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? KanameColor.danger.opacity(0.18) : Color.clear)
    }

    private func isSelected(_ zeroBasedLine: Int) -> Bool {
        guard let range = diagnostic?.focusTarget.sourceRange else { return false }
        return zeroBasedLine >= Int(range.start.line) && zeroBasedLine <= Int(range.end.line)
    }
}

private struct AutomationNodePalette: View {
    let isEditing: Bool
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Text("Add").font(.headline)
                    Spacer()
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search nodes and patterns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(7)
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
            paletteSection("START", items: [
                ("Trigger", "bolt.fill"), ("Schedule", "calendar.badge.clock"),
            ])
            paletteSection("PROCESS", items: [
                ("Data", "square.3.layers.3d"), ("Transform", "wand.and.stars"),
                ("AI", "sparkles"), ("Context", "text.append"),
                ("Subflow", "square.stack.3d.up"),
            ])
            paletteSection("FLOW", items: [
                ("Decision", "arrow.triangle.branch"), ("Parallel", "arrow.triangle.2.circlepath"),
                ("Join", "arrow.triangle.merge"), ("Loop", "repeat"),
                ("Wait", "clock.badge"),
            ])
            paletteSection("STORAGE", items: [
                ("Job storage", "shippingbox"), ("Workflow storage", "externaldrive"),
                ("Promote", "arrow.up.doc"),
            ])
            paletteSection("CONTROL", items: [
                ("Human review", "person.crop.circle"), ("Effect", "checkmark.shield"),
                ("Receipt", "doc.text.magnifyingglass"),
            ])
            paletteSection("PATTERNS", items: [
                ("Email feedback", "envelope.arrow.triangle.branch"),
                ("Approval + wait", "person.badge.clock"),
            ])
            Divider()
                .padding(.top, 4)
            Label(
                isEditing ? "Drag or press Return to add" : "Edit to change this graph",
                systemImage: isEditing ? "keyboard" : "lock.fill"
            )
            .font(.caption2)
            .foregroundStyle(isEditing ? KanameColor.accent : .secondary)
        }
        .padding(13)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func paletteSection(_ title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.1).frame(width: 14)
                    Text(item.0).lineLimit(1)
                    Spacer(minLength: 0)
                    if isEditing { Image(systemName: "plus.circle").foregroundStyle(KanameColor.accent) }
                }
                .font(.caption.weight(.medium))
                .padding(.vertical, 2)
            }
        }
    }
}
