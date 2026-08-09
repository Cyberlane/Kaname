import Foundation
import SwiftUI
import KanameConnectivity
import KanameDomain
import KanameLocalCore
import KanamePrototypeUI
#if os(macOS)
import AppKit
#endif

@MainActor
private final class CodexLiveWorkspaceModel: ObservableObject {
    enum State: Equatable {
        case idle
        case inspecting
        case ready
        case planning
        case planReady
        case authorizing
        case implementing
        case interrupted
        case reviewing
        case accepted
        case rejected
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Select worktree"
            case .inspecting: "Inspecting"
            case .ready: "Ready to plan"
            case .planning: "Planning"
            case .planReady: "Plan needs approval"
            case .authorizing: "Recording approval"
            case .implementing: "Implementing"
            case .interrupted: "Interrupted"
            case .reviewing: "Review evidence"
            case .accepted: "Accepted"
            case .rejected: "Rejected"
            case .failed: "Stopped safely"
            }
        }
    }

    @Published var worktreePath = ""
    @Published var task = "Add one focused regression test for the approved Kaname coding workflow, keep the change isolated, and run the relevant verification."
    @Published var searchQuery = "CodexLiveSession"
    @Published var obsidianNotePath = "Projects/Coding ADE/Overview.md"
    @Published var questionAnswer = ""
    @Published var knowledgeUpdateProposal = "Record the accepted coding result, exact evidence, and remaining boundaries in the Kaname Phase 2 closure note."
    @Published var selectedContextIDs: Set<String> = []
    @Published var selectedSearchIDs: Set<String> = []
    @Published private(set) var state: State = .idle
    @Published private(set) var snapshot: CodingWorkspaceSnapshot?
    @Published private(set) var events: [CodexRunEvent] = []
    @Published private(set) var receipts: [LocalCoreEventAppendReport] = []
    @Published private(set) var planText = ""
    @Published private(set) var evidence: CodingEvidenceSnapshot?
    @Published private(set) var reviewStorePosition: UInt64?

    private let projectID = "kaname"
    private let threadID = KanameID()
    private var session: CodexLiveSession?
    private var eventTask: _Concurrency.Task<Void, Never>?
    private var runner: LocalCoreRunner?
    private var implementationPrompt = ""

    deinit { eventTask?.cancel() }

    var selectedSources: [CodingContextSource] {
        snapshot?.contextSources.filter { selectedContextIDs.contains($0.id) } ?? []
    }

    var selectedMatches: [LocalSearchMatch] {
        snapshot?.searchMatches.filter { selectedSearchIDs.contains($0.id) } ?? []
    }

    var pendingQuestion: CodexRunEvent? {
        events.last { $0.kind == .questionRequested && $0.approvalID != nil }
    }

    func inspect() {
        guard state != .planning && state != .implementing && state != .authorizing else { return }
        state = .inspecting
        let workspace = URL(fileURLWithPath: worktreePath)
        _Concurrency.Task {
            do {
                let inspected = try await CodingWorkspaceInspector.inspect(
                    workspaceURL: workspace,
                    searchQuery: searchQuery,
                    obsidianNotePath: obsidianNotePath
                )
                guard inspected.isIsolatedWorktree else {
                    throw CodingWorkspaceInspectorError.notIsolatedWorktree
                }
                snapshot = inspected
                selectedContextIDs = Set(inspected.contextSources.map(\.id))
                selectedSearchIDs = Set(inspected.searchMatches.prefix(8).map(\.id))
                evidence = nil
                planText = ""
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
                await closeSession()
            }
        }
    }

    func startPlanning() {
        guard state == .ready, let snapshot else { return }
        guard let runner = LocalCoreRunner.bundled() else {
            state = .failed("The signed local journal service is unavailable, so Kaname did not start Codex.")
            return
        }
        let providerPrompt = CodingWorkspaceInspector.providerPrompt(
            task: "Propose a concise implementation plan only. Do not change files, run commands, use tools, or access the network.\n\n\(task)",
            selectedSources: selectedSources,
            selectedMatches: selectedMatches,
            mode: "discussion-and-plan"
        )
        resetSessionState()
        self.runner = runner
        state = .planning
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        let session = CodexLiveSession(configuration: .init(instance: instance, workspaceURL: snapshot.root))
        let recorder = CodexJournalRecorder(
            runner: runner,
            context: CodexJournalContext(
                projectID: KanameID(rawValue: projectID),
                threadID: threadID,
                runID: KanameID(),
                providerInstance: instance
            )
        )
        self.session = session
        _Concurrency.Task {
            let stream = await session.events()
            eventTask = _Concurrency.Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    do {
                        let receipt = try await recorder.record(event)
                        events.append(event)
                        receipts.append(receipt)
                        handle(event)
                    } catch {
                        state = .failed("The local journal rejected a provider observation. The run was stopped without accepting a result.")
                        await closeSession()
                        return
                    }
                }
            }
            do {
                _ = try await session.start(CodexCodingRequest(prompt: providerPrompt))
            } catch {
                state = .failed(error.localizedDescription)
                await closeSession()
            }
        }
    }

    func approveAndImplement() {
        guard state == .planReady || state == .interrupted,
              let runner,
              let session,
              let priorSnapshot = snapshot else { return }
        state = .authorizing
        _Concurrency.Task {
            do {
                let current = try await CodingWorkspaceInspector.inspect(
                    workspaceURL: priorSnapshot.root,
                    searchQuery: searchQuery,
                    obsidianNotePath: obsidianNotePath
                )
                guard current.revision == priorSnapshot.revision else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "The worktree changed after planning. Re-inspect and request a fresh plan before granting write authority."
                    )
                }
                implementationPrompt = CodingWorkspaceInspector.providerPrompt(
                    task: """
                    The following plan is approved for isolated implementation:
                    \(planText)

                    Implement only the approved task below inside the selected worktree. Do not access the network or write outside the worktree. Run the relevant local verification, report changed files and not-run boundaries, and finish with a concise knowledge-update proposal.

                    \(task)
                    """,
                    selectedSources: selectedSources,
                    selectedMatches: selectedMatches,
                    mode: "approved-isolated-implementation"
                )
                let implementationRequest = CodexCodingRequest(
                    prompt: implementationPrompt,
                    sandbox: .workspaceWrite
                )
                let authorization = try await Phase2ControlPlane.authorizeWorkspaceWrite(
                    runner: runner,
                    projectID: projectID,
                    threadID: threadID.rawValue,
                    workspace: current,
                    request: implementationRequest
                )
                snapshot = current
                state = .implementing
                _ = try await session.continueRun(
                    implementationRequest,
                    authorization: authorization
                )
            } catch {
                state = .failed(error.localizedDescription)
                await closeSession()
            }
        }
    }

    func answerQuestion() {
        guard let session, let requestID = pendingQuestion?.approvalID else { return }
        let answer = questionAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty,
              let payload = pendingQuestion?.payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let questions = object["questions"] as? [[String: Any]] else { return }
        let answers = Dictionary(uniqueKeysWithValues: questions.compactMap { question -> (String, [String])? in
            guard let id = question["id"] as? String else { return nil }
            return (id, [answer])
        })
        _Concurrency.Task {
            do {
                try await session.answerQuestion(requestID: requestID, answers: answers)
                questionAnswer = ""
            } catch {
                state = .failed(error.localizedDescription)
                await closeSession()
            }
        }
    }

    func interrupt() {
        guard let session else { return }
        _Concurrency.Task {
            do {
                try await session.interrupt()
            } catch {
                state = .failed("Kaname could not interrupt the provider. No result was accepted.")
                await closeSession()
            }
        }
    }

    func accept() { recordReview(accepted: true) }
    func reject() { recordReview(accepted: false) }

    private func recordReview(accepted: Bool) {
        guard state == .reviewing, let runner, let evidence,
              !accepted || evidence.passed else { return }
        _Concurrency.Task {
            do {
                let outcome = try await Phase2ControlPlane.recordReview(
                    runner: runner,
                    projectID: projectID,
                    threadID: threadID.rawValue,
                    workspace: evidence.workspace,
                    evidence: evidence,
                    accepted: accepted,
                    knowledgeUpdateProposal: knowledgeUpdateProposal
                )
                reviewStorePosition = outcome.storePosition
                state = accepted ? .accepted : .rejected
                await closeSession()
                #if os(macOS)
                NSApplication.shared.requestUserAttention(.informationalRequest)
                #endif
            } catch {
                state = .failed("The signed local control plane rejected the review decision: \(error.localizedDescription)")
                await closeSession()
            }
        }
    }

    private func handle(_ event: CodexRunEvent) {
        switch event.kind {
        case .providerCompleted:
            if state == .planning {
                planText = events.reversed().first(where: {
                    $0.kind == .planUpdated && !($0.text ?? "").isEmpty
                })?.text ?? events.reversed().first(where: {
                    $0.kind == .itemCompleted && !($0.text ?? "").isEmpty
                })?.text ?? "The provider completed without a readable plan."
                state = .planReady
            } else if state == .implementing {
                collectEvidence()
            }
        case .runInterrupted:
            state = .interrupted
        case .runFailed:
            state = .failed(event.text ?? "The provider failed without an accepted result.")
            let failedSession = session
            session = nil
            eventTask?.cancel()
            eventTask = nil
            _Concurrency.Task { await failedSession?.close() }
        case .approvalRequested:
            break
        case .sessionStarted, .runStarted, .messageDelta, .itemStarted, .itemCompleted,
             .planUpdated, .approvalAccepted, .approvalRejected, .questionRequested,
             .questionAnswered, .toolActivity, .diffUpdated, .nativeProviderEvent:
            break
        }
    }

    private func collectEvidence() {
        guard let snapshot else { return }
        state = .reviewing
        _Concurrency.Task {
            do {
                evidence = try await CodingWorkspaceInspector.collectEvidence(workspaceURL: snapshot.root)
                #if os(macOS)
                NSApplication.shared.requestUserAttention(.informationalRequest)
                #endif
            } catch {
                state = .failed("Evidence collection failed: \(error.localizedDescription)")
                await closeSession()
            }
        }
    }

    private func closeSession() async {
        let activeSession = session
        session = nil
        eventTask?.cancel()
        eventTask = nil
        await activeSession?.close()
    }

    private func resetSessionState() {
        eventTask?.cancel()
        eventTask = nil
        events.removeAll()
        receipts.removeAll()
        evidence = nil
        reviewStorePosition = nil
        planText = ""
    }
}

struct CodexLiveWorkspace: View {
    @StateObject private var model = CodexLiveWorkspaceModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                scope
                if let snapshot = model.snapshot { context(snapshot) }
                workflow
                if !model.events.isEmpty { activity }
                if let evidence = model.evidence { evidenceView(evidence) }
            }
            .padding(28)
        }
        .background(Nord.polarNight0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex coding vertical slice", systemImage: "checkmark.shield.fill")
                .font(.title2.weight(.bold)).foregroundStyle(Nord.snowStorm0)
            Text("Discuss → Plan → Approve → Implement → Review Evidence → Accept → Update Knowledge")
                .foregroundStyle(Nord.snowStorm0.opacity(0.78))
            HStack(spacing: 8) {
                badge(model.state.label, color: statusColor)
                Text("GPT-5.6 Terra · Extra High · isolated worktree · network denied")
                    .font(.caption.weight(.medium)).foregroundStyle(Nord.frost1)
            }
        }
    }

    private var scope: some View {
        card("Explicit project and task scope") {
            TextField("Linked Git worktree path", text: $model.worktreePath)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.task)
                .frame(minHeight: 90).scrollContentBackground(.hidden)
                .padding(8).background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Local search"); TextField("Search query", text: $model.searchQuery) }
                GridRow { Text("Obsidian note"); TextField("Vault-relative note path", text: $model.obsidianNotePath) }
            }
            Button("Inspect without mutation", action: model.inspect)
                .buttonStyle(.borderedProminent).tint(Nord.frost2)
        }
    }

    private func context(_ snapshot: CodingWorkspaceSnapshot) -> some View {
        card("Inspectable context") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Branch"); Text(snapshot.branch) }
                GridRow { Text("HEAD"); Text(String(snapshot.head.prefix(12))).monospaced() }
                GridRow { Text("Worktree"); Text(snapshot.isIsolatedWorktree ? "Linked and isolated" : "Not isolated") }
                GridRow { Text("Skills"); Text("\(snapshot.skills.count) discoverable; none loaded automatically") }
            }
            if !snapshot.contextSources.isEmpty {
                Text("Selected sources entering provider context").font(.subheadline.weight(.semibold))
                ForEach(snapshot.contextSources) { source in
                    Toggle(isOn: binding(for: source.id, in: $model.selectedContextIDs)) {
                        VStack(alignment: .leading) {
                            Text(source.title)
                            Text("\(source.path) · \(source.sha256.prefix(12))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !snapshot.searchMatches.isEmpty {
                Text("Selected local-search matches entering provider context").font(.subheadline.weight(.semibold))
                ForEach(snapshot.searchMatches.prefix(24)) { match in
                    Toggle(isOn: binding(for: match.id, in: $model.selectedSearchIDs)) {
                        Text("\(match.path):\(match.line)  \(match.preview)").font(.caption).lineLimit(2)
                    }
                }
            }
        }
    }

    private var workflow: some View {
        card("Workflow gate") {
            if model.state == .ready {
                Button("Discuss and request read-only plan", action: model.startPlanning)
                    .buttonStyle(.borderedProminent).tint(Nord.frost2)
            }
            if !model.planText.isEmpty {
                Text("Proposed plan").font(.headline)
                Text(model.planText).textSelection(.enabled)
            }
            if model.state == .planReady || model.state == .interrupted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approval consequence").font(.headline).foregroundStyle(Nord.auroraYellow)
                    Text("One network-denied Codex turn may write only inside the exact linked worktree. The prompt, worktree revision, expiry, and reversible consequence are fingerprinted and journaled by the signed Rust control plane before dispatch.")
                    HStack {
                        Button("Approve isolated implementation", action: model.approveAndImplement)
                            .buttonStyle(.borderedProminent).tint(Nord.auroraGreen)
                        Text("No session-wide or network grant").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12).background(Nord.auroraYellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.state == .planning || model.state == .implementing {
                HStack { ProgressView(); Text(model.state.label); Spacer(); Button("Interrupt", action: model.interrupt) }
            }
            if let question = model.pendingQuestion,
               model.state == .planning || model.state == .implementing {
                Text(question.text ?? "Codex requested user input.").foregroundStyle(Nord.auroraYellow)
                HStack {
                    TextField("Non-secret answer", text: $model.questionAnswer)
                    Button("Answer", action: model.answerQuestion)
                }
            }
        }
    }

    private var activity: some View {
        card("Durable provider activity") {
            HStack { Text("\(model.receipts.count) journaled observations"); Spacer(); Text("Raw text is not persisted").font(.caption) }
            ForEach(Array(model.events.suffix(30).enumerated()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(event.kind.rawValue).font(.subheadline.weight(.semibold)); Spacer(); Text(event.nativeType).font(.caption) }
                    if let text = event.text, !text.isEmpty { Text(text).font(.caption).lineLimit(5).textSelection(.enabled) }
                }
                .padding(10).background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func evidenceView(_ evidence: CodingEvidenceSnapshot) -> some View {
        card("Review evidence") {
            HStack {
                badge(evidence.passed ? "Evidence passed" : "Evidence failed", color: evidence.passed ? Nord.auroraGreen : Nord.auroraRed)
                Text(evidence.digest.prefix(16)).font(.caption.monospaced())
            }
            Text(evidence.diffStat.isEmpty ? "No diff was produced." : evidence.diffStat).textSelection(.enabled)
            Text("\(evidence.verificationCommand): exit \(evidence.verificationExitStatus) · diff check \(evidence.diffCheckPassed ? "pass" : "failed")")
            if evidence.verificationOutputWasTruncated { Text("Verification output was bounded and truncated.").foregroundStyle(Nord.auroraYellow) }
            Text(evidence.verificationOutput).font(.caption.monospaced()).lineLimit(20).textSelection(.enabled)
            DisclosureGroup("Diff") {
                ScrollView(.horizontal) { Text(evidence.diff).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Text("Knowledge-update proposal").font(.headline)
            TextEditor(text: $model.knowledgeUpdateProposal)
                .frame(minHeight: 80).scrollContentBackground(.hidden)
                .padding(8).background(Nord.polarNight0, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Accept verified result", action: model.accept)
                    .buttonStyle(.borderedProminent).tint(Nord.auroraGreen).disabled(!evidence.passed || model.state != .reviewing)
                Button("Reject result", action: model.reject)
                    .buttonStyle(.bordered).disabled(model.state != .reviewing)
                if let position = model.reviewStorePosition {
                    Text("Review journal position \(position)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Nord.snowStorm0)
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Nord.polarNight1, in: RoundedRectangle(cornerRadius: 16))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }

    private var statusColor: Color {
        switch model.state {
        case .idle, .ready, .accepted: Nord.auroraGreen
        case .inspecting, .planning, .authorizing, .implementing, .reviewing: Nord.frost1
        case .planReady, .interrupted: Nord.auroraYellow
        case .rejected, .failed: Nord.auroraRed
        }
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { selected in
                if selected { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }
}
