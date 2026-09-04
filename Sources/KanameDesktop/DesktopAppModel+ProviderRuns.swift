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
    public func providerEvents(threadID: String) -> [DesktopProviderEventRecord] {
        snapshot.operations.providerEvents
            .filter { $0.threadID == threadID }
            .sorted { $0.createdAtUnixMillis < $1.createdAtUnixMillis }
    }

    public func providerRuns(threadID: String) -> [DesktopProviderRunRecord] {
        snapshot.operations.providerRuns
            .filter { $0.threadID == threadID }
            .sorted { $0.startedAtUnixMillis < $1.startedAtUnixMillis }
    }

    public func providerRun(id: String) -> DesktopProviderRunRecord? {
        snapshot.operations.providerRuns.first { $0.id == id }
    }

    public var providerActivityThreadIDsRequiringPolling: Set<String> {
        let providerRunThreadIDs: [String] = snapshot.operations.providerRuns.compactMap { run -> String? in
            guard run.state == .proposed || run.state == .running else { return nil }
            return run.threadID
        }
        let activeSubagentThreadIDs: [String] = snapshot.operations.subagents.compactMap { subagent -> String? in
            guard Self.isActiveSubagentState(subagent.state) else { return nil }
            return subagent.threadID
        }
        return Set(providerRunThreadIDs).union(activeSubagentThreadIDs)
    }

    public func hasActiveSubagents(threadID: String) -> Bool {
        snapshot.operations.subagents.contains {
            $0.threadID == threadID && Self.isActiveSubagentState($0.state)
        }
    }

    @discardableResult
    public func recoverOrphanedSubagents(threadID: String) -> Bool {
        guard hasActiveSubagents(threadID: threadID) else { return true }
        let timestamp = now()
        return mutate { snapshot in
            Self.interruptActiveSubagents(in: &snapshot, threadID: threadID, timestamp: timestamp)
        }
    }

    @discardableResult
    public func enqueueProviderRun(
        threadID: String,
        sourceMessageID: String,
        usesProjectContext: Bool = true,
        workspacePathOverride: String? = nil,
        purpose: DesktopProviderRunPurpose = .conversation,
        runtimeModeOverride: ConversationRuntimeMode? = nil,
        networkAccessOverride: Bool? = nil
    ) -> String? {
        guard let thread = thread(id: threadID),
              let message = thread.messages.first(where: { $0.id == sourceMessageID && $0.role == .user }) else {
            return nil
        }
        if purpose == .codingPlan,
           let state = codingWorkflow(threadID: threadID)?.state,
           ![.discussing, .awaitingPlanApproval, .completed, .rejected, .failed].contains(state) {
            return nil
        }
        let run = DesktopProviderRunRecord(
            id: UUID().uuidString.lowercased(),
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            turnID: message.turnID ?? message.id,
            provider: thread.provider,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort,
            runtimeMode: runtimeModeOverride ?? thread.runtimeMode,
            networkAccess: networkAccessOverride ?? thread.networkAccess,
            briefDigest: Self.stableLocalDigest(message.body),
            contextReferenceCount: providerContextReferenceCount(for: thread),
            tokenUsage: nil,
            costSummary: "Pending",
            state: .proposed,
            startedAtUnixMillis: now(),
            completedAtUnixMillis: nil,
            usesProjectContext: usesProjectContext,
            workspacePathOverride: workspacePathOverride,
            purpose: purpose
        )
        let persisted = mutate { snapshot in
            snapshot.operations.providerRuns.append(run)
            guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            if purpose == .codingPlan {
                if let laneIndex = snapshot.operations.codingKnowledgeLanes.firstIndex(where: {
                    $0.threadID == threadID
                }) {
                    snapshot.operations.codingKnowledgeLanes[laneIndex].consultedSources.removeAll()
                    snapshot.operations.codingKnowledgeLanes[laneIndex].candidates.removeAll()
                    snapshot.operations.codingKnowledgeLanes[laneIndex].disposition = .collecting
                    snapshot.operations.codingKnowledgeLanes[laneIndex].dispositionReason = "A new coding cycle is collecting exact context and durable candidates."
                    snapshot.operations.codingKnowledgeLanes[laneIndex].acceptedWorktreeID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].proposalID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].writeID = nil
                    snapshot.operations.codingKnowledgeLanes[laneIndex].updatedAtUnixMillis = now()
                }
                // A planning turn refines the existing plan; only a fresh cycle
                // after completion, rejection, or failure starts from nothing.
                let previousState = snapshot.operations.codingWorkflows.first(where: { $0.threadID == threadID })?.state
                if [.completed, .rejected, .failed].contains(previousState ?? .discussing) {
                    snapshot.threads[index].plan.removeAll()
                    snapshot.threads[index].planBody = nil
                }
                snapshot.threads[index].evidence.removeAll()
                snapshot.threads[index].summary = "Planning…"
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .planning,
                    reason: "Read-only implementation planning is running.",
                    timestamp: now()
                )
            } else if purpose == .codingImplementation {
                Self.setCodingWorkflow(
                    in: &snapshot,
                    threadID: threadID,
                    state: .preparingImplementation,
                    reason: "The approved implementation is being prepared in an isolated worktree.",
                    timestamp: now()
                )
            }
            if !snapshot.operations.providerRuns.contains(where: {
                $0.threadID == threadID && $0.id != run.id && $0.state == .running
            }) {
                snapshot.threads[index].attention = .queued
            }
            snapshot.threads[index].updatedAtUnixMillis = now()
        }
        return persisted ? run.id : nil
    }

    public func nextQueuedProviderRun(threadID: String) -> DesktopProviderRunRecord? {
        snapshot.operations.providerRuns
            .filter { $0.threadID == threadID && $0.state == .proposed }
            .min { $0.startedAtUnixMillis < $1.startedAtUnixMillis }
    }

    public func beginProviderRun(id: String) -> DesktopProviderRunRecord? {
        var selected: DesktopProviderRunRecord?
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: {
                $0.id == id && $0.state == .proposed
            }) else { return }
            snapshot.operations.providerRuns[index].state = .running
            snapshot.operations.providerRuns[index].costSummary = "Running"
            selected = snapshot.operations.providerRuns[index]
            if let threadID = selected?.threadID,
               let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                snapshot.threads[threadIndex].attention = .running
                switch selected?.purpose {
                case .codingPlan:
                    snapshot.threads[threadIndex].summary = "Creating a read-only implementation plan…"
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .planning,
                        reason: "Read-only implementation planning is running.",
                        timestamp: now()
                    )
                case .codingImplementation:
                    snapshot.threads[threadIndex].summary = "Implementing the approved plan in an isolated worktree…"
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .implementing,
                        reason: "The approved plan is being implemented in an isolated worktree.",
                        timestamp: now()
                    )
                case .codingKnowledge:
                    snapshot.threads[threadIndex].summary = "Drafting the knowledge update…"
                case .conversation, nil:
                    snapshot.threads[threadIndex].summary = "Kaname is responding…"
                }
                snapshot.threads[threadIndex].updatedAtUnixMillis = now()
            }
        }
        return selected
    }

    public func attachNativeProviderRun(id: String, nativeThreadID: String, nativeTurnID: String?) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: { $0.id == id }) else { return }
            snapshot.operations.providerRuns[index].nativeThreadID = nativeThreadID
            if let nativeTurnID {
                snapshot.operations.providerRuns[index].nativeTurnID = nativeTurnID
            }
            guard let threadID = snapshot.operations.providerRuns[index].threadID else { return }
            let provider = snapshot.operations.providerRuns[index].provider
            let sessionID = "session-\(Self.stableLocalDigest("\(provider)|\(nativeThreadID)"))"
            let descriptor = Self.providerSessionDescriptor(provider: provider)
            let session = DesktopProviderSessionRecord(
                id: sessionID,
                threadID: threadID,
                provider: provider,
                nativeSessionID: nativeThreadID,
                source: "Kaname native adapter",
                capabilities: descriptor.capabilities,
                limitations: descriptor.limitations,
                state: .running,
                lastReconciledAtUnixMillis: timestamp
            )
            if let sessionIndex = snapshot.operations.providerSessions.firstIndex(where: { $0.id == sessionID }) {
                snapshot.operations.providerSessions[sessionIndex] = session
            } else {
                snapshot.operations.providerSessions.append(session)
            }
        }
    }

    public func latestNativeThreadID(threadID: String, provider: String? = nil) -> String? {
        latestNativeThreadID(threadID: threadID, provider: provider, workspacePathOverride: nil, matchWorkspace: false)
    }

    /// Native provider sessions are bound to the directory they started in
    /// (Claude Code stores them per project path), so a run only resumes a
    /// session that was started in the same workspace.
    public func latestNativeThreadID(
        threadID: String,
        provider: String?,
        workspacePathOverride: String?,
        matchWorkspace: Bool = true
    ) -> String? {
        let compactedAt = thread(id: threadID)?.compaction?.createdAtUnixMillis
        return snapshot.operations.providerRuns
            .filter {
                guard $0.threadID == threadID, $0.nativeThreadID != nil else { return false }
                if let compactedAt = compactedAt, $0.startedAtUnixMillis < compactedAt { return false }
                if matchWorkspace, $0.workspacePathOverride != workspacePathOverride { return false }
                guard let provider else { return true }
                return $0.provider.caseInsensitiveCompare(provider) == .orderedSame
            }
            .max { $0.startedAtUnixMillis < $1.startedAtUnixMillis }?
            .nativeThreadID
    }

    @discardableResult
    public func recordProviderEvent(
        _ event: DesktopProviderEventRecord,
        assistantDelta: String? = nil
    ) -> Bool {
        recordProviderEvents([DesktopProviderEventBatchItem(event: event, assistantDelta: assistantDelta)])?
            .acceptedEventIDs.contains(event.id) == true
    }

    @discardableResult
    public func recordProviderEvents(
        _ items: [DesktopProviderEventBatchItem]
    ) -> DesktopProviderEventBatchResult? {
        guard items.count <= 64,
              items.allSatisfy({ item in
                  item.event.detail.utf8.count <= 65_536
                      && (item.event.rawPayloadBase64?.utf8.count ?? 0) <= 360_000
              }) else { return nil }
        guard items.allSatisfy({ item in
            guard let run = snapshot.operations.providerRuns.first(where: { $0.id == item.event.runID }) else { return false }
            return run.threadID == item.event.threadID
        }) else { return nil }
        guard !items.isEmpty else {
            return DesktopProviderEventBatchResult(acceptedEventIDs: [], duplicateEventIDs: [])
        }

        var batchEventIDs: Set<String> = []
        var acceptedItems: [DesktopProviderEventBatchItem] = []
        var duplicateEventIDs: [String] = []
        acceptedItems.reserveCapacity(items.count)
        for item in items {
            if !providerEventIDs.contains(item.event.id), batchEventIDs.insert(item.event.id).inserted {
                acceptedItems.append(item)
            } else {
                duplicateEventIDs.append(item.event.id)
            }
        }
        guard !acceptedItems.isEmpty else {
            return DesktopProviderEventBatchResult(acceptedEventIDs: [], duplicateEventIDs: duplicateEventIDs)
        }

        let persisted = mutate { snapshot in
            for item in acceptedItems {
                var event = item.event
                if let run = snapshot.operations.providerRuns.first(where: { $0.id == event.runID }) {
                    event.turnID = run.turnID
                }
                snapshot.operations.providerEvents.append(event)
                if event.kind == .approval {
                    if let index = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) {
                        snapshot.threads[index].attention = event.title == "Approval requested" ? .needsApproval : .running
                    }
                } else if event.kind == .question {
                    if let index = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) {
                        snapshot.threads[index].attention = event.title == "Question answered" ? .running : .needsInput
                    }
                }
                Self.applyAssistantDelta(item.assistantDelta, for: event, to: &snapshot)
            }
        }
        guard persisted else { return nil }
        providerEventIDs.formUnion(acceptedItems.map(\.event.id))
        return DesktopProviderEventBatchResult(
            acceptedEventIDs: acceptedItems.map(\.event.id),
            duplicateEventIDs: duplicateEventIDs
        )
    }

    private static func applyAssistantDelta(
        _ delta: String?,
        for event: DesktopProviderEventRecord,
        to snapshot: inout DesktopAppSnapshot
    ) {
        guard let delta, !delta.isEmpty,
              let threadIndex = snapshot.threads.firstIndex(where: { $0.id == event.threadID }) else { return }
        let messageID = "assistant-\(event.runID)"
        if let messageIndex = snapshot.threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }) {
            let current = snapshot.threads[threadIndex].messages[messageIndex]
            snapshot.threads[threadIndex].messages[messageIndex] = DesktopMessage(
                id: current.id,
                turnID: event.turnID,
                role: .assistant,
                body: String((current.body + delta).prefix(262_144)),
                attachments: current.attachments,
                createdAtUnixMillis: current.createdAtUnixMillis
            )
        } else {
            snapshot.threads[threadIndex].messages.append(
                DesktopMessage(
                    id: messageID,
                    turnID: event.turnID,
                    role: .assistant,
                    body: String(delta.prefix(262_144)),
                    createdAtUnixMillis: event.createdAtUnixMillis
                )
            )
        }
        snapshot.threads[threadIndex].summary = "Kaname is responding…"
    }

    public func completeProviderRun(id: String, tokenUsage: Int? = nil) {
        finishProviderRun(id: id, outcome: .completed(tokenUsage))
    }

    public func stopProviderRun(id: String, interrupted: Bool, error: String) {
        finishProviderRun(id: id, outcome: .stopped(interrupted: interrupted, error: Self.normalized(error)))
    }

    private enum ProviderRunOutcome {
        case completed(Int?)
        case stopped(interrupted: Bool, error: String)
    }

    private func finishProviderRun(id: String, outcome: ProviderRunOutcome) {
        let timestamp = now()
        mutate { snapshot in
            guard let index = snapshot.operations.providerRuns.firstIndex(where: { $0.id == id }) else { return }
            let sessionState: DesktopProviderSessionState
            let threadSummary: String
            let attention: DesktopAttention
            switch outcome {
            case let .completed(tokenUsage):
                snapshot.operations.providerRuns[index].state = .completed
                snapshot.operations.providerRuns[index].tokenUsage = tokenUsage
                snapshot.operations.providerRuns[index].costSummary = tokenUsage.map { "\($0) tokens" } ?? "Usage not reported"
                sessionState = .ready
                let threadID = snapshot.operations.providerRuns[index].threadID
                let assistant = snapshot.threads.first(where: { $0.id == threadID })?.messages.last(where: { $0.role == .assistant })?.body
                switch snapshot.operations.providerRuns[index].purpose {
                case .codingPlan:
                    attention = .needsApproval
                    threadSummary = "Plan ready. Approve it to start implementing, or keep refining in Chat."
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID ?? "",
                        state: .awaitingPlanApproval,
                        reason: "The read-only plan is ready for explicit approval.",
                        timestamp: timestamp
                    )
                case .codingImplementation:
                    attention = .needsApproval
                    threadSummary = "Implementation turn finished. Review Changes, run checks, or keep steering in Chat."
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID ?? "",
                        state: .awaitingReview,
                        reason: "Implementation finished; explicit review is required before independent evidence collection.",
                        timestamp: timestamp
                    )
                case .codingKnowledge:
                    attention = .needsApproval
                    threadSummary = "Knowledge update drafted. Review the proposed notes in the Knowledge tab."
                case .conversation:
                    attention = .needsResponse
                    threadSummary = assistant.map(Self.provisionalConversationTitle) ?? "Provider completed."
                }
            case let .stopped(interrupted, error):
                snapshot.operations.providerRuns[index].state = interrupted ? .interrupted : .failed
                snapshot.operations.providerRuns[index].errorSummary = error
                snapshot.operations.providerRuns[index].costSummary = interrupted ? "Interrupted" : "Failed"
                for subagentIndex in snapshot.operations.subagents.indices
                where snapshot.operations.subagents[subagentIndex].runID == id
                    && Self.isActiveSubagentState(snapshot.operations.subagents[subagentIndex].state) {
                    snapshot.operations.subagents[subagentIndex].state = interrupted ? .interrupted : .failed
                    snapshot.operations.subagents[subagentIndex].completedAtUnixMillis = timestamp
                }
                sessionState = interrupted ? .recoverable : .interrupted
                threadSummary = interrupted ? "Provider turn interrupted. You can retry it." : error
                attention = interrupted ? .needsResponse : .failed
                if snapshot.operations.providerRuns[index].purpose != .conversation,
                   let threadID = snapshot.operations.providerRuns[index].threadID {
                    Self.setCodingWorkflow(
                        in: &snapshot,
                        threadID: threadID,
                        state: .failed,
                        reason: threadSummary,
                        timestamp: timestamp
                    )
                }
            }
            snapshot.operations.providerRuns[index].completedAtUnixMillis = timestamp
            Self.reconcileProviderSession(
                snapshot: &snapshot,
                runIndex: index,
                state: sessionState,
                timestamp: timestamp
            )
            guard let threadID = snapshot.operations.providerRuns[index].threadID,
                  let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
            snapshot.threads[threadIndex].summary = threadSummary
            snapshot.threads[threadIndex].attention = attention
            snapshot.threads[threadIndex].unread = true
            snapshot.threads[threadIndex].updatedAtUnixMillis = timestamp
        }
    }

    public func recoverOrphanedProviderRuns() {
        let hasOrphanedProviderRun = snapshot.operations.providerRuns.contains { $0.state == .running }
        let hasOrphanedSubagent = snapshot.operations.subagents.contains { Self.isActiveSubagentState($0.state) }
        guard hasOrphanedProviderRun || hasOrphanedSubagent else { return }
        let timestamp = now()
        mutate { snapshot in
            let orphaned = snapshot.operations.providerRuns.indices.filter {
                snapshot.operations.providerRuns[$0].state == .running
            }
            for index in orphaned {
                snapshot.operations.providerRuns[index].state = .interrupted
                snapshot.operations.providerRuns[index].errorSummary = "The UI or provider stopped before completion. Resume or retry from the durable conversation."
                snapshot.operations.providerRuns[index].costSummary = "Reconnect required"
                snapshot.operations.providerRuns[index].completedAtUnixMillis = timestamp
                if let threadID = snapshot.operations.providerRuns[index].threadID,
                   let threadIndex = snapshot.threads.firstIndex(where: { $0.id == threadID }) {
                    snapshot.threads[threadIndex].attention = .needsResponse
                    snapshot.threads[threadIndex].summary = "A provider turn needs recovery. No message was duplicated."
                    if snapshot.operations.providerRuns[index].purpose != .conversation {
                        Self.setCodingWorkflow(
                            in: &snapshot,
                            threadID: threadID,
                            state: .failed,
                            reason: "The coding provider stopped before completion; no result was accepted.",
                            timestamp: timestamp
                        )
                    }
                }
            }
            Self.interruptActiveSubagents(in: &snapshot, threadID: nil, timestamp: timestamp)
        }
    }

    private static func isActiveSubagentState(_ state: DesktopSubagentState) -> Bool {
        [.queued, .running, .waiting].contains(state)
    }

    private static func interruptActiveSubagents(
        in snapshot: inout DesktopAppSnapshot,
        threadID: String?,
        timestamp: Int64
    ) {
        for subagentIndex in snapshot.operations.subagents.indices
        where (threadID == nil || snapshot.operations.subagents[subagentIndex].threadID == threadID)
            && Self.isActiveSubagentState(snapshot.operations.subagents[subagentIndex].state) {
            snapshot.operations.subagents[subagentIndex].state = .interrupted
            snapshot.operations.subagents[subagentIndex].completedAtUnixMillis = timestamp
        }
    }

    private static func reconcileProviderSession(
        snapshot: inout DesktopAppSnapshot,
        runIndex: Int,
        state: DesktopProviderSessionState,
        timestamp: Int64
    ) {
        let run = snapshot.operations.providerRuns[runIndex]
        guard let nativeID = run.nativeThreadID,
              let sessionIndex = snapshot.operations.providerSessions.firstIndex(where: {
                  $0.nativeSessionID == nativeID
                      && $0.provider.caseInsensitiveCompare(run.provider) == .orderedSame
              }) else { return }
        snapshot.operations.providerSessions[sessionIndex].state = state
        snapshot.operations.providerSessions[sessionIndex].lastReconciledAtUnixMillis = timestamp
    }

    @discardableResult
    public func retryProviderRun(id: String) -> String? {
        guard let run = providerRun(id: id), let threadID = run.threadID, let sourceMessageID = run.sourceMessageID,
              [.failed, .interrupted].contains(run.state), run.purpose != .codingImplementation else { return nil }
        return enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: sourceMessageID,
            usesProjectContext: run.usesProjectContext ?? true,
            workspacePathOverride: run.workspacePathOverride,
            purpose: run.purpose,
            runtimeModeOverride: run.runtimeMode,
            networkAccessOverride: run.networkAccess
        )
    }

    private func providerContextReferenceCount(for thread: DesktopThread) -> Int {
        guard let project = project(id: thread.projectID) else { return 0 }
        return project.context.instructionReferences.count
            + project.context.knowledgeSourceIDs.count
            + project.context.skillIDs.count
    }

    private static func providerSessionDescriptor(provider: String) -> (
        capabilities: [String],
        limitations: [String]
    ) {
        switch provider.lowercased() {
        case "codex":
            (["Streaming", "Persistent resume", "Questions", "Approvals", "Diff events"], [])
        case "claude":
            (["Streaming", "Persistent resume", "Plan mode", "Subagent events"], ["Kaname keeps writes disabled until a worktree grant is approved"])
        case "opencode", "open code":
            (["Streaming", "Persistent resume", "Plan agent", "Model routing"], ["Some native event kinds remain provider-specific"])
        default:
            ([], ["This provider is not supported by the installed Kaname build"])
        }
    }
}
