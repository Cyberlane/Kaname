import CryptoKit
import Dispatch
import Foundation
import KanameConnectivity
import KanameDesktop
import KanameDomain
import KanameLocalCore

@MainActor
final class DesktopConversationRuntime: ObservableObject {
    private struct PreparedServiceEvent {
        let serviceEvent: KanameConversationServiceEvent
        let providerEvent: CodexRunEvent?
        let batchItem: DesktopProviderEventBatchItem?
    }

    private enum TitleApplication {
        case initial
        case regeneration(expectedTitle: String, expectedSource: DesktopConversationTitleSource)
    }

    private enum TitleGenerationError: Error, LocalizedError {
        case malformedResponse
        case providerStopped
        case unsafeProviderActivity
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .malformedResponse: "The title model did not return the required structured title."
            case .providerStopped: "The title model stopped before returning a title."
            case .unsafeProviderActivity: "The title model attempted activity outside the title-only boundary."
            case .responseTooLarge: "The title model returned an unexpectedly large response."
            }
        }
    }

    @Published private(set) var activeThreadIDs: Set<String> = []
    @Published private(set) var codingWorkflowBusyThreadIDs: Set<String> = []
    @Published private(set) var codingWorkflowErrors: [String: String] = [:]
    @Published private(set) var titleGenerationThreadIDs: Set<String> = []
    @Published private(set) var titleGenerationErrors: [String: String] = [:]

    private let model: DesktopAppModel
    private let environment: KanameDesktopEnvironment
    private let serviceStore: KanameConversationServiceStore
    private let pollingPolicy = DesktopConversationPollingPolicy()
    private var pollingTask: _Concurrency.Task<Void, Never>?
    private var orphanChecks: [String: Int] = [:]
    private var titleTasks: [String: _Concurrency.Task<Void, Never>] = [:]
    private var titleGenerationRegistry = DesktopConversationTitleGenerationRegistry()
    private var eventIndex: DesktopConversationEventCursorIndex
    private var performanceStore = DesktopConversationPerformanceStore()
    private var providerByRunID: [String: String]
    private var nativeThreadByRunID: [String: String]
    private var nativeTurnByRunID: [String: String]
    private var pollCandidateThreadIDs: Set<String>
    private var runningRunIDByThread: [String: String]
    private var codingContextPreparationRunIDs: Set<String> = []
    private var checkpointFinalizationRunIDs: Set<String> = []
    private var didReconcilePersistedTitles = false
    private let gitControl: DesktopGitControlService

    init(
        model: DesktopAppModel,
        environment: KanameDesktopEnvironment = .current,
        gitControl: DesktopGitControlService
    ) {
        self.model = model
        self.environment = environment
        self.gitControl = gitControl
        let indexStarted = DispatchTime.now().uptimeNanoseconds
        eventIndex = DesktopConversationEventCursorIndex(
            persistedEvents: model.snapshot.operations.providerEvents.map(Self.persistedIdentity)
        )
        let indexEnded = DispatchTime.now().uptimeNanoseconds
        providerByRunID = model.snapshot.operations.providerRuns.reduce(into: [:]) { $0[$1.id] = $1.provider }
        nativeThreadByRunID = model.snapshot.operations.providerRuns.reduce(into: [:]) { result, run in
            if let nativeThreadID = run.nativeThreadID { result[run.id] = nativeThreadID }
        }
        nativeTurnByRunID = model.snapshot.operations.providerRuns.reduce(into: [:]) { result, run in
            if let nativeTurnID = run.nativeTurnID { result[run.id] = nativeTurnID }
        }
        pollCandidateThreadIDs = model.providerActivityThreadIDsRequiringPolling
        runningRunIDByThread = model.snapshot.operations.providerRuns.reduce(into: [:]) { result, run in
            if run.state == .running, let threadID = run.threadID { result[threadID] = run.id }
        }
        serviceStore = KanameConversationServiceStore(
            rootDirectory: environment.applicationSupportRoot.appending(path: "ConversationService", directoryHint: .isDirectory)
        )
        quarantineTerminalPendingRequests()
        performanceStore.record(DesktopConversationPerformanceSample(
            metric: .historyIndex,
            durationNanoseconds: indexEnded >= indexStarted ? indexEnded - indexStarted : 0,
            itemCount: model.snapshot.operations.providerEvents.count
        ))
        pollingTask = _Concurrency.Task { [weak self] in await self?.pollService() }
    }

    deinit {
        pollingTask?.cancel()
        for task in titleTasks.values { task.cancel() }
    }

    @discardableResult
    func send(
        threadID: String,
        body: String,
        attachments: [ConversationImageAttachment] = []
    ) -> Bool {
        enqueue(threadID: threadID, body: body, attachments: attachments) != nil
    }

    @discardableResult
    func enqueue(
        threadID: String,
        body: String,
        attachments: [ConversationImageAttachment] = []
    ) -> String? {
        guard let runID = prepareEnqueue(threadID: threadID, body: body, attachments: attachments) else { return nil }
        if model.providerRun(id: runID)?.purpose == .codingImplementation {
            submitImplementationFollowUp(runID: runID)
        } else {
            resumePrepared(runID: runID)
        }
        return runID
    }

    /// Continues an approved implementation with another provider turn inside
    /// the same isolated worktree. Mirrors the authorization performed by
    /// `approvePlanAndImplement` so Codex receives a fresh workspace-write grant.
    private func submitImplementationFollowUp(runID: String) {
        guard let run = model.providerRun(id: runID),
              let threadID = run.threadID,
              let thread = model.thread(id: threadID),
              let projectID = thread.projectID,
              let path = run.workspacePathOverride,
              let sourceMessageID = run.sourceMessageID,
              let message = model.message(threadID: threadID, id: sourceMessageID),
              let runner = LocalCoreRunner.bundled() else {
            model.stopProviderRun(
                id: runID,
                interrupted: false,
                error: "Kaname could not continue the implementation because the isolated worktree or the local journal service is unavailable."
            )
            return
        }
        codingWorkflowErrors.removeValue(forKey: threadID)
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                let isolated = try await CodingWorkspaceInspector.inspect(
                    workspaceURL: URL(fileURLWithPath: path, isDirectory: true)
                )
                let request = CodexCodingRequest(
                    prompt: implementationPrompt(thread: thread, userMessage: message.body),
                    model: resolvedModel(provider: thread.provider, value: thread.model),
                    reasoningEffort: thread.reasoningEffort,
                    sandbox: .workspaceWrite,
                    networkAccess: run.networkAccess
                )
                let authorization = try await Phase2ControlPlane.authorizeWorkspaceWrite(
                    runner: runner,
                    projectID: projectID,
                    threadID: threadID,
                    workspace: isolated,
                    request: request
                )
                pollCandidateThreadIDs.insert(threadID)
                submit(runID: runID, authorization: authorization)
            } catch {
                codingWorkflowErrors[threadID] = error.localizedDescription
                model.stopProviderRun(id: runID, interrupted: false, error: error.localizedDescription)
            }
        }
    }

    func prepareEnqueue(
        threadID: String,
        body: String,
        attachments: [ConversationImageAttachment] = [],
        usesProjectContext: Bool = true,
        workspacePathOverride: String? = nil
    ) -> String? {
        guard let thread = model.thread(id: threadID) else { return nil }
        if let preflightError = conversationRuntimePreflightError() {
            codingWorkflowErrors[threadID] = preflightError
            return nil
        }
        guard attachments.isEmpty || Self.supportsImageAttachments(provider: thread.provider) else {
            codingWorkflowErrors[threadID] = "\(thread.provider) does not have a Kaname image adapter. Remove the images or choose Codex, Claude, or OpenCode."
            return nil
        }
        let stage = codingStage(threadID: threadID)
        if thread.kind == .coding, [.planning, .preparing, .implementing].contains(stage) {
            codingWorkflowErrors[threadID] = "Wait for the current turn to finish before sending another message."
            return nil
        }
        // After approval the conversation continues inside the isolated worktree:
        // every further message is another implementation turn on the same branch.
        let implementationWorktree = thread.kind == .coding
            && [.implementationReview, .evidenceReview, .knowledgeReview].contains(stage)
            ? latestCodingWorktree(threadID: threadID)
            : nil
        let purpose: DesktopProviderRunPurpose = thread.kind == .coding
            ? (implementationWorktree == nil ? .codingPlan : .codingImplementation)
            : .conversation
        guard let messageID = model.appendUserMessage(threadID: threadID, body: body, attachments: attachments),
              let runID = model.enqueueProviderRun(
                threadID: threadID,
                sourceMessageID: messageID,
                usesProjectContext: usesProjectContext,
                workspacePathOverride: implementationWorktree?.worktreePath ?? workspacePathOverride,
                purpose: purpose,
                runtimeModeOverride: purpose == .codingPlan
                    ? .approvalRequired
                    : (implementationWorktree == nil ? nil : Self.implementationRuntimeMode(provider: thread.provider)),
                networkAccessOverride: purpose == .codingPlan
                    ? false
                    : (implementationWorktree == nil ? nil : thread.networkAccess)
              ) else { return nil }
        codingWorkflowErrors.removeValue(forKey: threadID)
        pollCandidateThreadIDs.insert(threadID)
        return runID
    }

    func resumePrepared(runID: String) {
        guard let run = model.providerRun(id: runID), let threadID = run.threadID else { return }
        quarantineTerminalPendingRequests(threadID: threadID)
        let events = (try? serviceStore.events(threadID: threadID).filter { $0.runID == runID }) ?? []
        if !events.isEmpty { return }
        let pending = (try? serviceStore.pendingRequests(threadID: threadID).contains { $0.1.runID == runID }) ?? false
        if pending {
            pollCandidateThreadIDs.insert(threadID)
            launchWorkerIfAvailable(threadID: threadID)
            return
        }
        guard run.state == .proposed else { return }
        if run.purpose == .codingImplementation {
            model.stopProviderRun(
                id: runID,
                interrupted: false,
                error: "The exact implementation approval was not durably queued. Review the plan and approve a fresh isolated run."
            )
            return
        }
        submit(runID: runID)
    }

    func retry(runID: String) {
        guard let replacementID = model.retryProviderRun(id: runID) else { return }
        submit(runID: replacementID)
    }

    func startComparison(id: String, projectID: String?) {
        for runID in model.prepareProviderComparison(id: id, projectID: projectID) {
            submit(runID: runID)
        }
    }

    func interrupt(threadID: String) {
        guard let run = model.providerRuns(threadID: threadID).last(where: { $0.state == .running }) else { return }
        try? serviceStore.requestInterrupt(threadID: threadID, runID: run.id)
    }

    func answerQuestion(threadID: String, event: DesktopProviderEventRecord, answer: String) {
        guard let approvalID = event.approvalID else { return }
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAnswer.isEmpty, cleanAnswer.utf8.count <= 4_096 else { return }
        let questionIDs = Self.questionIDs(from: event.rawPayloadBase64)
        guard !questionIDs.isEmpty else { return }
        try? serviceStore.requestAnswer(
            threadID: threadID,
            runID: event.runID,
            requestID: approvalID,
            answers: Dictionary(uniqueKeysWithValues: questionIDs.map { ($0, [cleanAnswer]) })
        )
    }

    func isRunning(threadID: String) -> Bool {
        activeThreadIDs.contains(threadID)
    }

    func isGeneratingTitle(threadID: String) -> Bool {
        titleGenerationRegistry.isGenerating(threadID: threadID)
    }

    func canRegenerateTitle(threadID: String) -> Bool {
        guard !isGeneratingTitle(threadID: threadID),
              let thread = model.thread(id: threadID) else { return false }
        return thread.messages.contains { $0.role == .user }
    }

    @discardableResult
    func regenerateTitle(threadID: String) -> Bool {
        guard canRegenerateTitle(threadID: threadID),
              let thread = model.thread(id: threadID),
              let request = DesktopConversationTitleGeneration.request(
                  messages: thread.messages,
                  mode: .regeneration(previousTitle: thread.title)
              ),
              let workspace = model.workspaceURL(threadID: threadID) ?? (try? prepareStandaloneWorkspace()) else {
            titleGenerationErrors[threadID] = "Kaname could not prepare a safe title-generation workspace."
            return false
        }
        return beginTitleGeneration(
            threadID: threadID,
            request: request,
            workspace: workspace,
            application: .regeneration(
                expectedTitle: thread.title,
                expectedSource: thread.titleSource
            )
        )
    }

    func codingStage(threadID: String) -> DesktopCodingWorkflowStage {
        if let workflow = model.codingWorkflow(threadID: threadID) {
            switch workflow.state {
            case .discussing: return .discuss
            case .planning: return .planning
            case .awaitingPlanApproval: return .planReview
            case .preparingImplementation: return .preparing
            case .implementing: return .implementing
            case .awaitingReview: return .implementationReview
            case .reviewingEvidence, .awaitingAcceptance: return .evidenceReview
            case .updatingKnowledge: return .knowledgeReview
            case .completed: return .completed
            case .rejected: return .rejected
            case .failed: return .failed
            }
        }
        let runs = model.providerRuns(threadID: threadID)
        let worktree = latestCodingWorktree(threadID: threadID)
        if codingWorkflowBusyThreadIDs.contains(threadID) { return .preparing }
        if let active = runs.last(where: { $0.state == .running || $0.state == .proposed }) {
            switch active.purpose {
            case .codingImplementation: return .implementing
            case .codingKnowledge: return .knowledgeReview
            case .codingPlan, .conversation: return .planning
            }
        }
        if let latest = runs.last {
            if latest.state == .failed || latest.state == .interrupted { return .failed }
            if latest.purpose == .codingPlan && latest.state == .completed {
                return model.thread(id: threadID)?.plan.isEmpty == false ? .planReview : .failed
            }
            if latest.purpose == .codingImplementation && latest.state == .completed {
                switch worktree?.state {
                case .accepted: return .completed
                case .review: return .evidenceReview
                case .dirty, .ready: return .implementationReview
                case .failed: return .failed
                default: return .preparing
                }
            }
        }
        if worktree?.state == .accepted { return .completed }
        if worktree?.state == .review { return .evidenceReview }
        if worktree?.state == .dirty { return .implementationReview }
        if worktree?.state == .failed { return .failed }
        return .discuss
    }

    func performanceP95Nanoseconds(for metric: DesktopConversationPerformanceMetric) -> UInt64? {
        performanceStore.p95Nanoseconds(for: metric)
    }

    func approvePlanAndImplement(threadID: String) {
        guard !codingWorkflowBusyThreadIDs.contains(threadID),
              let thread = model.thread(id: threadID),
              thread.kind == .coding,
              Self.supportsIsolatedImplementation(provider: thread.provider),
              !thread.plan.isEmpty,
              let projectID = thread.projectID,
              let root = model.workspaceURL(threadID: threadID),
              let sourceMessageID = model.providerRuns(threadID: threadID).last(where: {
                  $0.purpose == .codingPlan && $0.state == .completed
              })?.sourceMessageID,
              let sourceMessage = model.message(threadID: threadID, id: sourceMessageID),
              let runner = LocalCoreRunner.bundled() else {
            codingWorkflowErrors[threadID] = "Coding implementation requires a project conversation with a provider adapter, a valid repository, and the signed local journal service."
            return
        }
        codingWorkflowBusyThreadIDs.insert(threadID)
        codingWorkflowErrors.removeValue(forKey: threadID)
        _ = model.updateCodingWorkflow(
            threadID: threadID,
            state: .preparingImplementation,
            reason: "Creating the approved isolated implementation boundary."
        )
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { codingWorkflowBusyThreadIDs.remove(threadID) }
            do {
                let rootSnapshot = try await CodingWorkspaceInspector.inspect(workspaceURL: root)
                guard rootSnapshot.isGitRepository, rootSnapshot.head != "unborn" else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Implementation needs a Git repository with at least one commit. Point the project at a repository root, or run git init and commit first."
                    )
                }
                let token = UUID().uuidString.lowercased().prefix(8)
                let target = environment.worktreeDirectory
                    .appending(path: "conversation-\(threadID.prefix(8))-\(token)", directoryHint: .isDirectory)
                    .standardizedFileURL
                let branch = "kaname/\(threadID.prefix(8))/\(token)"
                let planText = thread.plan.enumerated().map { index, item in
                    "\(index + 1). \(item.title)"
                }.joined(separator: "\n")
                guard let approvalID = model.createApproval(
                    threadID: threadID,
                    title: "Implement approved plan",
                    exactTarget: target.path,
                    consequence: "Create branch \(branch) from \(rootSnapshot.head), then allow \(thread.provider) implementation turns only inside that isolated worktree. Approved plan digest: \(CodingWorkspaceInspector.digest(Data(planText.utf8))).",
                    dataLeavingDevice: "The approved prompt is sent to \(thread.provider).",
                    reversible: true,
                    expiresAtUnixMillis: Int64(Date().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000)
                ) else {
                    throw CodingWorkspaceInspectorError.unavailable("Kaname could not persist the exact implementation approval.")
                }
                model.resolveApproval(id: approvalID, approved: true)
                guard model.addCodingKnowledgeCandidate(
                    threadID: threadID,
                    category: .decision,
                    title: "Approved implementation plan",
                    detail: KanameTextBounds.utf8Prefix(planText, maximumBytes: 8 * 1_024)
                ) != nil else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Kaname could not persist the approved plan in the durable knowledge lane."
                    )
                }
                guard let worktreeID = model.proposeWorktree(
                    projectID: projectID,
                    threadID: threadID,
                    rootWorkspacePath: root.path,
                    worktreePath: target.path,
                    branch: branch,
                    baseRevision: rootSnapshot.head
                ) else {
                    throw CodingWorkspaceInspectorError.unavailable("Kaname could not persist the managed worktree proposal.")
                }
                let created = try await gitControl.createWorktree(
                    repository: root,
                    target: target,
                    branch: branch,
                    baseRevision: rootSnapshot.head,
                    grant: LocalGitMutationGrant(
                        approvalID: approvalID,
                        kind: .createWorktree,
                        exactTarget: target.path
                    )
                )
                model.updateWorktree(
                    id: worktreeID,
                    headRevision: created.headRevision,
                    changedFileCount: created.changedFiles.count,
                    diffSummary: "Isolated worktree ready; implementation has not started.",
                    diagnosticSummary: "Created with exact local approval \(approvalID).",
                    state: .ready
                )
                let isolated = try await CodingWorkspaceInspector.inspect(workspaceURL: target)
                let prompt = implementationPrompt(thread: thread, userMessage: sourceMessage.body)
                let request = CodexCodingRequest(
                    prompt: prompt,
                    model: resolvedModel(provider: thread.provider, value: thread.model),
                    reasoningEffort: thread.reasoningEffort,
                    sandbox: .workspaceWrite,
                    networkAccess: false
                )
                let authorization = try await Phase2ControlPlane.authorizeWorkspaceWrite(
                    runner: runner,
                    projectID: projectID,
                    threadID: threadID,
                    workspace: isolated,
                    request: request
                )
                guard let runID = model.enqueueProviderRun(
                    threadID: threadID,
                    sourceMessageID: sourceMessageID,
                    workspacePathOverride: target.path,
                    purpose: .codingImplementation,
                    runtimeModeOverride: Self.implementationRuntimeMode(provider: thread.provider),
                    networkAccessOverride: thread.networkAccess
                ) else {
                    throw CodingWorkspaceInspectorError.unavailable("Kaname could not persist the approved implementation run.")
                }
                pollCandidateThreadIDs.insert(threadID)
                submit(runID: runID, authorization: authorization)
            } catch {
                codingWorkflowErrors[threadID] = error.localizedDescription
                _ = model.updateCodingWorkflow(
                    threadID: threadID,
                    state: .failed,
                    reason: error.localizedDescription
                )
                model.setAttention(threadID: threadID, attention: .failed)
            }
        }
    }

    func recheckImplementation(threadID: String) {
        refreshImplementationEvidence(threadID: threadID, accepted: nil)
    }

    func beginImplementationReview(threadID: String) {
        guard !codingWorkflowBusyThreadIDs.contains(threadID),
              model.codingWorkflow(threadID: threadID)?.state == .awaitingReview,
              let completedRun = model.providerRuns(threadID: threadID).last(where: {
                  $0.purpose == .codingImplementation && $0.state == .completed
              }),
              let path = completedRun.workspacePathOverride,
              let worktree = latestCodingWorktree(threadID: threadID),
              [.ready, .dirty].contains(worktree.state),
              URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                == URL(fileURLWithPath: worktree.worktreePath, isDirectory: true).standardizedFileURL else { return }
        codingWorkflowErrors.removeValue(forKey: threadID)
        guard model.updateCodingWorkflow(
            threadID: threadID,
            state: .reviewingEvidence,
            reason: "The user started independent diff and verification review."
        ) else { return }
        collectCodingEvidence(
            threadID: threadID,
            worktreeID: worktree.id,
            workspace: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    func reviewImplementation(threadID: String, accepted: Bool) {
        refreshImplementationEvidence(threadID: threadID, accepted: accepted)
    }

    private func refreshImplementationEvidence(threadID: String, accepted: Bool?) {
        guard !codingWorkflowBusyThreadIDs.contains(threadID),
              let thread = model.thread(id: threadID),
              let projectID = thread.projectID,
              let worktree = latestCodingWorktree(threadID: threadID),
              worktree.state == .review,
              let runner = LocalCoreRunner.bundled() else { return }
        codingWorkflowBusyThreadIDs.insert(threadID)
        codingWorkflowErrors.removeValue(forKey: threadID)
        guard model.updateCodingWorkflow(
            threadID: threadID,
            state: .reviewingEvidence,
            reason: accepted == nil
                ? "Independent evidence is being refreshed."
                : "The accepted or rejected review decision is being bound to fresh evidence."
        ) else { return }
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { codingWorkflowBusyThreadIDs.remove(threadID) }
            do {
                let worktreeURL = URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
                let verification = Self.detectVerificationCommand(workspace: worktreeURL)
                let evidence = try await CodingWorkspaceInspector.collectEvidence(
                    workspaceURL: worktreeURL,
                    verificationExecutable: verification?.executable,
                    verificationArguments: verification?.arguments ?? []
                )
                guard accepted != true || evidence.passed else {
                    throw CodingWorkspaceInspectorError.unavailable("Acceptance is disabled because the latest independent evidence does not pass.")
                }
                guard let accepted else {
                    guard persistCodingEvidence(evidence, threadID: threadID, worktreeID: worktree.id) else {
                        throw CodingWorkspaceInspectorError.unavailable(
                            "Kaname could not persist the exact evidence receipt."
                        )
                    }
                    return
                }
                _ = try await Phase2ControlPlane.recordReview(
                    runner: runner,
                    projectID: projectID,
                    threadID: threadID,
                    workspace: evidence.workspace,
                    evidence: evidence,
                    accepted: accepted,
                    knowledgeUpdateProposal: "Record the reviewed plan, isolated diff, verification result, evidence digest, acceptance decision, and remaining boundaries for \(thread.title)."
                )
                guard persistCodingEvidence(evidence, threadID: threadID, worktreeID: worktree.id) else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Kaname could not persist the fresh evidence receipt."
                    )
                }
                guard model.recordCodingReview(
                    threadID: threadID,
                    worktreeID: worktree.id,
                    accepted: accepted
                ) else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Kaname could not persist the exact review decision; the implementation remains unaccepted."
                    )
                }
                if accepted {
                    codingWorkflowBusyThreadIDs.remove(threadID)
                    runKnowledgeTurn(threadID: threadID)
                }
            } catch {
                codingWorkflowErrors[threadID] = error.localizedDescription
            }
        }
    }

    private func submit(
        runID: String,
        authorization: CodexWorkspaceAuthorization? = nil,
        codingContextSources: [CodingContextSource]? = nil,
        checkpointPrepared: Bool = false
    ) {
        guard let run = model.providerRun(id: runID),
              let threadID = run.threadID,
              let sourceMessageID = run.sourceMessageID,
              let message = model.message(threadID: threadID, id: sourceMessageID),
              let thread = model.thread(id: threadID) else {
            return
        }
        let workerURL: URL
        do {
            workerURL = try workerExecutableURL()
        } catch {
            let message = conversationRuntimePreflightError() ?? error.localizedDescription
            codingWorkflowErrors[threadID] = message
            model.stopProviderRun(id: run.id, interrupted: false, error: message)
            return
        }
        let workspace: URL
        if let override = run.workspacePathOverride {
            workspace = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else if let projectWorkspace = model.workspaceURL(threadID: threadID) {
            workspace = projectWorkspace
        } else if thread.projectID == nil, let standaloneWorkspace = try? prepareStandaloneWorkspace() {
            workspace = standaloneWorkspace
        } else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "Choose a valid project workspace before starting a provider. The message remains saved locally."
            )
            return
        }
        if run.purpose == .codingPlan, codingContextSources == nil {
            prepareCodingPlanContext(run: run, thread: thread, workspace: workspace, authorization: authorization)
            return
        }
        if run.purpose == .codingImplementation, !checkpointPrepared,
           let worktree = latestCodingWorktree(threadID: threadID) {
            _Concurrency.Task { [weak self] in
                guard let self else { return }
                let captured = await self.recordImplementationCheckpointBefore(
                    runID: run.id,
                    threadID: threadID,
                    worktree: worktree,
                    workspace: workspace
                )
                guard captured else {
                    model.stopProviderRun(
                        id: run.id,
                        interrupted: false,
                        error: "Kaname could not capture the exact pre-turn Git checkpoint, so no provider request was sent."
                    )
                    return
                }
                self.submit(
                    runID: run.id,
                    authorization: authorization,
                    codingContextSources: codingContextSources,
                    checkpointPrepared: true
                )
            }
            return
        }
        quarantineTerminalPendingRequests(threadID: threadID)
        providerByRunID[run.id] = run.provider
        pollCandidateThreadIDs.insert(threadID)
        guard let machService = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreMachService") as? String,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreServiceRequirement") as? String else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "The signed local journal service is unavailable, so Kaname did not send the message."
            )
            return
        }
        let previewGrant = model.snapshot.operations.approvals.contains { approval in
            CodingPreviewMCPGrant.matchesApprovedGrant(
                title: approval.title,
                exactTarget: approval.exactTarget,
                threadID: approval.threadID,
                isApproved: approval.state == .approved,
                expiresAtUnixMillis: approval.expiresAtUnixMillis,
                expectedThreadID: threadID,
                worktreePath: workspace.path
            )
        }
        let request = KanameConversationServiceRequest(
            runID: run.id,
            threadID: threadID,
            projectID: thread.projectID ?? "standalone",
            provider: run.provider,
            model: resolvedModel(provider: run.provider, value: run.model),
            reasoningEffort: run.reasoningEffort,
            runtimeMode: run.runtimeMode,
            networkAccess: run.networkAccess,
            prompt: providerPrompt(
                thread: thread,
                userMessage: message.body,
                includeProjectContext: run.usesProjectContext ?? true,
                runtimeMode: run.runtimeMode,
                networkAccess: run.networkAccess,
                purpose: run.purpose,
                codingContextSources: codingContextSources ?? []
            ),
            attachments: message.attachments,
            workspacePath: workspace.path,
            providerStatePath: environment.providerStateDirectory.path,
            resumableNativeThreadID: model.latestNativeThreadID(
                threadID: threadID,
                provider: run.provider,
                workspacePathOverride: run.workspacePathOverride
            ),
            localCoreMachService: machService,
            localCoreRequirement: requirement,
            workspaceAuthorization: authorization,
            isCodingPlan: run.purpose == .codingPlan,
            curatedPreviewMCPGranted: previewGrant && run.purpose == .codingImplementation,
            createdAtUnixMillis: run.startedAtUnixMillis,
            bridgeKnowledgeReadScopes: model.snapshot.operations.vaultScopes.filter(\.canRead).map(\.path),
            bridgeKnowledgeWriteScopes: model.snapshot.operations.vaultScopes.filter(\.canWrite).map(\.path)
        )
        var queuedRequestURL: URL?
        do {
            queuedRequestURL = try serviceStore.enqueue(request)
            _ = try KanameConversationWorkerLauncher.launch(
                executableURL: workerURL,
                storeRoot: serviceStore.rootDirectory,
                threadID: threadID
            )
            setThreadActive(threadID, active: true)
        } catch {
            var failure = error.localizedDescription
            if let queuedRequestURL {
                do {
                    try serviceStore.quarantinePendingRequest(at: queuedRequestURL, threadID: threadID)
                } catch {
                    failure += " Kaname could not quarantine the queued request; do not retry this thread until its local queue is inspected."
                }
            }
            codingWorkflowErrors[threadID] = failure
            model.stopProviderRun(id: run.id, interrupted: false, error: failure)
        }
    }

    private func prepareCodingPlanContext(
        run: DesktopProviderRunRecord,
        thread: DesktopThread,
        workspace: URL,
        authorization: CodexWorkspaceAuthorization?
    ) {
        guard codingContextPreparationRunIDs.insert(run.id).inserted else { return }
        let project = (run.usesProjectContext ?? true) ? model.project(id: thread.projectID) : nil
        let selectedSourceIDs = Set(project?.context.knowledgeSourceIDs ?? [])
        let selectedObsidianPaths = model.snapshot.domains.knowledgeSources.compactMap { source in
            selectedSourceIDs.contains(source.id) && source.kind == .obsidian ? source.scope : nil
        }
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { codingContextPreparationRunIDs.remove(run.id) }
            do {
                let snapshot = try await CodingWorkspaceInspector.inspect(
                    workspaceURL: workspace,
                    obsidianNotePaths: selectedObsidianPaths
                )
                guard !snapshot.obsidianNoteSelectionWasTruncated,
                      snapshot.missingObsidianNotePaths.isEmpty else {
                    let unavailable = snapshot.missingObsidianNotePaths.joined(separator: ", ")
                    throw CodingWorkspaceInspectorError.unavailable(
                        snapshot.obsidianNoteSelectionWasTruncated
                            ? "The selected Obsidian context exceeds the bounded planning limit. Narrow the project knowledge selection."
                            : "Kaname could not load selected Obsidian context: \(unavailable). No planning turn was sent."
                    )
                }
                let selectedContextSources = snapshot.contextSources.filter {
                    (run.usesProjectContext ?? true) || $0.kind == .repositoryInstructions
                }
                let records = selectedContextSources.map { source in
                    DesktopCodingKnowledgeConsultedSource(
                        sourceID: knowledgeSourceID(for: source, project: project),
                        title: source.title,
                        path: source.path,
                        digest: source.sha256,
                        provenance: knowledgeProvenance(for: source),
                        excerpt: KanameTextBounds.utf8Prefix(source.excerpt, maximumBytes: 8 * 1_024),
                        summary: source.excerpt.utf8.count > 8 * 1_024
                            ? "Bounded preview retained; the digest binds the full excerpt loaded into read-only planning."
                            : "Loaded into the read-only planning context."
                    )
                }
                guard model.replaceCodingKnowledgeContext(
                    threadID: thread.id,
                    projectID: thread.projectID,
                    sources: records
                ) else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Kaname could not persist the exact planning-context receipt. No planning turn was sent."
                    )
                }
                submit(runID: run.id, authorization: authorization, codingContextSources: selectedContextSources)
            } catch {
                codingWorkflowErrors[thread.id] = error.localizedDescription
                model.stopProviderRun(id: run.id, interrupted: false, error: error.localizedDescription)
            }
        }
    }

    private func pollService() async {
        while !_Concurrency.Task.isCancelled {
            let cycleState = pollingState()
            let threadIDs = cycleState.threadIDs
            let cycleStarted = DispatchTime.now().uptimeNanoseconds
            var remainingEventCapacity = pollingPolicy.maximumEventsPerCycle
            for threadID in threadIDs {
                let serviceEvents = Self.orderedServiceEvents((try? serviceStore.events(threadID: threadID)) ?? [])
                var mayApplyNewEvents = true
                for event in serviceEvents where eventIndex.contains(Self.identity(event)) && remainingEventCapacity > 0 {
                    guard let prepared = prepare(event), applyEffects(for: prepared) else {
                        mayApplyNewEvents = false
                        break
                    }
                    try? serviceStore.acknowledge(event)
                    remainingEventCapacity -= 1
                }
                let batchStarted = DispatchTime.now().uptimeNanoseconds
                let pendingEvents = eventIndex.unseenBatch(
                    from: serviceEvents,
                    maximumCount: mayApplyNewEvents ? remainingEventCapacity : 0,
                    identity: Self.identity
                )
                let batchEnded = DispatchTime.now().uptimeNanoseconds
                performanceStore.record(DesktopConversationPerformanceSample(
                    metric: .eventBatchSelection,
                    durationNanoseconds: batchEnded >= batchStarted ? batchEnded - batchStarted : 0,
                    itemCount: serviceEvents.count
                ))
                var preparedEvents: [PreparedServiceEvent] = []
                for event in pendingEvents {
                    guard let prepared = prepare(event) else { break }
                    preparedEvents.append(prepared)
                }
                let batchItems = preparedEvents.compactMap(\.batchItem)
                let persistenceStarted = DispatchTime.now().uptimeNanoseconds
                let batchResult = batchItems.isEmpty
                    ? DesktopProviderEventBatchResult(acceptedEventIDs: [], duplicateEventIDs: [])
                    : model.recordProviderEvents(batchItems)
                let persistenceEnded = DispatchTime.now().uptimeNanoseconds
                if !batchItems.isEmpty {
                    performanceStore.record(DesktopConversationPerformanceSample(
                        metric: .providerEventBatchPersistence,
                        durationNanoseconds: persistenceEnded >= persistenceStarted ? persistenceEnded - persistenceStarted : 0,
                        itemCount: batchItems.count
                    ))
                }
                if let batchResult {
                    let durableEventIDs = Set(batchResult.acceptedEventIDs + batchResult.duplicateEventIDs)
                    for prepared in preparedEvents {
                        guard prepared.batchItem == nil || durableEventIDs.contains(prepared.serviceEvent.id) else { break }
                        guard applyEffects(for: prepared) else { break }
                        eventIndex.markPersisted(Self.identity(prepared.serviceEvent))
                        try? serviceStore.acknowledge(prepared.serviceEvent)
                        remainingEventCapacity -= 1
                    }
                }
                quarantineTerminalPendingRequests(threadID: threadID)
                let alive = serviceStore.isWorkerAlive(threadID: threadID)
                let hasPending = (try? serviceStore.pendingRequests(threadID: threadID).isEmpty == false) ?? false
                if alive || hasPending {
                    setThreadActive(threadID, active: true)
                    orphanChecks[threadID] = 0
                    if hasPending && !alive { launchWorkerIfAvailable(threadID: threadID) }
                } else {
                    setThreadActive(threadID, active: false)
                    reconcileOrphanedRun(threadID: threadID, runningRunID: cycleState.runningRunIDs[threadID])
                    if runningRunIDByThread[threadID] == nil,
                       !model.hasActiveSubagents(threadID: threadID) {
                        pollCandidateThreadIDs.remove(threadID)
                    }
                }
            }
            reconcilePersistedTitlesOnce()
            let cycleEnded = DispatchTime.now().uptimeNanoseconds
            performanceStore.record(DesktopConversationPerformanceSample(
                metric: .pollingCycle,
                durationNanoseconds: cycleEnded >= cycleStarted ? cycleEnded - cycleStarted : 0,
                itemCount: threadIDs.count
            ))
            let interval = pollingPolicy.intervalNanoseconds(hasCandidateThreads: !threadIDs.isEmpty)
            try? await _Concurrency.Task.sleep(for: .nanoseconds(Int64(interval)))
        }
    }

    private func prepare(_ serviceEvent: KanameConversationServiceEvent) -> PreparedServiceEvent? {
        guard let run = model.providerRun(id: serviceEvent.runID),
              run.threadID == serviceEvent.threadID else { return nil }
        if serviceEvent.kind == .serviceStarted {
            if run.state == .proposed {
                let running = model.beginProviderRun(id: serviceEvent.runID)
                guard model.persistenceError == nil else { return nil }
                if running?.state == .running { runningRunIDByThread[serviceEvent.threadID] = serviceEvent.runID }
            }
            guard attachNativeIdentityIfNeeded(serviceEvent) else { return nil }
        }
        if serviceEvent.kind == .serviceFailed {
            let record = DesktopProviderEventRecord(
                id: serviceEvent.id,
                threadID: serviceEvent.threadID,
                runID: serviceEvent.runID,
                turnID: model.providerRun(id: serviceEvent.runID)?.turnID,
                kind: .error,
                title: "Provider stopped",
                detail: serviceEvent.text ?? "The durable provider worker stopped safely.",
                nativeType: serviceEvent.nativeType,
                nativeThreadID: serviceEvent.nativeThreadID,
                nativeTurnID: serviceEvent.nativeTurnID,
                approvalID: serviceEvent.approvalID,
                rawPayloadBase64: serviceEvent.rawPayloadBase64,
                payloadWasTruncated: serviceEvent.payloadWasTruncated,
                createdAtUnixMillis: serviceEvent.createdAtUnixMillis
            )
            return PreparedServiceEvent(
                serviceEvent: serviceEvent,
                providerEvent: nil,
                batchItem: DesktopProviderEventBatchItem(event: record)
            )
        }
        guard let providerKind = serviceEvent.providerKind else {
            return serviceEvent.kind == .serviceStarted
                ? PreparedServiceEvent(serviceEvent: serviceEvent, providerEvent: nil, batchItem: nil)
                : nil
        }
        let event = CodexRunEvent(
            kind: providerKind,
            nativeType: serviceEvent.nativeType,
            threadID: serviceEvent.nativeThreadID,
            turnID: serviceEvent.nativeTurnID,
            approvalID: serviceEvent.approvalID,
            toolObservation: serviceEvent.toolObservation,
            agentActivity: serviceEvent.agentActivity,
            text: serviceEvent.text,
            payload: serviceEvent.rawPayloadBase64.flatMap { Data(base64Encoded: $0) },
            payloadWasTruncated: serviceEvent.payloadWasTruncated
        )
        guard attachNativeIdentityIfNeeded(serviceEvent) else { return nil }
        let record = providerEventRecord(
            event,
            id: serviceEvent.id,
            threadID: serviceEvent.threadID,
            runID: serviceEvent.runID,
            createdAtUnixMillis: serviceEvent.createdAtUnixMillis
        )
        return PreparedServiceEvent(
            serviceEvent: serviceEvent,
            providerEvent: event,
            batchItem: DesktopProviderEventBatchItem(
                event: record,
                assistantDelta: event.kind == .messageDelta ? event.text : nil
            )
        )
    }

    private func applyEffects(for prepared: PreparedServiceEvent) -> Bool {
        let serviceEvent = prepared.serviceEvent
        if serviceEvent.kind == .serviceFailed {
            if model.providerRun(id: serviceEvent.runID)?.state != .failed {
                model.stopProviderRun(
                    id: serviceEvent.runID,
                    interrupted: false,
                    error: prepared.batchItem?.event.detail ?? "The durable provider worker stopped safely."
                )
                guard model.persistenceError == nil else { return false }
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
            return true
        }
        guard let event = prepared.providerEvent else { return true }
        if event.kind == .planUpdated, let planText = event.planText {
            model.setProviderPlanBody(threadID: serviceEvent.threadID, text: planText)
            guard model.persistenceError == nil else { return false }
        }
        if event.nativeType == "kaname/finding", let text = event.text {
            model.appendFindings(threadID: serviceEvent.threadID, runID: serviceEvent.runID, texts: [text])
            guard model.persistenceError == nil else { return false }
        }
        if event.nativeType == "kaname/knowledge_proposal",
           let payload = event.payload,
           let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let path = object["path"] as? String,
           let content = object["content"] as? String {
            let rationale = (object["rationale"] as? String) ?? ""
            model.addKnowledgeNoteProposal(
                threadID: serviceEvent.threadID,
                runID: serviceEvent.runID,
                path: path,
                content: content,
                rationale: rationale
            )
            guard model.persistenceError == nil else { return false }
        }
        if event.kind == .planUpdated, let update = event.planUpdate {
            model.replaceProviderPlan(
                threadID: serviceEvent.threadID,
                steps: update.entries.map { ($0.step, $0.status) },
                explanation: update.explanation
            )
            guard model.persistenceError == nil else { return false }
        } else if event.kind == .planUpdated, let text = event.text {
            model.addProviderPlan(threadID: serviceEvent.threadID, text: text, completed: false)
            guard model.persistenceError == nil else { return false }
        }
        if let activity = event.agentActivity {
            let subagentState: DesktopSubagentState = switch activity.activity {
            case .started, .interacted: .running
            case .completed: .completed
            case .failed: .failed
            case .interrupted: .interrupted
            }
            model.recordSubagentActivity(
                threadID: serviceEvent.threadID,
                runID: serviceEvent.runID,
                provider: providerName(runID: serviceEvent.runID),
                nativeID: activity.agentID,
                parentNativeID: activity.parentAgentID,
                title: activity.agentPath ?? activity.taskType ?? "Provider subagent",
                detail: "\(activity.activity.rawValue) · \(event.nativeType)",
                state: subagentState
            )
            guard model.persistenceError == nil else { return false }
        }

        switch event.kind {
        case .providerCompleted:
            let completedRun = model.providerRun(id: serviceEvent.runID)
            if completedRun?.purpose == .codingPlan || completedRun?.purpose == .codingImplementation,
               let reply = model.thread(id: serviceEvent.threadID)?.messages.last(where: { $0.role == .assistant })?.body {
                let findings = ProviderFindingsMarkdown.findings(fromMarkdown: reply)
                if !findings.isEmpty {
                    model.appendFindings(threadID: serviceEvent.threadID, runID: serviceEvent.runID, texts: findings)
                    guard model.persistenceError == nil else { return false }
                }
            }
            if completedRun?.purpose == .codingPlan,
               let fallback = model.thread(id: serviceEvent.threadID)?.messages.last(where: { $0.role == .assistant })?.body,
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The final planning message is the readable plan body unless the
                // provider already supplied one through a structured plan update.
                if model.thread(id: serviceEvent.threadID)?.planBody == nil {
                    model.setProviderPlanBody(threadID: serviceEvent.threadID, text: fallback)
                    guard model.persistenceError == nil else { return false }
                }
                if model.thread(id: serviceEvent.threadID)?.plan.isEmpty == true {
                    let steps = ProviderPlanMarkdown.steps(fromMarkdown: fallback)
                    if steps.isEmpty {
                        model.addProviderPlan(threadID: serviceEvent.threadID, text: fallback, completed: true)
                    } else {
                        model.replaceProviderPlan(
                            threadID: serviceEvent.threadID,
                            steps: steps.map { ($0, "pending") },
                            explanation: nil
                        )
                    }
                    guard model.persistenceError == nil else { return false }
                }
            }
            if completedRun?.purpose == .codingPlan,
               model.thread(id: serviceEvent.threadID)?.plan.isEmpty == false {
                model.finalizeCodingPlanForApproval(threadID: serviceEvent.threadID)
                guard model.persistenceError == nil else { return false }
            }
            if model.providerRun(id: serviceEvent.runID)?.state != .completed {
                model.completeProviderRun(id: serviceEvent.runID, tokenUsage: tokenUsage(from: event.payload))
                guard model.persistenceError == nil else { return false }
            }
            if completedRun?.purpose == .codingImplementation {
                scheduleImplementationCheckpointAfter(
                    runID: serviceEvent.runID,
                    threadID: serviceEvent.threadID
                )
            }
            if completedRun?.purpose == .codingPlan,
               model.thread(id: serviceEvent.threadID)?.plan.isEmpty == true {
                model.markCodingPlanUnavailable(threadID: serviceEvent.threadID)
                guard model.persistenceError == nil else { return false }
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
            guard registerServiceEvidence(threadID: serviceEvent.threadID, runID: serviceEvent.runID) else { return false }
            scheduleTitleIfNeeded(threadID: serviceEvent.threadID)
        case .runInterrupted:
            let interruptedRun = model.providerRun(id: serviceEvent.runID)
            if model.providerRun(id: serviceEvent.runID)?.state != .interrupted {
                model.stopProviderRun(id: serviceEvent.runID, interrupted: true, error: event.text ?? "The provider turn was interrupted.")
                guard model.persistenceError == nil else { return false }
            }
            if interruptedRun?.purpose == .codingImplementation {
                scheduleImplementationCheckpointAfter(runID: serviceEvent.runID, threadID: serviceEvent.threadID)
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
        case .runFailed:
            let failedRun = model.providerRun(id: serviceEvent.runID)
            if model.providerRun(id: serviceEvent.runID)?.state != .failed {
                model.stopProviderRun(id: serviceEvent.runID, interrupted: false, error: event.text ?? "The provider stopped without a readable result.")
                guard model.persistenceError == nil else { return false }
            }
            if failedRun?.purpose == .codingImplementation {
                scheduleImplementationCheckpointAfter(runID: serviceEvent.runID, threadID: serviceEvent.threadID)
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
        case .sessionStarted, .runStarted, .messageDelta, .itemStarted, .itemCompleted,
             .planUpdated, .approvalRequested, .approvalAccepted, .approvalRejected,
             .questionRequested, .questionAnswered, .toolActivity, .diffUpdated, .nativeProviderEvent:
            break
        }
        return true
    }

    private func reconcileOrphanedRun(threadID: String, runningRunID: String?) {
        let currentRunningRunID = runningRunID.flatMap { runID in
            model.providerRun(id: runID)?.state == .running ? runID : nil
        }
        guard currentRunningRunID != nil || model.hasActiveSubagents(threadID: threadID) else {
            orphanChecks[threadID] = 0
            return
        }
        let count = (orphanChecks[threadID] ?? 0) + 1
        orphanChecks[threadID] = count
        if count >= pollingPolicy.orphanedRunCheckCount {
            if let currentRunningRunID {
                let runPurpose = model.providerRun(id: currentRunningRunID)?.purpose
                model.stopProviderRun(
                    id: currentRunningRunID,
                    interrupted: true,
                    error: "The durable provider worker stopped before completion. Retry reuses the saved user message."
                )
                guard model.persistenceError == nil else { return }
                if runPurpose == .codingImplementation {
                    scheduleImplementationCheckpointAfter(runID: currentRunningRunID, threadID: threadID)
                }
            }
            guard model.recoverOrphanedSubagents(threadID: threadID) else { return }
            runningRunIDByThread.removeValue(forKey: threadID)
            orphanChecks[threadID] = 0
        }
    }

    private func pollingState() -> (threadIDs: [String], runningRunIDs: [String: String]) {
        (pollCandidateThreadIDs.union(activeThreadIDs).sorted(), runningRunIDByThread)
    }

    private func reconcilePersistedTitlesOnce() {
        guard !didReconcilePersistedTitles else { return }
        didReconcilePersistedTitles = true
        let completedThreadIDs = Set(model.snapshot.operations.providerRuns.compactMap { run in
            run.state == .completed ? run.threadID : nil
        })
        for thread in model.snapshot.threads where thread.titleSource == .provisional && completedThreadIDs.contains(thread.id) {
            scheduleTitleIfNeeded(threadID: thread.id)
        }
    }

    private func attachNativeIdentityIfNeeded(_ event: KanameConversationServiceEvent) -> Bool {
        guard let nativeThreadID = event.nativeThreadID else { return true }
        let currentThreadID = nativeThreadByRunID[event.runID]
        let currentTurnID = nativeTurnByRunID[event.runID]
        let needsTurnUpdate = event.nativeTurnID.map { $0 != currentTurnID } ?? false
        guard currentThreadID != nativeThreadID || needsTurnUpdate else { return true }
        model.attachNativeProviderRun(
            id: event.runID,
            nativeThreadID: nativeThreadID,
            nativeTurnID: event.nativeTurnID
        )
        guard model.persistenceError == nil else { return false }
        nativeThreadByRunID[event.runID] = nativeThreadID
        if let nativeTurnID = event.nativeTurnID {
            nativeTurnByRunID[event.runID] = nativeTurnID
        }
        return true
    }

    private func providerName(runID: String) -> String {
        if let provider = providerByRunID[runID] { return provider }
        let provider = model.providerRun(id: runID)?.provider ?? "Provider"
        providerByRunID[runID] = provider
        return provider
    }

    private func setThreadActive(_ threadID: String, active: Bool) {
        if active {
            if !activeThreadIDs.contains(threadID) { activeThreadIDs.insert(threadID) }
        } else if activeThreadIDs.contains(threadID) {
            activeThreadIDs.remove(threadID)
        }
    }

    private static func orderedServiceEvents(
        _ events: [KanameConversationServiceEvent]
    ) -> [KanameConversationServiceEvent] {
        let runStartedAt = events.reduce(into: [String: Int64]()) { result, event in
            result[event.runID] = min(result[event.runID] ?? event.createdAtUnixMillis, event.createdAtUnixMillis)
        }
        return events.sorted { lhs, rhs in
            if lhs.runID == rhs.runID { return lhs.ordinal < rhs.ordinal }
            let lhsStartedAt = runStartedAt[lhs.runID] ?? lhs.createdAtUnixMillis
            let rhsStartedAt = runStartedAt[rhs.runID] ?? rhs.createdAtUnixMillis
            if lhsStartedAt != rhsStartedAt { return lhsStartedAt < rhsStartedAt }
            return lhs.runID < rhs.runID
        }
    }

    private static func identity(_ event: KanameConversationServiceEvent) -> DesktopConversationEventIdentity {
        DesktopConversationEventIdentity(id: event.id, runID: event.runID, ordinal: event.ordinal)
    }

    private static func persistedIdentity(_ event: DesktopProviderEventRecord) -> DesktopConversationEventIdentity {
        let prefix = "\(event.runID)-service-"
        let ordinal = event.id.hasPrefix(prefix) ? Int(event.id.dropFirst(prefix.count)) ?? 0 : 0
        return DesktopConversationEventIdentity(id: event.id, runID: event.runID, ordinal: ordinal)
    }

    private func launchWorkerIfAvailable(threadID: String) {
        quarantineTerminalPendingRequests(threadID: threadID)
        let hasPending = (try? serviceStore.pendingRequests(threadID: threadID).isEmpty == false) ?? false
        guard hasPending else { return }
        _ = try? KanameConversationWorkerLauncher.launch(
            executableURL: workerExecutableURL(),
            storeRoot: serviceStore.rootDirectory,
            threadID: threadID
        )
    }

    private func workerExecutableURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "KanameConversationWorker", withExtension: nil) {
            return bundled
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appending(path: "KanameConversationWorker")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        throw KanameConversationServiceError.workerUnavailable
    }

    private func conversationRuntimePreflightError() -> String? {
        do {
            _ = try workerExecutableURL()
        } catch {
            if environment.channel == .development {
                return "Kaname's development coding runtime is incomplete. Rebuild and relaunch it with Scripts/run-phase0-prototype.sh."
            }
            return error.localizedDescription
        }
        guard LocalCoreRunner.bundled() != nil else {
            return "The signed local journal service is unavailable, so Kaname did not save or send the message."
        }
        return nil
    }

    private func quarantineTerminalPendingRequests() {
        let threadIDs = Set(model.snapshot.operations.providerRuns.compactMap(\.threadID))
        for threadID in threadIDs {
            quarantineTerminalPendingRequests(threadID: threadID)
        }
    }

    private func quarantineTerminalPendingRequests(threadID: String) {
        guard let pending = try? serviceStore.pendingRequests(threadID: threadID) else { return }
        for (url, request) in pending {
            let state = model.providerRun(id: request.runID)?.state
            guard state != .proposed, state != .running else { continue }
            do {
                try serviceStore.quarantinePendingRequest(at: url, threadID: threadID)
            } catch {
                codingWorkflowErrors[threadID] = "Kaname could not quarantine a terminal provider request. Do not retry this thread until its local queue is inspected."
            }
        }
    }

    private func scheduleTitleIfNeeded(threadID: String) {
        guard let thread = model.thread(id: threadID),
              thread.titleSource == .provisional,
              let request = DesktopConversationTitleGeneration.request(
                  messages: thread.messages,
                  mode: .initial
              ),
              let workspace = model.workspaceURL(threadID: threadID) ?? (try? prepareStandaloneWorkspace()) else { return }
        _ = beginTitleGeneration(
            threadID: threadID,
            request: request,
            workspace: workspace,
            application: .initial
        )
    }

    @discardableResult
    private func beginTitleGeneration(
        threadID: String,
        request: DesktopConversationTitleGenerationRequest,
        workspace: URL,
        application: TitleApplication
    ) -> Bool {
        guard let token = titleGenerationRegistry.begin(threadID: threadID) else { return false }
        titleGenerationThreadIDs.insert(threadID)
        titleGenerationErrors.removeValue(forKey: threadID)
        titleTasks[threadID] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { finishTitleGeneration(threadID: threadID, token: token) }
            do {
                let title = try await generateTitle(
                    request: request,
                    threadID: threadID,
                    workspace: workspace
                )
                try _Concurrency.Task.checkCancellation()
                guard titleGenerationRegistry.owns(threadID: threadID, token: token) else { return }
                let applied = switch application {
                case .initial:
                    model.applyProviderGeneratedTitle(threadID: threadID, title: title)
                case let .regeneration(expectedTitle, expectedSource):
                    model.applyProviderRegeneratedTitle(
                        threadID: threadID,
                        title: title,
                        expectedTitle: expectedTitle,
                        expectedSource: expectedSource
                    )
                }
                if !applied, case .initial = application {
                    model.markProviderTitleFallback(threadID: threadID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard titleGenerationRegistry.owns(threadID: threadID, token: token) else { return }
                switch application {
                case .initial:
                    model.markProviderTitleFallback(threadID: threadID)
                case .regeneration:
                    titleGenerationErrors[threadID] = error.localizedDescription
                }
            }
        }
        return true
    }

    private func finishTitleGeneration(threadID: String, token: UUID) {
        guard titleGenerationRegistry.finish(threadID: threadID, token: token) else { return }
        titleTasks.removeValue(forKey: threadID)
        titleGenerationThreadIDs.remove(threadID)
    }

    private func generateTitle(
        request: DesktopConversationTitleGenerationRequest,
        threadID: String,
        workspace: URL
    ) async throws -> String {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocalTitle")!,
            driver: .codex,
            displayName: "Codex title generator"
        )
        let session = CodexLiveSession(configuration: .init(instance: instance, workspaceURL: workspace))
        let stream = await session.events()
        let collector = _Concurrency.Task<String, Error> {
            var response = ""
            for await event in stream {
                try _Concurrency.Task.checkCancellation()
                switch event.kind {
                case .messageDelta:
                    if let text = event.text {
                        response += text
                        guard response.utf8.count <= 4_096 else {
                            throw TitleGenerationError.responseTooLarge
                        }
                    }
                case .providerCompleted:
                    return response
                case .toolActivity, .diffUpdated, .approvalRequested, .approvalAccepted,
                     .approvalRejected, .questionRequested, .questionAnswered:
                    try? await session.interrupt()
                    throw TitleGenerationError.unsafeProviderActivity
                case .runFailed, .runInterrupted:
                    throw TitleGenerationError.providerStopped
                case .sessionStarted, .runStarted, .itemStarted, .itemCompleted,
                     .planUpdated, .nativeProviderEvent:
                    break
                }
            }
            throw TitleGenerationError.providerStopped
        }
        do {
            let response = try await withTaskCancellationHandler {
                _ = try await session.start(
                    CodexCodingRequest(
                        prompt: request.prompt,
                        imagePaths: titleAttachmentPaths(
                            threadID: threadID,
                            attachments: request.attachments
                        ),
                        outputJSONSchema: DesktopConversationTitleGeneration.responseJSONSchema,
                        model: "gpt-5.6-luna",
                        reasoningEffort: "low",
                        sandbox: .readOnly,
                        networkAccess: false,
                        approvalPolicy: .never,
                        runtimeAuthority: .workflowApprovalRequired
                    )
                )
                return try await collector.value
            } onCancel: {
                collector.cancel()
                _Concurrency.Task {
                    try? await session.interrupt()
                    await session.close()
                }
            }
            await session.close()
            guard let title = DesktopConversationTitleGeneration.decodedTitle(from: response) else {
                throw TitleGenerationError.malformedResponse
            }
            return title
        } catch {
            collector.cancel()
            await session.close()
            throw error
        }
    }

    private func titleAttachmentPaths(
        threadID: String,
        attachments: [ConversationImageAttachment]
    ) -> [String] {
        let store = KanameConversationAttachmentStore(rootDirectory: serviceStore.rootDirectory)
        return attachments.compactMap { attachment in
            try? store.attachmentURL(threadID: threadID, attachment: attachment).path
        }
    }

    private func providerPrompt(
        thread: DesktopThread,
        userMessage: String,
        includeProjectContext: Bool,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool,
        purpose: DesktopProviderRunPurpose,
        codingContextSources: [CodingContextSource]
    ) -> String {
        let boundary = authorityBoundary(
            provider: thread.provider,
            runtimeMode: runtimeMode,
            networkAccess: networkAccess
        )
        if purpose == .codingPlan {
            return codingPlanPrompt(
                thread: thread,
                userMessage: userMessage,
                includeProjectContext: includeProjectContext,
                contextSources: codingContextSources
            )
        }
        if purpose == .codingImplementation {
            return implementationPrompt(thread: thread, userMessage: userMessage)
        }
        if purpose == .codingKnowledge {
            return knowledgePrompt(thread: thread)
        }
        guard includeProjectContext else {
            return """
            Respond inside Kaname's unified \(thread.kind.label.lowercased()) conversation.

            Authority boundary: this scheduled turn uses only its frozen prompt and workspace. \(boundary)

            User message:
            \(userMessage)
            """
        }
        let project = model.project(id: thread.projectID)
        let context = project?.context
        let instructions = context?.instructionReferences.joined(separator: ", ") ?? "None selected"
        let knowledge = context?.knowledgeSourceIDs.joined(separator: ", ") ?? "None selected"
        let skills = context?.skillIDs.joined(separator: ", ") ?? "None selected"
        let loadedSkills = skillContextSources(for: thread, userMessage: userMessage)
        let skillSection = loadedSkills.isEmpty
            ? "No skill bodies were loaded for this turn."
            : loadedSkills.map { "SKILL \($0.title) (\($0.path))" }.joined(separator: "\n")
        return """
        Respond inside Kaname's unified \(thread.kind.label.lowercased()) conversation.
        Project: \(project?.name ?? "Standalone")
        Selected instruction references: \(instructions)
        Selected knowledge sources: \(knowledge)
        Selected skills and tools: \(skills)

        Loaded skill bodies:
        \(skillSection)

        Authority boundary: \(boundary)

        User message:
        \(userMessage)
        """
    }

    private func codingPlanPrompt(
        thread: DesktopThread,
        userMessage: String,
        includeProjectContext: Bool,
        contextSources: [CodingContextSource]
    ) -> String {
        let project = includeProjectContext ? model.project(id: thread.projectID) : nil
        let instructions = project?.context.instructionReferences.joined(separator: ", ") ?? "None selected"
        let knowledge = project?.context.knowledgeSourceIDs.joined(separator: ", ") ?? "None selected"
        let skills = project?.context.skillIDs.joined(separator: ", ") ?? "None selected"
        let loadedSkills = skillContextSources(for: thread, userMessage: userMessage)
        let frozenContext = CodingWorkspaceInspector.providerPrompt(
            task: userMessage,
            selectedSources: contextSources,
            selectedMatches: [],
            mode: "DISCUSS AND PLAN ONLY",
            skillSources: loadedSkills
        )
        let planMechanism: String = switch thread.provider.lowercased() {
        case "codex":
            "Use the structured plan-update mechanism so every step appears in Kaname's Plan tab."
        case "claude":
            "Call the kaname plan_update tool with the full step list whenever the plan changes, and also finish your reply with the complete plan as Markdown under a '## Plan' heading. If plan mode offers a plan file, write the same plan there. Do not search for TodoWrite or ExitPlanMode."
        default:
            "Finish your reply with the complete plan as Markdown under a '## Plan' heading using a numbered list of steps."
        }
        let currentPlan = thread.plan.isEmpty
            ? "No plan yet. Discuss the idea with the user and draft the first version."
            : "This is a revision. Take the user's message as feedback on the current plan below, then re-emit the whole revised plan, not just the changed steps.\n\nCurrent plan:\n"
                + thread.plan.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        return """
        Kaname Coding stage: DISCUSS AND PLAN ONLY.

        You are in an ongoing planning conversation. Inspect the selected repository read-only as needed, answer the user, and keep one concrete implementation plan up to date. \(planMechanism) The plan steps must describe future implementation work, not the planning work you are doing, and stay pending. Do not edit files, create commits, run destructive commands, access the network, or begin implementation. Nothing is implemented until the user explicitly approves the plan in Kaname. If you investigated or debugged anything, end your reply with a '## Findings' section: one bullet per finding stating what you checked, what you observed, and what you concluded. When Kaname tools are available (MCP server `kaname`), use them: plan_update to keep the plan current (send the whole plan), finding_record for each finding, knowledge_search and knowledge_read for the user's notes, knowledge_propose to suggest a note update. Fall back to the Markdown sections only if the tools are absent.

        \(currentPlan)

        Project: \(project?.name ?? "Standalone")
        Selected instruction references: \(instructions)
        Selected knowledge sources: \(knowledge)
        Selected skills and tools: \(skills)
        Authority boundary: read-only workspace, network disabled, no implementation authority.

        Exact digest-bound context snapshot and user request:
        \(frozenContext)
        """
    }

    /// Runs one read-only provider turn that asks for the durable knowledge
    /// update through the Bridge. Safe to call again from the Knowledge tab.
    func runKnowledgeTurn(threadID: String) {
        guard !codingWorkflowBusyThreadIDs.contains(threadID),
              let thread = model.thread(id: threadID),
              thread.kind == .coding,
              model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge,
              !model.providerRuns(threadID: threadID).contains(where: { $0.state == .running || $0.state == .proposed }),
              let worktree = latestCodingWorktree(threadID: threadID),
              let sourceMessageID = thread.messages.last(where: { $0.role == .user })?.id else { return }
        codingWorkflowErrors.removeValue(forKey: threadID)
        guard let runID = model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            usesProjectContext: true,
            workspacePathOverride: worktree.worktreePath,
            purpose: .codingKnowledge,
            runtimeModeOverride: .approvalRequired,
            networkAccessOverride: false
        ) else { return }
        pollCandidateThreadIDs.insert(threadID)
        submit(runID: runID)
    }

    private func knowledgePrompt(thread: DesktopThread) -> String {
        let project = model.project(id: thread.projectID)
        let plan = thread.plan.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let findings = (thread.findings ?? []).map { "- \($0.detail)" }.joined(separator: "\n")
        let evidence = thread.evidence.map { "- \($0.label): \($0.state.rawValue)" }.joined(separator: "\n")
        let request = thread.messages.first(where: { $0.role == .user })?.body ?? ""
        let writable = model.snapshot.operations.vaultScopes.filter(\.canWrite).map(\.path)
        let readable = model.snapshot.operations.vaultScopes.filter(\.canRead).map(\.path)
        let projectName = project?.name ?? "this project"
        let suggestedPath = writable.first.map { "\($0.hasSuffix("/") ? String($0.dropLast()) : $0)/\(projectName).md" } ?? "(no writable scope granted)"
        return """
        Kaname Coding stage: KNOWLEDGE UPDATE (read-only).

        The implementation below was accepted. Your job now is to keep the user's Obsidian notes current. Do not edit repository files. Use the kaname MCP tools:
        1. knowledge_search and knowledge_read to look at the existing notes in the readable scopes (\(readable.joined(separator: ", "))) and avoid duplicating what is already written.
        2. knowledge_propose with the FULL updated content of each note that should change. Preferred project note: \(suggestedPath). Writable scopes: \(writable.joined(separator: ", ")). If a general, reusable lesson came out of this work (language, platform, tooling), propose a second note for it under the writable scope.
        3. Keep notes as curated current truth: decisions, constraints, gotchas, how things work now. Not a chat log. Preserve existing frontmatter and sections you are not changing.
        If nothing durable was learned, say so in one sentence and propose nothing.

        Project: \(projectName)
        Original request:
        \(request)

        Approved plan:
        \(plan)

        Findings:
        \(findings.isEmpty ? "(none recorded)" : findings)

        Evidence:
        \(evidence.isEmpty ? "(none recorded)" : evidence)
        """
    }

    private func implementationPrompt(thread: DesktopThread, userMessage: String) -> String {
        let plan = thread.plan.enumerated().map { index, item in
            "\(index + 1). \(item.title)"
        }.joined(separator: "\n")
        let project = model.project(id: thread.projectID)
        return """
        Kaname Coding stage: APPROVED ISOLATED IMPLEMENTATION.

        Implement the approved plan below inside the selected linked Git worktree, following the user's latest message. This is an ongoing conversation: the user may send follow-up instructions and you continue in the same worktree. Do not write outside the worktree. Run the relevant local verification, report changed files and anything not run, and do not commit, push, publish, or merge. Provider completion is never acceptance; the user reviews Changes and Evidence in Kaname. If you investigated or debugged anything, end your reply with a '## Findings' section: one bullet per finding stating what you checked, what you observed, and what you concluded. When Kaname tools are available (MCP server `kaname`), use them: plan_update to keep the plan current (send the whole plan), finding_record for each finding, knowledge_search and knowledge_read for the user's notes, knowledge_propose to suggest a note update. Fall back to the Markdown sections only if the tools are absent.

        Project: \(project?.name ?? "Standalone")
        User message:
        \(userMessage)

        Approved plan:
        \(plan)
        """
    }

    private func latestCodingWorktree(threadID: String) -> DesktopWorktreeRecord? {
        model.snapshot.operations.worktrees
            .filter { $0.threadID == threadID && $0.state != .removed }
            .max { $0.updatedAtUnixMillis < $1.updatedAtUnixMillis }
    }

    private func recordImplementationCheckpointBefore(
        runID: String,
        threadID: String,
        worktree: DesktopWorktreeRecord,
        workspace: URL
    ) async -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            let before = try await gitControl.createCheckpointBefore(
                worktree: workspace,
                threadID: threadID,
                turnID: runID
            )
            model.upsertCodingCheckpoint(DesktopCodingCheckpointRecord.make(
                id: "checkpoint-\(runID)",
                threadID: threadID,
                worktreeID: worktree.id,
                turnID: runID,
                beforeRef: before.ref,
                beforeHeadRevision: before.headRevision,
                beforeIndexTree: before.indexTree,
                beforeWorktreeTree: before.worktreeTree,
                beforeFingerprint: before.fingerprint,
                createdAtUnixMillis: now
            ))
            guard model.persistenceError == nil else {
                codingWorkflowErrors[threadID] = "Kaname could not persist the exact pre-turn Git checkpoint."
                return false
            }
            return true
        } catch {
            codingWorkflowErrors[threadID] = error.localizedDescription
            return false
        }
    }

    private func scheduleImplementationCheckpointAfter(runID: String, threadID: String) {
        guard checkpointFinalizationRunIDs.insert(runID).inserted else { return }
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { checkpointFinalizationRunIDs.remove(runID) }
            await finalizeImplementationCheckpointAfter(runID: runID, threadID: threadID)
        }
    }

    private func finalizeImplementationCheckpointAfter(runID: String, threadID: String) async {
        guard let checkpoint = model.snapshot.operations.codingCheckpoints.first(where: {
            $0.turnID == runID && $0.threadID == threadID
        }),
              let worktree = model.snapshot.operations.worktrees.first(where: {
                  $0.id == checkpoint.worktreeID && $0.threadID == threadID && $0.state != .removed
              }) else { return }
        let workspace = URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
        guard let beforeHeadRevision = checkpoint.beforeHeadRevision,
              let beforeIndexTree = checkpoint.beforeIndexTree,
              let beforeWorktreeTree = checkpoint.beforeWorktreeTree,
              let beforeFingerprint = checkpoint.beforeFingerprint else {
            codingWorkflowErrors[threadID] = "This legacy checkpoint lacks exact Git state metadata; start a fresh implementation turn."
            return
        }
        do {
            let after = try await gitControl.createCheckpointAfter(
                worktree: workspace,
                threadID: threadID,
                turnID: runID,
                before: GitCheckpointSnapshot.captured(
                    ref: checkpoint.beforeRef,
                    headRevision: beforeHeadRevision,
                    indexTree: beforeIndexTree,
                    worktreeTree: beforeWorktreeTree,
                    fingerprint: beforeFingerprint
                )
            )
            var updated = checkpoint
            updated.afterRef = after.after.ref
            updated.afterHeadRevision = after.after.headRevision
            updated.afterIndexTree = after.after.indexTree
            updated.afterWorktreeTree = after.after.worktreeTree
            updated.afterFingerprint = after.after.fingerprint
            updated.diffStat = after.diffStat
            updated.diffSummary = after.diffSummary
            model.upsertCodingCheckpoint(updated)
            let inspected = try await gitControl.inspect(worktree: workspace)
            model.updateWorktree(
                id: worktree.id,
                headRevision: inspected.headRevision,
                changedFileCount: inspected.changedFiles.count,
                diffSummary: after.diffStat.isEmpty ? inspected.diffSummary : after.diffStat,
                state: .dirty
            )
        } catch {
            codingWorkflowErrors[threadID] = error.localizedDescription
        }
    }

    private func knowledgeSourceID(
        for source: CodingContextSource,
        project: DesktopProject?
    ) -> String {
        if source.kind == .obsidian,
           let sourceID = project?.context.knowledgeSourceIDs.compactMap({ selectedID in
               model.snapshot.domains.knowledgeSources.first(where: {
                   $0.id == selectedID && $0.kind == .obsidian && $0.scope == source.path
               })?.id
           }).first {
            return sourceID
        }
        return "\(source.kind.rawValue):\(source.path)"
    }

    private func knowledgeProvenance(for source: CodingContextSource) -> String {
        switch source.kind {
        case .obsidian: "Obsidian CLI · selected vault note · bounded SHA-256 excerpt"
        case .repositoryInstructions: "Selected worktree · repository instructions"
        case .repositoryKnowledge: "Selected worktree · repository knowledge"
        case .searchResult: "Selected worktree · bounded local search"
        case .skill: "Selected skill · bounded SKILL.md excerpt"
        case .terminal: "Coding terminal · bounded untrusted scrollback excerpt"
        }
    }

    private func skillContextSources(for thread: DesktopThread, userMessage: String) -> [CodingContextSource] {
        let project = model.project(id: thread.projectID)
        let workspaceRoot = project?.path.flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        let registry = SkillRegistryLoader.loadRegistry(workspaceRoot: workspaceRoot)
        let inlineRegistryNames = DesktopComposerSkillPicker.selectedSkillNames(in: userMessage) { token in
            SkillRegistryLoader.resolveExactName(token, in: registry)?.name
        }
        let catalogRegistryNames = Dictionary(
            uniqueKeysWithValues: model.snapshot.domains.skills.compactMap { skill in
                skill.registryName.map { (skill.id, $0) }
            }
        )
        return SkillRegistryLoader.loadContextSources(
            registryNames: inlineRegistryNames,
            catalogIDs: project?.context.skillIDs ?? [],
            catalogRegistryNamesByID: catalogRegistryNames,
            workspaceRoot: workspaceRoot,
            registry: registry
        )
    }

    private func collectCodingEvidence(threadID: String, worktreeID: String, workspace: URL) {
        codingWorkflowBusyThreadIDs.insert(threadID)
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { codingWorkflowBusyThreadIDs.remove(threadID) }
            do {
                let verification = Self.detectVerificationCommand(workspace: workspace)
                let evidence = try await CodingWorkspaceInspector.collectEvidence(
                    workspaceURL: workspace,
                    verificationExecutable: verification?.executable,
                    verificationArguments: verification?.arguments ?? []
                )
                guard persistCodingEvidence(evidence, threadID: threadID, worktreeID: worktreeID) else {
                    throw CodingWorkspaceInspectorError.unavailable(
                        "Kaname could not persist the exact evidence receipt."
                    )
                }
            } catch {
                codingWorkflowErrors[threadID] = "Evidence collection failed: \(error.localizedDescription)"
                _ = model.updateCodingWorkflow(
                    threadID: threadID,
                    state: .awaitingReview,
                    reason: "Independent evidence collection failed and can be retried."
                )
                model.setAttention(threadID: threadID, attention: .needsApproval)
            }
        }
    }

    @discardableResult
    private func persistCodingEvidence(
        _ evidence: CodingEvidenceSnapshot,
        threadID: String,
        worktreeID: String
    ) -> Bool {
        guard model.recordCodingEvidence(
            threadID: threadID,
            worktreeID: worktreeID,
            revision: evidence.revision,
            diffStat: evidence.diffStat,
            diffCheckPassed: evidence.diffCheckPassed,
            verificationCommand: evidence.verificationCommand,
            verificationExitStatus: evidence.verificationExitStatus,
            verificationOutput: evidence.verificationOutput,
            artifactPaths: evidence.artifactPaths,
            digest: evidence.digest,
            verificationWasRun: evidence.verificationWasRun
        ) else { return false }
        _ = model.addCodingKnowledgeCandidate(
            threadID: threadID,
            category: .implementation,
            title: "Implementation evidence",
            detail: KanameTextBounds.utf8Prefix([
                evidence.diffStat.isEmpty ? "No diff summary was reported." : evidence.diffStat,
                "Changed paths: \(evidence.artifactPaths.joined(separator: ", "))",
                "Verification: \(evidence.verificationCommand) exited \(evidence.verificationExitStatus)",
            ].joined(separator: "\n"), maximumBytes: 8 * 1_024),
            evidenceDigest: evidence.digest
        )
        return true
    }

    private func resolvedModel(provider: String, value: String) -> String {
        guard value == "Use provider default" else { return value }
        return provider.caseInsensitiveCompare("Codex") == .orderedSame ? "gpt-5.6-sol" : value
    }

    private func authorityBoundary(
        provider: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> String {
        let network = provider.caseInsensitiveCompare("Codex") == .orderedSame
            ? (networkAccess ? "Network access is enabled." : "Network access is disabled.")
            : "Network access follows \(provider)'s native tool policy."
        switch runtimeMode {
        case .approvalRequired:
            return "Work read-only and ask before any action requiring broader authority. \(network)"
        case .autoAcceptEdits:
            return "Workspace edits are allowed; ask before commands or broader actions. \(network)"
        case .auto:
            return "Routine workspace actions may proceed automatically; escalate risky actions for review. \(network)"
        case .fullAccess:
            return "Full local command and file authority is enabled without approval prompts. Network access is enabled."
        }
    }

    private func providerEventRecord(
        _ event: CodexRunEvent,
        id: String,
        threadID: String,
        runID: String,
        createdAtUnixMillis: Int64
    ) -> DesktopProviderEventRecord {
        let provider = providerName(runID: runID)
        let presentation = Self.presentation(
            for: event,
            provider: provider,
            purpose: model.providerRun(id: runID)?.purpose ?? .conversation
        )
        let payloadObject = event.payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let enriched = Self.enrichedPresentation(for: event, payload: payloadObject, fallback: presentation)
        // Raw provider evidence is sealed separately by the worker. The
        // workspace keeps full bytes only for answerable questions, and a
        // bounded excerpt for tool calls so the Processes tab and Timeline
        // can show what ran and what came back.
        let retainedPayload: Data? = switch event.kind {
        case .questionRequested: event.payload
        case .toolActivity: Self.compactToolPayload(event: event, payload: payloadObject)
        default: nil
        }
        return DesktopProviderEventRecord(
            id: id,
            threadID: threadID,
            runID: runID,
            turnID: model.providerRun(id: runID)?.turnID,
            kind: enriched.kind,
            title: enriched.title,
            detail: String(enriched.detail.prefix(65_536)),
            nativeType: event.nativeType,
            nativeThreadID: event.threadID,
            nativeTurnID: event.turnID,
            approvalID: event.approvalID,
            toolObservation: event.toolObservation,
            agentActivity: event.agentActivity,
            rawPayloadBase64: retainedPayload?.base64EncodedString(),
            payloadWasTruncated: event.payloadWasTruncated,
            createdAtUnixMillis: createdAtUnixMillis
        )
    }

    // MARK: Event enrichment

    private static let toolPayloadTextLimit = 4_000

    /// Finds the Claude content block for this call (tool_use by `id`,
    /// tool_result by `tool_use_id`) anywhere in the payload.
    private static func claudeBlock(callID: String, in payload: Any?) -> [String: Any]? {
        func search(_ value: Any) -> [String: Any]? {
            if let dictionary = value as? [String: Any] {
                if (dictionary["id"] as? String) == callID || (dictionary["tool_use_id"] as? String) == callID {
                    return dictionary
                }
                for child in dictionary.values { if let found = search(child) { return found } }
            } else if let array = value as? [Any] {
                for child in array { if let found = search(child) { return found } }
            }
            return nil
        }
        return payload.flatMap(search)
    }

    private static func boundedText(_ value: Any?, limit: Int = toolPayloadTextLimit) -> String? {
        switch value {
        case let text as String: return String(text.prefix(limit))
        case let parts as [[String: Any]]:
            let joined = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return joined.isEmpty ? nil : String(joined.prefix(limit))
        case let parts as [Any]:
            let joined = parts.compactMap { $0 as? String }.joined(separator: " ")
            return joined.isEmpty ? nil : String(joined.prefix(limit))
        default: return nil
        }
    }

    /// A small payload that keeps only what the UI needs for one tool call.
    private static func compactToolPayload(event: CodexRunEvent, payload: [String: Any]?) -> Data? {
        guard let payload, let callID = event.toolObservation?.callID else { return nil }
        var compact: [String: Any] = [:]
        if var block = claudeBlock(callID: callID, in: payload) {
            if let content = block["content"] { block["content"] = boundedText(content) ?? "" }
            if var input = block["input"] as? [String: Any] {
                for (key, value) in input {
                    if let text = value as? String, text.count > toolPayloadTextLimit {
                        input[key] = String(text.prefix(toolPayloadTextLimit))
                    }
                }
                block["input"] = input
            }
            compact["message"] = ["content": [block]]
        }
        if var item = payload["item"] as? [String: Any] {
            for key in ["aggregatedOutput", "aggregated_output", "output"] {
                if let text = item[key] as? String { item[key] = String(text.prefix(toolPayloadTextLimit)) }
            }
            item.removeValue(forKey: "changes")
            compact["item"] = item
        }
        if let delta = payload["delta"] as? String { compact["delta"] = String(delta.prefix(toolPayloadTextLimit)) }
        guard !compact.isEmpty, JSONSerialization.isValidJSONObject(compact) else { return nil }
        return try? JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys])
    }

    private static func firstLine(_ text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Replaces generic titles such as "Provider event stream_event" with what
    /// actually happened, using the native payload when one is available.
    private static func enrichedPresentation(
        for event: CodexRunEvent,
        payload: [String: Any]?,
        fallback: (kind: DesktopProviderEventKind, title: String, detail: String)
    ) -> (kind: DesktopProviderEventKind, title: String, detail: String) {
        switch event.kind {
        case .toolActivity:
            guard let observation = event.toolObservation else { return fallback }
            let name = observation.name ?? observation.kind.rawValue
            var title = name
            var detail = fallback.detail
            if let block = claudeBlock(callID: observation.callID, in: payload) {
                if let input = block["input"] as? [String: Any] {
                    if let command = boundedText(input["command"]) {
                        title = "$ \(firstLine(command))"
                        detail = [input["description"] as? String, command.contains("\n") ? command : nil]
                            .compactMap { $0 }.joined(separator: "\n")
                    } else if let path = input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String {
                        title = "\(name) \(path)"
                        detail = (input["pattern"] as? String).map { "pattern \($0)" } ?? ""
                    } else if let pattern = input["pattern"] as? String {
                        title = "\(name) \(pattern)"
                        detail = (input["glob"] as? String) ?? ""
                    } else if let url = input["url"] as? String {
                        title = "\(name) \(url)"
                    } else if let description = input["description"] as? String ?? input["prompt"] as? String {
                        title = name
                        detail = firstLine(description, limit: 400)
                    } else if let query = input["query"] as? String {
                        title = "\(name) \(query)"
                    } else if !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
                        detail = String(decoding: data.prefix(400), as: UTF8.self)
                    }
                    if detail.isEmpty { detail = "started" }
                } else if block["tool_use_id"] != nil {
                    let failed = block["is_error"] as? Bool == true
                    let output = boundedText(block["content"], limit: 600) ?? ""
                    title = "\(name) \(failed ? "failed" : "finished")"
                    detail = output.isEmpty ? (failed ? "error" : "no output") : output
                }
            } else if let item = payload?["item"] as? [String: Any] {
                if let command = boundedText(item["command"]) {
                    title = "$ \(firstLine(command))"
                    let output = boundedText(item["aggregatedOutput"] ?? item["aggregated_output"], limit: 600) ?? ""
                    let exit = (item["exitCode"] as? Int) ?? (item["exit_code"] as? Int)
                    detail = [exit.map { "exit \($0)" }, output.isEmpty ? nil : output].compactMap { $0 }.joined(separator: "\n")
                    if detail.isEmpty { detail = observation.state.rawValue }
                } else if let path = item["path"] as? String ?? item["file"] as? String {
                    title = "\(name) \(path)"
                } else {
                    detail = "\(observation.state.rawValue) · \(event.nativeType)"
                }
            } else if let agent = event.agentActivity {
                title = "Subagent \(agent.activity.rawValue)"
                detail = agent.agentPath ?? agent.taskType ?? event.nativeType
            } else {
                detail = "\(observation.state.rawValue) · \(event.nativeType)"
            }
            return (.tool, title, detail)
        case .nativeProviderEvent:
            let type = event.nativeType
            switch type {
            case "system":
                var parts: [String] = []
                if let model = payload?["model"] as? String { parts.append(model) }
                if let mode = payload?["permissionMode"] as? String { parts.append("mode \(mode)") }
                if let tools = payload?["tools"] as? [Any] { parts.append("\(tools.count) tools") }
                if let cwd = payload?["cwd"] as? String { parts.append("cwd \(cwd)") }
                return (.status, "Session started", parts.isEmpty ? "Provider session initialised." : parts.joined(separator: " · "))
            case "result":
                var parts: [String] = []
                if let cost = payload?["total_cost_usd"] as? Double { parts.append(String(format: "$%.3f", cost)) }
                if let duration = payload?["duration_ms"] as? Int { parts.append("\(duration / 1_000)s") }
                if let turns = payload?["num_turns"] as? Int { parts.append("\(turns) turns") }
                if let subtype = payload?["subtype"] as? String, subtype != "success" { parts.append(subtype) }
                return (.usage, "Turn result", parts.isEmpty ? fallback.detail : parts.joined(separator: " · "))
            case "stream_event":
                let inner = payload?["event"] as? [String: Any]
                let innerType = inner?["type"] as? String ?? "delta"
                let deltaType = (inner?["delta"] as? [String: Any])?["type"] as? String
                return (.native, "Stream", [innerType, deltaType].compactMap { $0 }.joined(separator: " · "))
            case "rate_limit_event":
                return (.status, "Rate limit", boundedText(payload?["rate_limit_info"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }, limit: 300) ?? fallback.detail)
            case "user":
                return (.native, "Tool results delivered", "Provider received tool output.")
            case "kaname/finding":
                return (.reasoning, "Finding recorded", firstLine(event.text ?? "", limit: 200))
            case "kaname/knowledge_proposal":
                return (.status, "Note update proposed", event.text ?? "")
            case "kaname/knowledge_read":
                return (.status, "Read note", event.text ?? "")
            case "kaname/bridge-unavailable":
                return (.error, "Kaname Bridge unavailable", event.text ?? "")
            default:
                return fallback
            }
        case .messageDelta:
            return (.assistantText, "Response", firstLine(event.text ?? "", limit: 120))
        default:
            if let text = event.text, !text.isEmpty, event.kind != .planUpdated {
                return (fallback.kind, fallback.title, text)
            }
            return fallback
        }
    }

    private static func presentation(
        for event: CodexRunEvent,
        provider: String,
        purpose: DesktopProviderRunPurpose
    ) -> (
        kind: DesktopProviderEventKind,
        title: String,
        detail: String
    ) {
        switch event.kind {
        case .sessionStarted: (.status, "Provider connected", "A private \(provider) session is attached to this conversation.")
        case .runStarted: (.status, "Turn started", "\(provider) is working in the selected read-only context.")
        case .providerCompleted:
            switch purpose {
            case .codingPlan:
                (.status, "Plan ready", "Review the structured Plan tab. No implementation authority has been granted.")
            case .codingImplementation:
                (.status, "Implementation turn complete", "Kaname is collecting independent evidence before asking you to accept or reject the result.")
            case .codingKnowledge:
                (.status, "Knowledge draft ready", "Review the proposed notes in the Knowledge tab; nothing is written until you approve.")
            case .conversation:
                (.status, "Turn complete", "The provider completed; the response is ready for you.")
            }
        case .runInterrupted: (.error, "Turn interrupted", "Retry when you are ready.")
        case .runFailed: (.error, "Provider stopped", "Inspect the failure and retry without duplicating the message.")
        case .messageDelta: (.assistantText, "Response", "Streaming assistant text")
        case .planUpdated: (.reasoning, "Plan updated", "The provider updated its working plan.")
        case .toolActivity:
            if let activity = event.agentActivity {
                (
                    .tool,
                    "Subagent \(activity.activity.rawValue)",
                    activity.agentPath ?? activity.taskType ?? event.nativeType
                )
            } else if let tool = event.toolObservation {
                (
                    .tool,
                    tool.name ?? tool.kind.rawValue,
                    "\(tool.state.rawValue) · \(event.nativeType)"
                )
            } else {
                (.tool, "Tool activity", event.nativeType)
            }
        case .diffUpdated: (.diff, "Diff updated", "A file-change proposal was observed; no write authority was granted.")
        case .approvalRequested: (.approval, "Approval requested", "Kaname declined the provider request because this turn has no durable write grant.")
        case .approvalAccepted: (.approval, "Approval accepted", "A durable approval was applied.")
        case .approvalRejected: (.approval, "Approval declined", "No additional authority was granted.")
        case .questionRequested: (.question, "\(provider) has a question", "Answer to continue this turn.")
        case .questionAnswered: (.question, "Question answered", "The bounded answer was returned without persisting its text in the event journal.")
        case .itemStarted: (.native, "Item started", event.nativeType)
        case .itemCompleted: (.native, "Item completed", event.nativeType)
        case .nativeProviderEvent: (.native, "Provider event", event.nativeType)
        }
    }

    private func tokenUsage(from payload: Data?) -> Int? {
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return Self.findTokenUsage(in: object)
    }

    private func registerServiceEvidence(threadID: String, runID: String) -> Bool {
        guard let url = try? serviceStore.evidenceURL(threadID: threadID, runID: runID),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return true }
        guard !model.snapshot.operations.artifacts.contains(where: { $0.localPath == url.path }) else { return true }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifactID = model.registerArtifact(
            threadID: threadID,
            name: "Provider event evidence",
            kind: .log,
            localPath: url.path,
            digest: digest,
            provenance: "Signed Kaname conversation worker"
        )
        return artifactID != nil && model.persistenceError == nil
    }

    private static func findTokenUsage(in value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            for key in ["totalTokens", "total_tokens", "totalTokenCount"] {
                if let count = dictionary[key] as? Int { return count }
            }
            for child in dictionary.values {
                if let count = findTokenUsage(in: child) { return count }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let count = findTokenUsage(in: child) { return count }
            }
        }
        return nil
    }

    private static func questionIDs(from rawPayloadBase64: String?) -> [String] {
        guard let rawPayloadBase64,
              let data = Data(base64Encoded: rawPayloadBase64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questions = object["questions"] as? [[String: Any]] else { return [] }
        return questions.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Whichever provider the user selected for the thread plans and implements.
    /// The only requirement is that Kaname has a conversation adapter for it.
    static func supportsIsolatedImplementation(provider: String) -> Bool {
        provider.caseInsensitiveCompare("Codex") == .orderedSame
            || NativeConversationDriver(providerName: provider) != nil
    }

    /// Codex enforces the write boundary through its sandbox grant, so it keeps
    /// accept-edits semantics. Claude and OpenCode run non-interactively inside
    /// the isolated worktree, where prompts cannot be answered, so they use the
    /// provider's auto mode instead of stalling on every shell command.
    static func implementationRuntimeMode(provider: String) -> ConversationRuntimeMode {
        provider.lowercased() == "codex" ? .autoAcceptEdits : .auto
    }

    /// Picks the project's test command: a `kaname.json` script of kind
    /// `tests` first, then common ecosystem conventions. `nil` means no test
    /// runner exists and verification is reported as not run.
    static func detectVerificationCommand(workspace: URL) -> (executable: String, arguments: [String])? {
        if let manifest = try? KanameProjectScriptsManifestLoader.load(fromProjectRoot: workspace),
           let script = manifest.scripts.first(where: { $0.kind == .tests }) {
            return ("/bin/sh", ["-lc", script.command])
        }
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: workspace.appending(path: name).path) }
        func contains(_ name: String, _ needle: String) -> Bool {
            guard let data = fileManager.contents(atPath: workspace.appending(path: name).path),
                  data.count < 2 * 1_024 * 1_024 else { return false }
            return String(decoding: data, as: UTF8.self).contains(needle)
        }
        if exists("package.json"), contains("package.json", "\"test\"") {
            if exists("pnpm-lock.yaml") { return ("pnpm", ["test"]) }
            if exists("bun.lockb") || exists("bun.lock") { return ("bun", ["test"]) }
            if exists("yarn.lock") { return ("yarn", ["test"]) }
            return ("npm", ["test"])
        }
        if exists("Cargo.toml") { return ("cargo", ["test"]) }
        if exists("Package.swift") { return ("swift", ["test"]) }
        if exists("go.mod") { return ("go", ["test", "./..."]) }
        if exists("pytest.ini") || exists("pyproject.toml") && contains("pyproject.toml", "pytest") {
            return ("pytest", [])
        }
        if exists("Makefile"), contains("Makefile", "\ntest:") { return ("make", ["test"]) }
        return nil
    }

    static func supportsImageAttachments(provider: String) -> Bool {
        ["codex", "claude", "opencode", "open code", "cursor", "grok"].contains(provider.lowercased())
    }

    private func prepareStandaloneWorkspace() throws -> URL {
        let directory = environment.standaloneWorkspaceDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }
}
