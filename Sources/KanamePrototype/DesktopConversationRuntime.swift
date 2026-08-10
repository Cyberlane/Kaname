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
    private var sessions: [String: CodexLiveSession] = [:]
    private var eventTasks: [String: _Concurrency.Task<Void, Never>] = [:]
    private var recorders: [String: CodexJournalRecorder] = [:]
    private var currentRunIDs: [String: String] = [:]
    private var eventOrdinals: [String: Int] = [:]
    private var titleTasks: [String: _Concurrency.Task<Void, Never>] = [:]

    init(model: DesktopAppModel) {
        self.model = model
        model.recoverOrphanedProviderRuns()
    }

    deinit {
        for task in eventTasks.values { task.cancel() }
        for task in titleTasks.values { task.cancel() }
    }

    func send(threadID: String, body: String) {
        guard let messageID = model.appendUserMessage(threadID: threadID, body: body),
              model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID) != nil else { return }
        scheduleNext(threadID: threadID)
    }

    func retry(runID: String) {
        guard let threadID = model.providerRun(id: runID)?.threadID,
              model.retryProviderRun(id: runID) != nil else { return }
        scheduleNext(threadID: threadID)
    }

    func interrupt(threadID: String) {
        guard let session = sessions[threadID] else { return }
        _Concurrency.Task {
            do {
                try await session.interrupt()
            } catch {
                if let runID = currentRunIDs[threadID] {
                    model.stopProviderRun(id: runID, interrupted: true, error: error.localizedDescription)
                }
                await releaseSession(threadID: threadID)
            }
        }
    }

    func answerQuestion(threadID: String, event: DesktopProviderEventRecord, answer: String) {
        guard let session = sessions[threadID], let approvalID = event.approvalID else { return }
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAnswer.isEmpty, cleanAnswer.utf8.count <= 4_096 else { return }
        let questionIDs = Self.questionIDs(from: event.rawPayloadBase64)
        guard !questionIDs.isEmpty else { return }
        _Concurrency.Task {
            do {
                try await session.answerQuestion(
                    requestID: approvalID,
                    answers: Dictionary(uniqueKeysWithValues: questionIDs.map { ($0, [cleanAnswer]) })
                )
            } catch {
                if let runID = currentRunIDs[threadID] {
                    model.stopProviderRun(id: runID, interrupted: false, error: error.localizedDescription)
                }
                await releaseSession(threadID: threadID)
            }
        }
    }

    func isRunning(threadID: String) -> Bool {
        activeThreadIDs.contains(threadID)
    }

    private func scheduleNext(threadID: String) {
        guard !activeThreadIDs.contains(threadID) else { return }
        activeThreadIDs.insert(threadID)
        _Concurrency.Task { await runNext(threadID: threadID) }
    }

    private func runNext(threadID: String) async {
        guard let queued = model.nextQueuedProviderRun(threadID: threadID),
              let run = model.beginProviderRun(id: queued.id),
              let sourceMessageID = run.sourceMessageID,
              let message = model.message(threadID: threadID, id: sourceMessageID),
              let thread = model.thread(id: threadID) else {
            activeThreadIDs.remove(threadID)
            return
        }
        guard run.provider.caseInsensitiveCompare("Codex") == .orderedSame else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "\(run.provider) does not yet support the unified streaming runtime. Choose Codex or use its bounded Coding discussion surface."
            )
            activeThreadIDs.remove(threadID)
            scheduleNextIfQueued(threadID: threadID)
            return
        }
        let workspace: URL
        if let projectWorkspace = model.workspaceURL(threadID: threadID) {
            workspace = projectWorkspace
        } else if thread.projectID == nil, let standaloneWorkspace = try? Self.prepareStandaloneWorkspace() {
            workspace = standaloneWorkspace
        } else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "Choose a valid project workspace before starting a provider. The message remains saved locally."
            )
            activeThreadIDs.remove(threadID)
            return
        }
        guard let runner = LocalCoreRunner.bundled() else {
            model.stopProviderRun(
                id: run.id,
                interrupted: false,
                error: "The signed local journal service is unavailable, so Kaname did not send the message."
            )
            activeThreadIDs.remove(threadID)
            return
        }
        let projectID = KanameID(rawValue: thread.projectID ?? "standalone")
        let productThreadID = KanameID(rawValue: threadID)
        let productRunID = KanameID(rawValue: run.id)

        let providerInstance = ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
        recorders[threadID] = CodexJournalRecorder(
            runner: runner,
            context: CodexJournalContext(
                projectID: projectID,
                threadID: productThreadID,
                runID: productRunID,
                providerInstance: providerInstance
            )
        )
        currentRunIDs[threadID] = run.id
        eventOrdinals[run.id] = 0

        let request = CodexCodingRequest(
            prompt: providerPrompt(thread: thread, userMessage: message.body),
            model: resolvedModel(run.model),
            reasoningEffort: run.reasoningEffort,
            sandbox: .readOnly
        )
        do {
            let liveRun: CodexLiveRun
            if let existing = sessions[threadID] {
                liveRun = try await existing.continueRun(request)
            } else {
                let session = makeSession(instance: providerInstance, workspace: workspace)
                sessions[threadID] = session
                observe(session: session, threadID: threadID)
                let resumableThreadID = model.latestNativeThreadID(threadID: threadID)
                do {
                    liveRun = try await session.start(request, resumingNativeThreadID: resumableThreadID)
                } catch {
                    guard resumableThreadID != nil else { throw error }
                    await releaseSession(threadID: threadID, preserveActiveState: true)
                    let replacement = makeSession(instance: providerInstance, workspace: workspace)
                    sessions[threadID] = replacement
                    observe(session: replacement, threadID: threadID)
                    liveRun = try await replacement.start(request)
                }
            }
            model.attachNativeProviderRun(
                id: run.id,
                nativeThreadID: liveRun.nativeThreadID,
                nativeTurnID: liveRun.nativeTurnID
            )
        } catch {
            model.stopProviderRun(id: run.id, interrupted: false, error: error.localizedDescription)
            await releaseSession(threadID: threadID)
        }
    }

    private func observe(session: CodexLiveSession, threadID: String) {
        eventTasks[threadID]?.cancel()
        eventTasks[threadID] = _Concurrency.Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                guard let self else { return }
                await self.consume(event, threadID: threadID)
            }
        }
    }

    private func consume(_ event: CodexRunEvent, threadID: String) async {
        guard let runID = currentRunIDs[threadID], let recorder = recorders[threadID] else { return }
        do {
            _ = try await recorder.record(event)
        } catch {
            model.stopProviderRun(
                id: runID,
                interrupted: false,
                error: "The local journal rejected a provider observation. The run stopped without accepting a result."
            )
            await releaseSession(threadID: threadID)
            return
        }

        let ordinal = (eventOrdinals[runID] ?? 0) + 1
        eventOrdinals[runID] = ordinal
        let record = providerEventRecord(event, threadID: threadID, runID: runID, ordinal: ordinal)
        _ = model.recordProviderEvent(
            record,
            assistantDelta: event.kind == .messageDelta ? event.text : nil
        )
        if event.kind == .planUpdated, let text = event.text {
            model.addProviderPlan(threadID: threadID, text: text, completed: false)
        }

        switch event.kind {
        case .providerCompleted:
            model.completeProviderRun(id: runID, tokenUsage: tokenUsage(from: event.payload))
            currentRunIDs.removeValue(forKey: threadID)
            recorders.removeValue(forKey: threadID)
            eventOrdinals.removeValue(forKey: runID)
            activeThreadIDs.remove(threadID)
            scheduleTitleIfNeeded(threadID: threadID)
            scheduleNextIfQueued(threadID: threadID)
        case .runInterrupted:
            model.stopProviderRun(id: runID, interrupted: true, error: event.text ?? "The provider turn was interrupted.")
            await releaseSession(threadID: threadID)
            scheduleNextIfQueued(threadID: threadID)
        case .runFailed:
            model.stopProviderRun(id: runID, interrupted: false, error: event.text ?? "The provider stopped without a readable result.")
            await releaseSession(threadID: threadID)
            scheduleNextIfQueued(threadID: threadID)
        case .sessionStarted, .runStarted, .messageDelta, .itemStarted, .itemCompleted,
             .planUpdated, .approvalRequested, .approvalAccepted, .approvalRejected,
             .questionRequested, .questionAnswered, .toolActivity, .diffUpdated, .nativeProviderEvent:
            break
        }
    }

    private func scheduleNextIfQueued(threadID: String) {
        if model.nextQueuedProviderRun(threadID: threadID) != nil {
            scheduleNext(threadID: threadID)
        }
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

    private func releaseSession(threadID: String, preserveActiveState: Bool = false) async {
        let session = sessions.removeValue(forKey: threadID)
        eventTasks.removeValue(forKey: threadID)?.cancel()
        recorders.removeValue(forKey: threadID)
        if !preserveActiveState {
            if let runID = currentRunIDs.removeValue(forKey: threadID) { eventOrdinals.removeValue(forKey: runID) }
            activeThreadIDs.remove(threadID)
        }
        await session?.close()
    }

    private func makeSession(instance: ProviderInstance, workspace: URL) -> CodexLiveSession {
        CodexLiveSession(
            configuration: .init(
                instance: instance,
                workspaceURL: workspace,
                persistentSessionDirectory: Self.providerStateDirectory
            )
        )
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
        threadID: String,
        runID: String,
        ordinal: Int
    ) -> DesktopProviderEventRecord {
        let presentation = Self.presentation(for: event)
        return DesktopProviderEventRecord(
            id: "\(runID)-\(ordinal)",
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
            createdAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
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

    private static var providerStateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Kaname", directoryHint: .isDirectory)
            .appending(path: "Desktop", directoryHint: .isDirectory)
            .appending(path: "Codex", directoryHint: .isDirectory)
    }

    private static func prepareStandaloneWorkspace() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Kaname", directoryHint: .isDirectory)
            .appending(path: "Desktop", directoryHint: .isDirectory)
            .appending(path: "Standalone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }
}
