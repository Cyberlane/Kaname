import Foundation
import SwiftUI
import KanameConnectivity
import KanameDesignSystem
import KanameDesktop
import KanameDomain
import KanameFixtures
import KanamePrototypeUI
#if os(macOS)
import AppKit
import Darwin
#endif

struct ThreadsView: View {
    let fixtures: [Phase0Fixture]
    let openFixture: (Phase0Fixture) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhaseBanner()
                Text("Conversations with durable context")
                    .font(.largeTitle.weight(.bold))
                Text("Threads are the chat-like continuity for a task. Inbox is the separate attention view over those same conversations.")
                    .foregroundStyle(.secondary)

                LazyVStack(spacing: 10) {
                    ForEach(fixtures, id: \.name) { fixture in
                        Button {
                            openFixture(fixture)
                        } label: {
                            ThreadDirectoryRow(fixture: fixture)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ThreadDirectoryRow: View {
    let fixture: Phase0Fixture

    var body: some View {
        let projection = try? fixture.makeProjection()

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: fixture.thread.workspaceKind.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(fixture.thread.title)
                        .font(.headline)
                    Spacer()
                    KanameStatusBadge(
                        (projection?.attention ?? .none).legacyStatusPresentation,
                        density: .compact
                    )
                }
                Text(fixture.task.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(fixture.providerSession.provider) · \(fixture.thread.workspaceKind.displayName) context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(16)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum ThreadPanel: String, CaseIterable, Identifiable {
    case conversation
    case work
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .work: "Work"
        case .review: "Review"
        }
    }
}

struct ThreadWorkspaceView: View {
    let fixture: Phase0Fixture
    let returnTitle: String?
    let onBack: () -> Void
    @State private var selectedPanel: ThreadPanel = .conversation

    var body: some View {
        let projection = try? fixture.makeProjection()

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PhaseBanner()

                if let returnTitle {
                    Button {
                        onBack()
                    } label: {
                        Label("Back to \(returnTitle)", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fixture.thread.title)
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        KanameStatusBadge(
                            (projection?.attention ?? .none).legacyStatusPresentation,
                            density: .compact
                        )
                    }
                    Text("\(fixture.providerSession.provider) · \(fixture.thread.workspaceKind.displayName) workspace")
                        .foregroundStyle(.secondary)
                }

                ThreadSummary(fixture: fixture, projection: projection)

                if fixture.thread.workspaceKind == .coding {
                    Picker("Thread panel", selection: $selectedPanel) {
                        ForEach(ThreadPanel.allCases) { panel in
                            Text(panel.title).tag(panel)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            switch selectedPanel {
            case .conversation:
                ThreadConversationView(fixture: fixture)
                    .padding(.horizontal, 24)
            case .work:
                ScrollView {
                    CodingWorkView(fixture: fixture)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            case .review:
                ScrollView {
                    CodeReviewView(fixture: fixture)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(KanameColor.canvas)
        .onChange(of: fixture.name) { _ in
            selectedPanel = .conversation
        }
    }
}

private struct ThreadConversationView: View {
    let fixture: Phase0Fixture
    @State private var showsActivity = false
    @State private var draft = ""
    @State private var locallyQueuedReplies: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConversationBubble(
                        role: .user,
                        author: "Justin",
                        message: "Could you \(fixture.task.title.lowercased())? Keep the selected \(fixture.thread.workspaceKind.displayName.lowercased()) context separate from unrelated work."
                    )
                    ConversationBubble(
                        role: .agent,
                        author: fixture.providerSession.provider,
                        message: fixture.conversationSummary
                    )

                    if !fixture.approvals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Decision required")
                                .font(.headline)
                            ForEach(fixture.approvals, id: \.id) { approval in
                                ApprovalCard(approval: approval)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsActivity.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Label("Agent activity · \(fixture.events.count) events", systemImage: "bolt.horizontal.circle")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: showsActivity ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(KanameColor.accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Agent activity")
                        .accessibilityHint(showsActivity ? "Collapse activity" : "Expand activity")

                        if showsActivity {
                            VStack(spacing: 8) {
                                ForEach(fixture.events, id: \.id) { event in
                                    EventRow(event: event)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))

                    if !fixture.queueItems.isEmpty {
                        QueueCard(queueItems: fixture.queueItems)
                    }

                    if !locallyQueuedReplies.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Queued locally")
                                .font(.headline)
                            ForEach(locallyQueuedReplies, id: \.self) { reply in
                                Text(reply)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(KanameColor.accentStrong.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Reply or queue a follow-up", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button("Queue") {
                        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedDraft.isEmpty else { return }
                        locallyQueuedReplies.append(trimmedDraft)
                        draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Fixture only: queuing changes local prototype state and never contacts a provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(KanameColor.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum ConversationRole {
    case user
    case agent
}

private struct ConversationBubble: View {
    let role: ConversationRole
    let author: String
    let message: String

    var body: some View {
        HStack(alignment: .top) {
            if role == .agent {
                bubble
                Spacer(minLength: 80)
            } else {
                Spacer(minLength: 80)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(author)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            role == .user ? KanameColor.accentStrong.opacity(0.32) : KanameColor.surface,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

private struct CodingWorkView: View {
    let fixture: Phase0Fixture

    var body: some View {
        Group {
            if fixture.thread.workspaceKind != .coding {
                DomainUnavailableView(
                    title: "No coding workspace attached",
                    detail: "This conversation has a \(fixture.thread.workspaceKind.displayName.lowercased()) context, so it has no worktree or code-quality evidence."
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Work stays attached to this conversation")
                        .font(.title2.weight(.bold))
                    Text("The quality loop is a review model inside coding work, not a separate destination.")
                        .foregroundStyle(.secondary)
                    QualityProgressStrip()
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Current plan", systemImage: "list.bullet.clipboard")
                            .font(.headline)
                        Text("1. Inspect the selected repository context.\n2. Make the smallest isolated change.\n3. Present diffs, tests, and any not-run boundary for review.")
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    HStack {
                        CompactEvidence(label: "Workspace", value: "isolated fixture", tint: .blue)
                        CompactEvidence(label: "Plan", value: "approved", tint: .green)
                        CompactEvidence(label: "Evidence", value: "ready for review", tint: .orange)
                        CompactEvidence(label: "Knowledge", value: "proposal only", tint: .secondary)
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

private struct QualityProgressStrip: View {
    private let stages = ["Discuss", "Plan", "Approve", "Implement", "Review", "Accept", "Knowledge"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                VStack(spacing: 6) {
                    Circle()
                        .fill(index < 4 ? Color.green : (index == 4 ? Color.orange : Color.secondary.opacity(0.4)))
                        .frame(width: 12, height: 12)
                    Text(stage)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(height: 1)
                        .padding(.bottom, 18)
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ThreadSummary: View {
    let fixture: Phase0Fixture
    let projection: ThreadProjection?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fixture.thread.workspaceKind.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current task")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(fixture.task.title)
                    .font(.headline)
                Text("Run state: \(projection?.taskState.displayName ?? "Unknown") · event cursor \(projection?.latestSequence ?? 0)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Prototype data")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ApprovalCard: View {
    let approval: Approval
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    approval.status == .pending ? "Approval required" : "Approval \(approval.status.displayName)",
                    systemImage: "checkmark.shield"
                )
                .font(.headline)
                Spacer()
                Text(approval.action.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.13), in: Capsule())
            }

            LabeledContent("Target", value: approval.target)
            LabeledContent("Consequence", value: approval.consequence)

            if showsDetail {
                Divider()
                LabeledContent("Data leaving this Mac", value: approval.action.egressDescription)
                LabeledContent("Alternative", value: approval.action.alternativeDescription)
                Text("This is a fixture: these controls never contact a provider, account, repository, or calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(showsDetail ? "Hide decision detail" : "Inspect decision detail") {
                showsDetail.toggle()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CodingEvidenceSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Coding quality loop")
                    .font(.headline)
                Spacer()
                Text("Provider completed ≠ accepted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                CompactEvidence(label: "Plan", value: "approved", tint: .green)
                CompactEvidence(label: "Diff", value: "proposed", tint: .blue)
                CompactEvidence(label: "Tests", value: "review", tint: .orange)
                CompactEvidence(label: "Knowledge", value: "not updated", tint: .secondary)
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CompactEvidence: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EventRow: View {
    let event: EventEnvelope

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbolName)
                .frame(width: 22)
                .foregroundStyle(event.kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kind.displayName)
                    .font(.body.weight(.medium))
                Text(event.origin.nativeType ?? event.kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("#\(event.sequence)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QueueCard: View {
    let queueItems: [QueueItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Offline queue", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                Text("Editable before dispatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(queueItems, id: \.id) { item in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(item.position)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(item.body)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct CodeReviewView: View {
    let fixture: Phase0Fixture
    @State private var selectedFileID = DiffFixture.files[0].id
    @State private var question = ""
    @State private var draftedQuestion: String?

    private var selectedFile: DiffFile {
        DiffFixture.files.first { $0.id == selectedFileID } ?? DiffFixture.files[0]
    }

    var body: some View {
        Group {
            if fixture.thread.workspaceKind != .coding {
                DomainUnavailableView(
                    title: "No diff in this context",
                    detail: "Code review appears only in a coding conversation. Email, calendar, research, and knowledge work retain their own evidence surfaces."
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review evidence")
                                .font(.title2.weight(.bold))
                            Text("Changed files, diff, checks, and a scoped agent follow-up stay in the same coding conversation.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KanameStatusBadge(
                            AttentionState.needsReview.legacyStatusPresentation,
                            density: .compact
                        )
                    }

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Changed files")
                                .font(.headline)
                            ForEach(DiffFixture.files) { file in
                                Button {
                                    selectedFileID = file.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.path)
                                            .font(.caption.monospaced())
                                            .lineLimit(2)
                                        Text(file.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedFileID == file.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 220, alignment: .leading)

                        ScrollView(.horizontal) {
                            SyntaxHighlightedDiff(file: selectedFile)
                                .padding(14)
                        }
                        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
                    }

                    ReviewEvidenceList()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ask an agent about this review")
                            .font(.headline)
                        HStack {
                            TextField("For example: explain this change or investigate a failing check", text: $question)
                            Button("Draft task") {
                                let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmedQuestion.isEmpty else { return }
                                draftedQuestion = trimmedQuestion
                                question = ""
                            }
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .textFieldStyle(.roundedBorder)
                        if let draftedQuestion {
                            Text("Drafted locally: \(draftedQuestion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct DiffFile: Identifiable {
    let id: String
    let path: String
    let language: String
    let summary: String
    let patch: String
}

private enum DiffFixture {
    static let files: [DiffFile] = [
        DiffFile(
            id: "search-contract",
            path: "Sources/KanameDomain/SearchContract.swift",
            language: "Swift",
            summary: "+21 −4 · bounded result contract",
            patch: """
            --- a/Sources/KanameDomain/SearchContract.swift
            +++ b/Sources/KanameDomain/SearchContract.swift
            @@
            - let maximumResults = 1_000
            + let maximumResults = policy.maximumResults
            + guard policy.maximumResults > 0 else {
            +     throw SearchError.invalidLimit
            + }
            + return SearchPage(items: items.prefix(policy.maximumResults))
            """
        ),
        DiffFile(
            id: "search-tests",
            path: "Tests/KanameDomainTests/SearchContractTests.swift",
            language: "Swift",
            summary: "+18 · limit and error coverage",
            patch: """
            --- a/Tests/KanameDomainTests/SearchContractTests.swift
            +++ b/Tests/KanameDomainTests/SearchContractTests.swift
            @@
            + @Test func rejectsZeroLimit() throws {
            +     #expect(throws: SearchError.invalidLimit) {
            +         try makePage(limit: 0)
            +     }
            + }
            """
        ),
    ]
}

private struct SyntaxHighlightedDiff: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(file.language) syntax", systemImage: "textformat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.accent)
                Spacer()
                Text("+ addition  − deletion")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            ForEach(Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(KanameColor.separator)
                        .frame(width: 24, alignment: .trailing)
                    syntaxText(for: String(line))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(lineBackground(for: String(line)), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(minWidth: 430, alignment: .leading)
    }

    private func lineBackground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return KanameColor.success.opacity(0.13)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return KanameColor.danger.opacity(0.13)
        }
        return .clear
    }

    private func syntaxText(for line: String) -> Text {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return Text(line).foregroundColor(KanameColor.accent)
        }

        let first = line.first.map(String.init) ?? ""
        let source = first == "+" || first == "-" ? String(line.dropFirst()) : line
        let prefixColor = first == "+" ? KanameColor.success : (first == "-" ? KanameColor.danger : KanameColor.textPrimary)
        return Text(first).foregroundColor(prefixColor) + swiftTokens(source, baseColor: KanameColor.textPrimary)
    }

    private func swiftTokens(_ source: String, baseColor: Color) -> Text {
        let keywords: Set<String> = ["let", "var", "guard", "else", "throw", "return", "func", "try", "struct", "enum"]
        let tokens = source.split(separator: " ", omittingEmptySubsequences: false)

        return tokens.enumerated().reduce(Text("")) { result, entry in
            let token = String(entry.element)
            let normalized = token.trimmingCharacters(in: .punctuationCharacters)
            let color: Color
            if keywords.contains(normalized) {
                color = KanameColor.blocked
            } else if token.contains("Search") || token.contains("Error") || token.contains("Page") {
                color = KanameColor.accent
            } else if token.contains("\"") || token.allSatisfy({ $0.isNumber || $0 == "_" }) {
                color = KanameColor.warning
            } else {
                color = baseColor
            }
            return result + Text(token).foregroundColor(color)
        }
    }
}

private struct ReviewEvidenceList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Checks and evidence")
                .font(.headline)
            ReviewEvidenceRow(name: "Swift unit tests", status: "passed", detail: "4 deterministic projection tests", tint: .green)
            ReviewEvidenceRow(name: "Generic iOS build", status: "passed", detail: "iOS 16 compile target", tint: .green)
            ReviewEvidenceRow(name: "Visual QA", status: "not run", detail: "requires review after a real UI change", tint: .secondary)
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ReviewEvidenceRow: View {
    let name: String
    let status: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(name)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct DomainUnavailableView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

private struct CodingQualityLoopView: View {
    let fixture: Phase0Fixture
    @State private var selectedStage: QualityStage = .review

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhaseBanner()
                Text("Evidence before acceptance")
                    .font(.largeTitle.weight(.bold))
                Text("This surface keeps the plan, implementation evidence, and knowledge update distinct so provider completion is never mistaken for accepted work.")
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(QualityStage.allCases) { stage in
                        QualityStageCard(
                            stage: stage,
                            isSelected: selectedStage == stage
                        ) {
                            selectedStage = stage
                        }
                    }
                }

                QualityStageDetail(stage: selectedStage, fixture: fixture)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum QualityStage: String, CaseIterable, Identifiable {
    case discuss
    case plan
    case approve
    case implement
    case review
    case accept
    case updateKnowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discuss: "Discuss"
        case .plan: "Plan"
        case .approve: "Approve"
        case .implement: "Implement"
        case .review: "Review evidence"
        case .accept: "Accept"
        case .updateKnowledge: "Update knowledge"
        }
    }

    var status: String {
        switch self {
        case .discuss: "captured"
        case .plan: "approved"
        case .approve: "recorded"
        case .implement: "simulated"
        case .review: "current gate"
        case .accept: "waiting"
        case .updateKnowledge: "proposed"
        }
    }

    var tint: Color {
        switch self {
        case .discuss, .plan, .approve: .green
        case .implement: .blue
        case .review: .orange
        case .accept: .purple
        case .updateKnowledge: .secondary
        }
    }

    var detail: String {
        switch self {
        case .discuss:
            "The requested search workflow is attached to the coding thread with an explicit repository scope."
        case .plan:
            "The plan identifies the intended change, its verification, and the separate knowledge-update proposal."
        case .approve:
            "A code-change approval records its target, consequence, and reversibility before any implementation begins."
        case .implement:
            "The fixture renders a provider trace only. It makes no repository, worktree, or provider change."
        case .review:
            "Review gathers the diff, tests, diagnostics, and any not-run boundaries. This is the current gate in the fixture."
        case .accept:
            "Justin accepts or rejects evidence. Provider completion alone cannot advance this step."
        case .updateKnowledge:
            "A Lode or Obsidian update is proposed as a reviewable change after acceptance, never silently written."
        }
    }
}

private struct QualityStageCard: View {
    let stage: QualityStage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(stage.title)
                    .font(.subheadline.weight(.semibold))
                Text(stage.status)
                    .font(.caption)
                    .foregroundStyle(stage.tint)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(
                isSelected ? stage.tint.opacity(0.16) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? stage.tint : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct QualityStageDetail: View {
    let stage: QualityStage
    let fixture: Phase0Fixture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(stage.title)
                    .font(.title2.weight(.bold))
                Spacer()
                Text(stage.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stage.tint)
            }
            Text(stage.detail)
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("Thread", value: fixture.thread.title)
            LabeledContent("Evidence source", value: "deterministic coding-review fixture")
            LabeledContent("Boundary", value: stage == .review ? "provider completed; user acceptance not recorded" : "prototype only")
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension Phase0Fixture {
    var conversationSummary: String {
        switch thread.workspaceKind {
        case .coding:
            "I’ve attached the plan, isolated-workspace boundary, and review evidence to this coding conversation. Open Work for the plan and Review for the proposed diff and checks."
        case .research:
            "I retained the provider-native streaming evidence and made the failure explicit. No conclusion has been accepted from this failed research run."
        case .email:
            "The draft is prepared, but sending remains a separate approval with its recipient scope and data egress visible."
        case .calendar:
            "The requested event change is ready for review. It remains pending until its consequence and alternatives are explicitly approved."
        case .knowledge:
            "The selected knowledge context is attached to this conversation and remains separate from unrelated projects and personal domains."
        }
    }
}

private extension EventKind {
    var displayName: String {
        switch self {
        case .taskQueued: "Task queued"
        case .runStarting: "Run starting"
        case .runStarted: "Run started"
        case .approvalRequested: "Approval requested"
        case .approvalApproved: "Approval approved"
        case .approvalRejected: "Approval rejected"
        case .providerCompleted: "Provider completed"
        case .workAccepted: "Work accepted"
        case .runFailed: "Run failed"
        case .runCancelled: "Run cancelled"
        case .runInterrupted: "Run interrupted"
        case .nativeProviderEvent: "Native provider event"
        }
    }

    var detail: String {
        switch self {
        case .taskQueued: "Intent is durable and waiting for a run."
        case .runStarting: "Provider session is starting."
        case .runStarted: "Provider execution is active."
        case .approvalRequested: "A scoped decision is required before the side effect."
        case .approvalApproved: "The approval was recorded; the run may continue."
        case .approvalRejected: "The requested side effect was declined."
        case .providerCompleted: "Provider returned a result; review evidence is still required."
        case .workAccepted: "Justin accepted the reviewed outcome."
        case .runFailed: "The run ended with an explicit failure state."
        case .runCancelled: "The run was cancelled before completion."
        case .runInterrupted: "The run was deliberately interrupted."
        case .nativeProviderEvent: "Raw provider semantics are retained alongside the normalized event."
        }
    }

    var symbolName: String {
        switch self {
        case .taskQueued: "clock"
        case .runStarting, .runStarted: "play.circle"
        case .approvalRequested: "checkmark.shield"
        case .approvalApproved: "checkmark.circle"
        case .approvalRejected: "xmark.circle"
        case .providerCompleted: "checkmark.seal"
        case .workAccepted: "checkmark.seal.fill"
        case .runFailed: "exclamationmark.triangle"
        case .runCancelled, .runInterrupted: "pause.circle"
        case .nativeProviderEvent: "wrench.and.screwdriver"
        }
    }

    var tint: Color {
        switch self {
        case .approvalRequested, .providerCompleted: KanameColor.warning
        case .runFailed, .approvalRejected: KanameColor.danger
        case .workAccepted, .approvalApproved: KanameColor.success
        case .runCancelled, .runInterrupted: KanameColor.blocked
        default: KanameColor.separator
        }
    }
}
