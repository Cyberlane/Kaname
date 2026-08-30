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
    private lazy var gitControl = DesktopGitControlService(managedRoot: environment.worktreeDirectory)

    init(model: DesktopAppModel, environment: KanameDesktopEnvironment = .current) {
        self.model = model
        self.environment = environment
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
        resumePrepared(runID: runID)
        return runID
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
        if thread.kind == .coding,
           [.planning, .preparing, .implementing, .implementationReview, .evidenceReview, .knowledgeReview]
            .contains(codingStage(threadID: threadID)) {
            codingWorkflowErrors[threadID] = "Finish the current Coding stage before starting another plan."
            return nil
        }
        let purpose: DesktopProviderRunPurpose = thread.kind == .coding ? .codingPlan : .conversation
        guard let messageID = model.appendUserMessage(threadID: threadID, body: body, attachments: attachments),
              let runID = model.enqueueProviderRun(
                threadID: threadID,
                sourceMessageID: messageID,
                usesProjectContext: usesProjectContext,
                workspacePathOverride: workspacePathOverride,
                purpose: purpose,
                runtimeModeOverride: purpose == .codingPlan ? .approvalRequired : nil,
                networkAccessOverride: purpose == .codingPlan ? false : nil
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
            return active.purpose == .codingImplementation ? .implementing : .planning
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
                case .dirty: return .rejected
                case .failed: return .failed
                case .ready: return .implementationReview
                default: return .preparing
                }
            }
        }
        if worktree?.state == .accepted { return .completed }
        if worktree?.state == .review { return .evidenceReview }
        if worktree?.state == .dirty { return .rejected }
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
              thread.provider.caseInsensitiveCompare("Codex") == .orderedSame,
              !thread.plan.isEmpty,
              let projectID = thread.projectID,
              let root = model.workspaceURL(threadID: threadID),
              let sourceMessageID = model.providerRuns(threadID: threadID).last(where: {
                  $0.purpose == .codingPlan && $0.state == .completed
              })?.sourceMessageID,
              let sourceMessage = model.message(threadID: threadID, id: sourceMessageID),
              let runner = LocalCoreRunner.bundled() else {
            codingWorkflowErrors[threadID] = "Coding implementation requires a Codex project conversation with a valid repository and the signed local journal service."
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
                    consequence: "Create branch \(branch) from \(rootSnapshot.head), then allow one network-denied Codex implementation turn only inside that isolated worktree. Approved plan digest: \(CodingWorkspaceInspector.digest(Data(planText.utf8))).",
                    dataLeavingDevice: "The approved prompt is sent to Codex; network tools remain disabled.",
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
                    runtimeModeOverride: .autoAcceptEdits,
                    networkAccessOverride: false
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
              worktree.state == .ready,
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
                let evidence = try await CodingWorkspaceInspector.collectEvidence(
                    workspaceURL: URL(fileURLWithPath: worktree.worktreePath, isDirectory: true)
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
            resumableNativeThreadID: model.latestNativeThreadID(threadID: threadID, provider: run.provider),
            localCoreMachService: machService,
            localCoreRequirement: requirement,
            workspaceAuthorization: authorization,
            isCodingPlan: run.purpose == .codingPlan,
            curatedPreviewMCPGranted: previewGrant && run.purpose == .codingImplementation,
            createdAtUnixMillis: run.startedAtUnixMillis
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
            if completedRun?.purpose == .codingPlan,
               model.thread(id: serviceEvent.threadID)?.plan.isEmpty == true,
               let fallback = model.thread(id: serviceEvent.threadID)?.messages.last(where: { $0.role == .assistant })?.body,
               !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.addProviderPlan(threadID: serviceEvent.threadID, text: fallback, completed: true)
                guard model.persistenceError == nil else { return false }
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
        return """
        Kaname Coding stage: DISCUSS AND PLAN ONLY.

        Inspect the selected repository read-only as needed, then propose a concrete implementation plan. Use the provider's structured plan-update mechanism so every step appears in Kaname's Plan tab. The structured entries must describe future implementation work, not the planning work you are doing, and should remain pending. Do not edit files, create commits, run destructive commands, access the network, or begin implementation. End after the plan and wait for explicit user approval.

        Project: \(project?.name ?? "Standalone")
        Selected instruction references: \(instructions)
        Selected knowledge sources: \(knowledge)
        Selected skills and tools: \(skills)
        Authority boundary: read-only workspace, network disabled, no implementation authority.

        Exact digest-bound context snapshot and user request:
        \(frozenContext)
        """
    }

    private func implementationPrompt(thread: DesktopThread, userMessage: String) -> String {
        let plan = thread.plan.enumerated().map { index, item in
            "\(index + 1). \(item.title)"
        }.joined(separator: "\n")
        let project = model.project(id: thread.projectID)
        return """
        Kaname Coding stage: APPROVED ISOLATED IMPLEMENTATION.

        Implement only the approved plan below inside the selected linked Git worktree. Do not access the network or write outside the worktree. Run the relevant local verification, report changed files and not-run boundaries, and do not commit, push, publish, merge, or update external knowledge. After this turn Kaname must wait for the user to begin independent review; provider completion is never evidence review, acceptance, or knowledge-update authority.

        Project: \(project?.name ?? "Standalone")
        Original request:
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
                let evidence = try await CodingWorkspaceInspector.collectEvidence(workspaceURL: workspace)
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
            digest: evidence.digest
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
        return DesktopProviderEventRecord(
            id: id,
            threadID: threadID,
            runID: runID,
            turnID: model.providerRun(id: runID)?.turnID,
            kind: presentation.kind,
            title: presentation.title,
            detail: String((event.text ?? presentation.detail).prefix(65_536)),
            nativeType: event.nativeType,
            nativeThreadID: event.threadID,
            nativeTurnID: event.turnID,
            approvalID: event.approvalID,
            toolObservation: event.toolObservation,
            agentActivity: event.agentActivity,
            // Raw provider evidence is sealed separately by the worker. The
            // workspace needs payload bytes only while a question can still be
            // answered after its service event has been acknowledged.
            rawPayloadBase64: event.kind == .questionRequested
                ? event.payload?.base64EncodedString()
                : nil,
            payloadWasTruncated: event.payloadWasTruncated,
            createdAtUnixMillis: createdAtUnixMillis
        )
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
