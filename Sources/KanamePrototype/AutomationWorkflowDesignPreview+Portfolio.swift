import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

enum AutomationPreviewState {
    case complete
    case running
    case waiting
    case blocked
    case planned
    /// The compiler would execute this node as configured.
    case executable
    /// The compiler keeps this node schema-only; see the node's reason.
    case schemaOnly

    var label: String {
        switch self {
        case .complete: "Complete"
        case .running: "Running"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .planned: "Planned"
        case .executable: "Executable"
        case .schemaOnly: "Not executable"
        }
    }

    var symbol: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: "pause.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .planned: "circle.dashed"
        case .executable: "bolt.circle.fill"
        case .schemaOnly: "bolt.slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .complete: KanameColor.success
        case .running: KanameColor.accent
        case .waiting: KanameColor.warning
        case .blocked: KanameColor.danger
        case .planned: Color.secondary
        case .executable: KanameColor.success
        case .schemaOnly: KanameColor.warning
        }
    }
}

struct AutomationWorkflowPreview: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let progress: Int
    let state: AutomationPreviewState
    let version: String
    let trigger: String
    let lastRun: String
    let retention: String

    static let portfolio: [Self] = [
        .init(id: "reply-driven", name: "Reply-driven reporting", summary: "Synthetic fixture · not operational · Produce, deliver, and revise artifacts through email", symbol: "arrow.trianglehead.2.clockwise.rotate.90", progress: 3, state: .waiting, version: "6", trigger: "Email reply", lastRun: "Waiting · 12 min", retention: "30 days"),
        .init(id: "mailbox-review", name: "Mailbox review", summary: "Synthetic fixture · not operational · Review and classify incoming mail", symbol: "tray.full", progress: 3, state: .running, version: "4", trigger: "Every hour", lastRun: "Running · now", retention: "30 days"),
        .init(id: "approved-cleanup", name: "Approved cleanup", summary: "Synthetic fixture · not operational · Apply reviewed labels and archive", symbol: "archivebox", progress: 2, state: .waiting, version: "3", trigger: "Manual", lastRun: "Waiting · 2 h", retention: "30 days"),
        .init(id: "sender-cleanup", name: "Sender cleanup", summary: "Synthetic fixture · not operational · Exact-scope recurring cleanup", symbol: "scope", progress: 1, state: .planned, version: "1", trigger: "Daily 09:00", lastRun: "Never", retention: "After success"),
        .init(id: "financial-filing", name: "Financial filing", summary: "Synthetic fixture · not operational · Preserve and file financial mail", symbol: "doc.text", progress: 2, state: .waiting, version: "5", trigger: "New mail", lastRun: "Passed · yesterday", retention: "Forever"),
        .init(id: "structured-ingestion", name: "Structured ingestion", summary: "Synthetic fixture · not operational · Parse messages into a dataset", symbol: "tablecells", progress: 2, state: .blocked, version: "2", trigger: "New mail", lastRun: "Blocked · 3 d", retention: "30 days"),
        .init(id: "newsletter", name: "Newsletter management", summary: "Synthetic fixture · not operational · Review subscriptions and cleanup", symbol: "newspaper", progress: 1, state: .planned, version: "1", trigger: "Weekly", lastRun: "Never", retention: "30 days"),
        .init(id: "correspondence", name: "Correspondence", summary: "Synthetic fixture · not operational · Draft, review, reply, and forward", symbol: "arrowshape.turn.up.left", progress: 1, state: .planned, version: "2", trigger: "Manual", lastRun: "Passed · 8 d", retention: "30 days"),
        .init(id: "filter-management", name: "Filter management", summary: "Synthetic fixture · not operational · Preview and reconcile provider rules", symbol: "line.3.horizontal.decrease.circle", progress: 1, state: .planned, version: "1", trigger: "Manual", lastRun: "Never", retention: "After success"),
    ]
}

private struct AutomationMigrationProgress: View {
    let completed: Int
    private let labels = ["Designed", "Tested", "Shadowed", "Live"]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Circle()
                    .fill(index < completed ? KanameColor.success : KanameColor.separator)
                    .frame(width: 7, height: 7)
                    .help(label)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Migration: \(completed) of \(labels.count) stages complete")
    }
}

struct AutomationPipelinePreview: View {
    let workflows: [AutomationWorkflowPreview]
    @Binding var selectedWorkflowID: String
    let openBuilder: () -> Void
    let openRunHistory: () -> Void
    let createWorkflow: (() -> Void)?
    @State private var search = ""
    @State private var filter = WorkflowLibraryFilter.all

    private enum WorkflowLibraryFilter: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case drafts = "Drafts"
        case attention = "Attention"
    }

    private var selectedWorkflow: AutomationWorkflowPreview {
        workflows.first(where: { $0.id == selectedWorkflowID })
            ?? workflows.first
            ?? AutomationWorkflowPreview.portfolio[0]
    }

    private var visibleWorkflows: [AutomationWorkflowPreview] {
        workflows.filter { workflow in
            let searchMatches = search.isEmpty
                || workflow.name.localizedCaseInsensitiveContains(search)
                || workflow.summary.localizedCaseInsensitiveContains(search)
            let filterMatches: Bool
            switch filter {
            case .all: filterMatches = true
            case .active: filterMatches = [.running, .waiting, .complete].contains(workflow.state)
            case .drafts: filterMatches = workflow.state == .planned
            case .attention: filterMatches = workflow.state == .blocked
            }
            return searchMatches && filterMatches
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_050
            VStack(alignment: .leading, spacing: 14) {
                if isCompact {
                    libraryTitle
                    libraryControls
                } else {
                    HStack(spacing: 12) {
                        libraryTitle
                        Spacer()
                        libraryControls
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    workflowTable(isCompact: isCompact)
                        .frame(maxWidth: .infinity)
                    workflowSummary
                        .frame(width: 270)
                }
            }
        }
        .frame(minHeight: 570)
    }

    private var libraryTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Workflow library").font(.title3.weight(.bold))
            Text("Every workflow, trigger, published version, last run, and retention policy")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 12) {
            TextField("Search workflows", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 230)
            Picker("Filter", selection: $filter) {
                ForEach(WorkflowLibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            Button("New workflow", systemImage: "plus") { createWorkflow?() }
                .buttonStyle(.borderedProminent)
                .disabled(createWorkflow == nil)
        }
    }

    private func workflowTable(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Workflow").frame(maxWidth: .infinity, alignment: .leading)
                Text("State").frame(width: 95, alignment: .leading)
                if !isCompact {
                    Text("Trigger").frame(width: 100, alignment: .leading)
                }
                Text("Version").frame(width: 60, alignment: .leading)
                if !isCompact {
                    Text("Last run").frame(width: 105, alignment: .leading)
                }
                Text("Retention").frame(width: 92, alignment: .leading)
                Color.clear.frame(width: 8, height: 1)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ForEach(visibleWorkflows) { workflow in
                Button {
                    selectedWorkflowID = workflow.id
                    openBuilder()
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            Image(systemName: workflow.symbol)
                                .frame(width: 22)
                                .foregroundStyle(workflow.state.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workflow.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(workflow.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Label(workflow.state.label, systemImage: workflow.state.symbol)
                            .foregroundStyle(workflow.state.tint)
                            .frame(width: 95, alignment: .leading)
                        if !isCompact {
                            Text(workflow.trigger).frame(width: 100, alignment: .leading)
                        }
                        Text("v\(workflow.version)").font(.system(.caption, design: .monospaced)).frame(width: 60, alignment: .leading)
                        if !isCompact {
                            Text(workflow.lastRun).frame(width: 105, alignment: .leading)
                        }
                        Text(workflow.retention).frame(width: 92, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        selectedWorkflowID == workflow.id ? KanameColor.accent.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var workflowSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: selectedWorkflow.symbol)
                    .foregroundStyle(selectedWorkflow.state.tint)
                    .frame(width: 34, height: 34)
                    .background(selectedWorkflow.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedWorkflow.name).font(.headline)
                    Text("Published v\(selectedWorkflow.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(selectedWorkflow.summary).font(.caption).foregroundStyle(.secondary)
            Divider()
            libraryFact("State", value: selectedWorkflow.state.label)
            libraryFact("Trigger", value: selectedWorkflow.trigger)
            libraryFact("Last run", value: selectedWorkflow.lastRun)
            libraryFact("History", value: selectedWorkflow.retention)
            Divider()
            Text("Migration").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            AutomationMigrationProgress(completed: selectedWorkflow.progress)
            Text("Designed · Tested · Shadowed · Live")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Open in Builder", systemImage: "point.3.connected.trianglepath.dotted") {
                openBuilder()
            }
                .buttonStyle(.borderedProminent)
            Button("View run history", systemImage: "clock.arrow.circlepath") {
                openRunHistory()
            }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(minHeight: 520, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func libraryFact(_ label: String, value: String) -> some View {
        LabeledContent(label) { Text(value).foregroundStyle(.secondary) }
            .font(.caption)
    }
}

private struct AutomationPipelineStrip: View {
    let stages: [(String, String, AutomationPreviewState)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    VStack(spacing: 7) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(KanameColor.raised)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(stage.2.tint.opacity(stage.2 == .running ? 0.95 : 0.35), lineWidth: stage.2 == .running ? 2 : 1)
                                }
                            Image(systemName: stage.1)
                                .foregroundStyle(stage.2.tint)
                                .scaleEffect(stage.2 == .running && !reduceMotion ? 1 + sin(phase * 4) * 0.08 : 1)
                        }
                        .frame(height: 54)
                        Text(stage.0).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)

                    if index < stages.count - 1 {
                        Rectangle()
                            .fill(index < 3 ? KanameColor.success.opacity(0.8) : KanameColor.separator)
                            .frame(width: 12, height: 2)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(index < 3 ? KanameColor.success : .secondary)
                            }
                            .padding(.bottom, 23)
                    }
                }
            }
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
