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
    /// When true and an inbox `coding.preview_mcp_grant` was validated by the
    /// caller, Kaname injects only the curated `kaname-preview` MCP bridge.
    public let curatedPreviewMCPGranted: Bool

    public init(
        instance: ProviderInstance,
        executable: String = "codex",
        workspaceURL: URL,
        timeout: Duration = .seconds(20),
        codexHome: URL? = nil,
        persistentSessionDirectory: URL? = nil,
        launchArguments: [String] = [],
        curatedPreviewMCPGranted: Bool = false
    ) {
        (self.instance, self.executable) = (instance, executable)
        self.workspaceURL = workspaceURL.standardizedFileURL
        (self.timeout, self.codexHome) = (timeout, codexHome)
        self.persistentSessionDirectory = persistentSessionDirectory?.standardizedFileURL
        self.launchArguments = launchArguments
        self.curatedPreviewMCPGranted = curatedPreviewMCPGranted
            && CodexMCPIsolation.allowsCuratedPreviewMCP(hasPreviewGrant: curatedPreviewMCPGranted)
    }
}

/// Explicit per-run selection. Legacy Phase 2 callers retain their pinned
/// defaults while ordinary conversations provide every value explicitly.
public struct CodexCodingRequest: Sendable {
    public static let maximumPromptBytes = 32 * 1024
    public static let maximumOutputSchemaBytes = 16 * 1024

    public let prompt: String
    public let imagePaths: [String]
    public let outputJSONSchema: String?
    public let model: String
    public let reasoningEffort: String
    public let sandbox: CodexSandboxPolicy
    public let networkAccess: Bool
    public let approvalPolicy: CodexApprovalPolicy
    public let approvalsReviewer: CodexApprovalsReviewer
    public let runtimeAuthority: CodexRuntimeAuthority

    public init(
        prompt: String,
        imagePaths: [String] = [],
        outputJSONSchema: String? = nil,
        model: String = "gpt-5.6-terra",
        reasoningEffort: String = "xhigh",
        sandbox: CodexSandboxPolicy = .readOnly,
        networkAccess: Bool = false,
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        approvalsReviewer: CodexApprovalsReviewer = .user,
        runtimeAuthority: CodexRuntimeAuthority = .workflowApprovalRequired
    ) {
        self.prompt = prompt
        self.imagePaths = imagePaths
        self.outputJSONSchema = outputJSONSchema
        (self.model, self.reasoningEffort, self.sandbox) = (model, reasoningEffort, sandbox)
        self.networkAccess = sandbox == .dangerFullAccess ? true : networkAccess
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.runtimeAuthority = runtimeAuthority
    }

    public static func conversation(
        prompt: String,
        imagePaths: [String] = [],
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
            imagePaths: imagePaths,
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
    public let toolObservation: ProviderToolObservation?
    public let agentActivity: ProviderAgentActivity?
    public let text: String?
    public let payload: Data?
    public let payloadWasTruncated: Bool

    public init(
        kind: CodexRunEventKind,
        nativeType: String,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalID: String? = nil,
        toolObservation: ProviderToolObservation? = nil,
        agentActivity: ProviderAgentActivity? = nil,
        text: String? = nil,
        payload: Data? = nil,
        payloadWasTruncated: Bool = false
    ) {
        (self.kind, self.nativeType, self.threadID, self.turnID) =
            (kind, nativeType, threadID, turnID)
        (self.approvalID, self.toolObservation, self.agentActivity) =
            (approvalID, toolObservation, agentActivity)
        (self.text, self.payload, self.payloadWasTruncated) =
            (text, payload, payloadWasTruncated)
    }
}

public enum CodexRunEventRouteError: Error, Equatable, Sendable {
    case pendingRunAlreadyRegistered
    case runAlreadyRegistered
    case unknownRun
    case nativeTurnAlreadyBound
}

public struct CodexRunControlTarget: Equatable, Sendable {
    public let nativeThreadID: String
    public let nativeTurnID: String

    public init(nativeThreadID: String, nativeTurnID: String) {
        self.nativeThreadID = nativeThreadID
        self.nativeTurnID = nativeTurnID
    }
}

/// Routes one long-lived provider session back to Kaname-owned run identity.
/// Completed turns remain registered because Codex may attribute a child
/// completion to its spawning turn after that turn has already completed.
public struct CodexRunEventRouteTable: Sendable {
    private var registeredRunIDs: Set<String> = []
    private var pendingRunID: String?
    private var runIDByNativeTurnID: [String: String] = [:]
    private var controlTargetsByRunID: [String: CodexRunControlTarget] = [:]
    private var agentLedgersByRunID: [String: ProviderAgentActivityLedger] = [:]

    public init() {}

    public var hasOutstandingAgentActivity: Bool {
        agentLedgersByRunID.values.contains(where: \.hasOutstandingActivity)
    }

    public var runIDsWithOutstandingAgentActivity: [String] {
        agentLedgersByRunID.compactMap { runID, ledger in
            ledger.hasOutstandingActivity ? runID : nil
        }.sorted()
    }

    public func outstandingAgentActivities(for runID: String) -> [ProviderAgentActivity] {
        agentLedgersByRunID[runID]?.outstandingActivities ?? []
    }

    public func agentSettlementActivities(
        for runID: String,
        as terminalActivity: ProviderAgentActivityKind
    ) -> [ProviderAgentActivity] {
        agentLedgersByRunID[runID]?.settlementActivities(as: terminalActivity) ?? []
    }

    public func controlTarget(for runID: String) -> CodexRunControlTarget? {
        controlTargetsByRunID[runID]
    }

    public mutating func register(runID: String) throws {
        guard pendingRunID == nil else { throw CodexRunEventRouteError.pendingRunAlreadyRegistered }
        guard registeredRunIDs.insert(runID).inserted else { throw CodexRunEventRouteError.runAlreadyRegistered }
        pendingRunID = runID
    }

    public mutating func bind(runID: String, nativeTurnID: String) throws {
        guard registeredRunIDs.contains(runID) else { throw CodexRunEventRouteError.unknownRun }
        if let existing = runIDByNativeTurnID[nativeTurnID], existing != runID {
            throw CodexRunEventRouteError.nativeTurnAlreadyBound
        }
        runIDByNativeTurnID[nativeTurnID] = runID
    }

    public mutating func bind(
        runID: String,
        nativeThreadID: String,
        nativeTurnID: String
    ) throws {
        let target = CodexRunControlTarget(
            nativeThreadID: nativeThreadID,
            nativeTurnID: nativeTurnID
        )
        if let existing = controlTargetsByRunID[runID], existing != target {
            throw CodexRunEventRouteError.nativeTurnAlreadyBound
        }
        try bind(runID: runID, nativeTurnID: nativeTurnID)
        controlTargetsByRunID[runID] = target
    }

    public mutating func route(_ event: CodexRunEvent) throws -> String? {
        if let nativeTurnID = event.turnID,
           let runID = runIDByNativeTurnID[nativeTurnID] {
            return runID
        }
        guard let runID = pendingRunID else { return nil }
        if let nativeTurnID = event.turnID {
            try bind(runID: runID, nativeTurnID: nativeTurnID)
        }
        return runID
    }

    public mutating func observe(_ event: CodexRunEvent, routedTo runID: String) {
        if let activity = event.agentActivity {
            var ledger = agentLedgersByRunID[runID] ?? ProviderAgentActivityLedger()
            ledger.observe(activity)
            if ledger.hasOutstandingActivity {
                agentLedgersByRunID[runID] = ledger
            } else {
                agentLedgersByRunID.removeValue(forKey: runID)
            }
        }
        switch event.kind {
        case .providerCompleted:
            if pendingRunID == runID { pendingRunID = nil }
        case .runFailed, .runInterrupted:
            if pendingRunID == runID { pendingRunID = nil }
        case .sessionStarted, .runStarted, .messageDelta, .itemStarted, .itemCompleted,
             .planUpdated, .approvalRequested, .approvalAccepted, .approvalRejected,
             .questionRequested, .questionAnswered, .toolActivity, .diffUpdated,
             .nativeProviderEvent:
            break
        }
    }

    public mutating func cancel(runID: String) {
        if pendingRunID == runID { pendingRunID = nil }
        registeredRunIDs.remove(runID)
        controlTargetsByRunID.removeValue(forKey: runID)
        agentLedgersByRunID.removeValue(forKey: runID)
        runIDByNativeTurnID = runIDByNativeTurnID.filter { $0.value != runID }
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
    /// Full Markdown plan body when the provider supplied one (Claude `ExitPlanMode`).
    var planText: String? {
        guard kind == .planUpdated,
              let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let text = object["planText"] as? String else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(64 * 1_024))
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

/// Collapses contiguous provider deltas before they enter the bounded public
/// stream. The original JSON payloads remain available as bounded JSON Lines
/// evidence, while ordinary consumers receive substantially fewer events.
struct CodexProviderEventCoalescer {
    private static let messageChunkBytes = 4 * 1_024
    private static let messageChunkEvents = 32

    private struct Pending {
        var event: CodexRunEvent
        var eventCount: Int
        let key: String
    }

    private var pending: Pending?

    mutating func ingest(_ event: CodexRunEvent) -> [CodexRunEvent] {
        guard let key = Self.coalescingKey(for: event) else {
            return flush() + [event]
        }
        guard var current = pending else {
            pending = Pending(event: event, eventCount: 1, key: key)
            return []
        }
        guard current.key == key else {
            let flushed = flush()
            pending = Pending(event: event, eventCount: 1, key: key)
            return flushed
        }
        guard let combined = Self.combine(current.event, event) else {
            let flushed = flush()
            pending = Pending(event: event, eventCount: 1, key: key)
            return flushed
        }
        current.event = combined
        current.eventCount += 1
        pending = current

        let textBytes = combined.text?.utf8.count ?? 0
        if event.kind == .messageDelta,
           current.eventCount >= Self.messageChunkEvents || textBytes >= Self.messageChunkBytes {
            return flush()
        }
        return []
    }

    mutating func flush() -> [CodexRunEvent] {
        guard let pending else { return [] }
        self.pending = nil
        return [pending.event]
    }

    private static func coalescingKey(for event: CodexRunEvent) -> String? {
        let isDelta = event.kind == .messageDelta
            || (event.kind == .nativeProviderEvent
                && event.nativeType.localizedCaseInsensitiveContains("delta"))
        guard isDelta else { return nil }
        let payloadObject = event.payload.flatMap { CodexRunEvent.object(from: $0) }
        let itemID = payloadObject?["itemId"] as? String ?? ""
        return [
            event.kind.rawValue,
            event.nativeType,
            event.threadID ?? "",
            event.turnID ?? "",
            itemID,
        ].joined(separator: "\u{1f}")
    }

    private static func combine(_ left: CodexRunEvent, _ right: CodexRunEvent) -> CodexRunEvent? {
        let leftText = left.text ?? ""
        let rightText = right.text ?? ""
        guard leftText.utf8.count + rightText.utf8.count <= CodexRunEvent.maximumTextBytes else {
            return nil
        }
        let payload = combinedPayload(left.payload, right.payload)
        return CodexRunEvent(
            kind: left.kind,
            nativeType: left.nativeType,
            threadID: left.threadID,
            turnID: left.turnID,
            approvalID: left.approvalID,
            toolObservation: left.toolObservation,
            agentActivity: left.agentActivity,
            text: leftText + rightText,
            payload: payload.data,
            payloadWasTruncated: left.payloadWasTruncated || right.payloadWasTruncated || payload.wasTruncated
        )
    }

    private static func combinedPayload(_ left: Data?, _ right: Data?) -> (data: Data?, wasTruncated: Bool) {
        guard left != nil || right != nil else { return (nil, false) }
        var result = Data()
        var wasTruncated = false
        for payload in [left, right].compactMap({ $0 }) {
            let separatorBytes = result.isEmpty ? 0 : 1
            guard result.count + separatorBytes + payload.count <= CodexRunEvent.maximumRetainedPayloadBytes else {
                wasTruncated = true
                continue
            }
            if !result.isEmpty { result.append(0x0a) }
            result.append(payload)
        }
        return (result.isEmpty ? nil : result, wasTruncated)
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
    private var eventCoalescer = CodexProviderEventCoalescer()
    private var outputStreamOverflowed = false
    private var observedUnsafeMCPActivity = false
    private var ephemeralCodexHome: CodexEphemeralHome?
    private var previewMCPServer: KanamePreviewMCPHTTPServer?
    private var allowedMCPServerNames: Set<String> = []

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
            var curatedBinding: KanamePreviewMCPHTTPServer.Binding?
            if configuration.curatedPreviewMCPGranted {
                let server = KanamePreviewMCPHTTPServer()
                curatedBinding = try await server.start()
                previewMCPServer = server
                allowedMCPServerNames = [CodingPreviewMCPGrant.curatedServerName]
            }
            let launchArguments = try await CodexMCPIsolation.launchArguments(
                executable: configuration.executable,
                workingDirectory: configuration.workspaceURL,
                timeout: configuration.timeout,
                codexHome: isolatedHome.url,
                baseArguments: configuration.launchArguments,
                curatedPreview: curatedBinding
            )
            let processConfiguration = ProviderProbeConfiguration(
                instance: configuration.instance,
                executable: configuration.executable,
                workingDirectory: configuration.workspaceURL,
                timeout: configuration.timeout,
                codexHome: isolatedHome.url,
                codexLaunchArguments: launchArguments,
                environmentOverrides: CodexMCPIsolation.curatedPreviewEnvironment(
                    home: isolatedHome.url,
                    binding: curatedBinding
                ),
                allowedMCPServerNames: allowedMCPServerNames
            )
            let startedConnection = try await CodexAppServerConnection.start(configuration: processConfiguration)
            connection = startedConnection
            let messages = await startedConnection.messages()
            messageTask = _Concurrency.Task { [weak self] in
                for await message in messages {
                    await self?.receive(message)
                }
                await self?.messageStreamEnded(startedConnection)
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
        guard let activeRun else {
            throw CodexLiveSessionError.notStarted
        }
        try await interrupt(CodexRunControlTarget(
            nativeThreadID: activeRun.nativeThreadID,
            nativeTurnID: activeRun.nativeTurnID
        ))
    }

    public func interrupt(_ target: CodexRunControlTarget) async throws {
        guard let connection, nativeThreadID == target.nativeThreadID else {
            throw CodexLiveSessionError.notStarted
        }
        _ = try await connection.request(
            method: "turn/interrupt",
            parameters: [
                "threadId": target.nativeThreadID,
                "turnId": target.nativeTurnID,
            ],
            timeout: configuration.timeout
        )
    }

    public func close() async {
        let task = messageTask
        messageTask = nil
        task?.cancel()
        let closingConnection = connection
        connection = nil
        if let closingConnection {
            await closingConnection.shutdown()
        }
        activeRun = nil
        nativeThreadID = nil
        activeSandbox = nil
        pendingQuestions.removeAll()
        for event in eventCoalescer.flush() {
            deliver(event)
        }
        let isolatedHome = ephemeralCodexHome
        ephemeralCodexHome = nil
        let previewServer = previewMCPServer
        previewMCPServer = nil
        allowedMCPServerNames = []
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        try? isolatedHome?.cleanup()
        await previewServer?.stop()
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
        var input: [[String: Any]] = []
        if !request.prompt.isEmpty {
            input.append(["type": "text", "text": request.prompt])
        }
        input.append(contentsOf: request.imagePaths.map { ["type": "localImage", "path": $0] })
        var parameters: [String: Any] = [
            "threadId": threadID,
            "input": input,
            "model": request.model,
            "effort": request.reasoningEffort,
            "approvalPolicy": request.approvalPolicy.rawValue,
            "approvalsReviewer": request.approvalsReviewer.rawValue,
            "sandboxPolicy": request.sandbox.turnValue(
                workspaceURL: configuration.workspaceURL,
                networkAccess: request.networkAccess
            ),
        ]
        if let outputSchema = outputSchemaObject(from: request.outputJSONSchema) {
            parameters["outputSchema"] = outputSchema
        }
        return parameters
    }

    private static func validate(_ request: CodexCodingRequest) throws {
        guard (!request.prompt.isEmpty || !request.imagePaths.isEmpty),
              request.prompt.lengthOfBytes(using: .utf8) <= CodexCodingRequest.maximumPromptBytes,
              request.imagePaths.count <= ConversationImageAttachment.maximumCountPerMessage,
              request.imagePaths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\u{0}") })
        else {
            throw CodexLiveSessionError.invalidRequest("a bounded prompt or up to eight local images is required")
        }
        if let outputJSONSchema = request.outputJSONSchema {
            guard outputJSONSchema.lengthOfBytes(using: .utf8) <= CodexCodingRequest.maximumOutputSchemaBytes,
                  outputSchemaObject(from: outputJSONSchema) != nil else {
                throw CodexLiveSessionError.invalidRequest("output JSON schema must be a bounded JSON object")
            }
        }
        let identifierPattern = "^[A-Za-z0-9._-]{1,128}$"
        guard request.model.range(of: identifierPattern, options: .regularExpression) != nil,
              request.reasoningEffort.range(of: identifierPattern, options: .regularExpression) != nil
        else {
            throw CodexLiveSessionError.invalidRequest("model and reasoning effort must be bounded identifiers")
        }
    }

    private static func outputSchemaObject(from schema: String?) -> [String: Any]? {
        guard let schema,
              let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
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
        for event in eventCoalescer.ingest(event) {
            deliver(event)
        }
    }

    private func deliver(_ event: CodexRunEvent) {
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

    private func messageStreamEnded(_ endedConnection: CodexAppServerConnection) async {
        guard connection === endedConnection else { return }
        if await endedConnection.didMessageStreamOverflow() {
            await failClosedForEventLoss()
        } else {
            await close()
        }
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
            toolObservation: toolObservation,
            agentActivity: agentActivity,
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
                case "commandExecution", "dynamicToolCall", "collabToolCall", "mcpToolCall", "webSearch",
                     "imageGeneration", "imageView", "subAgentActivity":
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
        let activity = structuredActivity(nativeType: nativeType, object: object, item: item)
        return CodexRunEvent(
            kind: kind,
            nativeType: nativeType,
            threadID: object?["threadId"] as? String ?? thread?["id"] as? String ?? fallbackThreadID,
            turnID: object?["turnId"] as? String ?? turn?["id"] as? String ?? fallbackTurnID,
            toolObservation: activity.tool,
            agentActivity: activity.agent,
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

    private static func structuredActivity(
        nativeType: String,
        object: [String: Any]?,
        item: [String: Any]?
    ) -> (tool: ProviderToolObservation?, agent: ProviderAgentActivity?) {
        let itemType = item?["type"] as? String
        let callID = item?["id"] as? String ?? object?["itemId"] as? String
        let toolKind: ProviderToolKind? = switch itemType {
        case "commandExecution": .commandExecution
        case "fileChange": .fileChange
        case "mcpToolCall": .mcp
        case "dynamicToolCall": .dynamic
        case "collabToolCall": .collaboration
        case "webSearch": .webSearch
        case "imageGeneration": .imageGeneration
        case "imageView": .imageView
        default:
            if nativeType.hasPrefix("item/commandExecution/") { .commandExecution }
            else if nativeType.hasPrefix("item/fileChange/") { .fileChange }
            else if nativeType.hasPrefix("item/mcpToolCall/") { .mcp }
            else if nativeType.hasPrefix("item/dynamicToolCall/") { .dynamic }
            else if nativeType.hasPrefix("item/collabToolCall/") { .collaboration }
            else { nil }
        }
        let tool = callID.flatMap { callID in
            toolKind.map { kind in
                ProviderToolObservation(
                    callID: callID,
                    kind: kind,
                    state: toolState(item?["status"] as? String, nativeType: nativeType),
                    name: toolName(kind: kind, item: item)
                )
            }
        }

        if nativeType == "item/completed",
           itemType == "subAgentActivity",
           let agentID = item?["agentThreadId"] as? String,
           let rawActivity = item?["kind"] as? String,
           let activity = agentActivity(rawActivity) {
            return (
                tool,
                ProviderAgentActivity(
                    agentID: agentID,
                    activity: activity,
                    agentPath: item?["agentPath"] as? String,
                    taskType: "subAgentActivity",
                    sourceToolCallID: callID
                )
            )
        }

        if itemType == "collabToolCall",
           normalizedIdentifier(item?["tool"] as? String) == "spawnagent",
           nativeType == "item/completed",
           let agentID = item?["newThreadId"] as? String ?? item?["receiverThreadId"] as? String {
            let state = toolState(item?["status"] as? String, nativeType: nativeType)
            let senderThreadID = item?["senderThreadId"] as? String
            let rootThreadID = object?["threadId"] as? String
            let parentAgentID: String? = senderThreadID.flatMap { senderThreadID in
                guard let rootThreadID, senderThreadID != rootThreadID else { return nil }
                return senderThreadID
            }
            return (
                tool,
                ProviderAgentActivity(
                    agentID: agentID,
                    parentAgentID: parentAgentID,
                    activity: state == .failed ? .failed : .started,
                    taskType: item?["tool"] as? String,
                    sourceToolCallID: callID
                )
            )
        }
        return (tool, nil)
    }

    private static func toolState(_ status: String?, nativeType: String) -> ProviderToolState {
        switch status?.lowercased() {
        case "inprogress", "running", "pending": .running
        case "completed", "success", "succeeded": .completed
        case "failed", "error": .failed
        case "declined": .declined
        case "interrupted", "cancelled", "canceled": .interrupted
        default: nativeType == "item/started" ? .running : (nativeType == "item/completed" ? .completed : .observed)
        }
    }

    private static func toolName(kind: ProviderToolKind, item: [String: Any]?) -> String? {
        switch kind {
        case .commandExecution: "Command"
        case .fileChange: "File change"
        case .mcp, .dynamic, .collaboration: item?["tool"] as? String
        case .webSearch: "Web search"
        case .imageGeneration: "Image generation"
        case .imageView: "Image view"
        case .unknown: nil
        }
    }

    private static let agentActivityByNativeValue: [String: ProviderAgentActivityKind] = [
        "started": .started,
        "interacted": .interacted,
        "completed": .completed,
        "failed": .failed,
        "interrupted": .interrupted,
        "cancelled": .interrupted,
        "canceled": .interrupted,
    ]

    private static func agentActivity(_ value: String) -> ProviderAgentActivityKind? {
        agentActivityByNativeValue[value.lowercased()]
    }

    private static func normalizedIdentifier(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

}
