import CryptoKit
import Foundation
@testable import KanameDesktop
@testable import KanameDomain
import Testing

@MainActor
struct DesktopAppModelTests {
    @Test
    func createOrReuseConversationDraftReusesOnlyEmptyMatchingContext() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)

        let first = model.createOrReuseConversationDraft(kind: .coding, projectID: projectID)
        let reused = model.createOrReuseConversationDraft(
            kind: .coding,
            projectID: projectID,
            provider: "OpenCode",
            model: "opencode/default",
            reasoningEffort: "high"
        )

        #expect(reused == first)
        #expect(model.snapshot.threads.filter { $0.id == first }.count == 1)
        #expect(model.thread(id: first)?.provider == "OpenCode")
        #expect(model.thread(id: first)?.model == "opencode/default")
        #expect(model.thread(id: first)?.reasoningEffort == "high")

        _ = model.appendUserMessage(threadID: first, body: "Keep this draft")
        let second = model.createOrReuseConversationDraft(kind: .coding, projectID: projectID)
        #expect(second != first)

        let standalone = model.createOrReuseConversationDraft(kind: .coding, projectID: nil)
        #expect(standalone != second)
    }

    @Test
    func streamingActivityNeverReordersTheThreadDirectory() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 10_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let olderID = model.createConversation(kind: .research, projectID: projectID)
        clock += 1_000
        let newerID = model.createConversation(kind: .planning, projectID: projectID)
        let originalOrder = model.activeThreads.filter { $0.id == olderID || $0.id == newerID }.map(\.id)
        #expect(originalOrder == [newerID, olderID])

        clock += 1_000
        let messageID = try #require(model.appendUserMessage(threadID: olderID, body: "Stream without moving"))
        let runID = try #require(model.enqueueProviderRun(threadID: olderID, sourceMessageID: messageID))
        _ = model.beginProviderRun(id: runID)
        for ordinal in 1...200 {
            let event = DesktopProviderEventRecord(
                id: "stable-order-\(ordinal)",
                threadID: olderID,
                runID: runID,
                kind: .assistantText,
                title: "Response",
                detail: "delta",
                nativeType: "item/agentMessage/delta",
                nativeThreadID: "native",
                nativeTurnID: "turn",
                approvalID: nil,
                rawPayloadBase64: nil,
                payloadWasTruncated: false,
                createdAtUnixMillis: 50_000 + Int64(ordinal)
            )
            #expect(model.recordProviderEvent(event, assistantDelta: "x"))
        }

        #expect(model.activeThreads.filter { $0.id == olderID || $0.id == newerID }.map(\.id) == originalOrder)
        #expect(model.thread(id: olderID)?.messages.last?.body.count == 200)
    }

    @Test
    func imageOnlyDraftsPersistAndBecomeOneDurableUserMessage() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let threadID = model.createConversation(kind: .research, projectID: model.snapshot.projects.first?.id)
        let attachment = ConversationImageAttachment(
            id: "image-1",
            filename: "screenshot.png",
            mimeType: "image/png",
            byteCount: 128,
            pixelWidth: 20,
            pixelHeight: 10,
            relativePath: "Threads/\(threadID)/Attachments/image-1.png"
        )

        #expect(model.addComposerAttachment(threadID: threadID, attachment: attachment))
        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.composerAttachments(threadID: threadID) == [attachment])
        let messageID = try #require(restored.appendUserMessage(threadID: threadID, body: "", attachments: [attachment]))
        restored.clearComposerDraft(threadID: threadID)

        #expect(restored.message(threadID: threadID, id: messageID)?.body.isEmpty == true)
        #expect(restored.message(threadID: threadID, id: messageID)?.attachments == [attachment])
        #expect(restored.composerAttachments(threadID: threadID).isEmpty)
        #expect(restored.thread(id: threadID)?.summary == "1 image attached")
    }

    @Test
    func questionsAndApprovalsExposeDistinctBlockingAttention() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let threadID = model.createConversation(kind: .research, projectID: model.snapshot.projects.first?.id)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Ask when blocked"))
        let runID = try #require(model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID))
        _ = model.beginProviderRun(id: runID)

        func event(id: String, kind: DesktopProviderEventKind, title: String) -> DesktopProviderEventRecord {
            DesktopProviderEventRecord(
                id: id,
                threadID: threadID,
                runID: runID,
                kind: kind,
                title: title,
                detail: title,
                nativeType: title,
                nativeThreadID: nil,
                nativeTurnID: nil,
                approvalID: nil,
                rawPayloadBase64: nil,
                payloadWasTruncated: false,
                createdAtUnixMillis: 2_000
            )
        }

        #expect(model.recordProviderEvent(event(id: "question", kind: .question, title: "Codex has a question")))
        #expect(model.thread(id: threadID)?.attention == .needsInput)
        #expect(model.recordProviderEvent(event(id: "answer", kind: .question, title: "Question answered")))
        #expect(model.thread(id: threadID)?.attention == .running)
        #expect(model.recordProviderEvent(event(id: "approval", kind: .approval, title: "Approval requested")))
        #expect(model.thread(id: threadID)?.attention == .needsApproval)
        #expect(model.recordProviderEvent(event(id: "declined", kind: .approval, title: "Approval declined")))
        #expect(model.thread(id: threadID)?.attention == .running)
    }

    @Test
    func projectCreationPersistsReviewedContextAndRejectsCanonicalDuplicateFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-project-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Workspace", directoryHint: .isDirectory)
        let alias = root.appending(path: "Workspace Alias", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let context = DesktopProjectContext(
            instructionReferences: [" AGENTS.md ", "AGENTS.md"],
            defaultKind: .research
        )

        let projectID = try #require(model.createProject(
            name: "Reviewed workspace",
            path: alias.path,
            summary: "Deliberate local scope",
            context: context
        ))
        let project = try #require(model.project(id: projectID))

        #expect(project.path == folder.path)
        #expect(project.context.instructionReferences == ["AGENTS.md"])
        #expect(project.context.defaultKind == .research)
        #expect(model.createProject(name: "Duplicate", path: folder.path, summary: "") == nil)
    }

    @Test
    func desktopBackCommandRouterRetainsTheActiveHandlerUntilRemoval() {
        let router = DesktopBackCommandRouter()
        var calls = 0

        #expect(router.performBack() == false)
        router.install {
            calls += 1
            return true
        }
        #expect(router.performBack() == true)
        #expect(calls == 1)

        router.removeHandler()
        #expect(router.performBack() == false)
        #expect(calls == 1)
    }

    @Test
    func localThreadsProjectsAndMessagesSurviveRestart() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })

        clock += 1
        let projectID = try #require(
            model.createProject(
                name: "Desktop dogfood",
                path: "/tmp/kaname-desktop-test",
                summary: "Persistent local workspace"
            )
        )
        clock += 1
        let threadID = try #require(
            model.createThread(title: "Use Kaname tomorrow", kind: .planning, projectID: projectID)
        )
        clock += 1
        model.appendUserMessage(threadID: threadID, body: "Keep this exact local note after restart.")
        model.setAttention(threadID: threadID, attention: .needsResponse)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        let thread = try #require(restored.thread(id: threadID))

        #expect(restored.project(id: projectID)?.name == "Desktop dogfood")
        #expect(thread.projectID == projectID)
        #expect(thread.messages.last?.body == "Keep this exact local note after restart.")
        #expect(thread.attention == .needsResponse)
        #expect(restored.persistenceError == nil)
    }

    @Test
    func newConversationNeedsOnlyKindAndUsesItsFirstMessageAsAProvisionalTitle() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.snapshot.projects.first?.id)

        let threadID = model.createConversation(kind: .planning, projectID: projectID)
        let emptyConversation = try #require(model.thread(id: threadID))

        #expect(emptyConversation.projectID == projectID)
        #expect(emptyConversation.kind == .planning)
        #expect(emptyConversation.title == "New planning conversation")
        #expect(emptyConversation.titleSource == .placeholder)
        #expect(emptyConversation.messages.isEmpty)
        #expect(emptyConversation.provider == "Codex")
        #expect(emptyConversation.reasoningEffort == "medium")
        #expect(emptyConversation.runtimeMode == .approvalRequired)
        #expect(emptyConversation.networkAccess == false)

        clock += 1
        model.appendUserMessage(
            threadID: threadID,
            body: "  Plan how Kaname can rebuild itself   while a stable copy remains open.  "
        )
        let titledConversation = try #require(model.thread(id: threadID))

        #expect(titledConversation.title == "Plan how Kaname can rebuild itself while a stable copy remains open.")
        #expect(titledConversation.titleSource == .provisional)
        #expect(titledConversation.messages.count == 1)
        #expect(titledConversation.messages.first?.role == .user)

        clock += 1
        model.appendUserMessage(threadID: threadID, body: "Do not replace the title with this follow-up.")
        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.thread(id: threadID)?.title == titledConversation.title)
    }

    @Test
    func conversationRuntimeChoicesPersistAndFlowIntoTheQueuedRun() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(
            kind: .coding,
            projectID: projectID,
            provider: "Claude",
            model: "claude-opus-4-1",
            reasoningEffort: "max",
            runtimeMode: .fullAccess,
            networkAccess: false
        )
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Run the configured task."))
        let runID = try #require(model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID))

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        let thread = try #require(restored.thread(id: threadID))
        let run = try #require(restored.providerRun(id: runID))
        #expect(thread.provider == "Claude")
        #expect(thread.model == "claude-opus-4-1")
        #expect(thread.reasoningEffort == "max")
        #expect(thread.runtimeMode == .fullAccess)
        #expect(thread.networkAccess)
        #expect(run.provider == thread.provider)
        #expect(run.model == thread.model)
        #expect(run.reasoningEffort == thread.reasoningEffort)
        #expect(run.runtimeMode == thread.runtimeMode)
        #expect(run.networkAccess)
    }

    @Test
    func codingPlanOverridesFullAccessAndStopsForExplicitApproval() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(
            kind: .coding,
            projectID: projectID,
            provider: "Codex",
            runtimeMode: .fullAccess,
            networkAccess: true
        )
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Add the guarded flow."))
        let runID = try #require(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            purpose: .codingPlan,
            runtimeModeOverride: .approvalRequired,
            networkAccessOverride: false
        ))
        model.replaceProviderPlan(
            threadID: threadID,
            steps: [
                ("Inspect the flow", "completed"),
                ("Implement after approval", "pending"),
            ],
            explanation: "A bounded plan"
        )
        model.finalizeCodingPlanForApproval(threadID: threadID)
        _ = model.beginProviderRun(id: runID)
        model.completeProviderRun(id: runID)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        let run = try #require(restored.providerRun(id: runID))
        let thread = try #require(restored.thread(id: threadID))
        #expect(run.purpose == .codingPlan)
        #expect(run.runtimeMode == .approvalRequired)
        #expect(run.networkAccess == false)
        #expect(thread.plan.map(\.title) == ["Inspect the flow", "Implement after approval"])
        #expect(thread.plan.map(\.state) == [.pending, .pending])
        #expect(thread.attention == .needsApproval)
        #expect(thread.summary == "Plan ready for review. No implementation authority has been granted.")
    }

    @Test
    func codingImplementationRequiresEvidenceAndSeparateAcceptance() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .coding, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Implement the approved plan."))
        let worktreeID = try #require(model.proposeWorktree(
            projectID: projectID,
            threadID: threadID,
            rootWorkspacePath: "/tmp/root",
            worktreePath: "/tmp/worktree",
            branch: "kaname/test",
            baseRevision: "base"
        ))
        model.updateWorktree(
            id: worktreeID,
            headRevision: "base",
            changedFileCount: 0,
            diffSummary: "Ready",
            state: .ready
        )
        model.replaceProviderPlan(
            threadID: threadID,
            steps: [("Add the regression", "in_progress"), ("Run verification", "pending")],
            explanation: nil
        )
        let runID = try #require(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            workspacePathOverride: "/tmp/worktree",
            purpose: .codingImplementation,
            runtimeModeOverride: .autoAcceptEdits,
            networkAccessOverride: false
        ))
        _ = model.beginProviderRun(id: runID)
        #expect(model.thread(id: threadID)?.summary == "Implementing the approved plan in an isolated worktree…")
        clock += 1
        model.completeProviderRun(id: runID)
        #expect(model.thread(id: threadID)?.attention == .needsApproval)

        clock += 1
        #expect(model.updateCodingWorkflow(threadID: threadID, state: .reviewingEvidence))
        let verificationOutput = String(repeating: "build output\n", count: 3_000) + "FINAL RESULT: passed"
        #expect(model.recordCodingEvidence(
            threadID: threadID,
            worktreeID: worktreeID,
            revision: "base:diff",
            diffStat: "1 file changed",
            diffCheckPassed: true,
            verificationCommand: "swift test",
            verificationExitStatus: 0,
            verificationOutput: verificationOutput,
            artifactPaths: ["Sources/Flow.swift"],
            digest: String(repeating: "a", count: 64)
        ))
        #expect(model.thread(id: threadID)?.attention == .needsApproval)
        #expect(model.thread(id: threadID)?.evidence.allSatisfy { $0.state == .passed } == true)
        #expect(model.thread(id: threadID)?.plan.allSatisfy { $0.state == .complete } == true)
        let reviewWorktree = try #require(model.snapshot.operations.worktrees.first(where: { $0.id == worktreeID }))
        #expect(reviewWorktree.state == .review)
        #expect(reviewWorktree.testSummary.hasSuffix("FINAL RESULT: passed"))
        #expect(reviewWorktree.testSummary.count <= 32_000)

        clock += 1
        model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true)
        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.thread(id: threadID)?.attention == .needsApproval)
        #expect(restored.snapshot.operations.worktrees.first(where: { $0.id == worktreeID })?.state == .accepted)
    }

    @Test
    func unifiedProviderQueuePersistsEventsRecoveryAndTitleOwnership() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .coding, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Explain the desktop runtime boundary."))
        let runID = try #require(model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID))

        #expect(model.nextQueuedProviderRun(threadID: threadID)?.id == runID)
        #expect(model.beginProviderRun(id: runID)?.state == .running)
        model.attachNativeProviderRun(id: runID, nativeThreadID: "native-thread", nativeTurnID: "native-turn")
        let event = DesktopProviderEventRecord(
            id: "event-1",
            threadID: threadID,
            runID: runID,
            kind: .assistantText,
            title: "Response",
            detail: "A bounded delta",
            nativeType: "item/agentMessage/delta",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn",
            approvalID: nil,
            rawPayloadBase64: Data("private event".utf8).base64EncodedString(),
            payloadWasTruncated: false,
            createdAtUnixMillis: clock
        )
        #expect(model.recordProviderEvent(event, assistantDelta: "A bounded delta") == true)
        #expect(model.recordProviderEvent(event, assistantDelta: "A bounded delta") == false)
        clock += 1
        model.completeProviderRun(id: runID, tokenUsage: 42)
        #expect(model.applyProviderGeneratedTitle(threadID: threadID, title: "  Runtime Boundary  ") == true)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.providerRun(id: runID)?.state == .completed)
        #expect(restored.providerRun(id: runID)?.nativeThreadID == "native-thread")
        #expect(restored.providerRun(id: runID)?.tokenUsage == 42)
        #expect(restored.providerEvents(threadID: threadID).count == 1)
        #expect(restored.thread(id: threadID)?.messages.last?.body == "A bounded delta")
        #expect(restored.thread(id: threadID)?.title == "Runtime Boundary")
        #expect(restored.thread(id: threadID)?.titleSource == .providerGenerated)
    }

    @Test
    @MainActor
    func composerDraftSurvivesRestartAndClearsOnlyAfterSendCheckpoint() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let threadID = model.createConversation(kind: .coding, projectID: nil)
        #expect(model.updateComposerDraft(threadID: threadID, body: "Unsent work in progress"))

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.composerDraft(threadID: threadID) == "Unsent work in progress")
        #expect(restored.updateComposerDraft(threadID: threadID, body: ""))
        #expect(DesktopAppModel(store: store, now: { 3_000 }).composerDraft(threadID: threadID).isEmpty)
    }

    @Test
    func orphanedRunBecomesRecoverableWithoutDuplicatingItsUserMessage() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .planning, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Recover this exact turn."))
        let runID = try #require(model.enqueueProviderRun(threadID: threadID, sourceMessageID: messageID))
        _ = model.beginProviderRun(id: runID)

        model.recoverOrphanedProviderRuns()

        #expect(model.providerRun(id: runID)?.state == .interrupted)
        #expect(model.thread(id: threadID)?.messages.filter { $0.role == .user }.count == 1)
        let retryID = try #require(model.retryProviderRun(id: runID))
        #expect(retryID != runID)
        #expect(model.providerRun(id: retryID)?.sourceMessageID == messageID)
        #expect(model.thread(id: threadID)?.messages.filter { $0.role == .user }.count == 1)
    }

    @Test
    func versionSevenWorkspaceAddsConversationRuntimeDefaults() throws {
        let snapshot = DesktopAppSnapshot.starter(now: 1_000)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object["version"] = 7
        var threads = try #require(object["threads"] as? [[String: Any]])
        for index in threads.indices {
            threads[index].removeValue(forKey: "reasoningEffort")
            threads[index].removeValue(forKey: "runtimeMode")
            threads[index].removeValue(forKey: "networkAccess")
            threads[index].removeValue(forKey: "titleSource")
        }
        object["threads"] = threads
        var operations = try #require(object["operations"] as? [String: Any])
        operations.removeValue(forKey: "providerEvents")
        object["operations"] = operations
        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: object))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.threads.allSatisfy {
            $0.reasoningEffort == "xhigh"
                && $0.runtimeMode == .approvalRequired
                && $0.networkAccess == false
                && $0.titleSource == .manual
        })
        #expect(model.snapshot.operations.providerEvents.isEmpty)
    }

    @Test
    func versionNineWorkspaceAddsCodingControlCollections() throws {
        let snapshot = DesktopAppSnapshot.starter(now: 1_000)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["version"] = 9
        var operations = try #require(object["operations"] as? [String: Any])
        for key in ["providerSessions", "worktrees", "subagents", "comparisonDecisions", "pullRequests", "qualityGates"] {
            operations.removeValue(forKey: key)
        }
        object["operations"] = operations
        let model = DesktopAppModel(
            store: MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: object)),
            now: { 2_000 }
        )

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.operations.providerSessions.isEmpty)
        #expect(model.snapshot.operations.worktrees.isEmpty)
        #expect(model.snapshot.operations.subagents.isEmpty)
        #expect(model.snapshot.operations.comparisonDecisions.isEmpty)
        #expect(model.snapshot.operations.pullRequests.isEmpty)
        #expect(model.snapshot.operations.qualityGates.isEmpty)
    }

    @Test
    func equalContextComparisonCreatesSeparateThreadsAndExplicitSelection() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let comparisonID = try #require(model.createProviderComparison(
            title: "Compare safely",
            brief: "Review this exact frozen brief.",
            providers: ["Codex", "Claude", "OpenCode"]
        ))
        let runIDs = model.prepareProviderComparison(id: comparisonID, projectID: projectID)
        #expect(runIDs.count == 3)
        let threads = runIDs.compactMap { model.providerRun(id: $0)?.threadID }.compactMap(model.thread(id:))
        #expect(Set(threads.map(\.id)).count == 3)
        #expect(Set(threads.flatMap(\.messages).map(\.body)) == ["Review this exact frozen brief."])
        #expect(Set(threads.map(\.provider)) == ["Codex", "Claude", "OpenCode"])

        let selectedRunID = try #require(runIDs.first)
        _ = model.beginProviderRun(id: selectedRunID)
        model.completeProviderRun(id: selectedRunID, tokenUsage: 123)
        let selectedThreadID = model.selectProviderComparisonResult(comparisonID: comparisonID, runID: selectedRunID)
        #expect(selectedThreadID == model.providerRun(id: selectedRunID)?.threadID)
        #expect(model.snapshot.operations.comparisonDecisions.first { $0.comparisonID == comparisonID }?.selectedRunID == selectedRunID)
    }

    @Test
    func provisionalConversationTitleIsSingleLineAndBounded() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 1_000 })
        let threadID = model.createConversation(kind: .coding, projectID: nil)

        model.appendUserMessage(
            threadID: threadID,
            body: "Build a clean project conversation flow\nthat preserves context and continues well beyond seventy-two characters without asking for a separate title."
        )

        let title = try #require(model.thread(id: threadID)?.title)
        #expect(!title.contains("\n"))
        #expect(title.count == 73)
        #expect(title.hasSuffix("…"))
    }

    @Test
    func invalidStateFallsBackWithoutOverwritingTheLastDurableBytes() {
        let invalid = Data("not-json".utf8)
        let store = MemoryDesktopStateStore(data: invalid)
        let model = DesktopAppModel(store: store, now: { 1_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(!model.snapshot.threads.isEmpty)
        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .unreadableState)
        #expect(model.recoveryStatus?.quarantineCreated == false)
        #expect(model.persistenceError == nil)
        #expect(store.data == invalid)
    }

    @Test
    func versionOneWorkspaceMigratesWithoutDroppingUserContent() throws {
        var versionOne = DesktopAppSnapshot.starter(now: 1_000)
        versionOne.version = 1
        versionOne.projects.append(
            DesktopProject(name: "Preserved project", summary: "User-owned", createdAtUnixMillis: 1_001)
        )
        versionOne.threads.append(
            DesktopThread(
                title: "Preserved thread",
                summary: "User-owned",
                kind: .research,
                attention: .queued,
                updatedAtUnixMillis: 1_002
            )
        )
        let store = MemoryDesktopStateStore(data: try JSONEncoder().encode(versionOne))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.projects.contains { $0.name == "Preserved project" })
        #expect(model.snapshot.threads.contains { $0.title == "Preserved thread" })
        #expect(model.thread(id: "thread-desktop-dogfood")?.plan.allSatisfy { $0.state == .complete } == true)
        #expect(model.thread(id: "thread-desktop-dogfood")?.evidence.allSatisfy { $0.state == .passed } == true)
        #expect(!model.snapshot.domains.knowledgeSources.isEmpty)
        #expect(store.data != nil)
    }

    @Test
    func versionTwoWorkspaceAddsDomainStateWithoutDroppingUserContent() throws {
        var versionTwo = DesktopAppSnapshot.starter(now: 1_000)
        versionTwo.version = 2
        versionTwo.domains = .empty
        versionTwo.threads.append(
            DesktopThread(
                title: "Preserved version two thread",
                summary: "Must survive",
                kind: .personal,
                attention: .queued,
                updatedAtUnixMillis: 1_001
            )
        )
        let data = try JSONEncoder().encode(versionTwo)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "domains")
        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: json))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.threads.contains { $0.title == "Preserved version two thread" })
        #expect(model.snapshot.domains.knowledgeSources.contains { $0.id == "knowledge-coding-ade" })
        #expect(model.snapshot.domains.accounts.count == 4)
        #expect(model.snapshot.operations == .empty)
    }

    @Test
    func versionThreeWorkspaceAddsOperationalStateWithoutDroppingDomainContent() throws {
        var versionThree = DesktopAppSnapshot.starter(now: 1_000)
        versionThree.version = 3
        versionThree.domains.research.append(
            DesktopResearchRecord(
                id: "research-preserved",
                title: "Preserved",
                question: "Still here?",
                status: .draft,
                sourceCount: 0,
                updatedAtUnixMillis: 1_001
            )
        )
        let data = try JSONEncoder().encode(versionThree)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "operations")
        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: json))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.domains.research.contains { $0.id == "research-preserved" })
        #expect(model.snapshot.operations == .empty)
    }

    @Test
    func versionFourWorkspaceAddsCalendarSourcesAndScheduleZoneDefaults() throws {
        var versionFour = DesktopAppSnapshot.starter(now: 1_000)
        versionFour.version = 4
        let data = try JSONEncoder().encode(versionFour)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var domains = try #require(json["domains"] as? [String: Any])
        domains.removeValue(forKey: "calendarSources")
        json["domains"] = domains
        var preferences = try #require(json["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "defaultScheduleTimeZoneIdentifier")
        json["preferences"] = preferences
        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: json))

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.domains.calendarSources.isEmpty)
        #expect(TimeZone(identifier: model.snapshot.preferences.defaultScheduleTimeZoneIdentifier) != nil)
    }

    @Test
    func versionFiveCalendarProposalMigratesWithoutAnExactSource() throws {
        var versionFive = DesktopAppSnapshot.starter(now: 1_000)
        versionFive.version = 5
        versionFive.domains.calendarProposals = [DesktopCalendarProposal(
            id: "legacy-calendar-proposal",
            accountID: "google-account",
            title: "Legacy event",
            startAtUnixMillis: 2_000,
            durationMinutes: 30,
            timeZoneIdentifier: "Asia/Tokyo",
            recurrence: "Does not repeat",
            status: .proposed
        )]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(versionFive)) as? [String: Any])
        var domains = try #require(json["domains"] as? [String: Any])
        var proposals = try #require(domains["calendarProposals"] as? [[String: Any]])
        proposals[0].removeValue(forKey: "calendarSourceID")
        domains["calendarProposals"] = proposals
        json["domains"] = domains

        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: json))
        let model = DesktopAppModel(store: store, now: { 3_000 })

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(model.snapshot.domains.calendarProposals.first?.calendarSourceID == nil)
        #expect(model.snapshot.domains.calendarProposals.first?.title == "Legacy event")
    }

    @Test
    func versionSixWorkspaceAddsDeliberateProjectContext() throws {
        var versionSix = DesktopAppSnapshot.starter(now: 1_000)
        versionSix.version = 6
        let data = try JSONEncoder().encode(versionSix)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var projects = try #require(json["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "context")
        projects[0].removeValue(forKey: "archivedAtUnixMillis")
        json["projects"] = projects
        let store = MemoryDesktopStateStore(data: try JSONSerialization.data(withJSONObject: json))

        let model = DesktopAppModel(store: store, now: { 2_000 })
        let project = try #require(model.project(id: "project-kaname"))

        #expect(model.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(project.context.instructionReferences == ["AGENTS.md"])
        #expect(project.context.knowledgeSourceIDs == ["knowledge-coding-ade", "knowledge-kaname-repository"])
        #expect(project.context.skillIDs == ["skill-mori-review", "skill-obsidian"])
        #expect(project.archivedAtUnixMillis == nil)
    }

    @Test
    func projectContextSearchEditingAndArchiveStayCoherent() throws {
        let store = MemoryDesktopStateStore()
        var clock: Int64 = 1_000
        let model = DesktopAppModel(store: store, now: { clock })
        let projectID = try #require(
            model.createProject(name: "Quartz", path: "/tmp/quartz", summary: "Desktop client")
        )
        let context = DesktopProjectContext(
            instructionReferences: [" AGENTS.md ", "Docs/UX.md", "AGENTS.md", ""],
            knowledgeSourceIDs: ["knowledge-coding-ade", "missing-source"],
            skillIDs: ["skill-mori-review", "missing-skill"],
            defaultKind: .planning,
            defaultProvider: " Codex ",
            defaultModel: " Use provider default "
        )

        #expect(model.updateProject(
            id: projectID,
            name: "Quartz Desktop",
            path: "/tmp/quartz-desktop",
            summary: "Thoughtful native workspace",
            context: context
        ))
        let updated = try #require(model.project(id: projectID))
        #expect(updated.context.instructionReferences == ["AGENTS.md", "Docs/UX.md"])
        #expect(updated.context.knowledgeSourceIDs == ["knowledge-coding-ade"])
        #expect(updated.context.skillIDs == ["skill-mori-review"])
        #expect(updated.context.defaultKind == .planning)
        #expect(updated.context.defaultProvider == "Codex")
        #expect(model.projects(matching: "ux.md").map(\.id) == [projectID])

        clock += 1
        model.setProjectArchived(id: projectID, archived: true)
        #expect(!model.activeProjects.contains { $0.id == projectID })
        #expect(model.projects(matching: "quartz", includeArchived: true).map(\.id) == [projectID])

        model.setProjectArchived(id: projectID, archived: false)
        #expect(model.activeProjects.contains { $0.id == projectID })
    }

    @Test
    func searchArchiveAndPrivacyPreferencesRemainCoherent() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 1_000 })
        let threadID = try #require(
            model.createThread(title: "Searchable recovery plan", kind: .coding, projectID: "project-kaname")
        )
        model.appendUserMessage(threadID: threadID, body: "Unique reconciliation marker")

        #expect(model.threads(matching: "unique reconciliation marker").map(\.id) == [threadID])
        model.setAttention(threadID: threadID, attention: .archived)
        #expect(model.threads(matching: "unique reconciliation marker").isEmpty)
        #expect(model.archivedThreads.map(\.id).contains(threadID))

        var preferences = model.snapshot.preferences
        preferences.previewPrivacy = .safeSummary
        preferences.showTechnicalDetails = true
        preferences.safeMode = true
        preferences.auditRetentionDays = 30
        model.updatePreferences(preferences)

        let restored = DesktopAppModel(store: store, now: { 2_000 })
        #expect(restored.snapshot.preferences == preferences)
    }

    @Test
    func redactedDiagnosticsContainCountsButNoPrivateContent() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 7_000 })
        let sentinel = "PRIVATE-SENTINEL-7E67E7"
        let threadID = try #require(model.createThread(title: sentinel, kind: .personal, projectID: nil))
        model.appendUserMessage(threadID: threadID, body: "message-\(sentinel)")
        _ = model.saveEmailDraft(
            accountID: nil,
            recipients: "recipient-\(sentinel)",
            subject: "subject-\(sentinel)",
            body: "body-\(sentinel)"
        )

        let diagnostics = model.redactedDiagnostics()

        #expect(diagnostics.contains("\"schemaVersion\""))
        #expect(diagnostics.contains("\"emailDraftCount\" : 1"))
        #expect(!diagnostics.contains(sentinel))
        #expect(!diagnostics.contains("/Users/"))
    }

    @Test
    func domainDraftsAndRulesPersistWithoutExternalEffects() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 5_000 })

        let researchID = try #require(model.createResearch(title: "Provider recovery", question: "Which events can replay?"))
        let emailID = try #require(
            model.saveEmailDraft(
                accountID: nil,
                recipients: "",
                subject: "Draft only",
                body: "This must not send."
            )
        )
        let calendarID = try #require(
            model.createCalendarProposal(
                accountID: "google-account",
                calendarSourceID: "google-calendar-primary",
                title: "Review Kaname",
                startAtUnixMillis: 10_000,
                durationMinutes: 30,
                timeZoneIdentifier: "Asia/Tokyo",
                recurrence: "Does not repeat"
            )
        )
        let automationID = try #require(
            model.createAutomation(
                name: "Weekly review",
                schedule: "Every Monday at 09:00",
                timeZoneIdentifier: "Asia/Tokyo",
                actionSummary: "Prepare a local review draft",
                missedRunPolicy: .skip
            )
        )
        model.setAutomationPaused(id: automationID, paused: true)

        let restored = DesktopAppModel(store: store, now: { 6_000 })
        #expect(restored.snapshot.domains.research.contains { $0.id == researchID })
        #expect(restored.snapshot.domains.emailDrafts.contains { $0.id == emailID && $0.status == .draft })
        #expect(restored.snapshot.domains.calendarProposals.contains {
            $0.id == calendarID
                && $0.status == .proposed
                && $0.accountID == "google-account"
                && $0.calendarSourceID == "google-calendar-primary"
        })
        #expect(restored.snapshot.domains.automations.contains { $0.id == automationID && $0.status == .paused })
    }

    @Test
    func personalAccountsAndCalendarSelectionRemainMultiAccountAndLocal() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 5_000 })
        let gmailAccounts = (1...4).map { number in
            DesktopAccountRecord(
                id: "gmail-\(number)",
                service: .gmail,
                displayName: "Gmail \(number)",
                identity: "account\(number)@example.test",
                status: .ready,
                scope: "Native Google OAuth session"
            )
        }
        model.replaceAccounts(for: [.gmail], with: gmailAccounts)
        model.replaceCalendarSources([
            DesktopCalendarSourceRecord(
                id: "google-calendar-1",
                accountID: "gmail-1",
                externalIdentifier: "primary",
                provider: .google,
                displayName: "Primary",
                ownerIdentity: "account1@example.test",
                accessLevel: "owner",
                isPrimary: true,
                isEnabled: true
            ),
            DesktopCalendarSourceRecord(
                id: "apple-calendar-1",
                accountID: "apple-calendar-local",
                externalIdentifier: "eventkit-1",
                provider: .apple,
                displayName: "Personal",
                ownerIdentity: "On My Mac",
                accessLevel: "write",
                isPrimary: false,
                isEnabled: false
            ),
        ])
        model.setCalendarSourceEnabled(id: "apple-calendar-1", enabled: true)

        let restored = DesktopAppModel(store: store, now: { 6_000 })
        #expect(restored.snapshot.domains.accounts.filter { $0.service == .gmail }.count == 4)
        #expect(restored.snapshot.domains.calendarSources.count == 2)
        #expect(restored.snapshot.domains.calendarSources.allSatisfy { $0.isEnabled })
    }

    @Test
    func anchoredScheduleTimeStaysInSetupZoneWhileViewerZoneChanges() throws {
        let instant = Date(timeIntervalSince1970: 1_767_225_600)
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let presentation = try #require(
            DesktopTimeZonePresenter.presentation(
                for: instant,
                anchoredTimeZoneIdentifier: "Asia/Tokyo",
                viewerTimeZone: berlin,
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        #expect(presentation.anchoredTimeZoneIdentifier == "Asia/Tokyo")
        #expect(presentation.viewerTimeZoneIdentifier == "Europe/Berlin")
        #expect(presentation.differsFromViewer)
        #expect(presentation.anchored != presentation.viewerLocal)
    }

    @Test
    func operationalRecordsRemainLocalDurableAndLinked() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 9_000 })
        let researchID = try #require(model.createResearch(title: "Recovery", question: "What is durable?"))
        let sourceID = try #require(
            model.addResearchSource(
                researchID: researchID,
                title: "Primary specification",
                location: "https://example.com/spec",
                publisher: "Example",
                isPrimary: true,
                note: "Contract evidence"
            )
        )
        let approvalID = try #require(
            model.createApproval(
                threadID: nil,
                title: "Publish report",
                exactTarget: "example/repository",
                consequence: "Creates public state",
                dataLeavingDevice: "Report content",
                reversible: true,
                expiresAtUnixMillis: 10_000
            )
        )
        model.resolveApproval(id: approvalID, approved: false)
        let comparisonID = try #require(
            model.createProviderComparison(
                title: "Compare plans",
                brief: "Produce a bounded plan",
                providers: ["Codex", "Claude"]
            )
        )

        let restored = DesktopAppModel(store: store, now: { 10_000 })
        #expect(restored.snapshot.operations.researchSources.contains { $0.id == sourceID })
        #expect(restored.snapshot.domains.research.first { $0.id == researchID }?.sourceCount == 1)
        #expect(restored.snapshot.operations.approvals.first { $0.id == approvalID }?.state == .rejected)
        #expect(restored.snapshot.operations.audit.count == 2)
        #expect(restored.snapshot.operations.comparisons.first { $0.id == comparisonID }?.runIDs.count == 2)
        #expect(restored.snapshot.operations.providerRuns.allSatisfy { $0.state == .proposed })
    }

    @Test
    func knowledgeScopeClassificationAndExactWriteLifecycleAreDurable() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 12_000 })
        let scopeID = try #require(model.addVaultScope(
            path: "Projects/Coding ADE",
            sourceID: "knowledge-coding-ade",
            canWrite: true
        ))
        var document = DesktopKnowledgeDocumentRecord(
            path: "Projects/Coding ADE/Overview.md",
            title: "Overview",
            digest: String(repeating: "a", count: 64),
            provenance: "Obsidian CLI · local vault",
            lastReadAtUnixMillis: 12_000
        )
        document.replaceContext(
            projectID: nil,
            role: nil,
            sourceURLs: ["https://example.com/spec"],
            wikilinks: ["Research Index"],
            backlinks: ["Projects/Coding ADE/Fresh Session Start.md"],
            attachments: ["diagram.png"],
            properties: ["status": "active"],
            conflictDigest: nil
        )
        model.recordKnowledgeDocument(document)
        model.classifyKnowledgeDocument(path: document.path, projectID: "project-kaname", role: .decision)
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Edit Overview",
            target: document.path,
            summary: "0 removed · 1 added line",
            proposedContent: "# Overview\nUpdated",
            baseRevision: document.digest
        ))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: document.path,
            baseDigest: document.digest,
            proposedDigest: knowledgeDigest("# Overview\nUpdated"),
            diffSummary: "0 removed · 1 added line",
            unifiedDiff: "+Updated"
        ))
        let mismatchedApprovalID = try #require(model.createApproval(
            threadID: nil,
            title: "Write wrong Obsidian revision",
            exactTarget: "obsidian:\(document.path)#sha256=wrong",
            consequence: "This target must not bind.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        #expect(model.attachKnowledgeApproval(writeID: writeID, approvalID: mismatchedApprovalID) == false)
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Write Obsidian note",
            exactTarget: "obsidian:\(document.path)#sha256=\(document.digest)",
            consequence: "Replace only the inspected revision.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        #expect(model.attachKnowledgeApproval(writeID: writeID, approvalID: approvalID))
        model.resolveApproval(id: approvalID, approved: true)
        model.reconcileKnowledgeWrite(
            id: writeID,
            state: .reconciled,
            currentDigest: knowledgeDigest("# Overview\nUpdated"),
            detail: "Re-read matched."
        )

        let restored = DesktopAppModel(store: store, now: { 13_000 })
        #expect(restored.snapshot.operations.vaultScopes.first { $0.id == scopeID }?.canWrite == true)
        #expect(restored.snapshot.operations.knowledgeDocuments.first { $0.path == document.path }?.role == .decision)
        #expect(restored.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.state == .reconciled)
        #expect(restored.snapshot.operations.knowledgeProposals.first { $0.id == proposalID }?.state == .reconciled)
        #expect(restored.snapshot.operations.audit.last?.domain == "knowledge")
    }

    @Test
    func mailActionsStandingRulesAndMobileAttentionRemainAccountScopedAndDurable() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 14_000 })
        let target = "gmail:account-1:thread:thread-1:archive"
        let actionID = try #require(model.recordMailAction(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            threadID: "thread-1",
            kind: .archive,
            preview: "Remove Inbox from one thread.",
            exactTarget: target
        ))
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Archive",
            exactTarget: target,
            consequence: "Remove Inbox from one thread.",
            dataLeavingDevice: "Account and thread identifiers",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachMailApproval(actionID: actionID, approvalID: approvalID)
        model.resolveApproval(id: approvalID, approved: true)
        model.reconcileMailAction(id: actionID, state: .reconciled, remoteReceipt: "Labels: STARRED")
        let ruleID = try #require(model.createMailStandingRule(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            name: "Archive receipts",
            query: "from:receipts@example.test older_than:30d",
            action: .archive
        ))
        model.setMailStandingRuleEnabled(id: ruleID, enabled: false)
        model.reconcileMailAttention([(
            accountID: "account-1",
            threadID: "thread-2",
            accountIdentity: "one@example.test",
            sender: "Sender",
            subject: "Needs attention",
            unread: true
        )])

        let restored = DesktopAppModel(store: store, now: { 15_000 })
        #expect(restored.snapshot.operations.mailActions.first { $0.id == actionID }?.state == .reconciled)
        #expect(restored.snapshot.operations.mailStandingRules.first { $0.id == ruleID }?.enabled == false)
        #expect(restored.snapshot.operations.mailAttention.first?.id == "account-1:thread-2")
        #expect(restored.snapshot.operations.audit.last?.domain == "gmail")
    }

    @Test
    func resumableMailActionRestoresExactApprovedTargetWithoutReusingRejectedOrMismatchedAuthority() throws {
        let store = MemoryDesktopStateStore()
        var timestamp: Int64 = 14_000
        let model = DesktopAppModel(store: store, now: {
            defer { timestamp += 1 }
            return timestamp
        })
        let target = "gmail:account-1:thread:thread-1:trash"
        let approvedActionID = try #require(model.recordMailAction(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            threadID: "thread-1",
            kind: .trash,
            preview: "Move one exact thread to Trash.",
            exactTarget: target
        ))
        let approvalID = try #require(model.createApproval(
            threadID: nil,
            title: "Move to Trash",
            exactTarget: target,
            consequence: "Move one exact thread to Trash.",
            dataLeavingDevice: "Account and thread identifiers",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachMailApproval(actionID: approvedActionID, approvalID: approvalID)
        model.resolveApproval(id: approvalID, approved: true)

        let duplicateProposalID = try #require(model.recordMailAction(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            threadID: "thread-1",
            kind: .trash,
            preview: "Move one exact thread to Trash.",
            exactTarget: target
        ))
        let mismatchedActionID = try #require(model.recordMailAction(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            threadID: "thread-1",
            kind: .trash,
            preview: "Move one exact thread to Trash.",
            exactTarget: "gmail:account-1:thread:thread-1:archive"
        ))
        let mismatchedApprovalID = try #require(model.createApproval(
            threadID: nil,
            title: "Move to Trash",
            exactTarget: target,
            consequence: "Move one exact thread to Trash.",
            dataLeavingDevice: "Account and thread identifiers",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachMailApproval(actionID: mismatchedActionID, approvalID: mismatchedApprovalID)
        model.resolveApproval(id: mismatchedApprovalID, approved: true)
        let rejectedActionID = try #require(model.recordMailAction(
            accountID: "account-1",
            accountIdentity: "one@example.test",
            threadID: "thread-1",
            kind: .archive,
            preview: "Remove Inbox from one exact thread.",
            exactTarget: "gmail:account-1:thread:thread-1:archive"
        ))
        let rejectedApprovalID = try #require(model.createApproval(
            threadID: nil,
            title: "Archive",
            exactTarget: "gmail:account-1:thread:thread-1:archive",
            consequence: "Remove Inbox from one exact thread.",
            dataLeavingDevice: "Account and thread identifiers",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        model.attachMailApproval(actionID: rejectedActionID, approvalID: rejectedApprovalID)
        model.resolveApproval(id: rejectedApprovalID, approved: false)

        let restored = DesktopAppModel(store: store, now: { 15_000 })
        #expect(restored.resumableMailAction(
            accountID: "account-1",
            threadID: "thread-1",
            exactTarget: target
        )?.id == approvedActionID)
        #expect(restored.snapshot.operations.mailActions.first { $0.id == duplicateProposalID }?.state == .proposed)
        #expect(restored.resumableMailAction(
            accountID: "account-1",
            threadID: "thread-1",
            exactTarget: "gmail:account-1:thread:thread-1:archive"
        ) == nil)
    }

    @Test
    func fileStoreUsesPrivateDirectoryAndFileModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-desktop-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspace.json")
        let store = FileDesktopStateStore(fileURL: file)
        let previous = Data("previous-private-workspace".utf8)
        let expected = Data("private-local-workspace".utf8)

        try store.save(previous)
        try store.save(expected)

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        let recoveryMode = try #require(
            FileManager.default.attributesOfItem(atPath: store.recoveryFileURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(try store.load() == expected)
        #expect(try store.loadRecovery() == previous)
        #expect(directoryMode.intValue == 0o700)
        #expect(fileMode.intValue == 0o600)
        #expect(recoveryMode.intValue == 0o600)
    }

    @Test
    func corruptPrimaryOpensPreviousWorkspaceReadOnlyUntilExplicitRestore() throws {
        var previous = DesktopAppSnapshot.starter(now: 1_000)
        previous.threads.append(
            DesktopThread(
                title: "Recovered user thread",
                summary: "Must survive corruption",
                kind: .planning,
                attention: .needsResponse,
                updatedAtUnixMillis: 1_001
            )
        )
        let recovery = try JSONEncoder().encode(previous)
        let store = MemoryRecoveryDesktopStateStore(
            primary: Data("corrupt-primary".utf8),
            recovery: recovery
        )

        let model = DesktopAppModel(store: store, now: { 2_000 })

        #expect(model.snapshot.threads.contains { $0.title == "Recovered user thread" })
        #expect(model.isRecoveryReadOnly)
        #expect(model.recoveryStatus?.reason == .unreadableState)
        #expect(store.recovery == recovery)
        #expect(store.primary == Data("corrupt-primary".utf8))

        let originalProjectCount = model.snapshot.projects.count
        _ = model.createProject(name: "Must not persist", path: nil, summary: "Blocked")
        #expect(model.snapshot.projects.count == originalProjectCount)
        try model.restorePreviousWorkspace()
        #expect(!model.isRecoveryReadOnly)
        #expect(model.persistenceError == nil)
        let persisted = try #require(store.primary)
        #expect(try JSONDecoder().decode(DesktopAppSnapshot.self, from: persisted) == previous)
    }
}

// Durable coding workflow gates are intentionally exercised through the model
// surface so snapshot restoration is part of the contract under test.
extension DesktopAppModelTests {
    @Test
    func codingImplementationCompletionEntersAwaitingReview() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 20_000 })
        let (threadID, _) = try prepareCodingReview(model)

        #expect(model.codingWorkflow(threadID: threadID)?.state == .awaitingReview)
        #expect(model.thread(id: threadID)?.attention == .needsApproval)
    }

    @Test
    func orphanedCodingPlanFailsClosedAndCanRetryTheSameSavedMessage() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 20_250 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .coding, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Plan this safely."))
        let runID = try #require(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            purpose: .codingPlan,
            runtimeModeOverride: .approvalRequired,
            networkAccessOverride: false
        ))
        #expect(model.beginProviderRun(id: runID) != nil)

        model.recoverOrphanedProviderRuns()
        #expect(model.providerRun(id: runID)?.state == .interrupted)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .failed)
        let retryID = try #require(model.retryProviderRun(id: runID))
        #expect(model.providerRun(id: retryID)?.sourceMessageID == messageID)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .planning)
        #expect(model.thread(id: threadID)?.messages.filter { $0.role == .user }.count == 1)
    }

    @Test
    func schema26SnapshotDecodesEmptyCodingWorkflowCollections() throws {
        let store = MemoryDesktopStateStore()
        let encoder = JSONEncoder()
        let starter = DesktopAppSnapshot.starter(now: 20_500)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(starter)) as? [String: Any])
        object["version"] = 26
        var operations = try #require(object["operations"] as? [String: Any])
        operations.removeValue(forKey: "codingKnowledgeLanes")
        operations.removeValue(forKey: "codingWorkflows")
        object["operations"] = operations
        store.data = try JSONSerialization.data(withJSONObject: object)

        let restored = DesktopAppModel(store: store, now: { 20_501 })
        #expect(restored.snapshot.version == DesktopAppSnapshot.currentVersion)
        #expect(restored.snapshot.operations.codingKnowledgeLanes.isEmpty)
        #expect(restored.snapshot.operations.codingWorkflows.isEmpty)
    }

    @Test
    func codingAcceptanceRequiresExactThreadWorktreePassingEvidenceAndAwaitingAcceptance() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 21_000 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        let projectID = try #require(model.thread(id: threadID)?.projectID)
        let otherThreadID = model.createConversation(kind: .coding, projectID: projectID)
        let otherWorktreeID = try #require(model.proposeWorktree(
            projectID: projectID,
            threadID: otherThreadID,
            rootWorkspacePath: "/tmp/kaname-root",
            worktreePath: "/tmp/kaname-other-worktree",
            branch: "kaname/other",
            baseRevision: "base"
        ))
        model.updateWorktree(
            id: otherWorktreeID,
            headRevision: "other:diff",
            changedFileCount: 1,
            diffSummary: "Other thread change",
            state: .review
        )
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .awaitingAcceptance)

        #expect(model.recordCodingReview(threadID: threadID, worktreeID: otherWorktreeID, accepted: true) == false)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true) == true)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)

        // A later direct acceptance is not valid merely because the worktree and
        // evidence still look acceptable; the durable state gate is exact too.
        let secondModel = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 22_000 })
        let (secondThreadID, secondWorktreeID) = try prepareCodingReview(secondModel)
        recordPassingCodingEvidence(secondModel, threadID: secondThreadID, worktreeID: secondWorktreeID)
        #expect(secondModel.updateCodingWorkflow(threadID: secondThreadID, state: .reviewingEvidence))
        #expect(secondModel.recordCodingReview(threadID: secondThreadID, worktreeID: secondWorktreeID, accepted: true) == false)
        #expect(secondModel.codingWorkflow(threadID: secondThreadID)?.state == .reviewingEvidence)
    }

    @Test
    func acceptedCodingReviewLeavesKnowledgeLaneAndThreadNeedsApproval() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 23_000 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)

        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        #expect(model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .needsReview)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.acceptedWorktreeID == worktreeID)
        #expect(model.thread(id: threadID)?.attention == .needsApproval)
    }

    @Test
    func knowledgeProposalAndWaiverAreBlockedBeforeAcceptanceAndNonEmptyWaiverCompletesAfterward() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 24_000 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        let source = DesktopCodingKnowledgeConsultedSource(
            sourceID: "source",
            title: "Context",
            path: "Projects/Coding ADE/Overview.md",
            digest: String(repeating: "a", count: 64),
            provenance: "Obsidian CLI",
            excerpt: "Reference only"
        )
        #expect(model.replaceCodingKnowledgeContext(threadID: threadID, sources: [source]))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: "proposal-before-acceptance") == false)
        #expect(model.waiveCodingKnowledge(threadID: threadID, reason: "Not yet accepted") == false)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .awaitingReview)

        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        #expect(model.waiveCodingKnowledge(threadID: threadID, reason: "   ") == false)
        #expect(model.waiveCodingKnowledge(threadID: threadID, reason: "No durable knowledge change is required."))
        #expect(model.codingWorkflow(threadID: threadID)?.state == .completed)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .waived)
        #expect(model.thread(id: threadID)?.attention == .completed)
    }

    @Test
    func linkedKnowledgeProposalAndWriteSurviveSnapshotRestore() throws {
        let store = MemoryDesktopStateStore()
        let model = DesktopAppModel(store: store, now: { 25_000 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Update decision note",
            target: "Projects/Coding ADE/Decisions.md",
            summary: "Record the accepted implementation decision.",
            proposedContent: "# Decision\nUse the gated workflow.",
            baseRevision: String(repeating: "b", count: 64)
        ))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: proposalID))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: "Projects/Coding ADE/Decisions.md",
            baseDigest: String(repeating: "b", count: 64),
            proposedDigest: knowledgeDigest("# Decision\nUse the gated workflow."),
            diffSummary: "1 added line",
            unifiedDiff: "+Use the gated workflow."
        ))

        let restored = DesktopAppModel(store: store, now: { 26_000 })
        #expect(restored.codingKnowledgeLane(threadID: threadID)?.proposalID == proposalID)
        #expect(restored.codingKnowledgeLane(threadID: threadID)?.writeID == writeID)
        #expect(restored.snapshot.operations.knowledgeProposals.first { $0.id == proposalID }?.state == .proposed)
        #expect(restored.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.proposalID == proposalID)
        #expect(restored.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)
    }

    @Test
    func failedKnowledgeReconciliationRemainsUpdatingKnowledgeConflictUntilReconciled() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 27_000 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Reconcile decision",
            target: "Projects/Coding ADE/Decisions.md",
            summary: "Reconcile an external edit.",
            proposedContent: "Updated decision",
            baseRevision: "base"
        ))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: proposalID))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: "Projects/Coding ADE/Decisions.md",
            baseDigest: "base",
            proposedDigest: knowledgeDigest("Updated decision"),
            diffSummary: "1 changed line",
            unifiedDiff: "-old\n+next"
        ))

        model.reconcileKnowledgeWrite(
            id: writeID,
            state: .reconciled,
            currentDigest: "external",
            detail: "A caller attempted to reconcile the wrong digest."
        )
        #expect(model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .conflict)
        #expect(model.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.state == .failed)
        #expect(model.thread(id: threadID)?.attention == .needsApproval)

        model.reconcileKnowledgeWrite(
            id: writeID,
            state: .reconciled,
            currentDigest: knowledgeDigest("Updated decision"),
            detail: "The exact inspected revision was written."
        )
        #expect(model.codingWorkflow(threadID: threadID)?.state == .completed)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .reconciled)
        #expect(model.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.state == .reconciled)
        #expect(model.thread(id: threadID)?.attention == .completed)
    }

    @Test
    func conflictedKnowledgeProposalCanBeDetachedForRevisionWithoutCompletingWorkflow() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 27_500 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Revise decision",
            target: "Projects/Coding ADE/Decisions.md",
            summary: "Prepare a revision.",
            proposedContent: "Revised decision",
            baseRevision: "base"
        ))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: proposalID))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: "Projects/Coding ADE/Decisions.md",
            baseDigest: "base",
            proposedDigest: knowledgeDigest("Revised decision"),
            diffSummary: "1 changed line",
            unifiedDiff: "-old\n+next"
        ))
        model.reconcileKnowledgeWrite(
            id: writeID,
            state: .failed,
            currentDigest: "external",
            detail: "The note changed after inspection."
        )

        #expect(model.beginCodingKnowledgeRevision(threadID: threadID))
        #expect(model.codingKnowledgeLane(threadID: threadID)?.proposalID == nil)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.writeID == nil)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .needsReview)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)
        #expect(model.thread(id: threadID)?.attention == .needsApproval)
    }

    @Test
    func codingKnowledgeApprovalIsThreadBoundAndRejectionRequiresRevisionOrWaiver() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 27_750 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        let content = "Rejected proposal"
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Thread-bound decision",
            target: "Projects/Coding ADE/Decisions.md",
            summary: "Review an exact thread-bound proposal.",
            proposedContent: content,
            baseRevision: "base"
        ))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: proposalID))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: "Projects/Coding ADE/Decisions.md",
            baseDigest: "base",
            proposedDigest: knowledgeDigest(content),
            diffSummary: "1 changed line",
            unifiedDiff: "+Rejected proposal"
        ))
        let exactTarget = "obsidian:Projects/Coding ADE/Decisions.md#sha256=base"
        let unboundApprovalID = try #require(model.createApproval(
            threadID: nil,
            title: "Unbound write",
            exactTarget: exactTarget,
            consequence: "Must not bind to the coding lane.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        #expect(model.attachKnowledgeApproval(writeID: writeID, approvalID: unboundApprovalID) == false)
        let approvalID = try #require(model.createApproval(
            threadID: threadID,
            title: "Thread-bound write",
            exactTarget: exactTarget,
            consequence: "Write only this coding thread's exact proposal.",
            dataLeavingDevice: "Nothing",
            reversible: true,
            expiresAtUnixMillis: nil
        ))
        #expect(model.attachKnowledgeApproval(writeID: writeID, approvalID: approvalID))
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .awaitingApproval)

        model.resolveApproval(id: approvalID, approved: false)
        #expect(model.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.state == .rejected)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.disposition == .needsReview)
        #expect(model.beginCodingKnowledgeRevision(threadID: threadID))
        #expect(model.codingWorkflow(threadID: threadID)?.state == .updatingKnowledge)
    }

    @Test
    func newCodingCycleResetsOnlyTheActiveKnowledgeLaneAfterReasonedWaiver() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 27_900 })
        let (threadID, worktreeID) = try prepareCodingReview(model)
        recordPassingCodingEvidence(model, threadID: threadID, worktreeID: worktreeID)
        #expect(model.recordCodingReview(threadID: threadID, worktreeID: worktreeID, accepted: true))
        #expect(model.addCodingKnowledgeCandidate(
            threadID: threadID,
            category: .decision,
            title: "Previous cycle",
            detail: "This candidate belongs only to the completed cycle."
        ) != nil)
        let content = "Unneeded durable edit"
        let proposalID = try #require(model.createKnowledgeProposal(
            sourceID: "knowledge-coding-ade",
            title: "Previous proposal",
            target: "Projects/Coding ADE/Decisions.md",
            summary: "A proposal that will be waived.",
            proposedContent: content,
            baseRevision: "base"
        ))
        #expect(model.linkCodingKnowledge(threadID: threadID, proposalID: proposalID))
        let writeID = try #require(model.recordKnowledgeWrite(
            proposalID: proposalID,
            targetPath: "Projects/Coding ADE/Decisions.md",
            baseDigest: "base",
            proposedDigest: knowledgeDigest(content),
            diffSummary: "1 changed line",
            unifiedDiff: "+Unneeded durable edit"
        ))
        #expect(model.waiveCodingKnowledge(
            threadID: threadID,
            reason: "The accepted result does not change durable project truth."
        ))
        #expect(model.snapshot.operations.knowledgeWrites.first { $0.id == writeID }?.state == .cancelled)

        let nextMessageID = try #require(model.appendUserMessage(
            threadID: threadID,
            body: "Start the next implementation cycle."
        ))
        #expect(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: nextMessageID,
            purpose: .codingPlan,
            runtimeModeOverride: .approvalRequired,
            networkAccessOverride: false
        ) != nil)
        let lane = try #require(model.codingKnowledgeLane(threadID: threadID))
        #expect(lane.consultedSources.isEmpty)
        #expect(lane.candidates.isEmpty)
        #expect(lane.disposition == .collecting)
        #expect(lane.acceptedWorktreeID == nil)
        #expect(lane.proposalID == nil)
        #expect(lane.writeID == nil)
        #expect(model.codingWorkflow(threadID: threadID)?.state == .planning)
        #expect(model.snapshot.operations.knowledgeWrites.contains { $0.id == writeID })
    }

    @Test
    func codingKnowledgeContextDeduplicatesAndRejectsOversizedSources() throws {
        let model = DesktopAppModel(store: MemoryDesktopStateStore(), now: { 28_000 })
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .coding, projectID: projectID)
        let source = DesktopCodingKnowledgeConsultedSource(
            sourceID: "obsidian",
            title: "Overview",
            path: "Projects/Coding ADE/Overview.md",
            digest: String(repeating: "d", count: 64),
            provenance: "Obsidian CLI · local vault",
            excerpt: "bounded"
        )
        let second = DesktopCodingKnowledgeConsultedSource(
            sourceID: "repository",
            title: "AGENTS",
            path: "AGENTS.md",
            digest: String(repeating: "e", count: 64),
            provenance: "Repository checkout",
            excerpt: "policy reference"
        )
        #expect(model.replaceCodingKnowledgeContext(threadID: threadID, sources: [source, source, second]))
        #expect(model.codingKnowledgeLane(threadID: threadID)?.consultedSources.map(\.path) == [source.path, second.path])

        let oversized = DesktopCodingKnowledgeConsultedSource(
            sourceID: "oversized",
            title: "Too large",
            path: "large.md",
            digest: "digest",
            provenance: "fixture",
            excerpt: String(repeating: "x", count: 8_193)
        )
        #expect(model.replaceCodingKnowledgeContext(threadID: threadID, sources: [oversized]) == false)
        #expect(model.codingKnowledgeLane(threadID: threadID)?.consultedSources.map(\.path) == [source.path, second.path])

        let tooMany = (0..<65).map { index in
            DesktopCodingKnowledgeConsultedSource(
                sourceID: "source-\(index)",
                title: "Source \(index)",
                path: "source-\(index).md",
                digest: "digest-\(index)",
                provenance: "fixture"
            )
        }
        #expect(model.replaceCodingKnowledgeContext(threadID: threadID, sources: tooMany) == false)
    }

    private func prepareCodingReview(_ model: DesktopAppModel) throws -> (threadID: String, worktreeID: String) {
        let projectID = try #require(model.snapshot.projects.first?.id)
        let threadID = model.createConversation(kind: .coding, projectID: projectID)
        let messageID = try #require(model.appendUserMessage(threadID: threadID, body: "Implement the approved change."))
        let worktreeID = try #require(model.proposeWorktree(
            projectID: projectID,
            threadID: threadID,
            rootWorkspacePath: "/tmp/kaname-root",
            worktreePath: "/tmp/kaname-worktree-\(threadID)",
            branch: "kaname/test",
            baseRevision: "base"
        ))
        model.updateWorktree(id: worktreeID, headRevision: "base", changedFileCount: 0, diffSummary: "Ready", state: .ready)
        let runID = try #require(model.enqueueProviderRun(
            threadID: threadID,
            sourceMessageID: messageID,
            workspacePathOverride: "/tmp/kaname-worktree-\(threadID)",
            purpose: .codingImplementation,
            runtimeModeOverride: .autoAcceptEdits,
            networkAccessOverride: false
        ))
        #expect(model.beginProviderRun(id: runID) != nil)
        model.completeProviderRun(id: runID)
        return (threadID, worktreeID)
    }

    private func recordPassingCodingEvidence(_ model: DesktopAppModel, threadID: String, worktreeID: String) {
        #expect(model.updateCodingWorkflow(threadID: threadID, state: .reviewingEvidence))
        #expect(model.recordCodingEvidence(
            threadID: threadID,
            worktreeID: worktreeID,
            revision: "base:diff",
            diffStat: "1 file changed",
            diffCheckPassed: true,
            verificationCommand: "swift test --filter DesktopAppModelTests",
            verificationExitStatus: 0,
            verificationOutput: "PASS",
            artifactPaths: ["Sources/Flow.swift"],
            digest: String(repeating: "a", count: 64)
        ))
    }
}

private func knowledgeDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private final class MemoryDesktopStateStore: DesktopStateStoring {
    var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

private final class MemoryRecoveryDesktopStateStore: DesktopRecoveryStateStoring {
    var primary: Data?
    var recovery: Data?

    init(primary: Data?, recovery: Data?) {
        self.primary = primary
        self.recovery = recovery
    }

    func load() -> Data? { primary }
    func save(_ data: Data) { primary = data }
    func loadRecovery() -> Data? { recovery }
    func saveRecovered(_ data: Data) { primary = data }
}
