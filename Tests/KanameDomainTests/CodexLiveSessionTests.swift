import Foundation
import Testing
@testable import KanameConnectivity
@testable import KanameDomain
@testable import KanameProtocol

struct CodexLiveSessionTests {
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
}
