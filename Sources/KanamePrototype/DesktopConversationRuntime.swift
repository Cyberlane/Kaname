import CryptoKit
import Foundation
import KanameConnectivity
import KanameDesktop
import KanameDomain
import KanameLocalCore

@MainActor
final class DesktopConversationRuntime: ObservableObject {
    @Published private(set) var activeThreadIDs: Set<String> = []

    private let model: DesktopAppModel
    private let environment: KanameDesktopEnvironment
    private let serviceStore: KanameConversationServiceStore
    private var pollingTask: _Concurrency.Task<Void, Never>?
    private var orphanChecks: [String: Int] = [:]
    private var titleTasks: [String: _Concurrency.Task<Void, Never>] = [:]

    init(model: DesktopAppModel, environment: KanameDesktopEnvironment = .current) {
        self.model = model
        self.environment = environment
        serviceStore = KanameConversationServiceStore(
            rootDirectory: environment.applicationSupportRoot.appending(path: "ConversationService", directoryHint: .isDirectory)
        )
        pollingTask = _Concurrency.Task { [weak self] in await self?.pollService() }
    }

    deinit {
        pollingTask?.cancel()
        for task in titleTasks.values { task.cancel() }
    }

    @discardableResult
    func send(threadID: String, body: String) -> Bool {
        guard let messageID = model.appendUserMessage(threadID: threadID, body: body),
              let runID = model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID) else { return false }
        submit(runID: runID)
        return true
    }

    func retry(runID: String) {
        guard let replacementID = model.retryProviderRun(id: runID) else { return }
        submit(runID: replacementID)
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

    private func submit(runID: String) {
        guard let run = model.providerRun(id: runID),
              let threadID = run.threadID,
              let sourceMessageID = run.sourceMessageID,
              let message = model.message(threadID: threadID, id: sourceMessageID),
              let thread = model.thread(id: threadID) else {
            return
        }
        guard run.provider.caseInsensitiveCompare("Codex") == .orderedSame else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "\(run.provider) does not yet support the unified streaming runtime. Choose Codex or use its bounded Coding discussion surface."
            )
            return
        }
        let workspace: URL
        if let projectWorkspace = model.workspaceURL(threadID: threadID) {
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
            model: resolvedModel(run.model),
            reasoningEffort: run.reasoningEffort,
            prompt: providerPrompt(thread: thread, userMessage: message.body),
            workspacePath: workspace.path,
            providerStatePath: environment.providerStateDirectory.path,
            resumableNativeThreadID: model.latestNativeThreadID(threadID: threadID),
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
            activeThreadIDs.insert(threadID)
        } catch {
            model.stopProviderRun(id: run.id, interrupted: false, error: error.localizedDescription)
        }
    }

    private func pollService() async {
        while !_Concurrency.Task.isCancelled {
            for thread in model.snapshot.threads {
                let serviceEvents = (try? serviceStore.events(threadID: thread.id)) ?? []
                for event in serviceEvents {
                    if !model.snapshot.operations.providerEvents.contains(where: { $0.id == event.id }) {
                        consume(event)
                    }
                    try? serviceStore.acknowledge(event)
                }
                let alive = serviceStore.isWorkerAlive(threadID: thread.id)
                let hasPending = (try? serviceStore.pendingRequests(threadID: thread.id).isEmpty == false) ?? false
                if alive || hasPending {
                    activeThreadIDs.insert(thread.id)
                    orphanChecks[thread.id] = 0
                    if hasPending && !alive { launchWorkerIfAvailable(threadID: thread.id) }
                } else {
                    activeThreadIDs.remove(thread.id)
                    reconcileOrphanedRun(threadID: thread.id)
                }
                if thread.titleSource == .provisional,
                   model.providerRuns(threadID: thread.id).contains(where: { $0.state == .completed }) {
                    scheduleTitleIfNeeded(threadID: thread.id)
                }
            }
            try? await _Concurrency.Task.sleep(for: .milliseconds(200))
        }
    }

    private func consume(_ serviceEvent: KanameConversationServiceEvent) {
        if serviceEvent.kind == .serviceStarted {
            _ = model.beginProviderRun(id: serviceEvent.runID)
            if let nativeThreadID = serviceEvent.nativeThreadID, let nativeTurnID = serviceEvent.nativeTurnID {
                model.attachNativeProviderRun(id: serviceEvent.runID, nativeThreadID: nativeThreadID, nativeTurnID: nativeTurnID)
            }
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
            _ = model.recordProviderEvent(record)
            model.stopProviderRun(id: serviceEvent.runID, interrupted: false, error: record.detail)
            return
        }
        guard let providerKind = serviceEvent.providerKind else { return }
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
        let record = providerEventRecord(
            event,
            id: serviceEvent.id,
            threadID: serviceEvent.threadID,
            runID: serviceEvent.runID,
            createdAtUnixMillis: serviceEvent.createdAtUnixMillis
        )
        _ = model.recordProviderEvent(
            record,
            assistantDelta: event.kind == .messageDelta ? event.text : nil
        )
        if event.kind == .planUpdated, let text = event.text {
            model.addProviderPlan(threadID: serviceEvent.threadID, text: text, completed: false)
        }

        switch event.kind {
        case .providerCompleted:
            model.completeProviderRun(id: serviceEvent.runID, tokenUsage: tokenUsage(from: event.payload))
            scheduleTitleIfNeeded(threadID: serviceEvent.threadID)
        case .runInterrupted:
            model.stopProviderRun(id: serviceEvent.runID, interrupted: true, error: event.text ?? "The provider turn was interrupted.")
        case .runFailed:
            model.stopProviderRun(id: serviceEvent.runID, interrupted: false, error: event.text ?? "The provider stopped without a readable result.")
        case .sessionStarted, .runStarted, .messageDelta, .itemStarted, .itemCompleted,
             .planUpdated, .approvalRequested, .approvalAccepted, .approvalRejected,
             .questionRequested, .questionAnswered, .toolActivity, .diffUpdated, .nativeProviderEvent:
            break
        }
    }

    private func reconcileOrphanedRun(threadID: String) {
        guard let running = model.providerRuns(threadID: threadID).last(where: { $0.state == .running }) else {
            orphanChecks[threadID] = 0
            return
        }
        let count = (orphanChecks[threadID] ?? 0) + 1
        orphanChecks[threadID] = count
        if count >= 5 {
            model.stopProviderRun(
                id: running.id,
                interrupted: true,
                error: "The durable provider worker stopped before completion. Retry reuses the saved user message."
            )
            orphanChecks[threadID] = 0
        }
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
              let workspace = model.workspaceURL(threadID: threadID) else { return }
        titleTasks[threadID] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            defer { titleTasks.removeValue(forKey: threadID) }
            do {
                let title = try await generateTitle(firstMessage: firstMessage, workspace: workspace)
                if !model.applyProviderGeneratedTitle(threadID: threadID, title: title) {
                    model.markProviderTitleFallback(threadID: threadID)
                }
            } catch {
                model.markProviderTitleFallback(threadID: threadID)
            }
        }
    }

    private func generateTitle(firstMessage: String, workspace: URL) async throws -> String {
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
                    prompt: "Create a concise conversation title of at most 8 words. Return only the title, without quotes or punctuation decoration.\n\nFirst user message:\n\(firstMessage)",
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

    private func providerPrompt(thread: DesktopThread, userMessage: String) -> String {
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

    private func resolvedModel(_ value: String) -> String {
        value == "Use provider default" ? "gpt-5.6-terra" : value
    }

    private func providerEventRecord(
        _ event: CodexRunEvent,
        id: String,
        threadID: String,
        runID: String,
        createdAtUnixMillis: Int64
    ) -> DesktopProviderEventRecord {
        let presentation = Self.presentation(for: event)
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

    private static func presentation(for event: CodexRunEvent) -> (
        kind: DesktopProviderEventKind,
        title: String,
        detail: String
    ) {
        switch event.kind {
        case .sessionStarted: (.status, "Provider connected", "A private Codex session is attached to this conversation.")
        case .runStarted: (.status, "Turn started", "Codex is working in the selected read-only context.")
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
        case .questionRequested: (.question, "Codex has a question", "Answer to continue this turn.")
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
