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

    @Published private(set) var activeThreadIDs: Set<String> = []

    private let model: DesktopAppModel
    private let environment: KanameDesktopEnvironment
    private let serviceStore: KanameConversationServiceStore
    private let pollingPolicy = DesktopConversationPollingPolicy()
    private var pollingTask: _Concurrency.Task<Void, Never>?
    private var orphanChecks: [String: Int] = [:]
    private var titleTasks: [String: _Concurrency.Task<Void, Never>] = [:]
    private var eventIndex: DesktopConversationEventCursorIndex
    private var performanceStore = DesktopConversationPerformanceStore()
    private var providerByRunID: [String: String]
    private var nativeThreadByRunID: [String: String]
    private var nativeTurnByRunID: [String: String]
    private var pollCandidateThreadIDs: Set<String>
    private var runningRunIDByThread: [String: String]
    private var didReconcilePersistedTitles = false

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
        pollCandidateThreadIDs = Set(model.snapshot.operations.providerRuns.compactMap { run in
            guard run.state == .proposed || run.state == .running else { return nil }
            return run.threadID
        })
        runningRunIDByThread = model.snapshot.operations.providerRuns.reduce(into: [:]) { result, run in
            if run.state == .running, let threadID = run.threadID { result[threadID] = run.id }
        }
        serviceStore = KanameConversationServiceStore(
            rootDirectory: environment.applicationSupportRoot.appending(path: "ConversationService", directoryHint: .isDirectory)
        )
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
    func send(threadID: String, body: String) -> Bool {
        enqueue(threadID: threadID, body: body) != nil
    }

    @discardableResult
    func enqueue(threadID: String, body: String) -> String? {
        guard let runID = prepareEnqueue(threadID: threadID, body: body) else { return nil }
        resumePrepared(runID: runID)
        return runID
    }

    func prepareEnqueue(
        threadID: String,
        body: String,
        usesProjectContext: Bool = true,
        workspacePathOverride: String? = nil
    ) -> String? {
        guard let messageID = model.appendUserMessage(threadID: threadID, body: body),
              let runID = model.enqueueProviderRun(
                threadID: threadID,
                sourceMessageID: messageID,
                usesProjectContext: usesProjectContext,
                workspacePathOverride: workspacePathOverride
              ) else { return nil }
        pollCandidateThreadIDs.insert(threadID)
        return runID
    }

    func resumePrepared(runID: String) {
        guard let run = model.providerRun(id: runID), let threadID = run.threadID else { return }
        let events = (try? serviceStore.events(threadID: threadID).filter { $0.runID == runID }) ?? []
        if !events.isEmpty { return }
        let pending = (try? serviceStore.pendingRequests(threadID: threadID).contains { $0.1.runID == runID }) ?? false
        if pending {
            pollCandidateThreadIDs.insert(threadID)
            launchWorkerIfAvailable(threadID: threadID)
            return
        }
        guard run.state == .proposed else { return }
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

    func performanceP95Nanoseconds(for metric: DesktopConversationPerformanceMetric) -> UInt64? {
        performanceStore.p95Nanoseconds(for: metric)
    }

    private func submit(runID: String) {
        guard let run = model.providerRun(id: runID),
              let threadID = run.threadID,
              let sourceMessageID = run.sourceMessageID,
              let message = model.message(threadID: threadID, id: sourceMessageID),
              let thread = model.thread(id: threadID) else {
            return
        }
        providerByRunID[run.id] = run.provider
        pollCandidateThreadIDs.insert(threadID)
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
        guard let machService = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreMachService") as? String,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreServiceRequirement") as? String else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "The signed local journal service is unavailable, so Kaname did not send the message."
            )
            return
        }
        let request = KanameConversationServiceRequest(
            runID: run.id,
            threadID: threadID,
            projectID: thread.projectID ?? "standalone",
            provider: run.provider,
            model: resolvedModel(provider: run.provider, value: run.model),
            reasoningEffort: run.reasoningEffort,
            prompt: providerPrompt(
                thread: thread,
                userMessage: message.body,
                includeProjectContext: run.usesProjectContext ?? true
            ),
            workspacePath: workspace.path,
            providerStatePath: environment.providerStateDirectory.path,
            resumableNativeThreadID: model.latestNativeThreadID(threadID: threadID, provider: run.provider),
            localCoreMachService: machService,
            localCoreRequirement: requirement,
            createdAtUnixMillis: run.startedAtUnixMillis
        )
        do {
            try serviceStore.enqueue(request)
            _ = try KanameConversationWorkerLauncher.launch(
                executableURL: workerExecutableURL(),
                storeRoot: serviceStore.rootDirectory,
                threadID: threadID
            )
            setThreadActive(threadID, active: true)
        } catch {
            model.stopProviderRun(id: run.id, interrupted: false, error: error.localizedDescription)
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
                let alive = serviceStore.isWorkerAlive(threadID: threadID)
                let hasPending = (try? serviceStore.pendingRequests(threadID: threadID).isEmpty == false) ?? false
                if alive || hasPending {
                    setThreadActive(threadID, active: true)
                    orphanChecks[threadID] = 0
                    if hasPending && !alive { launchWorkerIfAvailable(threadID: threadID) }
                } else {
                    setThreadActive(threadID, active: false)
                    reconcileOrphanedRun(threadID: threadID, runningRunID: cycleState.runningRunIDs[threadID])
                    if runningRunIDByThread[threadID] == nil { pollCandidateThreadIDs.remove(threadID) }
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
        if serviceEvent.kind == .serviceStarted {
            if model.providerRun(id: serviceEvent.runID)?.state == .proposed {
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
        if event.kind == .planUpdated, let text = event.text {
            model.addProviderPlan(threadID: serviceEvent.threadID, text: text, completed: false)
            guard model.persistenceError == nil else { return false }
        }
        if event.kind == .toolActivity,
           let text = event.text,
           ["agent", "subagent", "task", "spawn"].contains(where: {
               text.localizedCaseInsensitiveContains($0) || event.nativeType.localizedCaseInsensitiveContains($0)
           }) {
            let terminal = event.nativeType.localizedCaseInsensitiveContains("completed")
                || event.nativeType.localizedCaseInsensitiveContains("finished")
            model.recordSubagentActivity(
                threadID: serviceEvent.threadID,
                runID: serviceEvent.runID,
                provider: providerName(runID: serviceEvent.runID),
                nativeID: event.approvalID ?? event.nativeType,
                title: text,
                detail: event.nativeType,
                state: terminal ? .completed : .running
            )
            guard model.persistenceError == nil else { return false }
        }

        switch event.kind {
        case .providerCompleted:
            if model.providerRun(id: serviceEvent.runID)?.state != .completed {
                model.completeProviderRun(id: serviceEvent.runID, tokenUsage: tokenUsage(from: event.payload))
                guard model.persistenceError == nil else { return false }
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
            guard registerServiceEvidence(threadID: serviceEvent.threadID, runID: serviceEvent.runID) else { return false }
            scheduleTitleIfNeeded(threadID: serviceEvent.threadID)
        case .runInterrupted:
            if model.providerRun(id: serviceEvent.runID)?.state != .interrupted {
                model.stopProviderRun(id: serviceEvent.runID, interrupted: true, error: event.text ?? "The provider turn was interrupted.")
                guard model.persistenceError == nil else { return false }
            }
            runningRunIDByThread.removeValue(forKey: serviceEvent.threadID)
        case .runFailed:
            if model.providerRun(id: serviceEvent.runID)?.state != .failed {
                model.stopProviderRun(id: serviceEvent.runID, interrupted: false, error: event.text ?? "The provider stopped without a readable result.")
                guard model.persistenceError == nil else { return false }
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
        guard let runningRunID else {
            orphanChecks[threadID] = 0
            return
        }
        let count = (orphanChecks[threadID] ?? 0) + 1
        orphanChecks[threadID] = count
        if count >= pollingPolicy.orphanedRunCheckCount {
            model.stopProviderRun(
                id: runningRunID,
                interrupted: true,
                error: "The durable provider worker stopped before completion. Retry reuses the saved user message."
            )
            if model.persistenceError == nil { runningRunIDByThread.removeValue(forKey: threadID) }
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

    private func scheduleTitleIfNeeded(threadID: String) {
        guard titleTasks[threadID] == nil,
              let thread = model.thread(id: threadID),
              thread.titleSource == .provisional,
              let firstMessage = thread.messages.first(where: { $0.role == .user })?.body,
              let workspace = model.workspaceURL(threadID: threadID) ?? (try? prepareStandaloneWorkspace()) else { return }
        titleTasks[threadID] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { titleTasks.removeValue(forKey: threadID) }
            do {
                let title = try await generateTitle(provider: thread.provider, firstMessage: firstMessage, workspace: workspace)
                if !model.applyProviderGeneratedTitle(threadID: threadID, title: title) {
                    model.markProviderTitleFallback(threadID: threadID)
                }
            } catch {
                model.markProviderTitleFallback(threadID: threadID)
            }
        }
    }

    private func generateTitle(provider: String, firstMessage: String, workspace: URL) async throws -> String {
        let prompt = "Create a concise conversation title of at most 8 words. Return only the title, without quotes or punctuation decoration.\n\nFirst user message:\n\(firstMessage)"
        if let driver = NativeConversationDriver(providerName: provider) {
            let session = NativeProviderConversationSession()
            let events = await session.events(for: NativeConversationRequest(
                driver: driver,
                prompt: prompt,
                workspace: workspace,
                model: nil,
                reasoningEffort: "low",
                resumableSessionID: nil
            ))
            var title = ""
            for await event in events {
                if event.kind == .messageDelta, let text = event.text { title += text }
                if event.kind == .providerCompleted { return title }
                if event.kind == .runFailed || event.kind == .runInterrupted {
                    throw NSError(domain: "KanameTitle", code: 1)
                }
            }
            throw NSError(domain: "KanameTitle", code: 2)
        }
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocalTitle")!,
            driver: .codex,
            displayName: "Codex title generator"
        )
        let session = CodexLiveSession(configuration: .init(instance: instance, workspaceURL: workspace))
        let stream = await session.events()
        let collector = _Concurrency.Task<String, Error> {
            var title = ""
            for await event in stream {
                if event.kind == .messageDelta, let text = event.text { title += text }
                if event.kind == .providerCompleted { return title }
                if event.kind == .runFailed || event.kind == .runInterrupted {
                    throw NSError(domain: "KanameTitle", code: 1)
                }
            }
            throw NSError(domain: "KanameTitle", code: 2)
        }
        do {
            _ = try await session.start(
                CodexCodingRequest(
                    prompt: prompt,
                    model: "gpt-5.6-terra",
                    reasoningEffort: "low",
                    sandbox: .readOnly
                )
            )
            let title = try await collector.value
            await session.close()
            return title
        } catch {
            collector.cancel()
            await session.close()
            throw error
        }
    }

    private func providerPrompt(thread: DesktopThread, userMessage: String, includeProjectContext: Bool) -> String {
        guard includeProjectContext else {
            return """
            Respond inside Kaname's unified \(thread.kind.label.lowercased()) conversation.

            Authority boundary: this scheduled turn uses only its frozen prompt and workspace. It is read-only with network disabled. Do not modify files, commit, push, access accounts, or request broader authority.

            User message:
            \(userMessage)
            """
        }
        let project = model.project(id: thread.projectID)
        let context = project?.context
        let instructions = context?.instructionReferences.joined(separator: ", ") ?? "None selected"
        let knowledge = context?.knowledgeSourceIDs.joined(separator: ", ") ?? "None selected"
        let skills = context?.skillIDs.joined(separator: ", ") ?? "None selected"
        return """
        Respond inside Kaname's unified \(thread.kind.label.lowercased()) conversation.
        Project: \(project?.name ?? "Standalone")
        Selected instruction references: \(instructions)
        Selected knowledge sources: \(knowledge)
        Selected skills and tools: \(skills)

        Authority boundary: this turn is read-only with network disabled. Do not modify files, commit, push, access accounts, or request broader authority. If the request needs an effect, explain the proposed action and exact approval required.

        User message:
        \(userMessage)
        """
    }

    private func resolvedModel(provider: String, value: String) -> String {
        guard value == "Use provider default" else { return value }
        return provider.caseInsensitiveCompare("Codex") == .orderedSame ? "gpt-5.6-terra" : value
    }

    private func providerEventRecord(
        _ event: CodexRunEvent,
        id: String,
        threadID: String,
        runID: String,
        createdAtUnixMillis: Int64
    ) -> DesktopProviderEventRecord {
        let provider = providerName(runID: runID)
        let presentation = Self.presentation(for: event, provider: provider)
        return DesktopProviderEventRecord(
            id: id,
            threadID: threadID,
            runID: runID,
            kind: presentation.kind,
            title: presentation.title,
            detail: String((event.text ?? presentation.detail).prefix(65_536)),
            nativeType: event.nativeType,
            nativeThreadID: event.threadID,
            nativeTurnID: event.turnID,
            approvalID: event.approvalID,
            rawPayloadBase64: event.payload?.base64EncodedString(),
            payloadWasTruncated: event.payloadWasTruncated,
            createdAtUnixMillis: createdAtUnixMillis
        )
    }

    private static func presentation(for event: CodexRunEvent, provider: String) -> (
        kind: DesktopProviderEventKind,
        title: String,
        detail: String
    ) {
        switch event.kind {
        case .sessionStarted: (.status, "Provider connected", "A private \(provider) session is attached to this conversation.")
        case .runStarted: (.status, "Turn started", "\(provider) is working in the selected read-only context.")
        case .providerCompleted: (.status, "Turn complete", "The provider completed; the result still awaits your review.")
        case .runInterrupted: (.error, "Turn interrupted", "Retry when you are ready.")
        case .runFailed: (.error, "Provider stopped", "Inspect the failure and retry without duplicating the message.")
        case .messageDelta: (.assistantText, "Response", "Streaming assistant text")
        case .planUpdated: (.reasoning, "Plan updated", "The provider updated its working plan.")
        case .toolActivity: (.tool, "Tool activity", event.nativeType)
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
