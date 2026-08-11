import Foundation
import KanameDomain

/// The sandbox requested from Codex for a single Kaname turn. `workspaceWrite`
/// is limited to the selected worktree; network access remains an independent
/// per-conversation choice.
public enum CodexSandboxPolicy: String, Codable, Equatable, Sendable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    fileprivate func threadValue() -> String {
        switch self {
        case .readOnly: "read-only"
        case .workspaceWrite: "workspace-write"
        case .dangerFullAccess: "danger-full-access"
        }
    }

    fileprivate func turnValue(workspaceURL: URL, networkAccess: Bool) -> [String: Any] {
        switch self {
        case .readOnly:
            ["type": "readOnly", "networkAccess": networkAccess]
        case .workspaceWrite:
            [
                "type": "workspaceWrite",
                "networkAccess": networkAccess,
                "writableRoots": [workspaceURL.standardizedFileURL.path],
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            ]
        case .dangerFullAccess:
            ["type": "dangerFullAccess"]
        }
    }
}

public enum CodexApprovalPolicy: String, Codable, Equatable, Sendable {
    case untrusted
    case onRequest = "on-request"
    case never
}

public enum CodexApprovalsReviewer: String, Codable, Equatable, Sendable {
    case user
    case autoReview = "auto_review"
}

public enum CodexRuntimeAuthority: Equatable, Sendable {
    case workflowApprovalRequired
    case userConfiguredConversation
}

/// Process and workspace settings belong to the device, not to the durable
/// provider snapshot.  In particular, this type contains no credential value.
public struct CodexLiveSessionConfiguration: Sendable {
    public let instance: ProviderInstance
    public let executable: String
    public let workspaceURL: URL
    public let timeout: Duration
    public let codexHome: URL?
    public let persistentSessionDirectory: URL?
    public let launchArguments: [String]

    public init(
        instance: ProviderInstance,
        executable: String = "codex",
        workspaceURL: URL,
        timeout: Duration = .seconds(20),
        codexHome: URL? = nil,
        persistentSessionDirectory: URL? = nil,
        launchArguments: [String] = []
    ) {
        (self.instance, self.executable) = (instance, executable)
        self.workspaceURL = workspaceURL.standardizedFileURL
        (self.timeout, self.codexHome) = (timeout, codexHome)
        self.persistentSessionDirectory = persistentSessionDirectory?.standardizedFileURL
        self.launchArguments = launchArguments
    }
}

/// Explicit per-run selection. Legacy Phase 2 callers retain their pinned
/// defaults while ordinary conversations provide every value explicitly.
public struct CodexCodingRequest: Sendable {
    public static let maximumPromptBytes = 32 * 1024

    public let prompt: String
    public let model: String
    public let reasoningEffort: String
    public let sandbox: CodexSandboxPolicy
    public let networkAccess: Bool
    public let approvalPolicy: CodexApprovalPolicy
    public let approvalsReviewer: CodexApprovalsReviewer
    public let runtimeAuthority: CodexRuntimeAuthority

    public init(
        prompt: String,
        model: String = "gpt-5.6-terra",
        reasoningEffort: String = "xhigh",
        sandbox: CodexSandboxPolicy = .readOnly,
        networkAccess: Bool = false,
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        approvalsReviewer: CodexApprovalsReviewer = .user,
        runtimeAuthority: CodexRuntimeAuthority = .workflowApprovalRequired
    ) {
        (self.prompt, self.model, self.reasoningEffort, self.sandbox) =
            (prompt, model, reasoningEffort, sandbox)
        self.networkAccess = sandbox == .dangerFullAccess ? true : networkAccess
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.runtimeAuthority = runtimeAuthority
    }

    public static func conversation(
        prompt: String,
        model: String,
        reasoningEffort: String,
        runtimeMode: ConversationRuntimeMode,
        networkAccess: Bool
    ) -> Self {
        let settings: (CodexSandboxPolicy, CodexApprovalPolicy, CodexApprovalsReviewer)
        switch runtimeMode {
        case .approvalRequired:
            settings = (.readOnly, .untrusted, .user)
        case .autoAcceptEdits:
            settings = (.workspaceWrite, .onRequest, .user)
        case .auto:
            settings = (.workspaceWrite, .onRequest, .autoReview)
        case .fullAccess:
            settings = (.dangerFullAccess, .never, .user)
        }
        return Self(
            prompt: prompt,
            model: model,
            reasoningEffort: reasoningEffort,
            sandbox: settings.0,
            networkAccess: runtimeMode == .fullAccess ? true : networkAccess,
            approvalPolicy: settings.1,
            approvalsReviewer: settings.2,
            runtimeAuthority: .userConfiguredConversation
        )
    }
}

public enum CodexRunEventKind: String, Codable, Equatable, Sendable {
    case sessionStarted
    case runStarted
    case providerCompleted
    case runFailed
    case runInterrupted
    case messageDelta
    case itemStarted
    case itemCompleted
    case planUpdated
    case approvalRequested
    case approvalAccepted
    case approvalRejected
    case questionRequested
    case questionAnswered
    case toolActivity
    case diffUpdated
    case nativeProviderEvent
}

/// A bounded native observation. Its raw payload and text remain runtime-only;
/// the journal recorder persists only a redacted metadata envelope until raw
/// evidence sealing and retention policy are implemented.
public struct CodexRunEvent: Equatable, Sendable {
    public static let maximumRetainedPayloadBytes = 256 * 1024
    public static let maximumTextBytes = 64 * 1024

    public let kind: CodexRunEventKind
    public let nativeType: String
    public let threadID: String?
    public let turnID: String?
    public let approvalID: String?
    public let text: String?
    public let payload: Data?
    public let payloadWasTruncated: Bool

    public init(
        kind: CodexRunEventKind,
        nativeType: String,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalID: String? = nil,
        text: String? = nil,
        payload: Data? = nil,
        payloadWasTruncated: Bool = false
    ) {
        (self.kind, self.nativeType, self.threadID, self.turnID) =
            (kind, nativeType, threadID, turnID)
        (self.approvalID, self.text, self.payload, self.payloadWasTruncated) =
            (approvalID, text, payload, payloadWasTruncated)
    }
}

public struct CodexPlanEntry: Equatable, Sendable {
    public let step: String
    public let status: String

    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

public struct CodexPlanUpdate: Equatable, Sendable {
    public let explanation: String?
    public let entries: [CodexPlanEntry]

    public init(explanation: String?, entries: [CodexPlanEntry]) {
        self.explanation = explanation
        self.entries = entries
    }
}

public extension CodexRunEvent {
    var planUpdate: CodexPlanUpdate? {
        guard kind == .planUpdated,
              let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let rawEntries = object["plan"] as? [[String: Any]] else { return nil }
        let entries = rawEntries.prefix(128).compactMap { entry -> CodexPlanEntry? in
            guard let rawStep = entry["step"] as? String else { return nil }
            let step = rawStep.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !step.isEmpty else { return nil }
            return CodexPlanEntry(
                step: String(step.prefix(2_000)),
                status: (entry["status"] as? String) ?? "pending"
            )
        }
        guard !entries.isEmpty else { return nil }
        let explanation = (object["explanation"] as? String).flatMap { value -> String? in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(8_000))
        }
        return CodexPlanUpdate(explanation: explanation, entries: entries)
    }
}

public struct CodexLiveRun: Equatable, Sendable {
    public let nativeThreadID: String
    public let nativeTurnID: String
    public let model: String
    public let reasoningEffort: String

    public init(nativeThreadID: String, nativeTurnID: String, model: String, reasoningEffort: String) {
        (self.nativeThreadID, self.nativeTurnID, self.model, self.reasoningEffort) =
            (nativeThreadID, nativeTurnID, model, reasoningEffort)
    }
}

public enum CodexLiveSessionError: Error, Equatable, LocalizedError, Sendable {
    case wrongProvider
    case missingWorkspace
    case invalidRequest(String)
    case malformedResponse(String)
    case isolatedHomeUnavailable
    case mcpConfigurationPresent
    case unexpectedMCPActivity
    case alreadyStarted
    case notStarted

    public var errorDescription: String? {
        switch self {
        case .wrongProvider: "A Codex live session requires a Codex provider instance."
        case .missingWorkspace: "The selected coding workspace is not a directory."
        case let .invalidRequest(detail): "The Codex request is invalid: \(detail)"
        case let .malformedResponse(detail): "Codex returned an unreadable response: \(detail)"
        case .isolatedHomeUnavailable: "Kaname could not create a temporary Codex home with only an authentication reference."
        case .mcpConfigurationPresent: "Kaname requires a Codex profile with no configured MCP servers, so it did not start Codex."
        case .unexpectedMCPActivity: "Kaname stopped Codex after observing unexpected MCP activity."
        case .alreadyStarted: "This Codex live session has already started."
        case .notStarted: "This Codex live session has not started."
        }
    }
}

/// A single long-lived app-server session.  It transports native events but does
/// not make them product authority: the caller must later append accepted,
/// normalized events through the Rust policy/journal boundary.
public actor CodexLiveSession {
    private let configuration: CodexLiveSessionConfiguration
    private var connection: CodexAppServerConnection?
    private var messageTask: _Concurrency.Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<CodexRunEvent>.Continuation] = [:]
    private var activeRun: CodexLiveRun?
    private var nativeThreadID: String?
    private var activeSandbox: CodexSandboxPolicy?
    private var pendingQuestions: [String: (CodexAppServerRequestID, Data)] = [:]
    private var outputStreamOverflowed = false
    private var observedUnsafeMCPActivity = false
    private var ephemeralCodexHome: CodexEphemeralHome?

    public init(configuration: CodexLiveSessionConfiguration) {
        self.configuration = configuration
    }

    public func events() -> AsyncStream<CodexRunEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                _Concurrency.Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start(
        _ request: CodexCodingRequest,
        authorization: CodexWorkspaceAuthorization? = nil,
        resumingNativeThreadID: String? = nil
    ) async throws -> CodexLiveRun {
        guard configuration.instance.driver == .codex else {
            throw CodexLiveSessionError.wrongProvider
        }
        guard connection == nil else {
            throw CodexLiveSessionError.alreadyStarted
        }
        try Self.validate(request)
        try await validateAuthorization(request: request, authorization: authorization)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configuration.workspaceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CodexLiveSessionError.missingWorkspace
        }

        let isolatedHome: CodexEphemeralHome
        do {
            isolatedHome = try CodexEphemeralHome.create(
                sourceHome: configuration.codexHome,
                persistentDirectory: configuration.persistentSessionDirectory
            )
        } catch {
            throw CodexLiveSessionError.isolatedHomeUnavailable
        }
        ephemeralCodexHome = isolatedHome

        do {
            let launchArguments = try await CodexMCPIsolation.launchArguments(
                executable: configuration.executable,
                workingDirectory: configuration.workspaceURL,
                timeout: configuration.timeout,
                codexHome: isolatedHome.url,
                baseArguments: configuration.launchArguments
            )
            let processConfiguration = ProviderProbeConfiguration(
                instance: configuration.instance,
                executable: configuration.executable,
                workingDirectory: configuration.workspaceURL,
                timeout: configuration.timeout,
                codexHome: isolatedHome.url,
                codexLaunchArguments: launchArguments
            )
            let startedConnection = try await CodexAppServerConnection.start(configuration: processConfiguration)
            connection = startedConnection
            let messages = await startedConnection.messages()
            messageTask = _Concurrency.Task { [weak self] in
                for await message in messages {
                    await self?.receive(message)
                }
                if await startedConnection.didMessageStreamOverflow() {
                    await self?.failClosedForEventLoss()
                }
            }

            _ = try await Self.object(startedConnection.request(
                method: "initialize",
                parameters: [
                    "clientInfo": [
                        "name": "kaname",
                        "title": "Kaname",
                        "version": "phase-2",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
                notificationAfterSend: "initialized",
                timeout: configuration.timeout
            ))
            try await attestRuntimeIsolation(on: startedConnection)

            let threadMethod = resumingNativeThreadID == nil ? "thread/start" : "thread/resume"
            let threadResponse: [String: Any]
            if let resumingNativeThreadID {
                threadResponse = try await Self.object(startedConnection.request(
                    method: threadMethod,
                    parameters: Self.threadResumeParameters(
                        configuration: configuration,
                        request: request,
                        threadID: resumingNativeThreadID
                    ),
                    timeout: configuration.timeout
                ))
            } else {
                threadResponse = try await Self.object(startedConnection.request(
                    method: threadMethod,
                    parameters: Self.threadStartParameters(configuration: configuration, request: request),
                    timeout: configuration.timeout
                ))
            }
            guard let thread = threadResponse["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String,
                  !threadID.isEmpty
            else {
                throw CodexLiveSessionError.malformedResponse("\(threadMethod) did not return thread.id")
            }
            nativeThreadID = threadID
            try await attestRuntimeIsolation(on: startedConnection)
            emit(CodexRunEvent.fromResponse(
                kind: .sessionStarted,
                nativeType: threadMethod,
                data: try JSONSerialization.data(withJSONObject: threadResponse),
                fallbackThreadID: threadID
            ))

            return try await beginTurn(
                request,
                authorization: authorization,
                connection: startedConnection,
                threadID: threadID
            )
        } catch {
            let mcpIsolationWasViolated = observedUnsafeMCPActivity
            await close()
            if mcpIsolationWasViolated {
                throw CodexLiveSessionError.unexpectedMCPActivity
            }
            throw error
        }
    }

    public func continueRun(
        _ request: CodexCodingRequest,
        authorization: CodexWorkspaceAuthorization? = nil
    ) async throws -> CodexLiveRun {
        guard let connection, let threadID = nativeThreadID, activeRun == nil else {
            throw CodexLiveSessionError.notStarted
        }
        try Self.validate(request)
        try await validateAuthorization(request: request, authorization: authorization)
        try requireNoUnsafeMCPActivity()
        return try await beginTurn(
            request,
            authorization: authorization,
            connection: connection,
            threadID: threadID
        )
    }

    public func answerQuestion(
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        guard let connection,
              let (id, parameters) = pendingQuestions.removeValue(forKey: requestID) else {
            throw CodexLiveSessionError.notStarted
        }
        let object: [String: Any]? = CodexRunEvent.object(from: parameters)
        let questions: [[String: Any]] = object?["questions"] as? [[String: Any]] ?? []
        guard !questions.contains(where: { $0["isSecret"] as? Bool == true }),
              !answers.isEmpty,
              answers.values.flatMap({ $0 }).allSatisfy({
                  $0.lengthOfBytes(using: .utf8) <= 4_096
              }) else {
            try await connection.reject(id: id, method: "item/tool/requestUserInput")
            throw CodexLiveSessionError.invalidRequest("question answers must be non-secret and bounded")
        }
        try await connection.respond(
            id: id,
            result: ["answers": answers.mapValues { ["answers": $0] }]
        )
        emit(CodexRunEvent(
            kind: .questionAnswered,
            nativeType: "item/tool/requestUserInput/answered",
            approvalID: requestID,
            text: "Answered \(answers.count) provider question(s) without persisting answer text."
        ))
    }

    public func interrupt() async throws {
        guard let connection, let activeRun else {
            throw CodexLiveSessionError.notStarted
        }
        _ = try await connection.request(
            method: "turn/interrupt",
            parameters: [
                "threadId": activeRun.nativeThreadID,
                "turnId": activeRun.nativeTurnID,
            ],
            timeout: configuration.timeout
        )
    }

    public func close() async {
        messageTask?.cancel()
        messageTask = nil
        if let connection {
            await connection.shutdown()
        }
        connection = nil
        activeRun = nil
        nativeThreadID = nil
        activeSandbox = nil
        pendingQuestions.removeAll()
        let isolatedHome = ephemeralCodexHome
        ephemeralCodexHome = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        try? isolatedHome?.cleanup()
    }

    static func threadStartParameters(
        configuration: CodexLiveSessionConfiguration,
        request: CodexCodingRequest
    ) -> [String: Any] {
        [
            "cwd": configuration.workspaceURL.path,
            "model": request.model,
            "approvalPolicy": request.approvalPolicy.rawValue,
            "approvalsReviewer": request.approvalsReviewer.rawValue,
            "sandbox": request.sandbox.threadValue(),
            "ephemeral": configuration.persistentSessionDirectory == nil,
            "threadSource": "kaname",
        ]
    }

    static func threadResumeParameters(
        configuration: CodexLiveSessionConfiguration,
        request: CodexCodingRequest,
        threadID: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "cwd": configuration.workspaceURL.path,
            "model": request.model,
            "approvalPolicy": request.approvalPolicy.rawValue,
            "approvalsReviewer": request.approvalsReviewer.rawValue,
            "sandbox": request.sandbox.threadValue(),
            "excludeTurns": true,
        ]
    }

    static func turnStartParameters(
        configuration: CodexLiveSessionConfiguration,
        request: CodexCodingRequest,
        threadID: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "input": [["type": "text", "text": request.prompt]],
            "model": request.model,
            "effort": request.reasoningEffort,
            "approvalPolicy": request.approvalPolicy.rawValue,
            "approvalsReviewer": request.approvalsReviewer.rawValue,
            "sandboxPolicy": request.sandbox.turnValue(
                workspaceURL: configuration.workspaceURL,
                networkAccess: request.networkAccess
            ),
        ]
    }

    private static func validate(_ request: CodexCodingRequest) throws {
        guard !request.prompt.isEmpty,
              request.prompt.lengthOfBytes(using: .utf8) <= CodexCodingRequest.maximumPromptBytes
        else {
            throw CodexLiveSessionError.invalidRequest("prompt must be 1–\(CodexCodingRequest.maximumPromptBytes) UTF-8 bytes")
        }
        let identifierPattern = "^[A-Za-z0-9._-]{1,128}$"
        guard request.model.range(of: identifierPattern, options: .regularExpression) != nil,
              request.reasoningEffort.range(of: identifierPattern, options: .regularExpression) != nil
        else {
            throw CodexLiveSessionError.invalidRequest("model and reasoning effort must be bounded identifiers")
        }
    }

    private func validateAuthorization(
        request: CodexCodingRequest,
        authorization: CodexWorkspaceAuthorization?
    ) async throws {
        guard request.sandbox != .readOnly else { return }
        if request.runtimeAuthority == .userConfiguredConversation { return }
        guard request.sandbox == .workspaceWrite else {
            throw CodexLiveSessionError.invalidRequest(
                "full-access turns require an explicit user-configured conversation mode"
            )
        }
        guard let authorization,
              authorization.validates(request: request, workspaceURL: configuration.workspaceURL) else {
            throw CodexLiveSessionError.invalidRequest(
                "workspace-write turns require a current signed local-control approval for this exact prompt and worktree"
            )
        }
        let currentRevision = try await CodingWorkspaceInspector.currentRevision(
            workspaceURL: configuration.workspaceURL
        )
        guard currentRevision == authorization.targetRevision else {
            throw CodexLiveSessionError.invalidRequest(
                "the approved worktree revision changed before dispatch"
            )
        }
    }

    private func beginTurn(
        _ request: CodexCodingRequest,
        authorization: CodexWorkspaceAuthorization?,
        connection: CodexAppServerConnection,
        threadID: String
    ) async throws -> CodexLiveRun {
        try await validateAuthorization(request: request, authorization: authorization)
        let turnResponse = try await Self.object(connection.request(
            method: "turn/start",
            parameters: Self.turnStartParameters(
                configuration: configuration,
                request: request,
                threadID: threadID
            ),
            timeout: configuration.timeout
        ))
        guard let turn = turnResponse["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else {
            throw CodexLiveSessionError.malformedResponse("turn/start did not return turn.id")
        }
        try requireNoUnsafeMCPActivity()
        let run = CodexLiveRun(
            nativeThreadID: threadID,
            nativeTurnID: turnID,
            model: request.model,
            reasoningEffort: request.reasoningEffort
        )
        activeRun = run
        activeSandbox = request.sandbox
        emit(CodexRunEvent.fromResponse(
            kind: .runStarted,
            nativeType: "turn/start",
            data: try JSONSerialization.data(withJSONObject: turnResponse),
            fallbackThreadID: threadID,
            fallbackTurnID: turnID
        ))
        return run
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let object = decoded as? [String: Any] {
            return object
        }
        throw CodexLiveSessionError.malformedResponse("expected an object")
    }

    private func receive(_ message: CodexAppServerIncomingMessage) async {
        if let connection, await connection.didMessageStreamOverflow() {
            await failClosedForEventLoss()
            return
        }
        var event = CodexRunEvent.from(message)
        if event.indicatesUnsafeMCPStartup {
            observedUnsafeMCPActivity = true
            emit(CodexRunEvent(
                kind: .runFailed,
                nativeType: "kaname/unexpected-mcp-activity",
                threadID: event.threadID,
                turnID: event.turnID,
                text: "Kaname stopped the run after observing unexpected MCP activity."
            ))
            await close()
            return
        }
        if case let .serverRequest(id, _, _) = message,
           event.kind == .approvalRequested || event.kind == .questionRequested {
            event = event.withApprovalID(id.stableValue)
        }
        if event.kind == .providerCompleted || event.kind == .runFailed || event.kind == .runInterrupted {
            activeRun = nil
            activeSandbox = nil
        }
        emit(event)
        guard case let .serverRequest(id, method, _) = message,
              let connection
        else {
            return
        }

        // The Phase 2 runner owns neither persistent approval state nor a UI
        // decision.  Do not leave Codex blocked, but never convert a provider
        // request into a write grant.  A later journal-backed approval flow can
        // replace this narrow decline response.
        if event.kind == .questionRequested {
            pendingQuestions[id.stableValue] = (id, event.payload ?? Data())
        } else if event.kind == .approvalRequested {
            do {
                if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                    try await connection.respond(id: id, result: ["decision": "decline"])
                } else {
                    try await connection.reject(id: id, method: method)
                }
            } catch {
                emit(CodexRunEvent(
                    kind: .runFailed,
                    nativeType: "\(method)/declineFailed",
                    threadID: event.threadID,
                    turnID: event.turnID,
                    approvalID: event.approvalID,
                    text: "Kaname could not deny this provider approval, so the run stopped without granting it."
                ))
                await close()
                return
            }
            emit(CodexRunEvent(
                kind: .approvalRejected,
                nativeType: "\(method)/declined",
                threadID: event.threadID,
                turnID: event.turnID,
                approvalID: event.approvalID,
                text: "Kaname declined this provider approval because no durable approval decision is available."
            ))
        } else {
            do {
                try await connection.reject(id: id, method: method)
            } catch {
                emit(CodexRunEvent(
                    kind: .runFailed,
                    nativeType: "\(method)/rejectFailed",
                    threadID: event.threadID,
                    turnID: event.turnID,
                    text: "Kaname could not reject an unsupported provider request, so the run stopped safely."
                ))
                await close()
            }
        }
    }

    private func emit(_ event: CodexRunEvent) {
        guard !outputStreamOverflowed else { return }
        var dropped = false
        for continuation in continuations.values {
            if case .dropped = continuation.yield(event) {
                dropped = true
            }
        }
        guard dropped else { return }

        outputStreamOverflowed = true
        let failure = CodexRunEvent(
            kind: .runFailed,
            nativeType: "kaname/provider-event-buffer-overflow",
            text: "Kaname stopped the run because a bounded provider-event buffer overflowed."
        )
        for continuation in continuations.values {
            _ = continuation.yield(failure)
            continuation.finish()
        }
        continuations.removeAll()
        _Concurrency.Task { [weak self] in await self?.close() }
    }

    private func requireNoUnsafeMCPActivity() throws {
        guard !observedUnsafeMCPActivity else {
            throw CodexLiveSessionError.unexpectedMCPActivity
        }
    }

    private func attestRuntimeIsolation(on connection: CodexAppServerConnection) async throws {
        try await _Concurrency.Task.sleep(for: CodexMCPIsolation.attestationObservationWindow)
        if await connection.didObserveUnsafeMCPStartup() {
            observedUnsafeMCPActivity = true
        }
        guard !(await connection.didMessageStreamOverflow()) else {
            throw CodexLiveSessionError.malformedResponse(
                "the provider event stream overflowed during MCP runtime attestation"
            )
        }
        try requireNoUnsafeMCPActivity()
    }

    private func failClosedForEventLoss() async {
        emit(CodexRunEvent(
            kind: .runFailed,
            nativeType: "kaname/provider-event-buffer-overflow",
            text: "Kaname stopped the run because a bounded provider-event buffer overflowed."
        ))
        await close()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

extension CodexRunEvent {
    var indicatesUnsafeMCPStartup: Bool {
        guard let payload else { return false }
        return CodexMCPIsolation.indicatesUnsafeStartup(method: nativeType, parameters: payload)
    }

    func withApprovalID(_ approvalID: String) -> CodexRunEvent {
        CodexRunEvent(
            kind: kind,
            nativeType: nativeType,
            threadID: threadID,
            turnID: turnID,
            approvalID: approvalID,
            text: text,
            payload: payload,
            payloadWasTruncated: payloadWasTruncated
        )
    }

    static func from(_ message: CodexAppServerIncomingMessage) -> CodexRunEvent {
        switch message {
        case let .notification(method, parameters):
            let object = Self.object(from: parameters)
            let turn = object?["turn"] as? [String: Any]
            let kind: CodexRunEventKind
            switch method {
            case "thread/started": kind = .sessionStarted
            case "turn/started": kind = .runStarted
            case "turn/completed":
                switch turn?["status"] as? String {
                case "completed": kind = .providerCompleted
                case "failed": kind = .runFailed
                case "interrupted", "cancelled": kind = .runInterrupted
                default: kind = .runFailed
                }
            case "item/agentMessage/delta": kind = .messageDelta
            case "item/started", "item/completed":
                switch (object?["item"] as? [String: Any])?["type"] as? String {
                case "plan": kind = .planUpdated
                case "commandExecution", "dynamicToolCall", "collabToolCall", "mcpToolCall", "webSearch":
                    kind = .toolActivity
                case "fileChange": kind = .diffUpdated
                default: kind = method == "item/started" ? .itemStarted : .itemCompleted
                }
            case "turn/plan/updated": kind = .planUpdated
            case "turn/diff/updated": kind = .diffUpdated
            default: kind = .nativeProviderEvent
            }
            return Self.bounded(
                kind: kind,
                nativeType: method,
                data: parameters,
                object: object,
                fallbackThreadID: nil,
                fallbackTurnID: nil
            )
        case let .serverRequest(_, method, parameters):
            return Self.bounded(
                kind: method.contains("requestApproval")
                    ? .approvalRequested
                    : (method == "item/tool/requestUserInput" ? .questionRequested : .nativeProviderEvent),
                nativeType: method,
                data: parameters,
                object: Self.object(from: parameters),
                fallbackThreadID: nil,
                fallbackTurnID: nil
            )
        case let .processExited(status, standardError):
            return CodexRunEvent(
                kind: .runFailed,
                nativeType: "codex-app-server/exited",
                text: standardError.isEmpty ? "Codex app-server exited with status \(status)." : standardError,
                payload: nil
            )
        }
    }

    static func fromResponse(
        kind: CodexRunEventKind,
        nativeType: String,
        data: Data,
        fallbackThreadID: String? = nil,
        fallbackTurnID: String? = nil
    ) -> CodexRunEvent {
        bounded(
            kind: kind,
            nativeType: nativeType,
            data: data,
            object: object(from: data),
            fallbackThreadID: fallbackThreadID,
            fallbackTurnID: fallbackTurnID
        )
    }

    private static func bounded(
        kind: CodexRunEventKind,
        nativeType: String,
        data: Data,
        object: [String: Any]?,
        fallbackThreadID: String?,
        fallbackTurnID: String?
    ) -> CodexRunEvent {
        let turn = object?["turn"] as? [String: Any]
        let item = object?["item"] as? [String: Any]
        let thread = object?["thread"] as? [String: Any]
        let text = string(
            object?["delta"] ?? object?["diff"] ?? item?["text"] ?? turn?["error"] ?? object?["error"]
        )
        let boundedText = text.flatMap { text in
            String(data: Data(text.utf8.prefix(maximumTextBytes)), encoding: .utf8)
        }
        return CodexRunEvent(
            kind: kind,
            nativeType: nativeType,
            threadID: object?["threadId"] as? String ?? thread?["id"] as? String ?? fallbackThreadID,
            turnID: object?["turnId"] as? String ?? turn?["id"] as? String ?? fallbackTurnID,
            text: boundedText,
            payload: data.count <= maximumRetainedPayloadBytes ? data : nil,
            payloadWasTruncated: data.count > maximumRetainedPayloadBytes
        )
    }

    fileprivate static func object(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

}
