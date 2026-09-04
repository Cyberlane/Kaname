import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

private struct AutomationBuilderInspectorShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(tint)
                }
            }
            Divider()
            content
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .font(.caption)
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AutomationConditionDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Correction requested",
            subtitle: "Selected connection",
            symbol: "arrow.triangle.branch",
            tint: KanameColor.warning
        ) {
            Text("Follow this path when").font(.caption.weight(.semibold))
            conditionField("Interpret reply", symbol: "point.3.connected.trianglepath.dotted")
            conditionField("Intent", symbol: "chevron.right.2")
            HStack(spacing: 6) {
                conditionField("equals", symbol: "equal")
                conditionField("correction", symbol: "text.quote")
            }
            HStack {
                Button("+ AND") {}.buttonStyle(.bordered).controlSize(.small)
                Button("+ OR") {}.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Text("Sample evaluation").font(.caption.weight(.semibold))
            Label("Matched fixture: Customer correction #3", systemImage: "checkmark.circle.fill")
                .foregroundStyle(KanameColor.success)
            Text("“Please keep the totals but change the table layout.”")
                .foregroundStyle(.secondary)
            DisclosureGroup("Advanced predicate") {
                Text("/intent equals correction")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Label("1 of 3 outcomes tested", systemImage: "checkmark.seal")
                .foregroundStyle(KanameColor.warning)
        }
    }

    private func conditionField(_ text: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.caption.weight(.medium))
            Spacer()
            Image(systemName: "chevron.down").foregroundStyle(.secondary)
        }
        .padding(8)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AutomationDataMappingDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Compile context",
            subtitle: "Input mapping",
            symbol: "text.append",
            tint: KanameColor.accent
        ) {
            Picker("Mapping", selection: .constant("Input")) {
                Text("Setup").tag("Setup")
                Text("Input").tag("Input")
                Text("Output").tag("Output")
                Text("Policy").tag("Policy")
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Available data").font(.caption.weight(.semibold))
            dataSource("Inbound email", field: "thread.id", sample: "18f3…", tint: KanameColor.accent)
            dataSource("Interpret reply", field: "instruction", sample: "change layout", tint: KanameColor.warning)
            dataSource("Case state", field: "episodes[]", sample: "3 items", tint: KanameColor.blocked)
            Divider()
            Text("Node inputs").font(.caption.weight(.semibold))
            mappedField("caseID", source: "Inbound email · thread.id")
            mappedField("instructions", source: "Interpret reply · instruction")
            mappedField("history", source: "Case state · episodes[]")
        } footer: {
            Label("3 mappings · all types compatible", systemImage: "checkmark.seal.fill")
                .foregroundStyle(KanameColor.success)
        }
    }

    private func dataSource(_ title: String, field: String, sample: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Circle().fill(tint).frame(width: 6, height: 6); Text(title).fontWeight(.semibold); Spacer(); Image(systemName: "line.3.horizontal") }
            HStack { Text(field).font(.system(.caption2, design: .monospaced)); Spacer(); Text(sample).foregroundStyle(.secondary) }
        }
        .padding(8).background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
    }

    private func mappedField(_ target: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            HStack { Image(systemName: "link").foregroundStyle(KanameColor.accent); Text(source).lineLimit(1); Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success) }
        }
        .padding(8).background(KanameColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AutomationStorageAccessDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Run work type",
            subtitle: "Storage access",
            symbol: "externaldrive.badge.checkmark",
            tint: KanameColor.accent
        ) {
            Text("Declared access").font(.caption.weight(.semibold))
            storageScope(
                "Job storage",
                detail: "Read + write",
                paths: "artifacts/draft/*\nstate/progress",
                symbol: "shippingbox.fill",
                tint: KanameColor.accent
            )
            storageScope(
                "Workflow storage",
                detail: "Read only",
                paths: "templates/*\nreference/*",
                symbol: "externaldrive.fill",
                tint: KanameColor.blocked
            )
            Divider()
            Text("Commit visibility").font(.caption.weight(.semibold))
            Label("Changes become visible after this node commits", systemImage: "checkmark.seal")
                .foregroundStyle(KanameColor.success)
            Text("Parallel branches may read the same job data. A same-key write conflict fails visibly unless an atomic update or Join is declared.")
                .foregroundStyle(.secondary)
            Divider()
            Label("No raw filesystem path", systemImage: "lock.shield.fill")
                .foregroundStyle(.secondary)
            Text("The node receives scoped file and value handles only.")
                .foregroundStyle(.secondary)
        } footer: {
            Label("2 scopes · no cross-workflow access", systemImage: "checkmark.seal.fill")
                .foregroundStyle(KanameColor.success)
        }
    }

    private func storageScope(
        _ title: String,
        detail: String,
        paths: String,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(detail).font(.caption2.weight(.bold)).foregroundStyle(tint)
            }
            Text(paths)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.28), lineWidth: 1) }
    }
}

struct AutomationStoragePromotionDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Promote artifact",
            subtitle: "Durable storage write",
            symbol: "arrow.up.doc.fill",
            tint: KanameColor.warning
        ) {
            Text("Source · job storage").font(.caption.weight(.semibold))
            storagePath("outputs/report-v3.xlsx", detail: "48.0 MB · digest 7d91…a8c2", tint: KanameColor.accent)
            HStack {
                Spacer()
                Image(systemName: "arrow.down").foregroundStyle(KanameColor.warning)
                Spacer()
            }
            Text("Destination · workflow storage").font(.caption.weight(.semibold))
            storagePath("cases/CASE-184/current/report.xlsx", detail: "Durable across jobs and versions", tint: KanameColor.blocked)
            Divider()
            promotionFact("On conflict", value: "Create a new revision")
            promotionFact("Retention", value: "Until explicit removal")
            promotionFact("Provenance", value: "Job #184 + content digest")
            promotionFact("Publish impact", value: "Storage contract changed")
            Divider()
            Label("Copy, verify digest, then publish durable reference", systemImage: "checkmark.shield.fill")
                .foregroundStyle(KanameColor.success)
            Text("The original job copy remains available until the job is deleted.")
                .foregroundStyle(.secondary)
        } footer: {
            Label("Workflow copy survives job deletion", systemImage: "externaldrive.fill.badge.checkmark")
                .foregroundStyle(KanameColor.blocked)
        }
    }

    private func storagePath(_ path: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path).font(.system(.caption2, design: .monospaced)).foregroundStyle(tint)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func promotionFact(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
    }
}

struct AutomationNodeTestDesignPanel: View {
    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Interpret reply",
            subtitle: "Test node",
            symbol: "play.square.stack",
            tint: KanameColor.success
        ) {
            Text("Fixture").font(.caption.weight(.semibold))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customer correction #3").fontWeight(.semibold)
                    Text("Redacted historical input").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.down")
            }
            .padding(9).background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Test node", systemImage: "play.fill") {}.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Test path") {}.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Label("Completed in 1.2 s", systemImage: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
            testFact("Outcome", value: "correction")
            testFact("Confidence", value: "0.96")
            testFact("Next path", value: "Append episode")
            Divider()
            Text("Output preview").font(.caption.weight(.semibold))
            Text("{\n  intent: correction,\n  preserveTotals: true,\n  requestedChange: tableLayout\n}")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(KanameColor.accent)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
        } footer: {
            Label("Effect nodes remain proposed only", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        }
    }

    private func testFact(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold) }
    }
}

struct AutomationPublishReviewDesignPanel: View {
    let currentVersion: Int

    var body: some View {
        AutomationBuilderInspectorShell(
            title: "Review v\(currentVersion + 1)",
            subtitle: "Publish checkpoint",
            symbol: "arrow.up.doc.fill",
            tint: KanameColor.success
        ) {
            HStack {
                Text("v\(currentVersion)").foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                Text("v\(currentVersion + 1)").fontWeight(.bold)
                Spacer(); Text("Draft").foregroundStyle(KanameColor.warning)
            }
            reviewRow("Graph", detail: "+2 nodes · +3 connections", state: .attention)
            reviewRow("Mappings", detail: "3 changed · all valid", state: .passed)
            reviewRow("Subflows", detail: "Work subflow pinned v3", state: .passed)
            reviewRow("Fixtures", detail: "6 of 6 paths pass", state: .passed)
            reviewRow("Authority", detail: "No increase", state: .passed)
            Divider()
            Text("Activation").font(.caption.weight(.semibold))
            Label("Publish without activating", systemImage: "circle.inset.filled")
                .foregroundStyle(KanameColor.accent)
            Text("Existing runs remain on their original definition. Activation is a separate action.")
                .foregroundStyle(.secondary)
            Button("View visual diff", systemImage: "point.3.connected.trianglepath.dotted") {}
                .buttonStyle(.bordered).controlSize(.small)
        } footer: {
            Button("Publish immutable v\(currentVersion + 1)", systemImage: "checkmark.seal.fill") {}
                .buttonStyle(.borderedProminent)
        }
    }

    private enum ReviewState { case passed, attention }

    private func reviewRow(_ title: String, detail: String, state: ReviewState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state == .passed ? "checkmark.circle.fill" : "circlebadge.2.fill")
                .foregroundStyle(state == .passed ? KanameColor.success : KanameColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

enum AutomationWorkflowDiagnosticFixture {
    static let presentations: [DesktopWorkflowDiagnosticPresentation] = {
        var response = Kaname_V1_CompileWorkflowResponse()
        response.diagnostics = [
            diagnostic(
                code: "graph.entrypoint.missing",
                severity: .error,
                summary: "Choose one entry node before publishing.",
                pointer: "/graph/entryNodeID",
                line: 3,
                byteOffset: 48
            ),
            diagnostic(
                code: "graph.node.unreachable",
                severity: .warning,
                summary: "Append episode has no reachable incoming route.",
                pointer: "/graph/nodes/7",
                line: 7,
                byteOffset: 212
            ),
            diagnostic(
                code: "mapping.type.incompatible",
                severity: .error,
                summary: "The correction value does not match the declared input type.",
                pointer: "/graph/nodes/2/configuration/mappings/0",
                line: 6,
                byteOffset: 176
            ),
            diagnostic(
                code: "graph.cycle.unbounded",
                severity: .error,
                summary: "The feedback cycle requires an iteration or time bound.",
                pointer: "/graph/edges/9",
                line: 9,
                byteOffset: 284
            ),
            diagnostic(
                code: "effect.authority.undeclared",
                severity: .error,
                summary: "Reply + attach requires an explicit send authority envelope.",
                pointer: "/graph/nodes/5/authority",
                line: 8,
                byteOffset: 252
            ),
        ]
        let routes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFocusTarget] = [
            .init(code: "graph.node.unreachable", instancePointer: "/graph/nodes/7"):
                .outline(nodeID: "append"),
            .init(code: "graph.cycle.unbounded", instancePointer: "/graph/edges/9"):
                .canvas(nodeID: "interpret", edgeID: "append-context-episode 4 · same case"),
            .init(code: "effect.authority.undeclared", instancePointer: "/graph/nodes/5/authority"):
                .canvas(nodeID: "reply"),
        ]
        let fixes: [DesktopWorkflowDiagnosticRouteKey: DesktopWorkflowDiagnosticFixMetadata] = [
            .init(code: "graph.entrypoint.missing", instancePointer: "/graph/entryNodeID"):
                .init(
                    id: "choose-entry-node",
                    title: "Preview entry selection",
                    explanation: "Shows the eligible trigger nodes without changing the draft."
                ),
        ]
        return DesktopWorkflowDiagnosticMapper.presentations(
            response: response,
            routes: routes,
            fixes: fixes
        )
    }()

    private static func diagnostic(
        code: String,
        severity: Kaname_V1_WorkflowDiagnosticSeverity,
        summary: String,
        pointer: String,
        line: UInt32,
        byteOffset: UInt64
    ) -> Kaname_V1_WorkflowDiagnostic {
        var start = Kaname_V1_WorkflowSourcePosition()
        start.byteOffset = byteOffset
        start.line = line
        start.column = 4
        var end = start
        end.byteOffset += 18
        end.column += 18
        var location = Kaname_V1_WorkflowSourceLocation()
        location.sourceID = "workflow.json"
        location.jsonPointer = pointer
        location.start = start
        location.end = end
        var result = Kaname_V1_WorkflowDiagnostic()
        result.code = code
        result.severity = severity
        result.summary = summary
        result.instancePointer = pointer
        result.schemaPointer = "/properties/graph"
        result.location = location
        return result
    }
}

struct AutomationProblemsDrawer: View {
    let diagnostics: [DesktopWorkflowDiagnosticPresentation]
    @Binding var selectedID: String?
    @Binding var isExpanded: Bool
    let focusMessage: String?
    let onFocus: (DesktopWorkflowDiagnosticPresentation) -> Void
    @State private var previewedFixID: String?

    private var selected: DesktopWorkflowDiagnosticPresentation? {
        diagnostics.first { $0.id == selectedID } ?? diagnostics.first
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedDrawer
            } else {
                collapsedDrawer
            }
        }
        .padding(isExpanded ? 13 : 8)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var collapsedDrawer: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 8) {
                Label("Problems", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text("\(diagnostics.count)")
                    .foregroundStyle(KanameColor.warning)
                severitySummary
                Spacer()
                Text("Show diagnostics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Problems, \(diagnostics.count) diagnostics")
    }

    private var expandedDrawer: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Problems", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text("\(diagnostics.count)").foregroundStyle(KanameColor.warning)
                    Spacer()
                    Text("Select an item to focus its exact graph or source location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        isExpanded = false
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse Problems")
                }
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(diagnostics) { diagnostic in
                            Button {
                                selectedID = diagnostic.id
                                onFocus(diagnostic)
                            } label: {
                                problem(diagnostic)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(diagnostic.accessibilityLabel)
                            .accessibilityHint("Focuses the declared \(diagnostic.focusTarget.projection.rawValue) location")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected problem").font(.caption.weight(.semibold))
                if let selected {
                    Text(selected.code).font(.system(.caption, design: .monospaced).weight(.bold))
                    Text(selected.summary).font(.headline)
                    Text(selected.instancePointer)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(KanameColor.accent)
                    HStack {
                        Button("Focus \(selected.focusTarget.projection.rawValue.capitalized)") {
                            onFocus(selected)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        if let fix = selected.fix {
                            Button(fix.title) { previewedFixID = fix.id }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    if previewedFixID == selected.fix?.id, let fix = selected.fix {
                        Label(fix.explanation, systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let focusMessage {
                        Text(focusMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 390, alignment: .leading)
        }
    }

    private var severitySummary: some View {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        return HStack(spacing: 8) {
            Label("\(errors) errors", systemImage: "xmark.octagon.fill")
                .foregroundStyle(KanameColor.danger)
            Label("\(warnings) warnings", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(KanameColor.warning)
        }
        .font(.caption2)
    }

    private func problem(_ diagnostic: DesktopWorkflowDiagnosticPresentation) -> some View {
        let selected = selectedID == diagnostic.id
        return HStack(spacing: 8) {
            Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? KanameColor.danger : KanameColor.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(diagnostic.code).font(.system(.caption2, design: .monospaced).weight(.bold))
                Text(diagnostic.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(diagnostic.focusTarget.projection.rawValue.capitalized)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(KanameColor.accent)
            Image(systemName: selected ? "scope" : "chevron.right")
                .foregroundStyle(selected ? KanameColor.accent : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? KanameColor.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AutomationVersionHistoryPanel: View {
    let currentVersion: Int

    private var versions: [(Int, String, String, Bool)] {
        (0..<min(currentVersion, 4)).map { offset in
            let version = currentVersion - offset
            if offset == 0 { return (version, "Current", "Published today · 3 runs", true) }
            if offset == 3 { return (version, "Retired", "18 Jul · 8 runs", false) }
            return (version, "Published", offset == 1 ? "9 Aug · 12 runs" : "2 Aug · 21 runs", false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Text("4 retained").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Each publish creates an immutable revision. Runs keep the exact graph and settings they used.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(versions, id: \.0) { version in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("v\(version.0)").font(.system(.caption, design: .monospaced).weight(.bold))
                        Text(version.1)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(version.3 ? KanameColor.success : .secondary)
                        Spacer()
                        if version.3 { Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success) }
                    }
                    Text(version.2).font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .font(.system(size: 9)).foregroundStyle(KanameColor.accent)
                }
                .padding(9)
                .background(version.3 ? KanameColor.accent.opacity(0.12) : KanameColor.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            }
            Spacer(minLength: 0)
            Divider()
            Button(
                "Compare v\(max(1, currentVersion - 1)) ↔ v\(currentVersion)",
                systemImage: "arrow.left.arrow.right"
            ) {}
                .buttonStyle(.bordered)
                .disabled(true)
            Label("Published versions cannot be edited", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AutomationLiveVersionHistoryPanel: View {
    let revisions: [DesktopWorkflowRevisionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                Text("\(revisions.count) retained").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Each publish creates an immutable revision. Runs keep the exact graph and settings they used.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if revisions.isEmpty {
                Text("No published revisions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("v\(revision.version)")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                            Text(index == 0 ? "Current" : "Published")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(index == 0 ? KanameColor.success : .secondary)
                            Spacer()
                            if index == 0 {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
                            }
                        }
                        Text(installedLabel(revision.installedAtUnixMillis))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(String(revision.manifestDigest.prefix(12)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(KanameColor.accent)
                    }
                    .padding(9)
                    .background(
                        index == 0 ? KanameColor.accent.opacity(0.12) : KanameColor.raised.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
            }
            Spacer(minLength: 0)
            Divider()
            Label("Published versions cannot be edited", systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func installedLabel(_ unixMillis: Int64) -> String {
        Date(timeIntervalSince1970: Double(unixMillis) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

struct AutomationNodeInspector: View {
    let step: AutomationCanvasStep
    @Binding var section: AutomationInspectorSection
    let showsCaseHistory: Bool
    var isLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: step.symbol)
                    .foregroundStyle(step.kind.tint)
                    .frame(width: 28, height: 28)
                    .background(step.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline).lineLimit(1)
                    Text(step.kind.label).font(.caption2.weight(.bold)).foregroundStyle(step.kind.tint)
                }
            }

            Picker("Inspector", selection: $section) {
                ForEach(AutomationInspectorSection.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            inspectorContent
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: isLive ? "shippingbox" : "testtube.2")
                Text(isLive
                    ? "Installed contract · qualification shown in Readiness"
                    : "Synthetic fixture contract · not operational")
            }
            .foregroundStyle(isLive ? KanameColor.accent : KanameColor.warning)
            Label(isLive ? "Bindings and authority are managed in Readiness" : "No live connections", systemImage: "network.slash")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(13)
        .frame(minHeight: 566, alignment: .topLeading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch section {
        case .configuration:
            inspectorFact("Node ID", value: step.id)
            inspectorFact("Execution", value: executionLabel)
            if step.state == .executable || step.state == .schemaOnly {
                inspectorFact("Compiler", value: step.state.label)
            }
            inspectorFact("Retry", value: retryLabel)
            Divider()
            if let reason = step.availabilityReason {
                Label(reason, systemImage: "bolt.slash.circle")
                    .foregroundStyle(KanameColor.warning)
                Divider()
            }
            Text(step.subtitle).foregroundStyle(.secondary)
        case .data:
            inspectorFact("Input", value: step.input)
            inspectorFact("Output", value: step.output)
            inspectorFact("Retention", value: "Until settled")
            Divider()
            Label("Typed ports validated", systemImage: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(KanameColor.accent)
        case .history:
            if showsCaseHistory {
                inspectorFact("Case", value: "CASE-184 · open")
                inspectorFact("Conversation", value: "One durable context")
                inspectorFact("Current", value: "Episode 3 · correction")
                inspectorFact("Artifacts", value: "v3 current · v1–v2 retained")
                Divider()
                historyRow("1", title: "Initial request", detail: "Artifact v1 · superseded", state: .complete)
                historyRow("2", title: "Correction", detail: "Artifact v2 · superseded", state: .complete)
                historyRow("3", title: "Revised attachment", detail: "Artifact v3 · current", state: .running)
                Divider()
                Text("Only current facts and required evidence enter the next model context. The complete lineage stays inspectable.")
                    .foregroundStyle(.secondary)
            } else {
                inspectorFact("Run", value: "#184")
                inspectorFact("Definition", value: "revision 1.0.0")
                inspectorFact("Input snapshot", value: "Immutable")
                inspectorFact("Replay boundary", value: retryLabel)
                Divider()
                Text("Published definitions and completed node attempts remain immutable.")
                    .foregroundStyle(.secondary)
            }
        case .safety:
            inspectorFact("Authority", value: step.authority)
            inspectorFact("Network", value: step.kind == .effect ? "Allowlisted connector" : "None by default")
            inspectorFact("Model egress", value: step.kind == .ai ? "Declared projection" : "None")
            Divider()
            Text(step.kind == .effect ? "The exact target and approval are rechecked immediately before execution." : "This node cannot inherit effect authority from its trigger or upstream nodes.")
                .foregroundStyle(step.kind == .effect ? KanameColor.warning : .secondary)
        }
    }

    private var executionLabel: String {
        switch step.kind {
        case .human, .wait: "Durable pause"
        case .decision, .policy, .data, .loop, .join, .parallel: "Deterministic"
        case .ai: "Model-assisted"
        case .context: "Deterministic projection"
        case .effect: "Privileged connector"
        case .trigger: "Event observation"
        case .error: "Blocked attention"
        case .subflow: "Pinned revision"
        case .receipt: "Local evidence"
        }
    }

    private var retryLabel: String {
        switch step.kind {
        case .effect: "Only known-safe failures"
        case .error: "Never automatic"
        case .human, .wait: "Resume, not retry"
        default: "From captured input"
        }
    }

    private func inspectorFact(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).textSelection(.enabled)
        }
    }

    private func historyRow(
        _ episode: String,
        title: String,
        detail: String,
        state: AutomationPreviewState
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(episode)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(state.tint)
                .frame(width: 18, height: 18)
                .background(state.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
