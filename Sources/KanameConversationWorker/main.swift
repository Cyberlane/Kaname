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
        var activeWorkspace: String?
        var sessionHasNativeThread = false
        var idleChecks = 0
        while idleChecks < 30 {
            let pending = try store.pendingRequests(threadID: threadID)
            guard let (requestURL, request) = pending.first else {
                idleChecks += 1
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
                    session = makeSession(request)
                    activeWorkspace = request.workspacePath
                    sessionHasNativeThread = false
                }
                guard let session else { continue }
                sessionHasNativeThread = await processCodex(
                    request,
                    session: session,
                    store: store,
                    continueExistingSession: sessionHasNativeThread
                ) || sessionHasNativeThread
            } else {
                await session?.close()
                session = nil
                activeWorkspace = nil
                sessionHasNativeThread = false
                _ = await processNativeProvider(request, store: store)
            }
            try store.finishRequest(at: requestURL, threadID: threadID)
        }
        await session?.close()
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
        let stream = await session.events()
        let terminal = _Concurrency.Task<CodexRunEventKind, Error> {
            for await event in stream {
                _ = try await recorder.record(event)
                if let payload = event.payload {
                    try store.appendEvidence(payload, threadID: request.threadID, runID: request.runID)
                }
                try await writer.append(kind: .provider, providerEvent: event)
                if [.providerCompleted, .runFailed, .runInterrupted].contains(event.kind) { return event.kind }
            }
            throw NSError(domain: "KanameConversationWorker", code: 1)
        }
        let controls = _Concurrency.Task<Void, Never> {
            while !_Concurrency.Task.isCancelled {
                if store.consumeInterrupt(threadID: request.threadID, runID: request.runID) {
                    try? await session.interrupt()
                }
                if let (requestID, answers) = store.consumeAnswer(threadID: request.threadID, runID: request.runID) {
                    try? await session.answerQuestion(requestID: requestID, answers: answers)
                }
                try? await _Concurrency.Task.sleep(for: .milliseconds(100))
            }
        }
        var didStartSession = false
        do {
            let codingRequest = CodexCodingRequest(
                prompt: request.prompt,
                model: request.model,
                reasoningEffort: request.reasoningEffort,
                sandbox: .readOnly
            )
            let liveRun: CodexLiveRun
            if continueExistingSession {
                liveRun = try await session.continueRun(codingRequest)
            } else {
                liveRun = try await session.start(codingRequest, resumingNativeThreadID: request.resumableNativeThreadID)
            }
            didStartSession = true
            try await writer.append(
                kind: .serviceStarted,
                providerEvent: CodexRunEvent(
                    kind: .runStarted,
                    nativeType: "kaname/service-started",
                    threadID: liveRun.nativeThreadID,
                    turnID: liveRun.nativeTurnID
                )
            )
            _ = try await terminal.value
        } catch {
            terminal.cancel()
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
        }
        controls.cancel()
        return didStartSession
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
        let providerKind: ProviderDriverKind = driver == .claude ? .claudeAgent : .openCode
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
        let session = NativeProviderConversationSession()
        let stream = await session.events(for: NativeConversationRequest(
            driver: driver,
            prompt: request.prompt,
            workspace: URL(fileURLWithPath: request.workspacePath),
            model: request.model,
            reasoningEffort: request.reasoningEffort,
            resumableSessionID: request.resumableNativeThreadID
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
        do {
            for await event in stream {
                _ = try await recorder.record(event)
                if let payload = event.payload {
                    try store.appendEvidence(payload, threadID: request.threadID, runID: request.runID)
                }
                try await writer.append(kind: .provider, providerEvent: event)
                if [.providerCompleted, .runFailed, .runInterrupted].contains(event.kind) {
                    completed = event.kind == .providerCompleted
                    break
                }
            }
        } catch {
            try? await writer.append(kind: .serviceFailed, text: error.localizedDescription)
        }
        controls.cancel()
        return completed
    }

    private static func makeSession(_ request: KanameConversationServiceRequest) -> CodexLiveSession {
        let instance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        return CodexLiveSession(configuration: .init(
            instance: instance,
            workspaceURL: URL(fileURLWithPath: request.workspacePath),
            persistentSessionDirectory: URL(fileURLWithPath: request.providerStatePath)
        ))
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
