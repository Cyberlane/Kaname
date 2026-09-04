import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

enum AutomationStorageCanvasMode {
    case scopes
    case promotion
}

struct AutomationStorageCanvasDesign: View {
    let mode: AutomationStorageCanvasMode

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let leftX = max(84, width * 0.17)
            let middleX = width * 0.50
            let rightX = min(width - 84, width * 0.83)
            let jobStorageWidth = min(360, width - 80)
            let workflowStorageWidth = min(410, width - 56)

            ZStack {
                AutomationDotGrid()

                RoundedRectangle(cornerRadius: 14)
                    .fill(KanameColor.accent.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(KanameColor.accent.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    }
                    .frame(width: width - 24, height: 310)
                    .position(x: width / 2, y: 167)

                Canvas { context, _ in
                    drawStorageConnections(
                        context: &context,
                        leftX: leftX,
                        middleX: middleX,
                        rightX: rightX
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill")
                    Text("JOB BOUNDARY · RUN #184")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(KanameColor.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(KanameColor.canvas.opacity(0.94), in: Capsule())
                .position(x: 112, y: 26)

                AutomationStorageProcessCard(
                    title: "Compile context",
                    subtitle: "Build bounded input",
                    symbol: "text.append",
                    access: "READS BOTH"
                )
                .position(x: leftX, y: 100)

                AutomationStorageProcessCard(
                    title: "Run work type",
                    subtitle: "Create revision",
                    symbol: "square.stack.3d.up",
                    access: "JOB READ + WRITE",
                    selected: mode == .scopes
                )
                .position(x: middleX, y: 100)

                AutomationStorageProcessCard(
                    title: "Verify all",
                    subtitle: "Validate output",
                    symbol: "checkmark.seal",
                    access: "JOB READ"
                )
                .position(x: rightX, y: 100)

                AutomationStorageResourceCard(
                    title: "Job storage · #184",
                    subtitle: "Visible only inside this job · survives waits and restarts",
                    symbol: "shippingbox.fill",
                    tint: KanameColor.accent,
                    facts: ["7 values", "3 files", "48.2 MB", "Deletes with job"],
                    width: jobStorageWidth,
                    selected: mode == .scopes
                )
                .position(x: middleX, y: 244)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.doc.fill")
                    Text(mode == .promotion ? "PROMOTE · SELECTED" : "EXPLICIT PROMOTION ONLY")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(mode == .promotion ? KanameColor.warning : KanameColor.blocked)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(KanameColor.canvas, in: Capsule())
                .overlay {
                    Capsule().stroke(
                        mode == .promotion ? KanameColor.warning : KanameColor.blocked.opacity(0.55),
                        lineWidth: mode == .promotion ? 2 : 1
                    )
                }
                .position(x: middleX, y: 350)

                AutomationStorageResourceCard(
                    title: "Workflow storage · Reply-driven reporting",
                    subtitle: "Isolated installation storage · durable across jobs and versions",
                    symbol: "externaldrive.fill",
                    tint: KanameColor.blocked,
                    facts: ["templates/", "cases/", "86 MB", "Explicit lifecycle"],
                    width: workflowStorageWidth,
                    selected: mode == .promotion
                )
                .position(x: middleX, y: 438)

                Label("Workflow storage is outside the job deletion boundary", systemImage: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: middleX, y: 500)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }
    }

    private func drawStorageConnections(
        context: inout GraphicsContext,
        leftX: CGFloat,
        middleX: CGFloat,
        rightX: CGFloat
    ) {
        var flow = Path()
        flow.move(to: CGPoint(x: leftX + 72, y: 100))
        flow.addLine(to: CGPoint(x: middleX - 72, y: 100))
        flow.move(to: CGPoint(x: middleX + 72, y: 100))
        flow.addLine(to: CGPoint(x: rightX - 72, y: 100))
        context.stroke(flow, with: .color(KanameColor.accent), style: StrokeStyle(lineWidth: 2.2, dash: [7, 6]))

        var jobAccess = Path()
        for x in [leftX, middleX, rightX] {
            jobAccess.move(to: CGPoint(x: x, y: 142))
            jobAccess.addCurve(
                to: CGPoint(x: middleX + (x - middleX) * 0.38, y: 198),
                control1: CGPoint(x: x, y: 170),
                control2: CGPoint(x: middleX + (x - middleX) * 0.38, y: 174)
            )
        }
        context.stroke(jobAccess, with: .color(KanameColor.accent.opacity(0.78)), style: StrokeStyle(lineWidth: 1.7, dash: [4, 5]))

        var promotion = Path()
        promotion.move(to: CGPoint(x: middleX, y: 290))
        promotion.addLine(to: CGPoint(x: middleX, y: 397))
        context.stroke(
            promotion,
            with: .color(mode == .promotion ? KanameColor.warning : KanameColor.blocked.opacity(0.65)),
            style: StrokeStyle(lineWidth: mode == .promotion ? 3 : 1.8, dash: mode == .promotion ? [7, 5] : [4, 6])
        )
    }
}

private struct AutomationStorageProcessCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let access: String
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(KanameColor.accent)
                Text(title).font(.caption.weight(.bold)).lineLimit(1)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(access)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(KanameColor.accent)
        }
        .padding(10)
        .frame(width: 148, height: 84, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? KanameColor.accent : KanameColor.separator, lineWidth: selected ? 2 : 1)
        }
    }
}

private struct AutomationStorageResourceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let facts: [String]
    let width: CGFloat
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fact.contains("Deletes") ? KanameColor.warning : tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.09), in: Capsule())
                }
            }
        }
        .padding(11)
        .frame(width: width, height: 92, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? tint : KanameColor.separator, lineWidth: selected ? 2 : 1)
        }
    }
}

struct AutomationNewWorkflowDesign: View {
    private enum StarterSection: String, CaseIterable {
        case patterns = "Patterns"
        case workflows = "My workflows"
        case source = "Source"

        var symbol: String {
            switch self {
            case .patterns: "square.grid.2x2.fill"
            case .workflows: "doc.on.doc"
            case .source: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    let workflows: [DesktopWorkflowDefinitionRecord]
    let message: String?
    let onUseTemplate: ((AutomationWorkflowStarterTemplate) -> Void)?
    let onDuplicate: ((DesktopWorkflowDefinitionRecord) -> Void)?
    let onImportSource: ((String) -> Bool)?
    let onCancel: (() -> Void)?
    @State private var section = StarterSection.patterns
    @State private var search = ""
    @State private var selectedTemplateID = AutomationWorkflowStarterTemplate.patterns[0].id
    @State private var sourceText: String
    @State private var sourceMessage: String?

    init(
        workflows: [DesktopWorkflowDefinitionRecord] = [],
        message: String? = nil,
        onUseTemplate: ((AutomationWorkflowStarterTemplate) -> Void)? = nil,
        onDuplicate: ((DesktopWorkflowDefinitionRecord) -> Void)? = nil,
        onImportSource: ((String) -> Bool)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.workflows = workflows
        self.message = message
        self.onUseTemplate = onUseTemplate
        self.onDuplicate = onDuplicate
        self.onImportSource = onImportSource
        self.onCancel = onCancel
        _sourceText = State(initialValue: DesktopWorkflowStudioScaffold.blankSource)
    }

    private var visibleTemplates: [AutomationWorkflowStarterTemplate] {
        AutomationWorkflowStarterTemplate.patterns.filter {
            search.isEmpty
                || $0.title.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    private var visibleWorkflows: [DesktopWorkflowDefinitionRecord] {
        workflows.filter {
            search.isEmpty
                || $0.name.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedTemplate: AutomationWorkflowStarterTemplate {
        AutomationWorkflowStarterTemplate.patterns.first { $0.id == selectedTemplateID }
            ?? AutomationWorkflowStarterTemplate.patterns[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create workflow").font(.title2.weight(.bold))
                    Text("Begin with a proven pattern, duplicate a version, or start from a typed trigger.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel?() }
                    .buttonStyle(.bordered)
                    .disabled(onCancel == nil)
            }

            HStack(spacing: 12) {
                Picker("Starting point", selection: $section) {
                    ForEach(StarterSection.allCases, id: \.self) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 500)
                Spacer()
                if section != .source {
                    TextField(section == .patterns ? "Search patterns" : "Search workflows", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KanameColor.warning)
            }

            starterContent
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
        .background(KanameColor.canvas)
    }

    @ViewBuilder
    private var starterContent: some View {
        switch section {
        case .patterns:
            patternContent
        case .workflows:
            workflowContent
        case .source:
            sourceContent
        }
    }

    private var patternContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(visibleTemplates) { template in
                    Button {
                        selectedTemplateID = template.id
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: template.symbol)
                                    .foregroundStyle(template.tint)
                                    .frame(width: 30, height: 30)
                                    .background(template.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                Spacer()
                                Image(systemName: selectedTemplateID == template.id
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTemplateID == template.id ? template.tint : .secondary)
                            }
                            Text(template.title).font(.headline)
                            Text(template.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 32, alignment: .topLeading)
                            Divider()
                            HStack {
                                Label("\(template.steps.count) nodes", systemImage: "point.3.connected.trianglepath.dotted")
                                Spacer()
                                Text(template.triggerKinds.map(\.label).joined(separator: " + "))
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedTemplateID == template.id ? template.tint : KanameColor.separator,
                                        lineWidth: selectedTemplateID == template.id ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Selects this editable workflow pattern")
                }
            }

            HStack {
                Label("Patterns create ordinary editable drafts; every block and connection can be changed.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create draft from \(selectedTemplate.title)", systemImage: "arrow.right") {
                    onUseTemplate?(selectedTemplate)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onUseTemplate == nil)
            }
            .font(.caption)
        }
    }

    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Duplicate a published version into a new local workflow. The original remains unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if visibleWorkflows.isEmpty {
                BoundaryCallout(
                    title: workflows.isEmpty ? "No published workflows yet" : "No matching workflows",
                    detail: workflows.isEmpty
                        ? "Choose a pattern or source to create the first workflow."
                        : "Clear the search to see all published workflows."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(visibleWorkflows) { workflow in
                    HStack(spacing: 12) {
                        Image(systemName: workflow.icon)
                            .foregroundStyle(KanameColor.accent)
                            .frame(width: 32, height: 32)
                            .background(KanameColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workflow.name).font(.headline)
                            Text(workflow.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(workflow.triggerKinds.map(\.label).joined(separator: " + "))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Duplicate", systemImage: "doc.on.doc") { onDuplicate?(workflow) }
                            .disabled(onDuplicate == nil)
                    }
                    .padding(14)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Canonical workflow source").font(.headline)
                    Text("Paste or edit the complete manifest. A successful import opens the exact same canvas and outline draft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset example") {
                    sourceText = DesktopWorkflowStudioScaffold.blankSource
                    sourceMessage = nil
                }
            }
            WorkflowJSONSourceEditor(
                text: $sourceText,
                minimumHeight: 330,
                accessibilityLabel: "Canonical workflow source"
            )
            if let sourceMessage {
                Label(sourceMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KanameColor.warning)
            }
            HStack {
                Label("Import is bounded, schema-validated, and capability-checked.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Validate and open draft", systemImage: "arrow.right") {
                    guard let onImportSource else { return }
                    sourceMessage = onImportSource(sourceText)
                        ? nil
                        : "Source was not imported. Review the validation message above."
                }
                .buttonStyle(.borderedProminent)
                .disabled(onImportSource == nil || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
