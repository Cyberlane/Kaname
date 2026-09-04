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

struct DesktopThreadsView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var runtime: DesktopConversationRuntime
    let gitControl: DesktopGitControlService
    let capabilities: [ProviderCapabilitySnapshot]
    let searchText: String
    @Binding var selectedThreadID: String?
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    let composerFocusRequest: DesktopComposerFocusRequest?
    let requestArchive: (String) -> Void
    @Binding var showsDirectory: Bool

    var body: some View {
        HSplitView {
            if showsDirectory {
                VStack(alignment: .leading, spacing: 0) {
                    SurfaceHeader(
                        title: "Threads",
                        detail: "Durable conversations and project continuity",
                        symbol: DesktopDestination.threads.symbol
                    )
                    List(selection: $selectedThreadID) {
                        let matching = model.threads(matching: searchText)
                        let active = matching.filter { $0.attention != .completed }
                        let completed = matching.filter { $0.attention == .completed }
                        Section("Active") {
                            ForEach(active) { thread in threadDirectoryRow(thread) }
                        }
                        if !completed.isEmpty {
                            Section("Completed") {
                                ForEach(completed) { thread in threadDirectoryRow(thread) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 310)
            }

            if let thread = model.thread(id: selectedThreadID) {
                DesktopThreadConversation(
                    model: model,
                    runtime: runtime,
                    gitControl: gitControl,
                    capabilities: capabilities,
                    thread: thread,
                    selectedRunID: $selectedRunID,
                    conversationAnchorID: $conversationAnchorID,
                    composerFocusRequest: composerFocusRequest
                )
                    .id(thread.id)
                    .frame(minWidth: 340)
            } else {
                EmptyPanel(
                    symbol: "bubble.left.and.bubble.right",
                    title: "Select a thread",
                    detail: "Open a durable conversation, plan, and its current evidence."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KanameColor.canvas)
        .onChange(of: selectedThreadID) { _ in
            selectedRunID = nil
            conversationAnchorID = nil
        }
    }

    private func threadDirectoryRow(_ thread: DesktopThread) -> some View {
        ThreadDirectoryLabel(
            thread: thread,
            runs: model.providerRuns(threadID: thread.id)
        )
        .tag(thread.id as String?)
        .contextMenu {
            Button(thread.attention == .completed ? "Mark active" : "Mark complete") {
                model.setAttention(
                    threadID: thread.id,
                    attention: thread.attention == .completed ? .needsResponse : .completed
                )
            }
            Button("Archive", role: .destructive) {
                requestArchive(thread.id)
            }
        }
    }
}

struct DesktopInboxView: View {
    @ObservedObject var model: DesktopAppModel
    let searchText: String
    @Binding var filter: DesktopAttention?
    @Binding var selectedThreadID: String?
    let requestArchive: (String) -> Void

    private var threads: [DesktopThread] {
        model.threads(matching: searchText, attention: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SurfaceHeader(
                title: "Inbox",
                detail: "The same threads, projected by attention",
                symbol: DesktopDestination.inbox.symbol
            ) {
                Picker("Attention filter", selection: $filter) {
                    Text("All active").tag(nil as DesktopAttention?)
                    ForEach([
                        DesktopAttention.needsResponse,
                        .needsApproval,
                        .running,
                        .queued,
                        .failed,
                        .completed,
                    ], id: \.self) { attention in
                        Text(attention.label).tag(attention as DesktopAttention?)
                    }
                }
                .frame(width: 180)
            }


            if !model.snapshot.operations.approvals.isEmpty {
                ApprovalQueueStrip(model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }

            if threads.isEmpty {
                EmptyPanel(
                    symbol: "tray",
                    title: "No matching inbox items",
                    detail: "Change the attention filter or create a new local thread."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedThreadID) {
                    ForEach(threads) { thread in
                        InboxThreadLabel(thread: thread)
                            .tag(thread.id as String?)
                            .swipeActions(edge: .trailing) {
                                Button("Archive", role: .destructive) {
                                    requestArchive(thread.id)
                                }
                                Button("Complete") {
                                    model.setAttention(threadID: thread.id, attention: .completed)
                                }
                                .tint(KanameColor.success)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(KanameColor.canvas)
    }
}

struct ThreadPlanView: View {
    let items: [DesktopPlanItem]
    let planBody: String?
    let phase: DesktopPlanPhase
    let provider: String
    let requestChanges: () -> Void
    let approvePlan: () -> Void

    private var presentation: DesktopPlanPresentation {
        DesktopPlanPresentation(items: items, phase: phase)
    }

    var body: some View {
        VStack(spacing: 0) {
            planScrollSurface

            if phase == .awaitingApproval {
                Divider()
                planReviewFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var planScrollSurface: some View {
        ScrollView {
            planScrollContent
        }
    }

    private var planScrollContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if presentation.rows.isEmpty, planBody == nil {
                emptyPlan
            } else {
                planHeader
                if let planBody, !planBody.isEmpty {
                    ThreadPlanBodyView(markdown: planBody)
                }
                if !presentation.rows.isEmpty {
                    planOutline
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var emptyPlan: some View {
        EmptyPanel(
            symbol: "list.bullet.clipboard",
            title: "No plan yet",
            detail: "Talk in Chat. The plan appears here as it forms."
        )
    }

    private var planOutline: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                ThreadPlanRow(row: row)
                if index < presentation.rows.count - 1 {
                    Divider().padding(.leading, 66)
                }
            }
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KanameColor.separator, lineWidth: 1)
        }
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeading
            phaseCallout
        }
    }

    private var planHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            planTitle
            planProgress
        }
    }

    private var planTitle: some View {
        Text("Implementation plan")
            .font(.title2.weight(.bold))
    }

    private var planProgress: some View {
        Label(presentation.progressLabel, systemImage: "list.number")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var phaseCallout: some View {
        HStack(alignment: .top, spacing: 11) {
            phaseIcon
            VStack(alignment: .leading, spacing: 3) {
                phaseTitle
                phaseDetail
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(phase.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(phase.tint.opacity(0.24), lineWidth: 1)
        }
    }

    private var phaseIcon: some View {
        Image(systemName: phase.symbol)
            .font(.title3)
            .foregroundStyle(phase.tint)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var phaseTitle: some View {
        Text(phase.label)
            .font(.subheadline.weight(.semibold))
    }

    private var phaseDetail: some View {
        Text(phase.detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var planReviewFooter: some View {
        DesktopDecisionFooter(
            title: "Ready for your decision",
            detail: "Ask for changes in Chat to revise this plan. Approve to create an isolated worktree and start implementing."
        ) {
            reviewActions
        }
    }

    private var reviewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                requestChangesButton
                approvePlanButton
            }
            VStack(alignment: .leading, spacing: 8) {
                requestChangesButton
                approvePlanButton
            }
        }
    }

    private var requestChangesButton: some View {
        Button("Request changes", systemImage: "text.bubble", action: requestChanges)
            .buttonStyle(.bordered)
            .tint(KanameColor.accent)
            .accessibilityHint("Opens Chat and focuses the composer for revision guidance")
    }

    private var approvePlanButton: some View {
        Button(action: approvePlan) {
            Label("Approve plan & implement", systemImage: "checkmark.shield.fill")
                .foregroundStyle(KanameColor.canvas)
        }
        .buttonStyle(.borderedProminent)
        .tint(KanameColor.success)
        .disabled(items.isEmpty || !providerSupportsImplementation)
        .help(approvalHelp)
        .accessibilityHint(approvalHelp)
    }

    private var providerSupportsImplementation: Bool {
        DesktopConversationRuntime.supportsIsolatedImplementation(provider: provider)
    }

    private var approvalHelp: String {
        if items.isEmpty { return "Wait for a readable plan before approving implementation" }
        return providerSupportsImplementation
            ? "Create an isolated worktree and start implementing the approved plan"
            : "\(provider) has no Kaname conversation adapter, so it cannot implement here"
    }
}

/// Lightweight Markdown rendering for the living plan body: headings, lists,
/// paragraphs, and fenced code. Inline emphasis and links use AttributedString.
private struct ThreadPlanBodyView: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(Int, String)
        case paragraph(String)
        case listItem(String)
        case code(String)

        var id: String {
            switch self {
            case let .heading(level, text): "h\(level)-\(text)"
            case let .paragraph(text): "p-\(text.prefix(80))-\(text.count)"
            case let .listItem(text): "li-\(text.prefix(80))-\(text.count)"
            case let .code(text): "code-\(text.prefix(80))-\(text.count)"
            }
        }
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                let level = line[range].filter { $0 == "#" }.count
                blocks.append(.heading(level, String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^(\d+[.)]|[-*+])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.listItem(String(line[range.upperBound...])))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inline(text)
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 6)
                case let .paragraph(text):
                    inline(text)
                        .font(.body)
                case let .listItem(text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(text).font(.body)
                    }
                    .padding(.leading, 6)
                case let .code(text):
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityLabel("Plan")
    }

    private func inline(_ text: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

private struct ThreadPlanRow: View {
    let row: DesktopPlanPresentation.Row

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ordinalBadge
            VStack(alignment: .leading, spacing: 8) {
                planStepTitle
                statusLabel
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.isCurrent ? row.tint.opacity(0.08) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var ordinalBadge: some View {
        Text("\(row.ordinal)")
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(row.tint)
            .frame(width: 28, height: 28)
            .background(row.tint.opacity(0.13), in: Circle())
    }

    private var planStepTitle: some View {
        Text(row.title)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var statusLabel: some View {
        Label(row.statusLabel, systemImage: row.statusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(row.tint)
            .fixedSize()
    }
}

struct ThreadEvidenceView: View {
    let items: [DesktopEvidence]
    let findings: [DesktopFinding]
    let isAwaitingReview: Bool
    let recheckEvidence: () -> Void
    let accept: () -> Void
    let reject: () -> Void
    var pullRequest: PullRequestAction? = nil

    struct PullRequestAction {
        let status: String?
        let open: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !findings.isEmpty {
                        Text("Findings")
                            .font(.headline)
                        ForEach(findings) { finding in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "magnifyingglass.circle.fill")
                                    .foregroundStyle(KanameColor.accent)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(finding.title).font(.subheadline.weight(.semibold))
                                    if finding.detail != finding.title {
                                        Text(finding.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(15)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        if !items.isEmpty {
                            Text("Checks")
                                .font(.headline)
                                .padding(.top, 8)
                        }
                    }
                    if items.isEmpty, findings.isEmpty {
                        EmptyPanel(symbol: "checkmark.seal", title: "No findings or checks yet", detail: "Findings appear as the agent investigates. Checks run after implementation.")
                    } else {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.state.symbol)
                                    .foregroundStyle(item.state.tint)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label).font(.headline)
                                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.state.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.state.tint)
                            }
                            .padding(15)
                            .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isAwaitingReview {
                Divider()
                DesktopDecisionFooter(
                    title: "Accept or reject",
                    detail: "Accepting marks this work done locally and starts the knowledge update. Nothing is merged or pushed."
                ) {
                    evidenceReviewActions
                }
            } else if let pullRequest {
                Divider()
                DesktopDecisionFooter(
                    title: "Accepted",
                    detail: pullRequest.status
                        ?? "Commit what is left, push the branch to origin, and open a pull request with the plan and findings as the description."
                ) {
                    Button("Open pull request", action: pullRequest.open)
                        .buttonStyle(.borderedProminent)
                        .disabled(pullRequest.status?.hasPrefix("Working") ?? false)
                }
            }
        }
    }

    private var evidenceReviewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { evidenceReviewButtons }
            VStack(alignment: .leading, spacing: 8) { evidenceReviewButtons }
        }
    }

    @ViewBuilder private var evidenceReviewButtons: some View {
        Button("Re-run checks", systemImage: "arrow.clockwise", action: recheckEvidence)
            .buttonStyle(.bordered)
        Button("Reject", role: .destructive, action: reject)
            .buttonStyle(.bordered)
            .accessibilityHint("Rejects this result while retaining isolated changes")
        Button("Accept", action: accept)
            .buttonStyle(.borderedProminent)
            .disabled(!evidencePassed)
            .help(evidencePassed ? "Record local acceptance" : "All independent evidence must pass before acceptance")
            .accessibilityHint(
                evidencePassed
                    ? "Records local acceptance without merging, pushing, or publishing"
                    : "All independent evidence must pass before acceptance"
            )
    }

    private var evidencePassed: Bool {
        !items.isEmpty && items.allSatisfy { $0.state == .passed }
    }
}

struct DesktopMessageBubble: View {
    let message: DesktopMessage
    let threadID: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 60) }
            if message.role != .user {
                Image(systemName: message.role == .assistant ? "sparkles" : "shield.lefthalf.filled")
                    .foregroundStyle(message.role == .assistant ? KanameColor.accent : KanameColor.blocked)
                    .frame(width: 25)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.role.label)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    RelativeTime(unixMillis: message.createdAtUnixMillis)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if message.role == .user {
                    Text(message.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ThreadPlanBodyView(markdown: message.body)
                }
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.attachments) { attachment in
                                DesktopConversationImagePreview(
                                    threadID: threadID,
                                    attachment: attachment,
                                    size: CGSize(width: 140, height: 96)
                                )
                            }
                        }
                    }
                }
            }
            .padding(13)
            .background(message.role.background, in: RoundedRectangle(cornerRadius: 15))
            if message.role != .user { Spacer(minLength: 42) }
        }
    }
}

struct DesktopComposerImageThumbnail: View {
    let threadID: String
    let attachment: ConversationImageAttachment
    let remove: () -> Void
    @State private var showsPreview = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { showsPreview = true } label: {
                DesktopConversationImagePreview(
                    threadID: threadID,
                    attachment: attachment,
                    size: CGSize(width: 58, height: 58)
                )
            }
            .buttonStyle(.plain)
            .help("Preview \(attachment.filename)")

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.72))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .popover(isPresented: $showsPreview) {
            VStack(alignment: .leading, spacing: 10) {
                DesktopConversationImagePreview(
                    threadID: threadID,
                    attachment: attachment,
                    size: CGSize(width: 520, height: 420)
                )
                Text(attachment.filename)
                    .font(.caption)
                Text("\(attachment.pixelWidth) × \(attachment.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
}

private struct DesktopConversationImagePreview: View {
    let threadID: String
    let attachment: ConversationImageAttachment
    let size: CGSize

    private var imageURL: URL? {
        let environment = KanameDesktopEnvironment.current
        let store = KanameConversationAttachmentStore(
            rootDirectory: environment.applicationSupportRoot
                .appending(path: "ConversationService", directoryHint: .isDirectory)
        )
        return try? store.attachmentURL(threadID: threadID, attachment: attachment)
    }

    var body: some View {
#if os(macOS)
        Group {
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(KanameColor.raised, in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("Attached image \(attachment.filename)")
#else
        EmptyView()
#endif
    }
}
