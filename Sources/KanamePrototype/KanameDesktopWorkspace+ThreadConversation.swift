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

enum DesktopConversationRuntimeSheetFocus {
    case full
    case model
}

struct DesktopThreadConversation: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var runtime: DesktopConversationRuntime
    let gitControl: DesktopGitControlService
    let capabilities: [ProviderCapabilitySnapshot]
    let thread: DesktopThread
    @Binding var selectedRunID: String?
    @Binding var conversationAnchorID: String?
    let composerFocusRequest: DesktopComposerFocusRequest?
    @State private var draft = ""
    @State private var composerSelection: TextSelection?
    @State private var composerCursorOffset: Int?
    @State private var composerHasSelection = false
    @State private var composerCommandSelection = DesktopComposerCommandSelectionState()
    @State private var composerCommandMenuDismissed = false
    @State private var composerSkillSelectionIndex = 0
    @State private var composerSkillMenuDismissed = false
    @State private var composerCommandKeyboardScrollRevision: UInt = 0
    @State private var attachments: [ConversationImageAttachment] = []
    @State private var attachmentError: String?
    @State private var isImportingAttachments = false
    @State private var questionAnswer = ""
    @State private var panel: DesktopThreadPanel = .conversation
    @State private var showsRename = false
    @State private var renamedTitle = ""
    @State private var showsRuntimeSettings = false
    @State private var runtimeSheetFocus = DesktopConversationRuntimeSheetFocus.full
    @State private var runtimeProvider = "Codex"
    @State private var runtimeModel = "Use provider default"
    @State private var runtimeReasoning = "xhigh"
    @State private var runtimeMode: ConversationRuntimeMode = .approvalRequired
    @State private var runtimeNetworkAccess = false
    @State private var narrativeRowLimit = DesktopConversationNarrativePresentation.defaultMaximumRows
    @State private var conversationSearch = ""
    @State private var showsCompactedHistory = false
    @State private var showsConversationSearch = false
    @State private var followsLatest = true
    @State private var hasNewNarrativeContent = false
    @FocusState private var composerFocused: Bool
    @FocusState private var conversationSearchFocused: Bool
#if os(macOS)
    @State private var sheetPreviousResponder: NSResponder?
    @State private var pasteMonitor: Any?
#endif

    init(
        model: DesktopAppModel,
        runtime: DesktopConversationRuntime,
        gitControl: DesktopGitControlService,
        capabilities: [ProviderCapabilitySnapshot],
        thread: DesktopThread,
        selectedRunID: Binding<String?>,
        conversationAnchorID: Binding<String?>,
        composerFocusRequest: DesktopComposerFocusRequest?
    ) {
        self.model = model
        self.runtime = runtime
        self.gitControl = gitControl
        self.capabilities = capabilities
        self.thread = thread
        _selectedRunID = selectedRunID
        _conversationAnchorID = conversationAnchorID
        self.composerFocusRequest = composerFocusRequest
        _draft = State(initialValue: model.composerDraft(threadID: thread.id))
        _attachments = State(initialValue: model.composerAttachments(threadID: thread.id))
        let requestedPanel = CommandLine.arguments.firstIndex(of: "--desktop-thread-panel")
            .flatMap { index in
                CommandLine.arguments.indices.contains(index + 1)
                    ? DesktopThreadPanel(rawValue: CommandLine.arguments[index + 1])
                    : nil
            }
            ?? .conversation
        _panel = State(initialValue: thread.kind == .coding || requestedPanel != .knowledge
            ? requestedPanel
            : .conversation)
    }

    var body: some View {
        let codingStage = runtime.codingStage(threadID: thread.id)
        VStack(spacing: 0) {
            threadHeader

            Divider()

            switch panel {
            case .conversation:
                conversation
            case .changes:
                DesktopThreadChangesView(
                    model: model,
                    thread: thread,
                    gitControl: gitControl,
                    isAwaitingReview: thread.kind == .coding && codingStage == .implementationReview,
                    beginReview: { runtime.beginImplementationReview(threadID: thread.id) }
                )
            case .terminal:
                DesktopCodingTerminalPanel(model: model, thread: thread)
            case .preview:
                DesktopCodingPreviewPanel(model: model, thread: thread)
            case .plan:
                ThreadPlanView(
                    items: thread.plan,
                    planBody: thread.planBody,
                    phase: codingStage.planPhase(hasSavedPlan: !thread.plan.isEmpty),
                    provider: thread.provider,
                    requestChanges: requestPlanChanges,
                    approvePlan: approvePlanAndImplement
                )
            case .evidence:
                ThreadEvidenceView(
                    items: thread.evidence,
                    findings: thread.findings ?? [],
                    isAwaitingReview: thread.kind == .coding && codingStage == .evidenceReview,
                    recheckEvidence: { runtime.recheckImplementation(threadID: thread.id) },
                    accept: { runtime.reviewImplementation(threadID: thread.id, accepted: true) },
                    reject: { runtime.reviewImplementation(threadID: thread.id, accepted: false) },
                    pullRequest: thread.kind == .coding && codingStage == .completed
                        ? .init(
                            status: runtime.pullRequestStatus(threadID: thread.id),
                            open: { runtime.openPullRequest(threadID: thread.id) }
                        )
                        : nil
                )
            case .knowledge:
                DesktopCodingKnowledgeLaneView(
                    model: model,
                    thread: thread,
                    draftKnowledge: { runtime.runKnowledgeTurn(threadID: thread.id) }
                )
                .id(thread.id)
            }
        }
        .sheet(isPresented: $showsRename, onDismiss: restoreSheetFocus) {
            DesktopRenameConversationSheet(
                title: $renamedTitle,
                cancel: { showsRename = false },
                save: {
                    if model.renameThread(id: thread.id, title: renamedTitle) { showsRename = false }
                }
            )
        }
        .sheet(isPresented: $showsRuntimeSettings, onDismiss: restoreSheetFocus) {
            DesktopConversationRuntimeSheet(
                provider: $runtimeProvider,
                model: $runtimeModel,
                reasoning: $runtimeReasoning,
                runtimeMode: $runtimeMode,
                networkAccess: $runtimeNetworkAccess,
                capabilities: capabilities,
                stagedCoding: thread.kind == .coding,
                initialFocus: runtimeSheetFocus,
                cancel: { showsRuntimeSettings = false },
                save: {
                    if model.updateThreadRuntime(
                        id: thread.id,
                        provider: runtimeProvider,
                        model: runtimeModel,
                        reasoningEffort: runtimeReasoning,
                        runtimeMode: runtimeMode,
                        networkAccess: runtimeNetworkAccess
                    ) { showsRuntimeSettings = false }
                }
            )
        }
        .onAppear {
            applyComposerFocusRequest()
#if os(macOS)
            installImagePasteMonitor()
#endif
        }
        .onDisappear {
            _ = model.flushComposerDrafts()
#if os(macOS)
            removeImagePasteMonitor()
#endif
        }
        .onChange(of: composerFocusRequest) { _ in applyComposerFocusRequest() }
        .onChange(of: composerFocused) { isFocused in
            if isFocused {
                composerCommandMenuDismissed = false
                reconcileComposerCommandSelection()
            }
        }
        .onChange(of: thread.id) { _, _ in
            panel = .conversation
            narrativeRowLimit = DesktopConversationNarrativePresentation.defaultMaximumRows
            conversationSearch = ""
            showsConversationSearch = false
            selectedRunID = nil
            conversationAnchorID = nil
            followsLatest = true
            hasNewNarrativeContent = false
            draft = model.composerDraft(threadID: thread.id)
            composerSelection = nil
            composerCursorOffset = nil
            composerHasSelection = false
            composerCommandSelection = DesktopComposerCommandSelectionState()
            composerCommandMenuDismissed = false
            attachments = model.composerAttachments(threadID: thread.id)
            attachmentError = nil
        }
        .onChange(of: runtime.codingStage(threadID: thread.id)) { _, stage in
            announceWorkflowAttentionIfNeeded(stage)
        }
        .onChange(of: runtime.titleGenerationErrors[thread.id]) { _, error in
            if let error { KanameAccessibilityAnnouncement.post(error) }
        }
    }

    private var threadHeader: some View {
        let stage = runtime.codingStage(threadID: thread.id)
        let workflow = DesktopCodingWorkflowPresentation(stage: stage)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("\(thread.title)\n\(thread.summary)")
                    .accessibilityLabel("\(thread.title). \(thread.summary)")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if thread.kind == .coding {
                    DesktopCodingWorkflowStatusControl(
                        stage: stage,
                        error: runtime.codingWorkflowErrors[thread.id],
                        openPanel: openPanel,
                        interrupt: runtime.isRunning(threadID: thread.id)
                            ? { runtime.interrupt(threadID: thread.id) }
                            : nil
                    )
                } else {
                    KanameStatusBadge(
                        KanameDesktopStatusPresentation.attention(thread.attention),
                        density: .compact
                    )
                }

                conversationSearchButton
                conversationActionsMenu
            }
            .padding(.horizontal, 18)
            .frame(height: 60)

            Divider()

            DesktopThreadTabBar(
                selection: $panel,
                panels: availablePanels,
                attentionPanel: thread.kind == .coding ? workflow.attentionPanel : nil
            )
            .frame(height: 42)
        }
        .background(KanameColor.surface)
    }

    private var conversationSearchButton: some View {
        Button {
            if panel == .conversation {
                showsConversationSearch.toggle()
            } else {
                panel = .conversation
                showsConversationSearch = true
            }
            if showsConversationSearch {
                DispatchQueue.main.async { conversationSearchFocused = true }
            } else {
                conversationSearch = ""
            }
        } label: {
            Image(systemName: showsConversationSearch ? "xmark" : "magnifyingglass")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(showsConversationSearch ? "Close conversation search" : "Search conversation")
        .accessibilityLabel(showsConversationSearch ? "Close conversation search" : "Search conversation")
    }

    private var conversationActionsMenu: some View {
        Menu {
            Button {
                if runtime.regenerateTitle(threadID: thread.id) {
                    KanameAccessibilityAnnouncement.post("Regenerating conversation title")
                }
            } label: {
                Label(
                    runtime.isGeneratingTitle(threadID: thread.id)
                        ? "Regenerating title…"
                        : "Regenerate title",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(!runtime.canRegenerateTitle(threadID: thread.id))
            Button("Rename conversation", systemImage: "pencil") {
                captureSheetFocus()
                renamedTitle = thread.title
                showsRename = true
            }
            Button("Runtime settings", systemImage: "slider.horizontal.3") {
                openRuntimeSettings()
            }
            .disabled(runtimeSettingsLocked)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Conversation actions")
        .accessibilityLabel("Conversation actions")
    }

    private func openPanel(_ destination: DesktopThreadPanel) {
        guard availablePanels.contains(destination) else { return }
        panel = destination
        KanameAccessibilityAnnouncement.post("\(destination.label) opened")
    }

    private func announceWorkflowAttentionIfNeeded(_ stage: DesktopCodingWorkflowStage) {
        guard thread.kind == .coding else { return }
        let presentation = DesktopCodingWorkflowPresentation(stage: stage)
        guard presentation.requiresAttention, let ownerPanel = presentation.ownerPanel else { return }
        KanameAccessibilityAnnouncement.post(
            "\(presentation.title). Open \(ownerPanel.label) when you are ready."
        )
    }

    private func requestPlanChanges() {
        panel = .conversation
        DispatchQueue.main.async { composerFocused = true }
        KanameAccessibilityAnnouncement.post("Chat opened. Describe the changes you want in the plan.")
    }

    private func approvePlanAndImplement() {
        panel = .plan
        runtime.approvePlanAndImplement(threadID: thread.id)
    }

    /// Messages shown in Chat. After a compaction only the messages sent since
    /// the cut are listed, unless the user asks for the earlier history.
    private var visibleMessages: [DesktopMessage] {
        guard let compaction = thread.compaction, !showsCompactedHistory, conversationSearch.isEmpty,
              let cut = thread.messages.firstIndex(where: { $0.id == compaction.throughMessageID }) else {
            return thread.messages
        }
        return Array(thread.messages[(cut + 1)...])
    }

    private var conversationByteCount: Int {
        thread.messages.reduce(0) { $0 + $1.body.utf8.count }
    }

    private var narrativePage: DesktopConversationNarrativePage {
        DesktopConversationNarrativePresentation.page(
            messages: visibleMessages,
            runs: model.providerRuns(threadID: thread.id),
            events: model.providerEvents(threadID: thread.id),
            maximumRows: narrativeRowLimit,
            searchText: conversationSearch
        )
    }

    private var narrative: [DesktopConversationNarrativeRow] { narrativePage.rows }

    /// Thread size and the compaction control. Compacting keeps every message
    /// but starts the provider on a fresh session seeded with a digest.
    @ViewBuilder
    private var conversationCompactionBar: some View {
        let kilobytes = max(1, conversationByteCount / 1_024)
        let isLarge = conversationByteCount > 48 * 1_024 || thread.messages.count > 40
        if let compaction = thread.compaction {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(KanameColor.accent)
                Text("Compacted \(compaction.messageCount) earlier messages. The provider continues from a digest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showsCompactedHistory ? "Hide earlier" : "Show earlier") {
                    showsCompactedHistory.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if thread.messages.count > compaction.messageCount + 6 {
                    Button("Compact again") { DesktopCompactionSummarizer.compact(model, threadID: thread.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(KanameColor.surface)
            Divider()
        } else if isLarge {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(KanameColor.warning)
                Text("Long thread: \(thread.messages.count) messages, about \(kilobytes) KB. Compact to keep the provider fast and focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Compact thread") { DesktopCompactionSummarizer.compact(model, threadID: thread.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Keeps every message, starts the provider on a fresh session seeded with a digest of the thread so far")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(KanameColor.surface)
            Divider()
        }
    }

    private var narrativeActivityCount: Int {
        thread.messages.reduce(0) { $0 + $1.body.utf8.count + 1 }
            + model.providerRuns(threadID: thread.id).count
            + model.providerRuns(threadID: thread.id).lazy.filter { $0.completedAtUnixMillis != nil }.count
            + model.providerEvents(threadID: thread.id).lazy.filter(\.kind.isNarrativeCritical).count
    }

    private var latestRecoverableRun: DesktopProviderRunRecord? {
        guard let latest = model.providerRuns(threadID: thread.id).last,
              latest.purpose != .codingImplementation,
              latest.state == .failed || latest.state == .interrupted else { return nil }
        return latest
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if showsConversationSearch {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find conversation or activity", text: $conversationSearch)
                        .font(.system(size: 14))
                        .textFieldStyle(.plain)
                        .focused($conversationSearchFocused)
                    if !conversationSearch.isEmpty {
                        Text("\(narrative.count) result\(narrative.count == 1 ? "" : "s")")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button {
                            conversationSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear conversation search")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(KanameColor.surface)

                Divider()
            }

            conversationCompactionBar

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if narrative.isEmpty {
                                EmptyPanel(
                                    symbol: conversationSearch.isEmpty ? "text.bubble" : "magnifyingglass",
                                    title: conversationSearch.isEmpty ? "Start the conversation" : "Nothing matches",
                                    detail: conversationSearch.isEmpty
                                        ? "Describe what you want to build or change. The plan takes shape as you talk."
                                        : "Search includes messages and the full recorded activity behind every run."
                                )
                            } else {
                                if narrativePage.hiddenOlderRowCount > 0 {
                                    Button("Show \(min(120, narrativePage.hiddenOlderRowCount)) older conversation items") {
                                        narrativeRowLimit += 120
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHint("Loads earlier conversation rows without expanding raw provider activity")
                                }
                                ForEach(narrative) { item in
                                    switch item {
                                    case let .message(message):
                                        DesktopMessageBubble(message: message, threadID: thread.id)
                                            .id(item.id)
                                    case let .criticalEvent(event):
                                        DesktopProviderEventCard(
                                            event: event,
                                            questionAnswer: $questionAnswer,
                                            answer: { answerQuestion(event) }
                                        )
                                        .id(item.id)
                                    case let .runSummary(summary):
                                        DesktopConversationRunCapsule(
                                            summary: summary,
                                            inspect: {
                                                selectedRunID = summary.id
                                            }
                                        )
                                        .id(item.id)
                                    }
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("narrative-bottom")
                                .onAppear {
                                    followsLatest = true
                                    hasNewNarrativeContent = false
                                }
                                .onDisappear { followsLatest = false }
                        }
                        .padding(22)
                    }
                    .defaultScrollAnchor(.bottom)

                    if hasNewNarrativeContent {
                        Button {
                            proxy.scrollTo("narrative-bottom", anchor: .bottom)
                            followsLatest = true
                            hasNewNarrativeContent = false
                        } label: {
                            Label("New response", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(16)
                        .shadow(radius: 8)
                    }
                }
                .onChange(of: narrativeActivityCount) { _ in
                    if followsLatest {
                        proxy.scrollTo("narrative-bottom", anchor: .bottom)
                    } else {
                        hasNewNarrativeContent = true
                    }
                }
                .onChange(of: conversationSearch) { _ in
                    if followsLatest { proxy.scrollTo("narrative-bottom", anchor: .bottom) }
                }
                .onChange(of: conversationAnchorID) { anchorID in
                    guard let anchorID else { return }
                    panel = .conversation
                    proxy.scrollTo("message-\(anchorID)", anchor: .center)
                    followsLatest = false
                    hasNewNarrativeContent = false
                    conversationAnchorID = nil
                }
                .onAppear {
                    followsLatest = true
                    DispatchQueue.main.async {
                        proxy.scrollTo("narrative-bottom", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if followsLatest { proxy.scrollTo("narrative-bottom", anchor: .bottom) }
                    }
                }
            }

            if let run = latestRecoverableRun,
               model.nextQueuedProviderRun(threadID: thread.id) == nil,
               !runtime.isRunning(threadID: thread.id) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(KanameColor.external)
                    Text(run.errorSummary ?? "This turn stopped before completion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry turn") { runtime.retry(runID: run.id) }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .frame(maxWidth: DesktopComposerPresentation.maximumWidth)
            }
            if let run = model.providerRuns(threadID: thread.id).last(where: { $0.state == .running }) {
                DesktopConversationActivityStrip(
                    run: run,
                    events: model.providerEvents(threadID: thread.id).filter { $0.runID == run.id },
                    stop: { runtime.interrupt(threadID: thread.id) }
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .frame(maxWidth: DesktopComposerPresentation.maximumWidth)
            }
            composerDock
        }
    }

    private var composerDock: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                DesktopComposerImageThumbnail(
                                    threadID: thread.id,
                                    attachment: attachment,
                                    remove: { removeAttachment(attachment) }
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                    }
                    .frame(height: 74)
                }

                if let attachmentError {
                    Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(KanameColor.danger)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let commandQuery = composerCommandQuery {
                    DesktopComposerCommandDrawer(
                        query: commandQuery.fragment,
                        commands: filteredComposerCommands,
                        selectedCommandID: selectedComposerCommand?.id,
                        keyboardScrollRevision: composerCommandKeyboardScrollRevision,
                        select: selectComposerCommand,
                        activate: activateComposerCommand
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                } else if let skillQuery = composerSkillQuery {
                    DesktopComposerSkillDrawer(
                        query: skillQuery.fragment,
                        skills: filteredComposerSkills,
                        selectedIndex: composerSkillSelectionIndex,
                        select: { composerSkillSelectionIndex = $0 },
                        activate: activateComposerSkill
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }

                TextField(
                    "Message \(thread.provider)",
                    text: $draft,
                    selection: $composerSelection,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: DesktopComposerPresentation.inputPointSize))
                    .lineLimit(DesktopComposerPresentation.minimumLines...DesktopComposerPresentation.maximumLines)
                    .padding(.horizontal, DesktopComposerPresentation.inputHorizontalPadding)
                    .padding(.top, DesktopComposerPresentation.inputTopPadding)
                    .padding(.bottom, DesktopComposerPresentation.inputBottomPadding)
                    .focused($composerFocused)
                    .disabled(!canSendMessage)
                    .onKeyPress(.return, phases: .down, action: handleComposerReturn)
                    .onChange(of: draft) { body in
                        composerCommandMenuDismissed = false
                        composerSkillMenuDismissed = false
                        composerCursorOffset = min(composerCursorOffset ?? body.count, body.count)
                        model.updateComposerDraft(threadID: thread.id, body: body)
                    }
                    .onChange(of: composerSelection) { _ in
                        composerCommandMenuDismissed = false
                        composerSkillMenuDismissed = false
                        updateComposerSelectionState()
                        reconcileComposerCommandSelection()
                        reconcileComposerSkillSelection()
                    }
                    .accessibilityLabel("Message composer for \(thread.title)")
                    .accessibilityHint("Return sends. Shift-Return inserts a new line.")
                    .accessibilityIdentifier("thread-composer")

                GeometryReader { geometry in
                    composerAccessoryRow(
                        compact: Double(geometry.size.width)
                            < DesktopComposerRuntimePresentation.compactWidthThreshold
                    )
                }
                .frame(height: 32)
                .padding(.leading, 9)
                .padding(.trailing, 9)
                .padding(.bottom, 9)
            }
            .background(
                KanameColor.surface,
                in: RoundedRectangle(cornerRadius: DesktopComposerPresentation.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesktopComposerPresentation.cornerRadius, style: .continuous)
                    .strokeBorder(conversationAccent.opacity(thread.kind == .coding ? 0.58 : 0.32), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
#if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                importImageURLs(urls)
            }
            .background {
                DesktopLocalKeyMonitor(handle: handleComposerCommandKey)
                    .frame(width: 0, height: 0)
            }
#endif

            composerContextShelf
        }
        .frame(maxWidth: DesktopComposerPresentation.maximumWidth)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity)
        .background(KanameColor.canvas)
        .onChange(of: runtime.isRunning(threadID: thread.id)) { isRunning in
            KanameAccessibilityAnnouncement.post(
                isRunning ? "\(thread.provider) is responding" : "\(thread.provider) finished responding"
            )
        }
    }

    private var composerContextShelf: some View {
        HStack(spacing: 6) {
            ForEach(Array(composerContextLabels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Circle()
                        .fill(Color.secondary.opacity(0.65))
                        .frame(width: 3, height: 3)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: DesktopComposerPresentation.contextPointSize, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context: \(composerContextLabels.joined(separator: ", "))")
    }

    private func applyComposerFocusRequest() {
        guard composerFocusRequest?.threadID == thread.id else { return }
        panel = .conversation
        DispatchQueue.main.async { composerFocused = true }
    }

    private func captureSheetFocus() {
#if os(macOS)
        sheetPreviousResponder = currentDesktopResponder()
#endif
    }

    private func restoreSheetFocus() {
#if os(macOS)
        let responder = sheetPreviousResponder
        sheetPreviousResponder = nil
        restoreDesktopResponder(responder)
#endif
    }

    private var runtimeSettingsLocked: Bool {
        runtime.isRunning(threadID: thread.id)
            || runtime.codingWorkflowBusyThreadIDs.contains(thread.id)
    }

    private var composerCommands: [DesktopComposerCommand] {
        DesktopComposerCommands.catalog { command in
            guard runtimeSettingsLocked, command == .model || command == .runtime else { return nil }
            return "Runtime settings are locked while work is active."
        }
    }

    private var composerCommandQuery: DesktopComposerCommandQuery? {
        guard composerFocused, !composerCommandMenuDismissed, composerSkillQuery == nil else { return nil }
        return DesktopComposerCommands.query(
            in: draft,
            cursorOffset: composerCursorOffset ?? draft.count,
            hasSelection: composerHasSelection
        )
    }

    private var composerSkills: [DesktopComposerSkill] {
        let project = model.project(id: thread.projectID)
        let workspaceRoot = project?.path.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        return DesktopComposerSkillPicker.skills(
            SkillRegistryLoader.loadRegistry(workspaceRoot: workspaceRoot).map {
                ($0.name, $0.description, $0.path)
            }
        )
    }

    private var composerSkillQuery: DesktopComposerSkillQuery? {
        guard composerFocused, !composerSkillMenuDismissed else { return nil }
        return DesktopComposerSkillPicker.query(
            in: draft,
            cursorOffset: composerCursorOffset ?? draft.count,
            hasSelection: composerHasSelection
        )
    }

    private var filteredComposerSkills: [DesktopComposerSkill] {
        guard let composerSkillQuery else { return [] }
        return DesktopComposerSkillPicker.matching(composerSkillQuery, in: composerSkills)
    }

    private var filteredComposerCommands: [DesktopComposerCommand] {
        guard let composerCommandQuery else { return [] }
        return DesktopComposerCommands.matching(composerCommandQuery, in: composerCommands)
    }

    private var selectedComposerCommand: DesktopComposerCommand? {
        composerCommandSelection.command(in: filteredComposerCommands) ?? filteredComposerCommands.first
    }

    private func updateComposerSelectionState() {
        guard let composerSelection else {
            composerCursorOffset = draft.count
            composerHasSelection = false
            return
        }
        switch composerSelection.indices {
        case let .selection(range):
            let projection = DesktopComposerSelectionProjection.project(
                range,
                in: draft,
                fallbackCursorOffset: composerCursorOffset
            )
            composerCursorOffset = projection.cursorOffset
            composerHasSelection = projection.hasSelection
            if projection.recoveredStaleSelection {
                KanameDevelopmentRuntimeLogger.shared.record(
                    .composerSelectionRecovered,
                    measurements: [
                        .draftCharacterCount: draft.count,
                        .fallbackCursorOffset: projection.cursorOffset,
                    ]
                )
            }
        case .multiSelection:
            composerCursorOffset = nil
            composerHasSelection = true
        @unknown default:
            composerCursorOffset = nil
            composerHasSelection = true
        }
    }

    private func reconcileComposerCommandSelection() {
        composerCommandSelection.reconcile(with: filteredComposerCommands)
    }

    private func reconcileComposerSkillSelection() {
        guard !filteredComposerSkills.isEmpty else {
            composerSkillSelectionIndex = 0
            return
        }
        composerSkillSelectionIndex = min(composerSkillSelectionIndex, filteredComposerSkills.count - 1)
    }

    private func activateComposerSkill(_ skill: DesktopComposerSkill) {
        guard let query = composerSkillQuery,
              let edit = DesktopComposerSkillPicker.consuming(query, selectedSkill: skill, from: draft) else { return }
        draft = edit.text
        composerCursorOffset = edit.insertionOffset
        composerSkillMenuDismissed = true
        composerSkillSelectionIndex = 0
        model.updateComposerDraft(threadID: thread.id, body: draft)
    }

    private func attachTerminalExcerpt(_ terminal: DesktopCodingTerminalRecord) {
        guard terminal.threadID == thread.id else { return }
        let service = DesktopCodingTerminalService.shared
        let key = DesktopCodingTerminalKey(threadID: thread.id, terminalID: terminal.id)
        _Concurrency.Task {
            guard let source = await service.attachContextSource(key: key, from: terminal) else { return }
            let attachment = """

            --- Terminal excerpt (\(terminal.id), digest \(terminal.scrollbackDigest)) ---
            \(source.excerpt)
            """
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? attachment.trimmingCharacters(in: .newlines)
                : draft + attachment
            model.updateComposerDraft(threadID: thread.id, body: draft)
        }
    }

#if os(macOS)
    private func handleComposerSkillKey(_ event: NSEvent) -> Bool {
        let commandModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard commandModifiers.isEmpty else { return false }
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText() {
            return false
        }

        switch event.keyCode {
        case 125:
            guard !filteredComposerSkills.isEmpty else { return false }
            composerSkillSelectionIndex = (composerSkillSelectionIndex + 1) % filteredComposerSkills.count
            return true
        case 126:
            guard !filteredComposerSkills.isEmpty else { return false }
            composerSkillSelectionIndex = composerSkillSelectionIndex == 0
                ? filteredComposerSkills.count - 1
                : composerSkillSelectionIndex - 1
            return true
        case 48:
            guard filteredComposerSkills.indices.contains(composerSkillSelectionIndex) else { return false }
            activateComposerSkill(filteredComposerSkills[composerSkillSelectionIndex])
            return true
        case 53:
            composerSkillMenuDismissed = true
            composerSkillSelectionIndex = 0
            return true
        default:
            return false
        }
    }
#endif

    private func selectComposerCommand(_ commandID: DesktopComposerCommandID) {
        composerCommandSelection = DesktopComposerCommandSelectionState(selectedCommandID: commandID)
    }

    private func handleComposerReturn(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers
#if os(macOS)
        let responder = currentDesktopResponder()
        let hasMarkedText = (responder as? NSTextInputClient)?.hasMarkedText() == true
#else
        let hasMarkedText = false
#endif
        let disposition = DesktopComposerReturnPolicy.disposition(
            shift: modifiers.contains(.shift),
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            hasMarkedText: hasMarkedText
        )
        switch disposition {
        case .submit:
            submitComposer()
            return .handled
        case .insertNewline:
#if os(macOS)
            guard let editor = responder as? NSTextView else {
                return .handled
            }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return .handled
#else
            return .ignored
#endif
        case .nativeEditing:
            return .ignored
        }
    }

#if os(macOS)
    private func handleComposerCommandKey(_ event: NSEvent) -> Bool {
        if composerSkillQuery != nil {
            return handleComposerSkillKey(event)
        }
        guard composerCommandQuery != nil else { return false }
        let commandModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard commandModifiers.isEmpty else { return false }
        if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText() {
            return false
        }

        switch event.keyCode {
        case 125:
            return moveComposerCommandSelection(.next)
        case 126:
            return moveComposerCommandSelection(.previous)
        case 48:
            return activateSelectedComposerCommand()
        case 53:
            composerCommandMenuDismissed = true
            composerCommandSelection = DesktopComposerCommandSelectionState()
            KanameAccessibilityAnnouncement.post("Command menu dismissed")
            return true
        default:
            return false
        }
    }
#endif

    private func moveComposerCommandSelection(
        _ direction: DesktopComposerCommandSelectionDirection
    ) -> Bool {
        guard !filteredComposerCommands.isEmpty else { return false }
        composerCommandSelection.reconcile(with: filteredComposerCommands)
        composerCommandSelection.move(direction, in: filteredComposerCommands)
        composerCommandKeyboardScrollRevision &+= 1
        announceSelectedComposerCommand()
        return true
    }

    private func announceSelectedComposerCommand() {
        guard let selectedComposerCommand else { return }
        let state = selectedComposerCommand.disabledReason.map { "Unavailable. \($0)" } ?? "Selected"
        KanameAccessibilityAnnouncement.post("\(selectedComposerCommand.invocation), \(state)")
    }

    private func submitComposer() {
        guard !activateSelectedComposerCommand() else { return }
        sendMessage()
    }

    @discardableResult
    private func activateSelectedComposerCommand() -> Bool {
        guard let composerCommandQuery else { return false }
        let resolution = DesktopComposerCommands.resolveSubmission(
            text: draft,
            query: composerCommandQuery,
            selectedCommandID: selectedComposerCommand?.id,
            commands: composerCommands
        )
        switch resolution {
        case let .local(command, edit):
            applyComposerCommandEdit(edit)
            performComposerCommand(command)
            return true
        case let .disabled(_, reason):
            KanameAccessibilityAnnouncement.post(reason)
            return true
        case .message:
            return false
        }
    }

    private func activateComposerCommand(_ commandID: DesktopComposerCommandID) {
        selectComposerCommand(commandID)
        guard let composerCommandQuery else { return }
        let resolution = DesktopComposerCommands.resolveSubmission(
            text: draft,
            query: composerCommandQuery,
            selectedCommandID: commandID,
            commands: composerCommands
        )
        switch resolution {
        case let .local(command, edit):
            applyComposerCommandEdit(edit)
            performComposerCommand(command)
        case let .disabled(_, reason):
            KanameAccessibilityAnnouncement.post(reason)
        case .message:
            break
        }
    }

    private func applyComposerCommandEdit(_ edit: DesktopComposerCommandEdit) {
        draft = edit.text
        let insertionOffset = min(max(edit.insertionOffset, 0), draft.count)
        let insertionPoint = draft.index(draft.startIndex, offsetBy: insertionOffset)
        composerSelection = TextSelection(insertionPoint: insertionPoint)
        composerCursorOffset = insertionOffset
        composerHasSelection = false
        composerCommandSelection = DesktopComposerCommandSelectionState()
        model.updateComposerDraft(threadID: thread.id, body: draft)
    }

    private func performComposerCommand(_ command: DesktopComposerCommandID) {
        switch command {
        case .model:
            openRuntimeSettings(focus: .model)
        case .runtime:
            openRuntimeSettings(focus: .full)
        case .chat:
            panel = .conversation
            DispatchQueue.main.async { composerFocused = true }
        case .diff:
            panel = .changes
        case .plan:
            panel = .plan
        case .checks:
            panel = .evidence
        case .rename:
            captureSheetFocus()
            renamedTitle = thread.title
            showsRename = true
        }
        KanameAccessibilityAnnouncement.post("\(command.title) opened")
    }

    private func openRuntimeSettings(focus: DesktopConversationRuntimeSheetFocus = .full) {
        captureSheetFocus()
        runtimeSheetFocus = focus
        runtimeProvider = thread.provider
        runtimeModel = thread.model
        runtimeReasoning = thread.reasoningEffort
        runtimeMode = thread.runtimeMode
        runtimeNetworkAccess = thread.networkAccess
        showsRuntimeSettings = true
    }

    private func updateRuntime(
        provider: String,
        runtimeModel: String,
        reasoning: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) {
        _ = model.updateThreadRuntime(
            id: thread.id,
            provider: provider,
            model: runtimeModel,
            reasoningEffort: reasoning,
            runtimeMode: runtimeMode,
            networkAccess: networkAccess
        )
    }

    private func composerAccessoryRow(compact: Bool) -> some View {
        HStack(spacing: 5) {
#if os(macOS)
            Button("Attach images", systemImage: "plus", action: chooseImages)
                .labelStyle(.iconOnly)
                .font(.system(size: DesktopComposerPresentation.toolbarPointSize, weight: .semibold))
                .frame(width: 26, height: 26)
                .buttonStyle(.plain)
                .disabled(
                    !imageAttachmentsSupported
                        || isImportingAttachments
                        || attachments.count >= ConversationImageAttachment.maximumCountPerMessage
                )
                .help(
                    imageAttachmentsSupported
                        ? "Attach images, or paste with Command-V"
                        : "Choose Codex, Claude, or OpenCode to attach images"
                )
                .accessibilityLabel("Attach images")
#endif

            DesktopComposerRuntimeControls(
                thread: thread,
                capabilities: capabilities,
                isLocked: runtimeSettingsLocked,
                compact: compact,
                editDetails: { openRuntimeSettings() },
                update: updateRuntime
            )

            if thread.kind == .coding,
               let attachableTerminal = model.snapshot.operations.codingTerminals.first(where: {
                   $0.threadID == thread.id && $0.hasAttachableExcerpt
               }) {
                Button("Attach terminal", systemImage: "terminal") {
                    attachTerminalExcerpt(attachableTerminal)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Insert bounded terminal excerpt as untrusted context")
            }

            Spacer(minLength: 8)

            if isImportingAttachments {
                ProgressView()
                    .controlSize(.small)
                    .help("Preparing image attachments")
                    .accessibilityLabel("Preparing image attachments")
            }

            if runtime.isRunning(threadID: thread.id), composerPrimaryAction.kind != .stop {
                ProgressView()
                    .controlSize(.small)
                    .help("\(thread.provider) is responding. New messages queue in order.")
                    .accessibilityLabel("\(thread.provider) is responding; new messages queue in order")
            }

            if composerPrimaryAction.kind == .queue {
                Button {
                    runtime.interrupt(threadID: thread.id)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(.plain)
                .foregroundStyle(KanameColor.danger)
                .help("Stop the current turn")
                .accessibilityLabel("Stop current turn")
            }

            Button(action: performComposerPrimaryAction) {
                ViewThatFits(in: .horizontal) {
                    Label(composerPrimaryAction.title, systemImage: composerPrimaryAction.systemImage)
                    Image(systemName: composerPrimaryAction.systemImage)
                }
                .font(.system(size: DesktopComposerPresentation.toolbarPointSize, weight: .semibold))
                .padding(.horizontal, compact ? 8 : 10)
                .frame(minWidth: 30, minHeight: 29)
                .foregroundStyle(composerPrimaryAction.isEnabled ? KanameColor.canvas : Color.secondary)
                .background(
                    composerPrimaryAction.isEnabled
                        ? (composerPrimaryAction.kind == .stop ? KanameColor.danger : conversationAccent)
                        : KanameColor.raised,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(!composerPrimaryAction.isEnabled)
            .help(composerSubmissionAccessibilityLabel)
            .accessibilityLabel(composerSubmissionAccessibilityLabel)
            .accessibilityIdentifier("thread-composer-primary-action")
        }
    }

    private var composerPrimaryAction: DesktopComposerPrimaryAction {
        DesktopComposerPresentation.primaryAction(
            isRunning: runtime.isRunning(threadID: thread.id),
            hasSendableContent: hasSendableContent,
            canSend: canSendMessage,
            isImportingAttachments: isImportingAttachments,
            selectedCommandIsEnabled: selectedComposerCommand.map { $0.disabledReason == nil }
        )
    }

    private func performComposerPrimaryAction() {
        if composerPrimaryAction.kind == .stop {
            runtime.interrupt(threadID: thread.id)
        } else {
            submitComposer()
        }
    }

    private var canSendMessage: Bool {
        guard thread.kind == .coding else { return true }
        return ![.planning, .preparing, .implementing].contains(runtime.codingStage(threadID: thread.id))
    }

    private var availablePanels: [DesktopThreadPanel] {
        DesktopThreadPanel.available(forCodingThread: thread.kind == .coding)
    }

    private var latestCodingWorktree: DesktopWorktreeRecord? {
        model.snapshot.operations.worktrees
            .filter { $0.threadID == thread.id && $0.state != .removed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    private var codingStage: DesktopCodingWorkflowStage? {
        thread.kind == .coding ? runtime.codingStage(threadID: thread.id) : nil
    }

    private var conversationAccent: Color {
        codingStage?.tint ?? KanameColor.accent
    }

    private var composerContextLabels: [String] {
        var labels = [model.project(id: thread.projectID)?.name ?? "No project"]
        if let worktree = latestCodingWorktree {
            labels.append("isolated worktree")
            labels.append(worktree.branch)
        } else if thread.kind == .coding {
            labels.append("plan first")
            labels.append("network off")
        } else {
            labels.append(thread.kind.label)
            labels.append(DesktopComposerRuntimePresentation.access(thread.runtimeMode).title)
        }
        return labels
    }

    private var hasSendableContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var imageAttachmentsSupported: Bool {
        DesktopConversationRuntime.supportsImageAttachments(provider: thread.provider)
    }

    private var composerSubmissionAccessibilityLabel: String {
        if let selectedComposerCommand {
            return selectedComposerCommand.disabledReason == nil
                ? "Run \(selectedComposerCommand.invocation) command"
                : "\(selectedComposerCommand.invocation) command unavailable"
        }
        return switch composerPrimaryAction.kind {
        case .send: "Send message"
        case .queue: "Queue follow-up"
        case .stop: "Stop current turn"
        case .run: "Run composer command"
        }
    }

    private func sendMessage() {
        let body = draft
        if canSendMessage,
           hasSendableContent,
           runtime.send(threadID: thread.id, body: body, attachments: attachments) {
            draft = ""
            attachments = []
            attachmentError = nil
            model.clearComposerDraft(threadID: thread.id)
        }
    }

    private func answerQuestion(_ event: DesktopProviderEventRecord) {
        runtime.answerQuestion(
            threadID: thread.id,
            event: event,
            answer: questionAnswer
        )
        questionAnswer = ""
    }

    private var attachmentStore: KanameConversationAttachmentStore {
        KanameConversationAttachmentStore(
            rootDirectory: KanameDesktopEnvironment.current.applicationSupportRoot
                .appending(path: "ConversationService", directoryHint: .isDirectory)
        )
    }

    private func removeAttachment(_ attachment: ConversationImageAttachment) {
        try? attachmentStore.remove(threadID: thread.id, attachment: attachment)
        _ = model.removeComposerAttachment(threadID: thread.id, attachmentID: attachment.id)
        attachments = model.composerAttachments(threadID: thread.id)
        attachmentError = nil
    }

#if os(macOS)
    private func chooseImages() {
        guard imageAttachmentsSupported, !isImportingAttachments else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach images"
        panel.message = "Images are copied into Kaname's private conversation storage and sent only with this message."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        _ = importImageURLs(panel.urls)
    }

    @discardableResult
    private func importImageURLs(_ urls: [URL]) -> Bool {
        guard imageAttachmentsSupported, !isImportingAttachments else { return false }
        let remaining = ConversationImageAttachment.maximumCountPerMessage - attachments.count
        let candidates = Array(urls.filter(Self.isImageURL).prefix(max(0, remaining)))
        guard !candidates.isEmpty else {
            attachmentError = remaining == 0 ? "A message can contain up to eight images." : "Choose a readable image file."
            return false
        }
        beginImageImport(candidates.map { ($0, nil, $0.lastPathComponent) })
        return true
    }

    private func importClipboardImage(_ data: Data, filename: String) {
        beginImageImport([(nil, data, filename)])
    }

    private func beginImageImport(_ inputs: [(URL?, Data?, String)]) {
        guard !inputs.isEmpty else { return }
        isImportingAttachments = true
        attachmentError = nil
        let store = attachmentStore
        let threadID = thread.id
        _Concurrency.Task {
            let results = await _Concurrency.Task.detached(priority: .userInitiated) {
                inputs.map { url, suppliedData, filename -> (ConversationImageAttachment?, String?) in
                    let accessed = url?.startAccessingSecurityScopedResource() ?? false
                    defer { if accessed { url?.stopAccessingSecurityScopedResource() } }
                    do {
                        let data: Data
                        if let suppliedData {
                            data = suppliedData
                        } else if let url {
                            data = try Data(contentsOf: url, options: .mappedIfSafe)
                        } else {
                            throw KanameConversationAttachmentError.invalidImage
                        }
                        return (try store.importImage(data: data, suggestedFilename: filename, threadID: threadID), nil)
                    } catch {
                        return (nil, error.localizedDescription)
                    }
                }
            }.value
            for result in results {
                if let attachment = result.0 {
                    if !model.addComposerAttachment(threadID: threadID, attachment: attachment) {
                        try? store.remove(threadID: threadID, attachment: attachment)
                        attachmentError = "Kaname could not save that attachment in the draft."
                    }
                } else if let error = result.1 {
                    attachmentError = error
                }
            }
            attachments = model.composerAttachments(threadID: threadID)
            isImportingAttachments = false
        }
    }

    private func installImagePasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard composerFocused,
                  modifiers.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return handleImagePasteboard() ? nil : event
        }
    }

    private func removeImagePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    private func handleImagePasteboard() -> Bool {
        guard imageAttachmentsSupported, !isImportingAttachments else { return false }
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).filter(Self.isImageURL)
        if !urls.isEmpty { return importImageURLs(urls) }
        guard let image = NSImage(pasteboard: pasteboard), let data = image.tiffRepresentation else { return false }
        importClipboardImage(data, filename: "Pasted image.png")
        return true
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
#endif

}
