import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

extension DesktopAppModel {
    public var activeThreads: [DesktopThread] {
        snapshot.threads
            .filter { $0.attention != .archived }
            .sorted {
                $0.createdAtUnixMillis == $1.createdAtUnixMillis
                    ? $0.id < $1.id
                    : $0.createdAtUnixMillis > $1.createdAtUnixMillis
            }
    }

    public var archivedThreads: [DesktopThread] {
        snapshot.threads
            .filter { $0.attention == .archived }
            .sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }
    }

    public func thread(id: String?) -> DesktopThread? {
        guard let id else { return nil }
        return snapshot.threads.first { $0.id == id }
    }

    public func threads(matching query: String, attention: DesktopAttention? = nil) -> [DesktopThread] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return activeThreads.filter { thread in
            let matchesAttention = attention == nil || thread.attention == attention
            let matchesQuery = normalized.isEmpty
                || thread.title.lowercased().contains(normalized)
                || thread.summary.lowercased().contains(normalized)
                || thread.messages.contains { $0.body.lowercased().contains(normalized) }
            return matchesAttention && matchesQuery
        }
    }

    @discardableResult
    public func createThread(
        title: String,
        kind: DesktopWorkKind,
        projectID: String?
    ) -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 160 else { return nil }
        let timestamp = now()
        let thread = DesktopThread(
            projectID: projectID,
            title: cleanTitle,
            summary: "Local conversation ready. No provider or external service has been started.",
            kind: kind,
            attention: .queued,
            updatedAtUnixMillis: timestamp,
            messages: [
                DesktopMessage(
                    role: .system,
                    body: "Created locally in Kaname. Choose a validated execution surface before granting provider or write authority.",
                    createdAtUnixMillis: timestamp
                ),
            ]
        )
        mutate { $0.threads.append(thread) }
        return thread.id
    }

    public func createConversation(
        kind: DesktopWorkKind,
        projectID: String?,
        provider: String? = nil,
        model: String? = nil,
        reasoningEffort: String = "medium",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false
    ) -> String {
        let timestamp = now()
        let selectedProvider = provider ?? project(id: projectID)?.context.defaultProvider ?? "Codex"
        let selectedModel = model ?? project(id: projectID)?.context.defaultModel ?? "Use provider default"
        let thread = DesktopThread(
            projectID: projectID,
            title: kind.newConversationTitle,
            summary: "Ready for your first message.",
            kind: kind,
            attention: .queued,
            provider: selectedProvider,
            model: selectedModel,
            reasoningEffort: reasoningEffort,
            runtimeMode: runtimeMode,
            networkAccess: runtimeMode == .fullAccess ? true : networkAccess,
            titleSource: .placeholder,
            updatedAtUnixMillis: timestamp
        )
        mutate { $0.threads.append(thread) }
        return thread.id
    }

    public func createOrReuseConversationDraft(
        kind: DesktopWorkKind,
        projectID: String?,
        provider: String? = nil,
        model: String? = nil,
        reasoningEffort: String = "medium",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false
    ) -> String {
        let selectedProvider = provider ?? project(id: projectID)?.context.defaultProvider ?? "Codex"
        let selectedModel = model ?? project(id: projectID)?.context.defaultModel ?? "Use provider default"
        if let existing = snapshot.threads.last(where: { thread in
            thread.projectID == projectID
                && thread.kind == kind
                && thread.titleSource == .placeholder
                && thread.messages.isEmpty
                && !snapshot.operations.providerRuns.contains { $0.threadID == thread.id }
        }) {
            mutate { snapshot in
                guard let index = snapshot.threads.firstIndex(where: { $0.id == existing.id }) else { return }
                snapshot.threads[index].provider = selectedProvider
                snapshot.threads[index].model = selectedModel
                snapshot.threads[index].reasoningEffort = reasoningEffort
                snapshot.threads[index].runtimeMode = runtimeMode
                snapshot.threads[index].networkAccess = runtimeMode == .fullAccess ? true : networkAccess
                snapshot.threads[index].updatedAtUnixMillis = now()
            }
            return existing.id
        }
        return createConversation(
            kind: kind,
            projectID: projectID,
            provider: selectedProvider,
            model: selectedModel,
            reasoningEffort: reasoningEffort,
            runtimeMode: runtimeMode,
            networkAccess: networkAccess
        )
    }

    /// Compacts a thread: keeps every message on disk, but marks a cut so that
    /// providers start a fresh native session seeded with a bounded digest of the
    /// conversation so far. Provider-neutral and instant (no LLM call).
    @discardableResult
    public func compactThread(threadID: String) -> Bool {
        guard let thread = thread(id: threadID), thread.messages.count >= 2,
              let lastMessage = thread.messages.last else { return false }
        let digest = Self.compactionDigest(thread: thread)
        let compaction = DesktopThreadCompaction(
            summary: digest,
            throughMessageID: lastMessage.id,
            messageCount: thread.messages.count,
            createdAtUnixMillis: now()
        )
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].compaction = compaction
            snapshot.threads[index].updatedAtUnixMillis = compaction.createdAtUnixMillis
        }
        return persistenceError == nil
    }

    /// Replaces the compaction digest with a better summary (for example one a
    /// model wrote) as long as the compaction it was written for is still the
    /// current one. Returns false when the thread was compacted again since.
    @discardableResult
    public func updateCompactionSummary(threadID: String, throughMessageID: String, summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let thread = thread(id: threadID),
              let compaction = thread.compaction,
              compaction.throughMessageID == throughMessageID else { return false }
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }),
                  snapshot.threads[index].compaction?.throughMessageID == throughMessageID else { return }
            snapshot.threads[index].compaction?.summary = KanameTextBounds.utf8Prefix(trimmed, maximumBytes: 12_000)
        }
        return persistenceError == nil
    }

    static func compactionDigest(thread: DesktopThread) -> String {
        func clip(_ text: String, _ bytes: Int) -> String {
            let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return KanameTextBounds.utf8Prefix(flat, maximumBytes: bytes) + (flat.utf8.count > bytes ? "…" : "")
        }
        var parts: [String] = []
        if let first = thread.messages.first(where: { $0.role == .user }) {
            parts.append("Original request:\n" + clip(first.body, 1_200))
        }
        if let plan = thread.planBody, !plan.isEmpty {
            parts.append("Current plan:\n" + clip(plan, 2_400))
        } else if !thread.plan.isEmpty {
            parts.append("Current plan:\n" + thread.plan.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n"))
        }
        if let findings = thread.findings, !findings.isEmpty {
            parts.append("Findings so far:\n" + findings.suffix(12).map { "- " + clip($0.detail, 240) }.joined(separator: "\n"))
        }
        let recent = thread.messages.suffix(8).filter { $0.role != .system }
        if !recent.isEmpty {
            parts.append("Most recent exchange:\n" + recent.map { "\($0.role == .user ? "User" : "Assistant"): " + clip($0.body, 600) }.joined(separator: "\n\n"))
        }
        if let previous = thread.compaction?.summary, !previous.isEmpty {
            parts.append("Earlier compaction digest:\n" + clip(previous, 1_500))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Appends a Kaname-authored note to a thread (for example a pull request link).
    @discardableResult
    public func appendSystemMessage(threadID: String, body: String) -> String? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty, cleanBody.utf8.count <= 32_000 else { return nil }
        let message = DesktopMessage(role: .system, body: cleanBody, createdAtUnixMillis: now())
        var appended = false
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[index].messages.append(message)
            appended = true
        }
        return appended ? message.id : nil
    }

    public func appendUserMessage(
        threadID: String,
        body: String,
        attachments: [ConversationImageAttachment] = []
    ) -> String? {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!cleanBody.isEmpty || !attachments.isEmpty),
              cleanBody.utf8.count <= 32_000,
              attachments.count <= ConversationImageAttachment.maximumCountPerMessage else { return nil }
        let timestamp = now()
        let message = DesktopMessage(
            role: .user,
            body: cleanBody,
            attachments: attachments,
            createdAtUnixMillis: timestamp
        )
        mutate { snapshot in
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            let shouldProjectTitle = snapshot.threads[index].title == snapshot.threads[index].kind.newConversationTitle
                && !snapshot.threads[index].messages.contains { $0.role == .user }
            snapshot.threads[index].messages.append(message)
            if shouldProjectTitle {
                snapshot.threads[index].title = Self.provisionalConversationTitle(
                    from: cleanBody.isEmpty ? attachments.first?.filename ?? "Image conversation" : cleanBody
                )
                snapshot.threads[index].titleSource = .provisional
            }
            snapshot.threads[index].summary = cleanBody.isEmpty
                ? "\(attachments.count) image\(attachments.count == 1 ? "" : "s") attached"
                : cleanBody
            snapshot.threads[index].attention = .queued
            snapshot.threads[index].updatedAtUnixMillis = timestamp
            snapshot.threads[index].unread = false
        }
        return snapshot.threads.contains(where: { $0.id == threadID && $0.messages.contains(where: { $0.id == message.id }) })
            ? message.id
            : nil
    }

    public func renameThread(id: String, title: String) -> Bool {
        let cleanTitle = Self.normalized(title)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 160 else { return false }
        return mutateThread(id: id) { thread in
            thread.title = cleanTitle
            thread.titleSource = .manual
            thread.updatedAtUnixMillis = now()
        }
    }

    public func updateThreadRuntime(
        id: String,
        provider: String,
        model: String,
        reasoningEffort: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> Bool {
        let cleanProvider = Self.normalized(provider)
        let cleanModel = Self.normalized(model)
        let cleanReasoning = Self.normalized(reasoningEffort).lowercased()
        guard !cleanProvider.isEmpty, cleanProvider.utf8.count <= 120,
              !cleanModel.isEmpty, cleanModel.utf8.count <= 200,
              Self.isBoundedProviderIdentifier(cleanReasoning),
              !snapshot.operations.providerRuns.contains(where: { $0.threadID == id && $0.state == .running }) else {
            return false
        }
        return mutateThread(id: id) { thread in
            thread.provider = cleanProvider
            thread.model = cleanModel
            thread.reasoningEffort = cleanReasoning
            thread.runtimeMode = runtimeMode
            thread.networkAccess = runtimeMode == .fullAccess ? true : networkAccess
            thread.updatedAtUnixMillis = now()
        }
    }

    public func applyProviderGeneratedTitle(threadID: String, title: String) -> Bool {
        guard let cleanTitle = DesktopConversationTitleGeneration.normalizedTitle(from: title) else { return false }
        guard thread(id: threadID)?.titleSource == .provisional else { return false }
        return mutateThread(id: threadID) { thread in
            thread.title = cleanTitle
            thread.titleSource = .providerGenerated
            thread.updatedAtUnixMillis = now()
        }
    }

    public func applyProviderRegeneratedTitle(
        threadID: String,
        title: String,
        expectedTitle: String,
        expectedSource: DesktopConversationTitleSource
    ) -> Bool {
        guard let cleanTitle = DesktopConversationTitleGeneration.normalizedTitle(from: title),
              let current = thread(id: threadID),
              cleanTitle != expectedTitle,
              current.title == expectedTitle,
              current.titleSource == expectedSource else { return false }
        return mutateThread(id: threadID) { thread in
            thread.title = cleanTitle
            thread.titleSource = .providerGenerated
            thread.updatedAtUnixMillis = now()
        }
    }

    public func markProviderTitleFallback(threadID: String) {
        guard thread(id: threadID)?.titleSource == .provisional else { return }
        mutateThread(id: threadID) { thread in
            thread.titleSource = .providerFallback
        }
    }

    public func message(threadID: String, id: String) -> DesktopMessage? {
        thread(id: threadID)?.messages.first { $0.id == id }
    }

    public func workspaceURL(threadID: String) -> URL? {
        guard let thread = thread(id: threadID), let projectID = thread.projectID else { return nil }
        if let path = project(id: projectID)?.path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard let path = snapshot.domains.gitWorkspaces.first(where: {
            $0.projectID == projectID && $0.status == .ready
        })?.localPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public func setAttention(threadID: String, attention: DesktopAttention) {
        mutateThread(id: threadID) { thread in
            thread.attention = attention
            thread.updatedAtUnixMillis = now()
            if attention == .completed || attention == .archived {
                thread.unread = false
            }
        }
    }

    public func markRead(threadID: String) {
        mutateThread(id: threadID) { $0.unread = false }
    }

    private static func isBoundedProviderIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil
    }
}
