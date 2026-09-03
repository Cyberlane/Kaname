#if os(macOS)
import Darwin
#endif
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore

private actor ServiceEventWriter {
    private let store: KanameConversationServiceStore
    private let request: KanameConversationServiceRequest
    private var ordinal = 0
    private var pendingAssistantText = ""
    private var pendingAssistantEvent: CodexRunEvent?
    private var lastAssistantFlushAtUnixMillis: Int64 = 0

    init(store: KanameConversationServiceStore, request: KanameConversationServiceRequest) {
        self.store = store
        self.request = request
    }

    func append(kind: KanameConversationServiceEvent.Kind, providerEvent: CodexRunEvent? = nil, text: String? = nil) throws {
        if let providerEvent, providerEvent.kind == .messageDelta {
            pendingAssistantText += providerEvent.text ?? ""
            pendingAssistantEvent = providerEvent
            let timestamp = now()
            if pendingAssistantText.utf8.count >= 4_096 || timestamp - lastAssistantFlushAtUnixMillis >= 250 {
                try flushAssistantText(at: timestamp)
            }
            return
        }
        let timestamp = now()
        try flushAssistantText(at: timestamp)
        try write(kind: kind, providerEvent: providerEvent, text: text, createdAtUnixMillis: timestamp)
    }

    private func flushAssistantText(at timestamp: Int64) throws {
        guard !pendingAssistantText.isEmpty, let pendingAssistantEvent else { return }
        let combined = CodexRunEvent(
            kind: .messageDelta,
            nativeType: pendingAssistantEvent.nativeType,
            threadID: pendingAssistantEvent.threadID,
            turnID: pendingAssistantEvent.turnID,
            approvalID: pendingAssistantEvent.approvalID,
            toolObservation: pendingAssistantEvent.toolObservation,
            agentActivity: pendingAssistantEvent.agentActivity,
            text: pendingAssistantText,
            payload: nil,
            payloadWasTruncated: false
        )
        pendingAssistantText = ""
        self.pendingAssistantEvent = nil
        lastAssistantFlushAtUnixMillis = timestamp
        try write(kind: .provider, providerEvent: combined, text: nil, createdAtUnixMillis: timestamp)
    }

    private func write(
        kind: KanameConversationServiceEvent.Kind,
        providerEvent: CodexRunEvent?,
        text: String?,
        createdAtUnixMillis: Int64
    ) throws {
        ordinal += 1
        let event = KanameConversationServiceEvent.record(
            id: "\(request.runID)-service-\(ordinal)",
            runID: request.runID,
            threadID: request.threadID,
            ordinal: ordinal,
            kind: kind,
            providerKind: providerEvent?.kind,
            nativeType: providerEvent?.nativeType ?? kind.rawValue,
            nativeThreadID: providerEvent?.threadID,
            nativeTurnID: providerEvent?.turnID,
            approvalID: providerEvent?.approvalID,
            toolObservation: providerEvent?.toolObservation,
            agentActivity: providerEvent?.agentActivity,
            text: providerEvent?.text ?? text,
            rawPayloadBase64: providerEvent?.payload?.base64EncodedString(),
            payloadWasTruncated: providerEvent?.payloadWasTruncated ?? false,
            createdAtUnixMillis: createdAtUnixMillis
        )
        try store.append(event)
    }

    private func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

private enum CodexSessionEventPumpError: Error, LocalizedError {
    case routingFailed
    case persistenceFailed
    case streamEnded

    var errorDescription: String? {
        switch self {
        case .routingFailed:
            "The provider event stream could not be matched to its durable Kaname run."
        case .persistenceFailed:
            "The provider event stream could not be persisted without losing ordering."
        case .streamEnded:
            "The provider event stream ended before the active turn settled."
        }
    }
}

/// One pump owns the entire lifetime of a reusable Codex session. Per-turn
/// consumers wait for their own terminal event, while the pump keeps routing
/// late child activity to the run identified by the native turn ID.
private actor CodexSessionEventPump {
    private struct Route {
        let request: KanameConversationServiceRequest
        let writer: ServiceEventWriter
        let recorder: CodexJournalRecorder
    }

    private let store: KanameConversationServiceStore
    private var routes: [String: Route] = [:]
    private var routeTable = CodexRunEventRouteTable()
    private var waiters: [String: CheckedContinuation<CodexRunEventKind, Error>] = [:]
    private var terminalResults: [String: Result<CodexRunEventKind, Error>] = [:]
    private var terminalRunIDs: Set<String> = []
    private var pumpTask: _Concurrency.Task<Void, Never>?
    private var controlTask: _Concurrency.Task<Void, Never>?
    private var fatalError: CodexSessionEventPumpError?
    private var streamEnded = false

    init(store: KanameConversationServiceStore) {
        self.store = store
    }

    func start(_ stream: AsyncStream<CodexRunEvent>, session: CodexLiveSession) {
        guard pumpTask == nil else { return }
        pumpTask = _Concurrency.Task { [weak self] in
            await self?.consume(stream)
        }
        controlTask = _Concurrency.Task { [weak self] in
            await self?.consumeControls(session: session)
        }
    }

    func register(
        request: KanameConversationServiceRequest,
        writer: ServiceEventWriter,
        recorder: CodexJournalRecorder
    ) throws {
        if let fatalError { throw fatalError }
        guard !streamEnded else { throw CodexSessionEventPumpError.streamEnded }
        try routeTable.register(runID: request.runID)
        routes[request.runID] = Route(request: request, writer: writer, recorder: recorder)
    }

    func bind(runID: String, nativeThreadID: String, nativeTurnID: String) throws {
        try routeTable.bind(
            runID: runID,
            nativeThreadID: nativeThreadID,
            nativeTurnID: nativeTurnID
        )
    }

    func waitForTerminal(runID: String) async throws -> CodexRunEventKind {
        if let result = terminalResults.removeValue(forKey: runID) {
            return try result.get()
        }
        guard routes[runID] != nil else { throw CodexSessionEventPumpError.routingFailed }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[runID] = continuation
        }
    }

    func hasOutstandingAgentActivity() -> Bool {
        !streamEnded && routeTable.hasOutstandingAgentActivity
    }

    func waitUntilStopped() async {
        await pumpTask?.value
        await controlTask?.value
    }

    private func consume(_ stream: AsyncStream<CodexRunEvent>) async {
        for await event in stream {
            await ingest(event)
        }
        await finishStream()
    }

    private func consumeControls(session: CodexLiveSession) async {
        while !_Concurrency.Task.isCancelled {
            let runIDs = routes.keys.sorted()
            for runID in runIDs {
                guard let route = routes[runID] else { continue }
                if let target = routeTable.controlTarget(for: runID),
                   store.consumeInterrupt(
                    threadID: route.request.threadID,
                    runID: route.request.runID
                ) {
                    try? await session.interrupt(target)
                }
                if let (requestID, answers) = store.consumeAnswer(
                    threadID: route.request.threadID,
                    runID: route.request.runID
                ) {
                    try? await session.answerQuestion(requestID: requestID, answers: answers)
                }
            }
            try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
    }

    private func ingest(_ event: CodexRunEvent) async {
        guard fatalError == nil else { return }
        let runID: String
        do {
            guard let routedRunID = try routeTable.route(event) else { return }
            runID = routedRunID
        } catch {
            await failAll(with: .routingFailed, nativeType: "kaname/routing-failed")
            return
        }
        guard let route = routes[runID] else {
            await failAll(with: .routingFailed, nativeType: "kaname/routing-failed")
            return
        }
        do {
            try await persist(event, routedTo: runID, route: route)
            if [.providerCompleted, .runFailed, .runInterrupted].contains(event.kind) {
                complete(runID: runID, with: .success(event.kind))
            }
            if [.runFailed, .runInterrupted].contains(event.kind) {
                await settleOutstandingAgents(
                    for: runID,
                    as: .interrupted,
                    nativeType: "kaname/turn-ended"
                )
            }
        } catch {
            try? await route.writer.append(
                kind: .serviceFailed,
                text: CodexSessionEventPumpError.persistenceFailed.localizedDescription
            )
            complete(runID: runID, with: .failure(CodexSessionEventPumpError.persistenceFailed))
            await failAll(with: .persistenceFailed, nativeType: "kaname/persistence-failed")
        }
    }

    private func persist(
        _ event: CodexRunEvent,
        routedTo runID: String,
        route: Route
    ) async throws {
        _ = try await route.recorder.record(event)
        if let payload = event.payload {
            try store.appendEvidence(
                payload,
                threadID: route.request.threadID,
                runID: route.request.runID
            )
        }
        try await route.writer.append(kind: .provider, providerEvent: event)
        routeTable.observe(event, routedTo: runID)
    }

    private func settleOutstandingAgents(
        for runID: String,
        as terminalActivity: ProviderAgentActivityKind,
        nativeType: String
    ) async {
        guard let route = routes[runID] else { return }
        let activities = routeTable.agentSettlementActivities(
            for: runID,
            as: terminalActivity
        )
        for activity in activities {
            let event = CodexRunEvent(
                kind: .toolActivity,
                nativeType: nativeType,
                agentActivity: activity
            )
            do {
                try await persist(event, routedTo: runID, route: route)
            } catch {
                try? await route.writer.append(
                    kind: .serviceFailed,
                    text: CodexSessionEventPumpError.persistenceFailed.localizedDescription
                )
            }
        }
    }

    private func settleAllOutstandingAgents(nativeType: String) async {
        for runID in routeTable.runIDsWithOutstandingAgentActivity {
            await settleOutstandingAgents(
                for: runID,
                as: .interrupted,
                nativeType: nativeType
            )
        }
    }

    private func complete(
        runID: String,
        with result: Result<CodexRunEventKind, Error>
    ) {
        guard terminalRunIDs.insert(runID).inserted else { return }
        if let waiter = waiters.removeValue(forKey: runID) {
            waiter.resume(with: result)
        } else {
            terminalResults[runID] = result
        }
    }

    private func failAll(
        with error: CodexSessionEventPumpError,
        nativeType: String
    ) async {
        await settleAllOutstandingAgents(nativeType: nativeType)
        fatalError = error
        streamEnded = true
        controlTask?.cancel()
        for waiter in waiters.values { waiter.resume(throwing: error) }
        waiters.removeAll()
    }

    private func finishStream() async {
        await settleAllOutstandingAgents(nativeType: "kaname/session-ended")
        streamEnded = true
        controlTask?.cancel()
        for waiter in waiters.values {
            waiter.resume(throwing: CodexSessionEventPumpError.streamEnded)
        }
        waiters.removeAll()
    }
}

@main
private enum KanameConversationWorker {
    static func main() async {
        do {
            let root = try requiredValue(after: "--root")
            let threadID = try requiredValue(after: "--thread")
            let storeRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            let recoveryLock = try KanameRuntimeRecoveryFileLock.acquireShared(
                applicationSupportRoot: storeRoot.deletingLastPathComponent()
            )
            defer { withExtendedLifetime(recoveryLock) {} }
            let store = KanameConversationServiceStore(rootDirectory: storeRoot)
            let lock = try acquireLock(at: store.workerLockURL(threadID: threadID))
            defer {
                flock(lock, LOCK_UN)
                Darwin.close(lock)
            }
            try await serve(store: store, threadID: threadID)
        } catch {
            FileHandle.standardError.write(Data("kaname-conversation-worker: stopped safely\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func serve(store: KanameConversationServiceStore, threadID: String) async throws {
        var session: CodexLiveSession?
        var eventPump: CodexSessionEventPump?
        var codexBridge: KanameBridgeMCPServer?
        var activeWorkspace: String?
        var sessionHasNativeThread = false
        var idleChecks = 0
        while true {
            let hasOutstandingAgentActivity = if let eventPump {
                await eventPump.hasOutstandingAgentActivity()
            } else {
                false
            }
            guard idleChecks < 30 || hasOutstandingAgentActivity else { break }
            let pending = try store.pendingRequests(threadID: threadID)
            guard let (requestURL, request) = pending.first else {
                idleChecks = min(idleChecks + 1, 30)
                try await _Concurrency.Task.sleep(for: .milliseconds(100))
                continue
            }
            idleChecks = 0
            try store.writeWorkerState(KanameConversationWorkerState.record(
                threadID: threadID,
                runID: request.runID,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                updatedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            ))
            if request.provider.caseInsensitiveCompare("Codex") == .orderedSame {
                if activeWorkspace != request.workspacePath {
                    await session?.close()
                    await eventPump?.waitUntilStopped()
                    await codexBridge?.stop()
                    // Kaname Bridge for this Codex session. Tool calls are injected
                    // into the session stream and routed to the active run.
                    let relay = CodexBridgeRelay()
                    let bridge = KanameBridgeMCPServer(
                        knowledge: nil,
                        readableScopes: [],
                        writableScopes: []
                    ) { event in await relay.inject(event) }
                    await bridge.updateScopes(
                        readable: request.bridgeKnowledgeReadScopes ?? [],
                        writable: request.bridgeKnowledgeWriteScopes ?? []
                    )
                    await bridge.updateMemory(request.bridgeMemoryPack ?? [])
                    await bridge.updateWorkflowPublisher(LocalCoreRunner(
                        machService: request.localCoreMachService,
                        serviceRequirement: request.localCoreRequirement
                    ))
                    let bridgeBinding = try? await bridge.start()
                    let newSession = makeSession(request, bridgeBinding: bridgeBinding)
                    await relay.attach(newSession)
                    let newEventPump = CodexSessionEventPump(store: store)
                    await newEventPump.start(await newSession.events(), session: newSession)
                    session = newSession
                    eventPump = newEventPump
                    codexBridge = bridge
                    activeWorkspace = request.workspacePath
                    sessionHasNativeThread = false
                } else {
                    await codexBridge?.updateScopes(
                        readable: request.bridgeKnowledgeReadScopes ?? [],
                        writable: request.bridgeKnowledgeWriteScopes ?? []
                    )
                    await codexBridge?.updateMemory(request.bridgeMemoryPack ?? [])
                }
                guard let activeSession = session, let activeEventPump = eventPump else { continue }
                let sessionIsReusable = await processCodex(
                    request,
                    session: activeSession,
                    eventPump: activeEventPump,
                    store: store,
                    continueExistingSession: sessionHasNativeThread
                )
                if sessionIsReusable {
                    sessionHasNativeThread = true
                } else {
                    await activeSession.close()
                    await activeEventPump.waitUntilStopped()
                    session = nil
                    eventPump = nil
                    activeWorkspace = nil
                    sessionHasNativeThread = false
                }
            } else {
                await session?.close()
                await eventPump?.waitUntilStopped()
                await codexBridge?.stop()
                codexBridge = nil
                session = nil
                eventPump = nil
                activeWorkspace = nil
                sessionHasNativeThread = false
                _ = await processNativeProvider(request, store: store)
            }
            try store.finishRequest(at: requestURL, threadID: threadID)
        }
        await session?.close()
        await eventPump?.waitUntilStopped()
        await codexBridge?.stop()
        try store.writeWorkerState(KanameConversationWorkerState.record(
            threadID: threadID,
            runID: nil,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            updatedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        ))
    }

    private static func processCodex(
        _ request: KanameConversationServiceRequest,
        session: CodexLiveSession,
        eventPump: CodexSessionEventPump,
        store: KanameConversationServiceStore,
        continueExistingSession: Bool
    ) async -> Bool {
        let writer = ServiceEventWriter(store: store, request: request)
        let runner = LocalCoreRunner(
            machService: request.localCoreMachService,
            serviceRequirement: request.localCoreRequirement
        )
        guard let providerID = ProviderInstanceID(rawValue: "codexLocal") else {
            try? await writer.append(kind: .serviceFailed, text: "The durable request contained an invalid identity.")
            return false
        }
        let projectID = KanameID(rawValue: request.projectID)
        let threadID = KanameID(rawValue: request.threadID)
        let runID = KanameID(rawValue: request.runID)
        let provider = ProviderInstance(id: providerID, driver: .codex, displayName: "Codex local")
        let recorder = CodexJournalRecorder(
            runner: runner,
            context: CodexJournalContext(projectID: projectID, threadID: threadID, runID: runID, providerInstance: provider)
        )
        do {
            try await eventPump.register(request: request, writer: writer, recorder: recorder)
        } catch {
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
            return false
        }
        var sessionIsReusable = false
        do {
            let attachmentStore = KanameConversationAttachmentStore(rootDirectory: store.rootDirectory)
            let attachmentPaths = try request.attachments.map {
                try attachmentStore.attachmentURL(threadID: request.threadID, attachment: $0).path
            }
            let codingRequest = request.codexCodingRequest(attachmentPaths: attachmentPaths)
            let liveRun: CodexLiveRun
            if continueExistingSession {
                liveRun = try await session.continueRun(
                    codingRequest,
                    authorization: request.workspaceAuthorization
                )
            } else {
                liveRun = try await session.start(
                    codingRequest,
                    authorization: request.workspaceAuthorization,
                    resumingNativeThreadID: request.resumableNativeThreadID
                )
            }
            try await eventPump.bind(
                runID: request.runID,
                nativeThreadID: liveRun.nativeThreadID,
                nativeTurnID: liveRun.nativeTurnID
            )
            try await writer.append(
                kind: .serviceStarted,
                providerEvent: CodexRunEvent(
                    kind: .runStarted,
                    nativeType: "kaname/service-started",
                    threadID: liveRun.nativeThreadID,
                    turnID: liveRun.nativeTurnID
                )
            )
            _ = try await eventPump.waitForTerminal(runID: request.runID)
            sessionIsReusable = true
        } catch {
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
            sessionIsReusable = false
        }
        return sessionIsReusable
    }

    private static func processNativeProvider(
        _ request: KanameConversationServiceRequest,
        store: KanameConversationServiceStore
    ) async -> Bool {
        let writer = ServiceEventWriter(store: store, request: request)
        guard let driver = NativeConversationDriver(providerName: request.provider),
              let providerID = ProviderInstanceID(rawValue: "\(driver.rawValue)Local") else {
            try? await writer.append(kind: .serviceFailed, text: "\(request.provider) has no installed Kaname conversation adapter.")
            return false
        }
        let providerKind: ProviderDriverKind
        switch driver {
        case .claude: providerKind = .claudeAgent
        case .openCode: providerKind = .openCode
        case .cursor: providerKind = .cursorAgent
        case .grok: providerKind = .grokBuild
        }
        let provider = ProviderInstance(id: providerID, driver: providerKind, displayName: "\(driver.displayName) local")
        let runner = LocalCoreRunner(
            machService: request.localCoreMachService,
            serviceRequirement: request.localCoreRequirement
        )
        let recorder = CodexJournalRecorder(
            runner: runner,
            context: CodexJournalContext(
                projectID: KanameID(rawValue: request.projectID),
                threadID: KanameID(rawValue: request.threadID),
                runID: KanameID(rawValue: request.runID),
                providerInstance: provider
            )
        )
        let attachmentStore = KanameConversationAttachmentStore(rootDirectory: store.rootDirectory)
        let attachmentPaths: [String]
        do {
            attachmentPaths = try request.attachments.map {
                try attachmentStore.attachmentURL(threadID: request.threadID, attachment: $0).path
            }
        } catch {
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
            return false
        }
        let session = NativeProviderConversationSession()
        // Kaname Bridge: the agent's direct channel back into Kaname. Tool calls
        // become run events on the same durable stream as provider output.
        var bridge: KanameBridgeMCPServer?
        var bridgeBinding: KanameBridgeMCPServer.Binding?
        if driver == .claude || driver == .openCode {
            let scopes = request.bridgeKnowledgeReadScopes ?? []
            let writeScopes = request.bridgeKnowledgeWriteScopes ?? []
            let knowledge = scopes.isEmpty && writeScopes.isEmpty
                ? nil
                : try? ObsidianVaultService(readableScopes: scopes + writeScopes, writableScopes: writeScopes)
            let server = KanameBridgeMCPServer(knowledge: knowledge, readableScopes: scopes + writeScopes, writableScopes: writeScopes, memory: request.bridgeMemoryPack ?? []) { event in
                _ = try? await recorder.record(event)
                try? await writer.append(kind: .provider, providerEvent: event)
            }
            await server.updateWorkflowPublisher(runner)
            if let binding = try? await server.start() {
                bridge = server
                bridgeBinding = binding
            } else {
                try? await writer.append(
                    kind: .provider,
                    providerEvent: CodexRunEvent(kind: .nativeProviderEvent, nativeType: "kaname/bridge-unavailable", text: "Kaname Bridge could not start; continuing without Kaname tools.")
                )
            }
        }
        defer { if let bridge { _Concurrency.Task { await bridge.stop() } } }
        let stream = await session.events(for: NativeConversationRequest(
            driver: driver,
            prompt: request.prompt,
            attachmentPaths: attachmentPaths,
            workspace: URL(fileURLWithPath: request.workspacePath),
            model: request.model,
            reasoningEffort: request.reasoningEffort,
            runtimeMode: request.runtimeMode,
            networkAccess: request.networkAccess,
            resumableSessionID: request.resumableNativeThreadID,
            bridge: bridgeBinding
        ))
        try? await writer.append(
            kind: .serviceStarted,
            providerEvent: CodexRunEvent(
                kind: .runStarted,
                nativeType: "kaname/service-started",
                threadID: request.resumableNativeThreadID
            )
        )
        let controls = _Concurrency.Task<Void, Never> {
            while !_Concurrency.Task.isCancelled {
                if store.consumeInterrupt(threadID: request.threadID, runID: request.runID) {
                    await session.interrupt()
                }
                try? await _Concurrency.Task.sleep(for: .milliseconds(100))
            }
        }
        var completed = false
        var agentLedger = ProviderAgentActivityLedger()
        do {
            for await event in stream {
                _ = try await recorder.record(event)
                if let payload = event.payload {
                    try store.appendEvidence(payload, threadID: request.threadID, runID: request.runID)
                }
                try await writer.append(kind: .provider, providerEvent: event)
                agentLedger.observe(event.agentActivity)
                if [.providerCompleted, .runFailed, .runInterrupted].contains(event.kind) {
                    completed = event.kind == .providerCompleted
                    try await settleNativeProviderAgents(
                        &agentLedger,
                        recorder: recorder,
                        writer: writer,
                        nativeType: "kaname/provider-observation-ended"
                    )
                    break
                }
            }
            try await settleNativeProviderAgents(
                &agentLedger,
                recorder: recorder,
                writer: writer,
                nativeType: "kaname/provider-stream-ended"
            )
        } catch {
            try? await settleNativeProviderAgents(
                &agentLedger,
                recorder: recorder,
                writer: writer,
                nativeType: "kaname/provider-failed"
            )
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
        }
        controls.cancel()
        return completed
    }

    private static func settleNativeProviderAgents(
        _ agentLedger: inout ProviderAgentActivityLedger,
        recorder: CodexJournalRecorder,
        writer: ServiceEventWriter,
        nativeType: String
    ) async throws {
        for activity in agentLedger.settlementActivities(as: .interrupted) {
            let event = CodexRunEvent(
                kind: .toolActivity,
                nativeType: nativeType,
                agentActivity: activity
            )
            _ = try await recorder.record(event)
            try await writer.append(kind: .provider, providerEvent: event)
            agentLedger.observe(activity)
        }
    }

    private static func makeSession(
        _ request: KanameConversationServiceRequest,
        bridgeBinding: KanameBridgeMCPServer.Binding? = nil
    ) -> CodexLiveSession {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        return CodexLiveSession(configuration: .init(
            instance: instance,
            workspaceURL: URL(fileURLWithPath: request.workspacePath),
            persistentSessionDirectory: URL(fileURLWithPath: request.providerStatePath),
            curatedPreviewMCPGranted: request.curatedPreviewMCPGranted,
            bridgeBinding: bridgeBinding
        ))
    }

    /// Bridges tool-call events into whichever Codex session is currently
    /// attached; the session did not exist yet when the Bridge was created.
    actor CodexBridgeRelay {
        private weak var session: CodexLiveSession?

        func attach(_ session: CodexLiveSession) { self.session = session }

        func inject(_ event: CodexRunEvent) async {
            await session?.injectBridgeEvent(event)
        }
    }

    private static func requiredValue(after flag: String) throws -> String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty else { throw KanameConversationServiceError.invalidIdentifier }
        return arguments[index + 1]
    }

    private static func acquireLock(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KanameConversationServiceError.launchFailed(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            if failure == EWOULDBLOCK { exit(EXIT_SUCCESS) }
            throw KanameConversationServiceError.launchFailed(failure)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }
}
