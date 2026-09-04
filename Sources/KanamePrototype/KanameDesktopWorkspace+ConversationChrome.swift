import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct DesktopThreadChangesView: View {
    @ObservedObject var model: DesktopAppModel
    let thread: DesktopThread
    let isAwaitingReview: Bool
    let beginReview: () -> Void
    @StateObject private var changes: DesktopThreadChangesViewModel
    @StateObject private var codingControl: DesktopCodingControlViewModel
    @State private var revertMessage: String?

    init(
        model: DesktopAppModel,
        thread: DesktopThread,
        gitControl: DesktopGitControlService,
        isAwaitingReview: Bool,
        beginReview: @escaping () -> Void
    ) {
        self.model = model
        self.thread = thread
        self.isAwaitingReview = isAwaitingReview
        self.beginReview = beginReview
        _changes = StateObject(wrappedValue: DesktopThreadChangesViewModel(service: gitControl))
        _codingControl = StateObject(wrappedValue: DesktopCodingControlViewModel(service: gitControl))
    }

    private var worktree: DesktopWorktreeRecord? {
        model.snapshot.operations.worktrees
            .filter { $0.threadID == thread.id && $0.state != .removed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let worktree {
                    changesWorkspace(worktree)
                        .onAppear { changes.load(worktree: worktree) }
                        .onChange(of: worktree.updatedAtUnixMillis) { _ in
                            changes.load(worktree: worktree, force: true)
                        }
                } else {
                    EmptyPanel(
                        symbol: "doc.text.magnifyingglass",
                        title: "No code changes for this thread",
                        detail: "When an approved coding run creates an isolated worktree, its files and per-file patches appear here instead of filling the conversation."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if isAwaitingReview {
                Divider()
                DesktopDecisionFooter(
                    title: "Review the changes",
                    detail: "When the diff looks right, run the project's checks. Nothing is merged or pushed."
                ) {
                    Button("Run checks", systemImage: "checkmark.shield", action: beginReview)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Starts independent checks for the isolated changes")
                }
            }
        }
        .background(KanameColor.canvas)
    }

    private func changesWorkspace(_ worktree: DesktopWorktreeRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("\(changes.snapshot?.changedFiles.count ?? worktree.changedFileCount) changed", systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                Text(worktree.branch)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(worktree.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(worktree.state == .failed ? KanameColor.danger : KanameColor.accent)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)])
                } label: {
                    Label("Reveal worktree", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(worktree.worktreePath)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(changes.patch, forType: .string)
                } label: {
                    Label("Copy patch", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(changes.patch.isEmpty)
                Button {
                    changes.load(worktree: worktree, force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(changes.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(KanameColor.surface)

            if !turnCheckpoints(worktree).isEmpty {
                DisclosureGroup("Turn checkpoints") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(turnCheckpoints(worktree)) { checkpoint in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Turn \(checkpoint.turnID.suffix(8))")
                                    .font(.caption.weight(.semibold))
                                Text(checkpoint.diffStat.isEmpty ? "Awaiting after-bracket diff" : checkpoint.diffStat)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                Button("Request revert approval") {
                                    requestCheckpointRevert(checkpoint, worktree: worktree)
                                }
                                .controlSize(.small)
                                .disabled(!checkpoint.hasAfterBracket || worktree.state == .accepted)
                                Button("Execute approved revert") {
                                    codingControl.executeCheckpointRevert(
                                        model: model,
                                        worktree: worktree,
                                        checkpoint: checkpoint
                                    )
                                    revertMessage = codingControl.message
                                    changes.load(worktree: worktree, force: true)
                                }
                                .controlSize(.small)
                                .disabled(!checkpoint.hasAfterBracket || worktree.state == .accepted)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                if let revertMessage {
                    Text(revertMessage)
                        .font(.caption2)
                        .foregroundStyle(KanameColor.warning)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                Divider()
            }

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter files", text: $changes.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(11)
                    Divider()

                    if changes.filteredPaths.isEmpty {
                        Text(changes.isLoading ? "Reading worktree…" : "Working tree is clean")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(changes.filteredPaths, id: \.self) { path in
                            Button {
                                changes.select(path: path, worktree: worktree)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Label(path, systemImage: "doc.text")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(KanameColor.accent)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let stat = fileStat(path) {
                                        Text(stat.added > 0 ? "+\(stat.added)" : "")
                                            .foregroundStyle(KanameColor.success)
                                        Text(stat.removed > 0 ? "-\(stat.removed)" : "")
                                            .foregroundStyle(KanameColor.danger)
                                    }
                                }
                                .font(.system(.caption2, design: .monospaced))
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                changes.selectedPath == path
                                    ? KanameColor.accent.opacity(0.12)
                                    : Color.clear
                            )
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

                diffPane
            }
        }
    }

    /// Added and removed line counts for one path, parsed from `git diff --numstat`-style
    /// or `--stat`-style summary lines when the worktree snapshot carries them.
    private func fileStat(_ path: String) -> (added: Int, removed: Int)? {
        guard let summary = changes.snapshot?.diffSummary, !summary.isEmpty else { return nil }
        for line in summary.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 3, parts[2].trimmingCharacters(in: .whitespaces) == path,
               let added = Int(parts[0]), let removed = Int(parts[1]) {
                return (added, removed)
            }
            if line.contains(path), let bar = line.firstIndex(of: "|") {
                let tail = line[line.index(after: bar)...]
                let added = tail.filter { $0 == "+" }.count
                let removed = tail.filter { $0 == "-" }.count
                if added + removed > 0 { return (added, removed) }
            }
        }
        return nil
    }

    private func turnCheckpoints(_ worktree: DesktopWorktreeRecord) -> [DesktopCodingCheckpointRecord] {
        model.snapshot.operations.codingCheckpoints
            .filter { $0.threadID == thread.id && $0.worktreeID == worktree.id }
            .sorted { $0.createdAtUnixMillis > $1.createdAtUnixMillis }
    }

    private func requestCheckpointRevert(
        _ checkpoint: DesktopCodingCheckpointRecord,
        worktree: DesktopWorktreeRecord
    ) {
        guard let exactTarget = checkpoint.approvalExactTarget(worktreePath: worktree.worktreePath) else {
            revertMessage = "This legacy checkpoint cannot be restored safely. Run a new implementation turn first."
            return
        }
        _ = model.createApproval(
            threadID: thread.id,
            title: "Revert implementation turn",
            exactTarget: exactTarget,
            consequence: "Restore tracked and non-ignored files plus staged state to the checkpoint captured before turn \(checkpoint.turnID). Ignored files and empty directories are outside this checkpoint and remain untouched. Changed paths: \(checkpoint.diffSummary.isEmpty ? "see diff stat after approval" : checkpoint.diffSummary)",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: Int64(Date().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
        )
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(changes.selectedPath ?? "Select a file")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let selected = changes.selectedPath, let worktree {
                    Button("Open file", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: worktree.worktreePath).appendingPathComponent(selected))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if changes.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KanameColor.surface)

            Divider()

            if let message = changes.message {
                EmptyPanel(symbol: "exclamationmark.triangle", title: "Diff unavailable", detail: message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changes.patch.isEmpty {
                Text(changes.isLoading ? "Loading patch…" : "No textual patch for this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let parsed = DesktopUnifiedDiffPresentation.parse(changes.patch)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text("\(parsed.hunks) hunk\(parsed.hunks == 1 ? "" : "s")")
                        Text("+\(parsed.added)").foregroundStyle(KanameColor.success)
                        Text("-\(parsed.removed)").foregroundStyle(KanameColor.danger)
                        if parsed.isBinary { Text("binary").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Copy patch", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(changes.patch, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Copy the unified diff for this file")
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(parsed.rows.filter { $0.kind != .header }) { row in
                                DesktopUnifiedDiffLine(row: row)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesktopUnifiedDiffLine: View {
    let row: DesktopUnifiedDiffPresentation.Row

    private var tint: Color {
        switch row.kind {
        case .added: KanameColor.success
        case .removed: KanameColor.danger
        case .hunk: KanameColor.accent
        case .context, .header, .meta: .clear
        }
    }

    private var marker: String {
        switch row.kind {
        case .added: "+"
        case .removed: "-"
        default: " "
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.kind == .hunk {
                Text(row.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(KanameColor.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            } else {
                Text(row.oldLine.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
                Text(row.newLine.map(String.init) ?? "")
                    .frame(width: 42, alignment: .trailing)
                    .padding(.trailing, 6)
                Text(marker)
                    .frame(width: 12)
                Text(row.text.isEmpty ? " " : row.text)
                    .foregroundStyle(row.kind == .meta ? Color.secondary : Color.primary)
                    .padding(.trailing, 10)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(row.kind == .hunk ? 0.08 : 0.13))
    }
}

struct DesktopThreadTabBar: View {
    @Binding var selection: DesktopThreadPanel
    let panels: [DesktopThreadPanel]
    let attentionPanel: DesktopThreadPanel?
    @FocusState private var focusedPanel: DesktopThreadPanel?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(panels) { panel in
                tabButton(panel)
            }
        }
        .onMoveCommand(perform: moveSelection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread sections")
    }

    @ViewBuilder private func tabButton(_ panel: DesktopThreadPanel) -> some View {
        let isSelected = selection == panel
        let needsAttention = attentionPanel == panel
        Button {
            selection = panel
            focusedPanel = panel
        } label: {
            ZStack(alignment: .bottom) {
                ViewThatFits(in: .horizontal) {
                    Text(panel.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: panel.symbol)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isSelected {
                    Rectangle()
                        .fill(KanameColor.accent)
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(KanameColor.warning)
                        .padding(.top, 7)
                        .padding(.trailing, 7)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focusedPanel, equals: panel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isSelected ? KanameColor.accent.opacity(0.07) : Color.clear)
        .accessibilityLabel(needsAttention ? "\(panel.label), requires attention" : panel.label)
        .accessibilityHint("Shows the \(panel.label) section")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let movement: DesktopCyclicSelectionDirection
        switch direction {
        case .left: movement = .previous
        case .right: movement = .next
        default:
            return
        }
        guard let destination = DesktopCyclicSelection.moving(
            focusedPanel ?? selection,
            movement,
            in: panels
        ) else { return }
        focusedPanel = destination
        selection = destination
    }
}

struct DesktopCodingWorkflowStatusControl: View {
    let stage: DesktopCodingWorkflowStage
    let error: String?
    let openPanel: (DesktopThreadPanel) -> Void
    let interrupt: (() -> Void)?
    @State private var showsDetails = false

    private var presentation: DesktopCodingWorkflowPresentation {
        DesktopCodingWorkflowPresentation(stage: stage)
    }

    private var statusTint: Color {
        error == nil ? stage.tint : KanameColor.danger
    }

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: error == nil ? presentation.symbol : "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(presentation.compactLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minWidth: 44, maxWidth: 190)
            .background(statusTint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetails) {
            statusDetails
        }
        .help("Show workflow status")
        .accessibilityLabel(
            "Workflow status: \(presentation.title). \(presentation.progressLabel)"
                + (error == nil ? "" : ". Error details available")
        )
        .accessibilityHint("Shows workflow details and navigation")
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: presentation.symbol)
                .font(.headline)
                .foregroundStyle(stage.tint)
            Text(presentation.progressLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(presentation.detail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KanameColor.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            GroupBox {
                Text(DesktopCodingWorkflowPresentation.workflowPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Label("Guarded workflow", systemImage: "shield.lefthalf.filled")
                    .font(.caption.weight(.semibold))
            }

            if presentation.ownerPanel != nil || interrupt != nil {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { statusActions }
                    VStack(alignment: .leading, spacing: 8) { statusActions }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stage.progressLabel). \(stage.compactStatus)")
    }

    @ViewBuilder private var statusActions: some View {
        if let ownerPanel = presentation.ownerPanel {
            Button("Open \(ownerPanel.label)", systemImage: ownerPanel.symbol) {
                showsDetails = false
                openPanel(ownerPanel)
            }
            .buttonStyle(.borderedProminent)
        }
        if let interrupt {
            Button("Interrupt", systemImage: "stop.circle", role: .destructive) {
                showsDetails = false
                interrupt()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Stops the active provider turn")
        }
    }
}

/// Live "it is doing something" row above the composer while a run is active.
/// Shows the current tool or command and a tool count; details stay in the
/// timeline and the Processes tab.
struct DesktopConversationActivityStrip: View {
    let run: DesktopProviderRunRecord
    let events: [DesktopProviderEventRecord]
    let stop: () -> Void

    private var latestActivity: String {
        guard let event = events.last(where: { $0.kind == .tool || $0.kind == .reasoning || $0.kind == .status }) else {
            return "Thinking…"
        }
        if event.kind == .tool, let observation = event.toolObservation {
            if let process = DesktopCodingProcessProjection.processes(from: [event]).first, !process.command.isEmpty,
               process.command != observation.name {
                return "$ \(process.command)"
            }
            return observation.name ?? event.title
        }
        return event.title
    }

    private var toolCount: Int {
        Set(events.filter { $0.kind == .tool }.compactMap { $0.toolObservation?.callID }).count
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int64(context.date.timeIntervalSince1970 * 1_000) - run.startedAtUnixMillis) / 1_000
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working · \(run.provider) · \(elapsed / 60 > 0 ? "\(elapsed / 60)m \(elapsed % 60)s" : "\(elapsed)s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(latestActivity)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if toolCount > 0 {
                    Text("\(toolCount) tool\(toolCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(KanameColor.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(run.provider) is working. \(latestActivity)")
        }
    }
}

struct DesktopConversationRunCapsule: View {
    let summary: DesktopConversationRunSummary
    let inspect: () -> Void

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 11) {
            GridRow {
                Image(systemName: summary.run.state.accessibilitySymbol)
                    .foregroundStyle(summary.run.state.tint)
                    .frame(width: 24)
                DesktopConversationRunCapsuleDetails(summary: summary, inspect: inspect)
            }
        }
        .padding(12)
        .background(summary.run.state.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(summary.run.state.tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(summary.run.provider) run \(summary.run.state.label). \(summary.conciseActivityLabel)")
    }
}

private struct DesktopConversationRunCapsuleDetails: View {
    let summary: DesktopConversationRunSummary
    let inspect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            capsuleHeader
            capsuleSummary
            capsuleLatestActivity
            capsuleActionLayout
        }
    }

    private var runLabel: String {
        let state = summary.run.state == .running
            ? "Working"
            : "Run \(summary.run.state.label.lowercased())"
        return "\(state) · \(summary.run.provider)"
    }

    private var capsuleHeader: some View {
        LabeledContent(runLabel) {
            RelativeTime(unixMillis: summary.presentationTimeUnixMillis)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold))
    }

    private var capsuleSummary: some View {
        Text(summary.conciseActivityLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder private var capsuleLatestActivity: some View {
        if let latest = summary.latestActivity,
           !latest.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(latest.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var capsuleActionLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { capsuleActions }
            VStack(alignment: .leading, spacing: 6) { capsuleActions }
        }
    }

    @ViewBuilder private var capsuleActions: some View {
        Button("Open activity", systemImage: "list.bullet.rectangle", action: inspect)
            .buttonStyle(.bordered)
            .controlSize(.small)
        if summary.payloadWasTruncated {
            Label("Evidence payload capped", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(KanameColor.warning)
        }
    }
}

private struct DesktopProviderEventGroupCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: DesktopProviderEventGroup
    @Binding var isExpanded: Bool
    @Binding var questionAnswer: String
    let answer: (DesktopProviderEventRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpansion) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: group.kind.timelineSymbol)
                        .foregroundStyle(group.kind.timelineTint)
                        .frame(width: 25)
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent {
                            RelativeTime(unixMillis: group.latestCreatedAtUnixMillis)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } label: {
                            Text(group.summaryTitle)
                                .font(.caption.weight(.semibold))
                        }
                        if !group.latestSummary.isEmpty {
                            Text(group.latestSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if group.containsTruncatedPayload {
                            Label("Some raw payloads exceeded the evidence limit", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(KanameColor.warning)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isExpanded)
                        .frame(width: 14, height: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(group.accessibilityLabel(isExpanded: isExpanded))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse event group" : "Expand event group")
            .accessibilityIdentifier("provider-event-group-\(group.id)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.events) { event in
                        DesktopProviderEventCard(
                            event: event,
                            questionAnswer: $questionAnswer,
                            answer: { answer(event) }
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(12)
        .background(group.kind.timelineTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }
    }
}

struct DesktopProviderEventCard: View {
    let event: DesktopProviderEventRecord
    @Binding var questionAnswer: String
    let answer: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack {
                Image(systemName: event.kind.timelineSymbol)
                    .foregroundStyle(event.kind.timelineTint)
                Spacer(minLength: 0)
            }
            .frame(width: 25)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.title).font(.caption.weight(.semibold))
                    Spacer()
                    RelativeTime(unixMillis: event.createdAtUnixMillis)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if event.kind == .question, event.approvalID != nil {
                    HStack {
                        TextField("Answer Codex", text: $questionAnswer)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(answer)
                        Button("Answer", action: answer)
                            .buttonStyle(.borderedProminent)
                            .disabled(questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if event.payloadWasTruncated {
                    Label("Raw payload exceeded the evidence limit", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(KanameColor.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(event.kind.timelineTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title). \(event.detail)")
    }
}

extension DesktopProviderEventKind {
    var timelineSymbol: String {
        switch self {
        case .status: "circle.dotted"
        case .reasoning: "list.bullet.clipboard"
        case .tool: "wrench.and.screwdriver"
        case .question: "questionmark.bubble"
        case .approval: "checkmark.shield"
        case .diff: "doc.badge.ellipsis"
        case .usage: "gauge.with.dots.needle.50percent"
        case .error: "exclamationmark.triangle"
        case .native: "waveform.path.ecg"
        case .assistantText: "sparkles"
        }
    }

    var timelineTint: Color {
        switch self {
        case .error: KanameColor.danger
        case .question, .approval: KanameColor.warning
        case .diff: KanameColor.blocked
        case .tool, .reasoning: KanameColor.active
        case .status, .usage, .native, .assistantText: KanameColor.accent
        }
    }
}
