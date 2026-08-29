import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain
@testable import KanameProtocol

struct CodexLiveSessionTests {
    @Test
    func turnInputPreservesTextAndLocalImagesInProviderOrder() throws {
        let configuration = CodexLiveSessionConfiguration(
            instance: codexInstance(),
            workspaceURL: URL(fileURLWithPath: "/private/tmp/kaname-images")
        )
        let request = CodexCodingRequest(
            prompt: "Compare these screenshots",
            imagePaths: ["/private/tmp/one.png", "/private/tmp/two.jpg"]
        )
        let parameters = CodexLiveSession.turnStartParameters(
            configuration: configuration,
            request: request,
            threadID: "thread-images"
        )
        let input = try #require(parameters["input"] as? [[String: Any]])

        #expect(input.count == 3)
        #expect(input[0]["type"] as? String == "text")
        #expect(input[0]["text"] as? String == "Compare these screenshots")
        #expect(input[1]["type"] as? String == "localImage")
        #expect(input[1]["path"] as? String == "/private/tmp/one.png")
        #expect(input[2]["path"] as? String == "/private/tmp/two.jpg")
    }

    @Test
    func turnForwardsStructuredOutputSchema() throws {
        let configuration = CodexLiveSessionConfiguration(
            instance: codexInstance(),
            workspaceURL: URL(fileURLWithPath: "/private/tmp/kaname-structured-output")
        )
        let request = CodexCodingRequest(
            prompt: "Return a title.",
            outputJSONSchema: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
        )

        let parameters = CodexLiveSession.turnStartParameters(
            configuration: configuration,
            request: request,
            threadID: "thread-structured-output"
        )
        let schema = try #require(parameters["outputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let title = try #require(properties["title"] as? [String: Any])

        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["title"])
        #expect(title["type"] as? String == "string")
    }

    @Test
    func structuredPlanUpdatePreservesEveryVisibleStepAndStatus() throws {
        let event = try notification(
            method: "turn/plan/updated",
            parameters: [
                "turnId": "turn-plan",
                "explanation": "Plan before implementation.",
                "plan": [
                    ["step": "Inspect the existing runtime", "status": "completed"],
                    ["step": "Add the approval gate", "status": "inProgress"],
                    ["step": "Collect independent evidence", "status": "pending"],
                ],
            ]
        )

        let update = try #require(event.planUpdate)
        #expect(event.kind == .planUpdated)
        #expect(update.explanation == "Plan before implementation.")
        #expect(update.entries.map(\.step) == [
            "Inspect the existing runtime",
            "Add the approval gate",
            "Collect independent evidence",
        ])
        #expect(update.entries.map(\.status) == ["completed", "inProgress", "pending"])
    }

    @Test
    func structuredPlanUpdateWithEmptyPlanIsIgnored() throws {
        let event = try notification(
            method: "turn/plan/updated",
            parameters: [
                "turnId": "turn-empty-plan",
                "plan": [],
            ]
        )

        #expect(event.kind == .planUpdated)
        #expect(event.planUpdate == nil)
    }

    @Test
    func codexItemsPreserveToolCallIdentityKindAndLifecycle() throws {
        let started = try notification(
            method: "item/started",
            parameters: [
                "threadId": "thread-tools",
                "turnId": "turn-tools",
                "item": [
                    "id": "call-command-1",
                    "type": "commandExecution",
                    "status": "inProgress",
                    "command": "private command stays in raw evidence",
                ],
            ]
        )
        let completed = try notification(
            method: "item/completed",
            parameters: [
                "threadId": "thread-tools",
                "turnId": "turn-tools",
                "item": [
                    "id": "call-command-1",
                    "type": "commandExecution",
                    "status": "completed",
                ],
            ]
        )

        #expect(started.kind == .toolActivity)
        #expect(started.toolObservation?.callID == "call-command-1")
        #expect(started.toolObservation?.kind == .commandExecution)
        #expect(started.toolObservation?.state == .running)
        #expect(started.toolObservation?.name == "Command")
        #expect(completed.toolObservation?.callID == started.toolObservation?.callID)
        #expect(completed.toolObservation?.state == .completed)
        #expect(completed.toolObservation?.name == "Command")
    }

    @Test
    func codexSubagentActivityUsesTypedNativeIdentityWithoutTextGuessing() throws {
        let startedEnvelope = try notification(
            method: "item/started",
            parameters: [
                "threadId": "thread-parent",
                "turnId": "turn-parent",
                "item": [
                    "id": "activity-1",
                    "type": "subAgentActivity",
                    "kind": "completed",
                    "agentThreadId": "thread-child",
                ],
            ]
        )
        let activity = try notification(
            method: "item/completed",
            parameters: [
                "threadId": "thread-parent",
                "turnId": "turn-parent",
                "item": [
                    "id": "activity-1",
                    "type": "subAgentActivity",
                    "kind": "completed",
                    "agentThreadId": "thread-child",
                    "agentPath": "/root/reviewer",
                ],
            ]
        )

        #expect(startedEnvelope.agentActivity == nil)
        #expect(activity.kind == .toolActivity)
        #expect(activity.toolObservation == nil)
        #expect(activity.agentActivity?.agentID == "thread-child")
        #expect(activity.agentActivity?.activity == .completed)
        #expect(activity.agentActivity?.agentPath == "/root/reviewer")
        #expect(activity.agentActivity?.sourceToolCallID == "activity-1")
    }

    @Test
    func onlyCollaborationSpawnCreatesAnAgentObservation() throws {
        let send = try notification(
            method: "item/completed",
            parameters: [
                "item": [
                    "id": "call-send",
                    "type": "collabToolCall",
                    "tool": "sendMessage",
                    "status": "completed",
                    "receiverThreadId": "thread-existing",
                ],
            ]
        )
        let spawn = try notification(
            method: "item/completed",
            parameters: [
                "threadId": "thread-root",
                "item": [
                    "id": "call-spawn",
                    "type": "collabToolCall",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "thread-root",
                    "newThreadId": "thread-new",
                ],
            ]
        )
        let nestedSpawn = try notification(
            method: "item/completed",
            parameters: [
                "threadId": "thread-root",
                "item": [
                    "id": "call-nested-spawn",
                    "type": "collabToolCall",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "thread-parent-agent",
                    "newThreadId": "thread-nested-agent",
                ],
            ]
        )

        #expect(send.toolObservation?.kind == .collaboration)
        #expect(send.agentActivity == nil)
        #expect(spawn.agentActivity?.agentID == "thread-new")
        #expect(spawn.agentActivity?.activity == .started)
        #expect(spawn.agentActivity?.parentAgentID == nil)
        #expect(spawn.agentActivity?.sourceToolCallID == "call-spawn")
        #expect(nestedSpawn.agentActivity?.agentID == "thread-nested-agent")
        #expect(nestedSpawn.agentActivity?.parentAgentID == "thread-parent-agent")
    }

    @Test
    func sessionRouteTableKeepsLateChildCompletionOnItsOriginalRun() throws {
        var routes = CodexRunEventRouteTable()
        try routes.register(runID: "run-one")
        let firstStarted = CodexRunEvent(
            kind: .runStarted,
            nativeType: "turn/started",
            turnID: "native-turn-one"
        )
        #expect(try routes.route(firstStarted) == "run-one")
        routes.observe(firstStarted, routedTo: "run-one")

        let childStarted = CodexRunEvent(
            kind: .toolActivity,
            nativeType: "item/completed",
            turnID: "native-turn-one",
            agentActivity: ProviderAgentActivity(
                agentID: "child-one",
                parentAgentID: "parent-one",
                activity: .started,
                agentPath: "/root/child-one",
                sourceToolCallID: "call-child-one"
            )
        )
        #expect(try routes.route(childStarted) == "run-one")
        routes.observe(childStarted, routedTo: "run-one")
        #expect(routes.hasOutstandingAgentActivity)
        #expect(routes.runIDsWithOutstandingAgentActivity == ["run-one"])
        let trackedChild = try #require(childStarted.agentActivity)
        #expect(routes.outstandingAgentActivities(for: "run-one") == [trackedChild])

        let firstCompleted = CodexRunEvent(
            kind: .providerCompleted,
            nativeType: "turn/completed",
            turnID: "native-turn-one"
        )
        #expect(try routes.route(firstCompleted) == "run-one")
        routes.observe(firstCompleted, routedTo: "run-one")
        #expect(routes.hasOutstandingAgentActivity)

        try routes.register(runID: "run-two")
        let secondStarted = CodexRunEvent(
            kind: .runStarted,
            nativeType: "turn/started",
            turnID: "native-turn-two"
        )
        #expect(try routes.route(secondStarted) == "run-two")
        routes.observe(secondStarted, routedTo: "run-two")

        let lateChildCompletion = CodexRunEvent(
            kind: .toolActivity,
            nativeType: "item/completed",
            turnID: "native-turn-one",
            agentActivity: ProviderAgentActivity(agentID: "child-one", activity: .completed)
        )
        #expect(try routes.route(lateChildCompletion) == "run-one")
        routes.observe(lateChildCompletion, routedTo: "run-one")
        #expect(!routes.hasOutstandingAgentActivity)
    }

    @Test
    func sequentialRunsKeepDistinctImmutableControlTargets() throws {
        var routes = CodexRunEventRouteTable()
        try routes.register(runID: "run-one")
        try routes.bind(
            runID: "run-one",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn-one"
        )
        routes.observe(
            CodexRunEvent(kind: .providerCompleted, nativeType: "turn/completed"),
            routedTo: "run-one"
        )

        try routes.register(runID: "run-two")
        try routes.bind(
            runID: "run-two",
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn-two"
        )

        #expect(routes.controlTarget(for: "run-one") == CodexRunControlTarget(
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn-one"
        ))
        #expect(routes.controlTarget(for: "run-two") == CodexRunControlTarget(
            nativeThreadID: "native-thread",
            nativeTurnID: "native-turn-two"
        ))
        #expect(throws: CodexRunEventRouteError.nativeTurnAlreadyBound) {
            try routes.bind(
                runID: "run-one",
                nativeThreadID: "native-thread",
                nativeTurnID: "native-turn-two"
            )
        }
    }

    @Test
    func targetedInterruptUsesOriginalTurnAndUnexpectedExitFinishesEventStream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaname-codex-control-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let codexHome = root.appending(path: "codex-home", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("test-only-authentication".utf8).write(to: codexHome.appending(path: "auth.json"))
        let executable = try makeCodexControlFixture(in: root)
        let interruptCapture = URL(fileURLWithPath: executable.path + ".interrupt.json")
        let session = CodexLiveSession(configuration: CodexLiveSessionConfiguration(
            instance: codexInstance(),
            executable: executable.path,
            workspaceURL: workspace,
            timeout: .seconds(8),
            codexHome: codexHome
        ))
        let stream = await session.events()
        let collector = _Concurrency.Task { () -> [CodexRunEvent] in
            var events: [CodexRunEvent] = []
            for await event in stream { events.append(event) }
            return events
        }

        do {
            let request = CodexCodingRequest(prompt: "exercise targeted controls")
            let firstRun = try await session.start(request)
            let secondRun = try await continueRunAfterTerminal(session: session, request: request)
            #expect(firstRun.nativeTurnID == "native-turn-one")
            #expect(secondRun.nativeTurnID == "native-turn-two")

            try await session.interrupt(CodexRunControlTarget(
                nativeThreadID: firstRun.nativeThreadID,
                nativeTurnID: firstRun.nativeTurnID
            ))

            let interruptData = try Data(contentsOf: interruptCapture)
            let interruptObject = try #require(
                JSONSerialization.jsonObject(with: interruptData) as? [String: Any]
            )
            let interruptParameters = try #require(interruptObject["params"] as? [String: Any])
            #expect(interruptObject["method"] as? String == "turn/interrupt")
            #expect(interruptParameters["threadId"] as? String == firstRun.nativeThreadID)
            #expect(interruptParameters["turnId"] as? String == firstRun.nativeTurnID)
            #expect(interruptParameters["turnId"] as? String != secondRun.nativeTurnID)

            let events = try await collectedEvents(from: collector, timeout: .seconds(5))
            #expect(events.contains { event in
                event.agentActivity?.agentID == "native-child-one"
                    && event.agentActivity?.activity == .started
            })
            #expect(events.filter { $0.kind == .providerCompleted }.count == 2)
            #expect(events.contains {
                $0.kind == .runFailed && $0.nativeType == "codex-app-server/exited"
            })
        } catch {
            collector.cancel()
            await session.close()
            throw error
        }
        await session.close()
    }

    @Test
    func agentLedgerPreservesIdentityAndSettlesUnknownChildrenWithoutInventingSuccess() throws {
        var ledger = ProviderAgentActivityLedger()
        ledger.observe(ProviderAgentActivity(
            agentID: "child-two",
            parentAgentID: "parent-two",
            activity: .started,
            agentPath: "/root/child-two",
            taskType: "review",
            sourceToolCallID: "call-child-two"
        ))
        ledger.observe(ProviderAgentActivity(
            agentID: "child-one",
            activity: .started,
            taskType: "research"
        ))

        let settlements = ledger.settlementActivities(as: .interrupted)
        #expect(settlements.map(\.agentID) == ["child-one", "child-two"])
        #expect(settlements.allSatisfy { $0.activity == .interrupted })
        let childTwo = try #require(settlements.last)
        #expect(childTwo.parentAgentID == "parent-two")
        #expect(childTwo.agentPath == "/root/child-two")
        #expect(childTwo.taskType == "review")
        #expect(childTwo.sourceToolCallID == "call-child-two")
        #expect(ledger.hasOutstandingActivity)

        for settlement in settlements { ledger.observe(settlement) }
        #expect(!ledger.hasOutstandingActivity)
        #expect(ledger.outstandingActivities.isEmpty)
    }

    @Test
    func failedParentTurnRetainsChildrenUntilTypedInterruptionIsPersisted() throws {
        var routes = CodexRunEventRouteTable()
        try routes.register(runID: "run-failed")
        let child = ProviderAgentActivity(agentID: "child-failed", activity: .started)
        routes.observe(
            CodexRunEvent(kind: .toolActivity, nativeType: "item/completed", agentActivity: child),
            routedTo: "run-failed"
        )
        routes.observe(
            CodexRunEvent(kind: .runFailed, nativeType: "turn/completed"),
            routedTo: "run-failed"
        )

        #expect(routes.outstandingAgentActivities(for: "run-failed") == [child])
        routes.observe(
            CodexRunEvent(
                kind: .toolActivity,
                nativeType: "kaname/turn-ended",
                agentActivity: ProviderAgentActivity(agentID: "child-failed", activity: .interrupted)
            ),
            routedTo: "run-failed"
        )
        #expect(!routes.hasOutstandingAgentActivity)
    }

    @Test
    func initializeHandshakeIsOneImmediateOrderedJSONLSequence() throws {
        let data = try CodexAppServerConnection.encodedRequestSequence(
            method: "initialize",
            parameters: [
                "clientInfo": [
                    "name": "kaname",
                    "title": "Kaname",
                    "version": "test",
                ],
            ],
            requestID: 7,
            notificationAfterSend: "initialized"
        )
        let lines = data.split(separator: 0x0A)

        #expect(lines.count == 2)
        let request = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
        )
        let notification = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any]
        )
        #expect(request["id"] as? Int == 7)
        #expect(request["method"] as? String == "initialize")
        #expect(request["params"] is [String: Any])
        #expect(notification["id"] == nil)
        #expect(notification["method"] as? String == "initialized")
        #expect((notification["params"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func mcpIsolationDisablesImplicitAppsAndRejectsCallerOverrides() throws {
        #expect(
            try CodexMCPIsolation.enforcedLaunchArguments(baseArguments: ["--strict-config"])
                == ["--strict-config", "--disable", "apps"]
        )
        #expect(throws: CodexLiveSessionError.mcpConfigurationPresent) {
            try CodexMCPIsolation.enforcedLaunchArguments(baseArguments: ["--enable", "apps"])
        }
        #expect(throws: CodexLiveSessionError.mcpConfigurationPresent) {
            try CodexMCPIsolation.enforcedLaunchArguments(baseArguments: ["-c", "features.apps=true"])
        }
    }

    @Test
    func phaseTwoRequestPinsTerraExtraHighAndConstrainsTheWorktree() {
        let workspace = URL(fileURLWithPath: "/private/tmp/kaname-worktree")
        let configuration = CodexLiveSessionConfiguration(
            instance: codexInstance(),
            workspaceURL: workspace
        )
        #expect(configuration.launchArguments.isEmpty)
        let request = CodexCodingRequest(
            prompt: "Review this adapter without making changes.",
            sandbox: .workspaceWrite
        )

        let thread = CodexLiveSession.threadStartParameters(configuration: configuration, request: request)
        #expect(thread["cwd"] as? String == workspace.path)
        #expect(thread["model"] as? String == "gpt-5.6-terra")
        #expect(thread["approvalPolicy"] as? String == "on-request")
        #expect(thread["sandbox"] as? String == "workspace-write")
        #expect(thread["ephemeral"] as? Bool == true)

        let persistentConfiguration = CodexLiveSessionConfiguration(
            instance: codexInstance(),
            workspaceURL: workspace,
            persistentSessionDirectory: URL(fileURLWithPath: "/private/tmp/kaname-codex-sessions")
        )
        let persistentThread = CodexLiveSession.threadStartParameters(
            configuration: persistentConfiguration,
            request: request
        )
        #expect(persistentThread["ephemeral"] as? Bool == false)
        let resume = CodexLiveSession.threadResumeParameters(
            configuration: persistentConfiguration,
            request: request,
            threadID: "thread-123"
        )
        #expect(resume["threadId"] as? String == "thread-123")
        #expect(resume["cwd"] as? String == workspace.path)
        #expect(resume["excludeTurns"] as? Bool == true)

        let turn = CodexLiveSession.turnStartParameters(
            configuration: configuration,
            request: request,
            threadID: "thread-123"
        )
        #expect(turn["threadId"] as? String == "thread-123")
        #expect(turn["model"] as? String == "gpt-5.6-terra")
        #expect(turn["effort"] as? String == "xhigh")
        #expect(turn["approvalPolicy"] as? String == "on-request")
        let sandbox = turn["sandboxPolicy"] as? [String: Any]
        #expect(sandbox?["type"] as? String == "workspaceWrite")
        #expect(sandbox?["networkAccess"] as? Bool == false)
        #expect(sandbox?["writableRoots"] as? [String] == [workspace.path])
    }

    @Test
    func conversationModesMapToCodexAuthorityAndNetworkExactly() throws {
        let workspace = URL(fileURLWithPath: "/private/tmp/kaname-conversation")
        let configuration = CodexLiveSessionConfiguration(instance: codexInstance(), workspaceURL: workspace)

        let supervised = CodexCodingRequest.conversation(
            prompt: "Inspect",
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            runtimeMode: .approvalRequired,
            networkAccess: false
        )
        #expect(supervised.sandbox == .readOnly)
        #expect(supervised.approvalPolicy == .untrusted)
        #expect(supervised.approvalsReviewer == .user)
        #expect(supervised.runtimeAuthority == .userConfiguredConversation)
        let supervisedSandbox = try #require(
            CodexLiveSession.turnStartParameters(
                configuration: configuration,
                request: supervised,
                threadID: "thread"
            )["sandboxPolicy"] as? [String: Any]
        )
        #expect(supervisedSandbox["type"] as? String == "readOnly")
        #expect(supervisedSandbox["networkAccess"] as? Bool == false)

        let edits = CodexCodingRequest.conversation(
            prompt: "Edit",
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            runtimeMode: .autoAcceptEdits,
            networkAccess: true
        )
        #expect(edits.sandbox == .workspaceWrite)
        #expect(edits.approvalPolicy == .onRequest)
        #expect(edits.approvalsReviewer == .user)
        let editsSandbox = try #require(
            CodexLiveSession.turnStartParameters(
                configuration: configuration,
                request: edits,
                threadID: "thread"
            )["sandboxPolicy"] as? [String: Any]
        )
        #expect(editsSandbox["networkAccess"] as? Bool == true)
        #expect(editsSandbox["writableRoots"] as? [String] == [workspace.path])

        let automatic = CodexCodingRequest.conversation(
            prompt: "Work",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            runtimeMode: .auto,
            networkAccess: false
        )
        #expect(automatic.sandbox == .workspaceWrite)
        #expect(automatic.approvalsReviewer == .autoReview)

        let full = CodexCodingRequest.conversation(
            prompt: "Work",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            runtimeMode: .fullAccess,
            networkAccess: false
        )
        #expect(full.sandbox == .dangerFullAccess)
        #expect(full.approvalPolicy == .never)
        #expect(full.networkAccess)
        let fullSandbox = try #require(
            CodexLiveSession.turnStartParameters(
                configuration: configuration,
                request: full,
                threadID: "thread"
            )["sandboxPolicy"] as? [String: Any]
        )
        #expect(fullSandbox["type"] as? String == "dangerFullAccess")
    }

    @Test
    func persistentIsolatedHomeRetainsHistoryButOnlyReferencesAuthentication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-persistent-home-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let persistent = root.appendingPathComponent("persistent")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("authentication".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("must-not-copy".utf8).write(to: source.appendingPathComponent("config.toml"))

        let isolated = try CodexEphemeralHome.create(sourceHome: source, persistentDirectory: persistent)
        try isolated.cleanup()

        #expect(FileManager.default.fileExists(atPath: persistent.path))
        #expect(FileManager.default.fileExists(atPath: persistent.appendingPathComponent("auth.json").path))
        #expect(!FileManager.default.fileExists(atPath: persistent.appendingPathComponent("config.toml").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: persistent.appendingPathComponent("auth.json").path)
            == source.appendingPathComponent("auth.json").path)
    }

    @Test
    func isolatedHomeEnvironmentUsesAFileSystemPathWhenItContainsSpaces() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname codex home \(UUID().uuidString)")

        let environment = CodexMCPIsolation.codexEnvironment(home: root)
        let appServerEnvironment = CodexAppServerConnection.processEnvironment(codexHome: root)

        #expect(environment["CODEX_HOME"] == root.path)
        #expect(environment["CODEX_HOME"]?.contains("%20") == false)
        #expect(appServerEnvironment["CODEX_HOME"] == root.path)
        #expect(appServerEnvironment["CODEX_HOME"]?.contains("%20") == false)
    }

    @Test
    func swiftApprovalFingerprintMatchesTheRustAuthorityVector() {
        var scope = Kaname_V1_Scope()
        scope.projectID = "kaname"
        scope.workspaceID = "/tmp/kaname-isolated-worktree"
        scope.authorityID = "local-user"
        scope.egressClass = "provider_and_workspace"
        scope.destinationDigest = "codex-model-digest"
        var request = Kaname_V1_ApprovalRequest()
        request.approvalID = "approval-002"
        request.actionKind = "codex.workspace_write"
        request.scope = scope
        request.targetID = scope.workspaceID
        request.targetRevision = "revision-002"
        request.effectDigest = Data(repeating: 0x22, count: 32)
        request.consequence = "One isolated reversible turn."
        request.reversible = true
        request.expiresAtUnixMillis = 2_000
        request.policyReference = "phase2-explicit-isolated-worktree"
        request.approvalPayloadVersion = 1

        let fingerprint = Phase2ControlPlane.approvalFingerprint(request)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(fingerprint == "0e6b39798cf4854da40480ca88267e0656caea7db0147b19339eb8661023da35")
    }

    @Test
    func terminalAndUnknownNotificationsRetainNativeTypeWithoutChangingCompletionMeaning() throws {
        let completed = try notification(
            method: "turn/completed",
            parameters: [
                "threadId": "thread-1",
                "turn": ["id": "turn-1", "status": "completed"],
            ]
        )
        #expect(completed.kind == .providerCompleted)
        #expect(completed.threadID == "thread-1")
        #expect(completed.turnID == "turn-1")
        #expect(completed.nativeType == "turn/completed")

        let failed = try notification(
            method: "turn/completed",
            parameters: [
                "threadId": "thread-1",
                "turn": ["id": "turn-2", "status": "failed"],
            ]
        )
        #expect(failed.kind == .runFailed)

        let unsupportedTerminalStatus = try notification(
            method: "turn/completed",
            parameters: [
                "threadId": "thread-1",
                "turn": ["id": "turn-3", "status": "awaiting_confirmation"],
            ]
        )
        #expect(unsupportedTerminalStatus.kind == .runFailed)

        let missingTerminalStatus = try notification(
            method: "turn/completed",
            parameters: ["threadId": "thread-1", "turn": ["id": "turn-4"]]
        )
        #expect(missingTerminalStatus.kind == .runFailed)

        let unknown = try notification(
            method: "future/native/observation",
            parameters: ["threadId": "thread-1", "newField": ["preserved": true]]
        )
        #expect(unknown.kind == .nativeProviderEvent)
        #expect(unknown.nativeType == "future/native/observation")
        #expect(unknown.payload != nil)

        let threadStarted = try notification(
            method: "thread/started",
            parameters: ["thread": ["id": "thread-nested"]]
        )
        #expect(threadStarted.kind == .sessionStarted)
        #expect(threadStarted.threadID == "thread-nested")
    }

    @Test
    func approvalRequestsAreVisibleAndOversizedNativePayloadsAreNotRetained() throws {
        let approvalPayload = try JSONSerialization.data(withJSONObject: [
            "threadId": "thread-1",
            "turnId": "turn-1",
            "itemId": "item-1",
        ])
        let approval = CodexRunEvent.from(.serverRequest(
            id: .integer(1),
            method: "item/fileChange/requestApproval",
            parameters: approvalPayload
        ))
        #expect(approval.kind == .approvalRequested)
        #expect(approval.threadID == "thread-1")
        #expect(approval.turnID == "turn-1")
        #expect(approval.withApprovalID("integer-1").approvalID == "integer-1")

        let oversized = try notification(
            method: "item/agentMessage/delta",
            parameters: [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-1",
                "delta": String(repeating: "x", count: CodexRunEvent.maximumRetainedPayloadBytes + 1),
            ]
        )
        #expect(oversized.kind == .messageDelta)
        #expect(oversized.payload == nil)
        #expect(oversized.payloadWasTruncated)
        #expect(oversized.text?.utf8.count == CodexRunEvent.maximumTextBytes)
    }

    @Test
    func requestUserInputMapsToQuestionRequestedWithStableIDsAndRedactedJournalMetadata() throws {
        let requestID = CodexAppServerRequestID.string("request-user-input-042")
        let questionText = "test-only-question-text-must-not-be-persisted"
        let firstOptionID = "option-001"
        let firstOptionLabel = "test-only-option-label-must-not-be-persisted"
        let secondOptionID = "option-002"
        let parameters = try JSONSerialization.data(withJSONObject: [
            "threadId": "native-thread-question-001",
            "turnId": "native-turn-question-001",
            "questions": [[
                "id": "question-001",
                "question": questionText,
                "options": [
                    ["id": firstOptionID, "label": firstOptionLabel],
                    ["id": secondOptionID, "label": "second test-only option"],
                ],
            ]],
        ])
        let event = CodexRunEvent.from(.serverRequest(
            id: requestID,
            method: "item/tool/requestUserInput",
            parameters: parameters
        )).withApprovalID(requestID.stableValue)

        #expect(event.kind == .questionRequested)
        #expect(event.approvalID == "string-request-user-input-042")
        #expect(event.threadID == "native-thread-question-001")
        #expect(event.turnID == "native-turn-question-001")
        let retainedPayload = try #require(event.payload)
        let payloadObject = try #require(
            JSONSerialization.jsonObject(with: retainedPayload) as? [String: Any]
        )
        let payloadQuestions = try #require(payloadObject["questions"] as? [[String: Any]])
        let payloadQuestion = try #require(payloadQuestions.first)
        let payloadOptions = try #require(payloadQuestion["options"] as? [[String: Any]])
        #expect(payloadQuestion["id"] as? String == "question-001")
        #expect(payloadOptions.compactMap { $0["id"] as? String } == [firstOptionID, secondOptionID])

        let context = CodexJournalContext(
            projectID: KanameID(rawValue: "kaname"),
            threadID: KanameID(rawValue: "thread-001"),
            runID: KanameID(rawValue: "run-001"),
            providerInstance: codexInstance()
        )
        let envelope = event.journalEnvelope(
            context: context,
            ordinal: 8,
            occurredAt: Date(timeIntervalSince1970: 1_762_000_000)
        )
        let retainedMetadata = try #require(
            JSONSerialization.jsonObject(with: envelope.payload.value) as? [String: Any]
        )

        #expect(envelope.kind == "question.requested")
        #expect(envelope.causationID == "string-request-user-input-042")
        #expect(Set(retainedMetadata.keys) == Set([
            "nativeKind",
            "nativeType",
            "nativeThreadID",
            "nativeTurnID",
            "approvalID",
            "textByteCount",
            "rawPayloadByteCount",
            "payloadWasTruncated",
        ]))
        let encodedMetadata = String(decoding: envelope.payload.value, as: UTF8.self)
        #expect(!encodedMetadata.contains(questionText))
        #expect(!encodedMetadata.contains(firstOptionLabel))
    }

    @Test
    func onlyActiveMcpStartupStatesStopTheRun() throws {
        let disabled = try notification(
            method: "mcpServer/startupStatus/updated",
            parameters: ["status": "disabled"]
        )
        #expect(!disabled.indicatesUnsafeMCPStartup)

        let starting = try notification(
            method: "mcpServer/startupStatus/updated",
            parameters: ["status": ["state": "starting"]]
        )
        #expect(starting.indicatesUnsafeMCPStartup)
    }

    @Test
    func ephemeralHomeReferencesAuthenticationWithoutCopyingUserConfiguration() throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "kaname-codex-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let authentication = source.appending(path: "auth.json")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("test-only-authentication".utf8).write(to: authentication)
        defer { try? FileManager.default.removeItem(at: source) }

        let home = try CodexEphemeralHome.create(sourceHome: source)
        defer { try? home.cleanup() }
        let linkedAuthentication = home.url.appending(path: "auth.json")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkedAuthentication.path)
        #expect(destination == authentication.path)
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "config.toml").path))
    }

    @Test
    func recorderMakesAProviderEnvelopeWithoutPersistingNativeTextOrRawPayload() throws {
        let context = CodexJournalContext(
            projectID: KanameID(rawValue: "kaname"),
            threadID: KanameID(rawValue: "thread-001"),
            runID: KanameID(rawValue: "run-001"),
            providerInstance: codexInstance()
        )
        let event = CodexRunEvent(
            kind: .approvalRejected,
            nativeType: "item/fileChange/requestApproval/declined",
            threadID: "native-thread",
            turnID: "native-turn",
            approvalID: "integer-9",
            text: "private provider response",
            payload: Data("raw provider payload".utf8)
        )

        let envelope = event.journalEnvelope(
            context: context,
            ordinal: 7,
            occurredAt: Date(timeIntervalSince1970: 1_762_000_000)
        )

        #expect(envelope.eventID == "codex-run-001-7")
        #expect(envelope.streamID == "thread:project:kaname:thread-001")
        #expect(envelope.kind == "approval.rejected")
        #expect(envelope.causationID == "integer-9")
        #expect(envelope.correlationID == "run-001")
        #expect(envelope.provenance.sourceKind == "provider")
        #expect(envelope.provenance.providerInstanceID == "codexLocal")
        let retainedMetadata = String(decoding: envelope.payload.value, as: UTF8.self)
        #expect(!retainedMetadata.contains("private provider response"))
        #expect(!retainedMetadata.contains("raw provider payload"))
        #expect(retainedMetadata.contains("textByteCount"))
        #expect(retainedMetadata.contains("rawPayloadByteCount"))
    }

    @Test
    func journalEnvelopeRetainsTypedActivityMetadataAndStableCausationOnly() throws {
        let context = CodexJournalContext(
            projectID: KanameID(rawValue: "kaname"),
            threadID: KanameID(rawValue: "thread-001"),
            runID: KanameID(rawValue: "run-typed"),
            providerInstance: codexInstance()
        )
        let toolEvent = CodexRunEvent(
            kind: .toolActivity,
            nativeType: "item/completed",
            threadID: "native-thread",
            turnID: "native-turn",
            toolObservation: ProviderToolObservation(
                callID: "call-typed",
                kind: .collaboration,
                state: .completed,
                name: "private tool label"
            ),
            agentActivity: ProviderAgentActivity(
                agentID: "agent-typed",
                activity: .started,
                agentPath: "/private/provider/path"
            )
        )
        let toolEnvelope = toolEvent.journalEnvelope(
            context: context,
            ordinal: 9,
            occurredAt: Date(timeIntervalSince1970: 1_762_000_000)
        )
        let metadata = try #require(
            JSONSerialization.jsonObject(with: toolEnvelope.payload.value) as? [String: Any]
        )

        #expect(toolEnvelope.causationID == "call-typed")
        #expect(metadata["toolCallID"] as? String == "call-typed")
        #expect(metadata["toolKind"] as? String == "collaboration")
        #expect(metadata["toolState"] as? String == "completed")
        #expect(metadata["agentID"] as? String == "agent-typed")
        #expect(metadata["agentActivity"] as? String == "started")
        #expect(!String(decoding: toolEnvelope.payload.value, as: UTF8.self).contains("private tool label"))
        #expect(!String(decoding: toolEnvelope.payload.value, as: UTF8.self).contains("/private/provider/path"))

        let agentEnvelope = CodexRunEvent(
            kind: .toolActivity,
            nativeType: "item/completed",
            agentActivity: ProviderAgentActivity(agentID: "agent-only", activity: .completed)
        ).journalEnvelope(
            context: context,
            ordinal: 10,
            occurredAt: Date(timeIntervalSince1970: 1_762_000_001)
        )
        #expect(agentEnvelope.causationID == "agent-only")
    }

    @Test
    func commandOutputBurstIsCoalescedBeforeTheBoundedConsumerStream() throws {
        var coalescer = CodexProviderEventCoalescer()
        var delivered: [CodexRunEvent] = []
        for ordinal in 0..<608 {
            delivered += coalescer.ingest(try notification(
                method: "item/commandExecution/outputDelta",
                parameters: [
                    "threadId": "native-thread",
                    "turnId": "native-turn",
                    "itemId": "command-1",
                    "delta": "\(ordinal),",
                ]
            ))
        }
        delivered += coalescer.ingest(try notification(
            method: "turn/completed",
            parameters: [
                "threadId": "native-thread",
                "turn": ["id": "native-turn", "status": "completed"],
            ]
        ))

        #expect(delivered.count == 2)
        #expect(delivered[0].kind == .nativeProviderEvent)
        #expect(delivered[0].toolObservation?.callID == "command-1")
        #expect(delivered[0].toolObservation?.kind == .commandExecution)
        #expect(delivered[0].text == (0..<608).map { "\($0)," }.joined())
        #expect(delivered[0].payload?.split(separator: 0x0a).count == 608)
        #expect(delivered[0].payloadWasTruncated == false)
        #expect(delivered[1].kind == .providerCompleted)
    }

    @Test
    func assistantDeltaBurstRemainsStreamingButCannotFillTheEventBuffer() throws {
        var coalescer = CodexProviderEventCoalescer()
        var delivered: [CodexRunEvent] = []
        for _ in 0..<4_096 {
            delivered += coalescer.ingest(try notification(
                method: "item/agentMessage/delta",
                parameters: [
                    "threadId": "native-thread",
                    "turnId": "native-turn",
                    "itemId": "message-1",
                    "delta": "x",
                ]
            ))
        }
        delivered += coalescer.flush()

        #expect(delivered.count == 128)
        #expect(delivered.allSatisfy { $0.kind == .messageDelta })
        #expect(delivered.compactMap(\.text).joined().count == 4_096)
        #expect(delivered.allSatisfy {
            ($0.payload?.count ?? 0) <= CodexRunEvent.maximumRetainedPayloadBytes
        })
    }

    private func codexInstance() -> ProviderInstance {
        ProviderInstance(
            id: ProviderInstanceID(rawValue: "codexLocal")!,
            driver: .codex,
            displayName: "Codex local"
        )
    }

    private func notification(method: String, parameters: [String: Any]) throws -> CodexRunEvent {
        let payload = try JSONSerialization.data(withJSONObject: parameters)
        return CodexRunEvent.from(.notification(method: method, parameters: payload))
    }

    private func makeCodexControlFixture(in root: URL) throws -> URL {
        let executable = root.appending(path: "codex-fixture")
        let source = """
        #!/bin/sh
        if [ "$1" = "mcp" ]; then
          printf '[]\n'
          exit 0
        fi
        IFS= read -r initialize_request || exit 10
        printf '{"id":1,"result":{}}\n'
        IFS= read -r initialized_notification || exit 11
        IFS= read -r thread_request || exit 12
        printf '{"id":2,"result":{"thread":{"id":"native-thread"}}}\n'
        IFS= read -r first_turn_request || exit 13
        printf '{"id":3,"result":{"turn":{"id":"native-turn-one"}}}\n'
        sleep 1
        printf '{"method":"item/completed","params":{"threadId":"native-thread","turnId":"native-turn-one","item":{"id":"spawn-one","type":"collabToolCall","tool":"spawnAgent","status":"completed","senderThreadId":"native-thread","newThreadId":"native-child-one"}}}\n'
        printf '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"native-turn-one","status":"completed"}}}\n'
        IFS= read -r second_turn_request || exit 14
        printf '{"id":4,"result":{"turn":{"id":"native-turn-two"}}}\n'
        IFS= read -r interrupt_request || exit 15
        printf '%s\n' "$interrupt_request" > "$0.interrupt.json"
        printf '{"id":5,"result":{}}\n'
        printf '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"native-turn-two","status":"completed"}}}\n'
        sleep 1
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func continueRunAfterTerminal(
        session: CodexLiveSession,
        request: CodexCodingRequest
    ) async throws -> CodexLiveRun {
        for _ in 0..<100 {
            do {
                return try await session.continueRun(request)
            } catch CodexLiveSessionError.notStarted {
                try await _Concurrency.Task.sleep(for: .milliseconds(20))
            }
        }
        throw CodexControlFixtureError.timeout
    }

    private func collectedEvents(
        from collector: _Concurrency.Task<[CodexRunEvent], Never>,
        timeout: Duration
    ) async throws -> [CodexRunEvent] {
        try await withThrowingTaskGroup(of: [CodexRunEvent].self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout)
                collector.cancel()
                throw CodexControlFixtureError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }
}

private enum CodexControlFixtureError: Error {
    case timeout
}
