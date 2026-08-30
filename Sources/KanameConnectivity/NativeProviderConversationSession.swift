@preconcurrency import Foundation
import KanameDomain

public enum NativeConversationDriver: String, Codable, CaseIterable, Sendable {
    case claude
    case openCode
    case cursor
    case grok

    public init?(providerName: String) {
        switch providerName.lowercased() {
        case "claude": self = .claude
        case "opencode", "open code": self = .openCode
        case "cursor", "cursoragent", "cursor-agent", "cursor agent": self = .cursor
        case "grok", "grokbuild", "grok build": self = .grok
        default: return nil
        }
    }

    public var displayName: String {
        inventoryEntry.displayName
    }

    public var executableName: String {
        inventoryEntry.executableCandidates[0]
    }

    private var inventoryEntry: ProviderInventoryEntry {
        guard let provider = ProviderInventory.provider(conversationDriver: .native(self)) else {
            preconditionFailure("Native conversation driver '\(rawValue)' is missing from ProviderInventory.")
        }
        return provider
    }
}

public struct NativeConversationRequest: Sendable {
    public let driver: NativeConversationDriver
    public let prompt: String
    public let attachmentPaths: [String]
    public let workspace: URL
    public let model: String?
    public let reasoningEffort: String
    public let runtimeMode: ConversationRuntimeMode
    public let networkAccess: Bool
    public let resumableSessionID: String?

    public init(
        driver: NativeConversationDriver,
        prompt: String,
        attachmentPaths: [String] = [],
        workspace: URL,
        model: String?,
        reasoningEffort: String,
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false,
        resumableSessionID: String?
    ) {
        self.driver = driver
        self.prompt = String(prompt.prefix(262_144))
        self.attachmentPaths = Array(attachmentPaths.prefix(ConversationImageAttachment.maximumCountPerMessage))
        self.workspace = workspace.standardizedFileURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.runtimeMode = runtimeMode
        self.networkAccess = runtimeMode == .fullAccess ? true : networkAccess
        self.resumableSessionID = resumableSessionID
    }
}

public actor NativeProviderConversationSession {
    private var running: RunningLocalProcess?

    public init() {}

    public func events(for request: NativeConversationRequest) -> AsyncStream<CodexRunEvent> {
        AsyncStream { continuation in
            _Concurrency.Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.execute(request, continuation: continuation)
            }
        }
    }

    public func interrupt() {
        running?.terminate()
    }

    private func execute(
        _ request: NativeConversationRequest,
        continuation: AsyncStream<CodexRunEvent>.Continuation
    ) async {
        let command = ProviderExecutableLocator.resolveNativeConversationExecutable(for: request.driver)
        do {
            let arguments = Self.arguments(for: request)
            let child = try LocalProcess.start(
                executable: command,
                arguments: arguments,
                workingDirectory: request.workspace,
                environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals()
            )
            running = child
            try? child.standardInput.close()
            async let parsed = _Concurrency.Task.detached {
                Self.readEvents(
                    from: child.standardOutput,
                    driver: request.driver,
                    fallbackSessionID: request.resumableSessionID,
                    continuation: continuation
                )
            }.value
            async let errorOutput = _Concurrency.Task.detached {
                Self.readBounded(child.standardError, maximumBytes: 65_536)
            }.value
            let status = await _Concurrency.Task.detached {
                child.waitForExit()
                return child.process.terminationStatus
            }.value
            let result = await parsed
            let stderr = await errorOutput
            running = nil
            if status == 0 {
                continuation.yield(CodexRunEvent(
                    kind: .providerCompleted,
                    nativeType: "\(request.driver.rawValue)/completed",
                    threadID: result.sessionID,
                    text: result.usageSummary
                ))
            } else {
                let detail = String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.yield(CodexRunEvent(
                    kind: status == SIGTERM ? .runInterrupted : .runFailed,
                    nativeType: "\(request.driver.rawValue)/failed",
                    threadID: result.sessionID,
                    text: detail.isEmpty ? "\(request.driver.displayName) exited with status \(status)." : String(detail.prefix(4_096))
                ))
            }
        } catch {
            running = nil
            continuation.yield(CodexRunEvent(
                kind: .runFailed,
                nativeType: "\(request.driver.rawValue)/launch-failed",
                threadID: request.resumableSessionID,
                text: error.localizedDescription
            ))
        }
        continuation.finish()
    }

    static func arguments(for request: NativeConversationRequest) -> [String] {
        switch request.driver {
        case .claude:
            let permissionMode: String
            switch request.runtimeMode {
            case .approvalRequired: permissionMode = "plan"
            case .autoAcceptEdits: permissionMode = "acceptEdits"
            case .auto: permissionMode = "auto"
            case .fullAccess: permissionMode = "bypassPermissions"
            }
            var arguments = [
                "--print",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--permission-mode", permissionMode,
                "--max-budget-usd", "2",
                "--effort", request.reasoningEffort,
            ]
            let directories = Set(request.attachmentPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            if !directories.isEmpty { arguments += ["--add-dir"] + directories.sorted() }
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--resume", sessionID]
            } else {
                arguments += ["--session-id", UUID().uuidString.lowercased()]
            }
            let attachmentContext = request.attachmentPaths.enumerated().map { index, path in
                "Image \(index + 1) (inspect with the Read tool): `\(path)`"
            }.joined(separator: "\n")
            arguments.append(
                attachmentContext.isEmpty
                    ? request.prompt
                    : [request.prompt, "Attached images:", attachmentContext].filter { !$0.isEmpty }.joined(separator: "\n\n")
            )
            return arguments
        case .openCode:
            let agent = request.runtimeMode == .approvalRequired ? "plan" : "build"
            var arguments = [
                "run",
                "--format", "json",
                "--agent", agent,
                "--dir", request.workspace.path,
                "--variant", request.reasoningEffort,
            ]
            if request.runtimeMode == .auto || request.runtimeMode == .fullAccess {
                arguments.append("--auto")
            }
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--session", sessionID]
            }
            for path in request.attachmentPaths { arguments += ["--file", path] }
            arguments.append(request.prompt)
            return arguments
        case .cursor:
            var arguments = [
                "--print",
                "--output-format", "stream-json",
                "--stream-partial-output",
                "--workspace", request.workspace.path,
            ]
            switch request.runtimeMode {
            case .approvalRequired:
                arguments += ["--mode", "plan"]
            case .autoAcceptEdits, .auto:
                break
            case .fullAccess:
                arguments += ["--force"]
            }
            if !request.networkAccess {
                arguments += ["--sandbox", "enabled"]
            }
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--resume", sessionID]
            }
            let attachmentContext = request.attachmentPaths.enumerated().map { index, path in
                "Image \(index + 1): `\(path)`"
            }.joined(separator: "\n")
            arguments.append(
                attachmentContext.isEmpty
                    ? request.prompt
                    : [request.prompt, "Attached images:", attachmentContext].filter { !$0.isEmpty }.joined(separator: "\n\n")
            )
            return arguments
        case .grok:
            var arguments = [
                "--single", request.prompt,
                "--output-format", "streaming-messages-json",
                "--cwd", request.workspace.path,
                "--disable-web-search",
            ]
            switch request.runtimeMode {
            case .approvalRequired, .autoAcceptEdits:
                break
            case .auto, .fullAccess:
                arguments.append("--always-approve")
            }
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--resume", sessionID]
            }
            return arguments
        }
    }

    private struct ReadResult: Sendable {
        var sessionID: String?
        var usageSummary: String?
    }

    private static func readEvents(
        from handle: FileHandle,
        driver: NativeConversationDriver,
        fallbackSessionID: String?,
        continuation: AsyncStream<CodexRunEvent>.Continuation
    ) -> ReadResult {
        var buffered = Data()
        var parser = NativeProviderStreamParser(driver: driver, sessionID: fallbackSessionID)
        var totalBytes = 0
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            totalBytes += data.count
            guard totalBytes <= 8 * 1_024 * 1_024 else { continue }
            buffered.append(data)
            while let newline = buffered.firstIndex(of: 0x0A) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                parser.consume(line: line).forEach { continuation.yield($0) }
            }
        }
        if !buffered.isEmpty {
            parser.consume(line: buffered).forEach { continuation.yield($0) }
        }
        parser.settleOutstandingAgentEvents(
            nativeType: "\(driver.rawValue)/observation-ended"
        ).forEach { continuation.yield($0) }
        return ReadResult(sessionID: parser.sessionID, usageSummary: parser.usageSummary)
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            if result.count < maximumBytes {
                result.append(chunk.prefix(maximumBytes - result.count))
            }
        }
        return result
    }
}

struct NativeProviderStreamParser {
    private struct ToolContext {
        let name: String
        let kind: ProviderToolKind
        let parentCallID: String?
    }

    let driver: NativeConversationDriver
    private(set) var sessionID: String?
    private(set) var usageSummary: String?
    private var sawTextDelta = false
    private var emittedSessionStarted = false
    private var toolsByCallID: [String: ToolContext] = [:]
    private var agentLedger = ProviderAgentActivityLedger()

    init(driver: NativeConversationDriver, sessionID: String? = nil) {
        self.driver = driver
        self.sessionID = sessionID
    }

    mutating func consume(line: Data) -> [CodexRunEvent] {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        sessionID = findString(keys: ["session_id", "sessionID"], in: object) ?? sessionID
        let nativeType = (object["type"] as? String) ?? "\(driver.rawValue)/event"
        let retained = Data(line.prefix(CodexRunEvent.maximumRetainedPayloadBytes))
        let truncated = line.count > retained.count
        var events: [CodexRunEvent] = []

        switch driver {
        case .claude, .cursor, .grok:
            let delta = (object["event"] as? [String: Any])?["delta"] as? [String: Any]
            if let text = delta?["text"] as? String, !text.isEmpty {
                sawTextDelta = true
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            } else if nativeType == "assistant", !sawTextDelta {
                for text in contentTexts(in: object) where !text.isEmpty {
                    events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
                }
            } else if ["result", "message"].contains(nativeType), !sawTextDelta,
                      let text = object["result"] as? String ?? object["text"] as? String, !text.isEmpty {
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            }
            for block in contentBlocks(in: object) {
                switch block["type"] as? String {
                case "tool_use":
                    guard let callID = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let parentCallID = object["parent_tool_use_id"] as? String
                    let toolKind = claudeToolKind(name)
                    toolsByCallID[callID] = ToolContext(
                        name: name,
                        kind: toolKind,
                        parentCallID: parentCallID
                    )
                    let observation = ProviderToolObservation(
                        callID: callID,
                        parentCallID: parentCallID,
                        kind: toolKind,
                        state: .running,
                        name: name
                    )
                    events.append(event(
                        .toolActivity,
                        nativeType: nativeType,
                        text: name,
                        toolObservation: observation,
                        agentActivity: claudeAgentActivity(
                            callID: callID,
                            parentCallID: parentCallID,
                            name: name,
                            activity: .started
                        ),
                        payload: retained,
                        truncated: truncated
                    ))
                case "tool_result":
                    guard let callID = block["tool_use_id"] as? String else { continue }
                    let context = toolsByCallID[callID]
                    let failed = block["is_error"] as? Bool == true
                    let observation = ProviderToolObservation(
                        callID: callID,
                        parentCallID: context?.parentCallID,
                        kind: context?.kind ?? .unknown,
                        state: failed ? .failed : .completed,
                        name: context?.name
                    )
                    events.append(event(
                        .toolActivity,
                        nativeType: nativeType,
                        text: context?.name,
                        toolObservation: observation,
                        agentActivity: context.flatMap {
                            claudeAgentActivity(
                                callID: callID,
                                parentCallID: $0.parentCallID,
                                name: $0.name,
                                activity: failed ? .failed : .completed
                            )
                        },
                        payload: retained,
                        truncated: truncated
                    ))
                default:
                    continue
                }
            }
            if ["system", "session_update", "stream_event"].contains(nativeType), sessionID != nil, !emittedSessionStarted {
                emittedSessionStarted = true
                events.append(event(
                    .sessionStarted,
                    nativeType: nativeType,
                    text: "\(driver.displayName) session reconciled.",
                    payload: retained,
                    truncated: truncated
                ))
            }
        case .openCode:
            if let text = openCodeText(in: object), !text.isEmpty {
                sawTextDelta = true
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            }
            if let part = object["part"] as? [String: Any],
               (nativeType == "tool_use" || (part["type"] as? String) == "tool"),
               let callID = part["callID"] as? String ?? part["id"] as? String,
               let toolName = part["tool"] as? String {
                let state = part["state"] as? [String: Any]
                let rawStatus = state?["status"] as? String
                let metadata = state?["metadata"] as? [String: Any]
                let toolState = openCodeToolState(rawStatus)
                let observation = ProviderToolObservation(
                    callID: callID,
                    kind: openCodeToolKind(toolName),
                    state: toolState,
                    name: toolName
                )
                let childSessionID = metadata?["sessionId"] as? String
                let rawParentSessionID = metadata?["parentSessionId"] as? String
                let parentAgentID = rawParentSessionID.flatMap {
                    $0 == sessionID ? nil : $0
                }
                let agentActivity = openCodeAgentActivity(
                    toolState: toolState,
                    isBackground: metadata?["background"] as? Bool == true
                )
                let agent = toolName.caseInsensitiveCompare("task") == .orderedSame
                    ? childSessionID.flatMap { childSessionID in
                        agentActivity.map {
                            ProviderAgentActivity(
                                agentID: childSessionID,
                                parentAgentID: parentAgentID,
                                activity: $0,
                                taskType: toolName,
                                sourceToolCallID: callID
                            )
                        }
                    }
                    : nil
                events.append(event(
                    .toolActivity,
                    nativeType: nativeType,
                    text: toolName,
                    toolObservation: observation,
                    agentActivity: agent,
                    payload: retained,
                    truncated: truncated
                ))
            }
            if sessionID != nil, nativeType.localizedCaseInsensitiveContains("start"), !emittedSessionStarted {
                emittedSessionStarted = true
                events.append(event(.sessionStarted, nativeType: nativeType, text: "OpenCode session reconciled.", payload: retained, truncated: truncated))
            }
        }
        usageSummary = usage(in: object) ?? usageSummary
        if events.isEmpty {
            events.append(event(.nativeProviderEvent, nativeType: nativeType, text: nil, payload: retained, truncated: truncated))
        }
        for event in events { agentLedger.observe(event.agentActivity) }
        return events
    }

    mutating func settleOutstandingAgentEvents(nativeType: String) -> [CodexRunEvent] {
        let events = agentLedger.settlementActivities(as: .interrupted).map {
            CodexRunEvent(
                kind: .toolActivity,
                nativeType: nativeType,
                threadID: sessionID,
                agentActivity: $0
            )
        }
        for event in events { agentLedger.observe(event.agentActivity) }
        return events
    }

    private func event(
        _ kind: CodexRunEventKind,
        nativeType: String,
        text: String?,
        toolObservation: ProviderToolObservation? = nil,
        agentActivity: ProviderAgentActivity? = nil,
        payload: Data,
        truncated: Bool
    ) -> CodexRunEvent {
        CodexRunEvent(
            kind: kind,
            nativeType: nativeType,
            threadID: sessionID,
            toolObservation: toolObservation,
            agentActivity: agentActivity,
            text: text,
            payload: payload,
            payloadWasTruncated: truncated
        )
    }

    private func contentTexts(in object: [String: Any]) -> [String] {
        contentBlocks(in: object).compactMap { block in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }
    }

    private func contentBlocks(in object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    private func openCodeText(in object: [String: Any]) -> String? {
        if let text = object["text"] as? String { return text }
        guard let part = object["part"] as? [String: Any],
              (part["type"] as? String) == "text" else { return nil }
        return part["text"] as? String
    }

    private func usage(in object: [String: Any]) -> String? {
        guard let usage = object["usage"] as? [String: Any],
              JSONSerialization.isValidJSONObject(usage),
              let data = try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static let commonNativeToolKinds: [String: ProviderToolKind] = [
        "bash": .commandExecution,
        "shell": .commandExecution,
        "edit": .fileChange,
        "write": .fileChange,
        "webfetch": .webSearch,
        "websearch": .webSearch,
        "task": .collaboration,
    ]

    private static let claudeToolAliases: [String: ProviderToolKind] = [
        "computer": .commandExecution,
        "notebookedit": .fileChange,
        "agent": .collaboration,
    ]

    private static let openCodeToolAliases: [String: ProviderToolKind] = [
        "patch": .fileChange,
    ]

    private func nativeToolKind(
        _ name: String,
        providerAliases: [String: ProviderToolKind]
    ) -> ProviderToolKind {
        let normalizedName = name.lowercased()
        return providerAliases[normalizedName]
            ?? Self.commonNativeToolKinds[normalizedName]
            ?? .unknown
    }

    private func claudeToolKind(_ name: String) -> ProviderToolKind {
        nativeToolKind(name, providerAliases: Self.claudeToolAliases)
    }

    private func claudeAgentActivity(
        callID: String,
        parentCallID: String?,
        name: String,
        activity: ProviderAgentActivityKind
    ) -> ProviderAgentActivity? {
        guard name.caseInsensitiveCompare("Agent") == .orderedSame
                || name.caseInsensitiveCompare("Task") == .orderedSame else { return nil }
        return ProviderAgentActivity(
            agentID: callID,
            parentAgentID: parentCallID,
            activity: activity,
            taskType: name,
            sourceToolCallID: callID
        )
    }

    private func openCodeToolKind(_ name: String) -> ProviderToolKind {
        nativeToolKind(name, providerAliases: Self.openCodeToolAliases)
    }

    private func openCodeToolState(_ status: String?) -> ProviderToolState {
        switch status?.lowercased() {
        case "pending", "running": .running
        case "completed", "success", "succeeded": .completed
        case "error", "failed": .failed
        case "declined", "denied": .declined
        case "interrupted", "cancelled", "canceled": .interrupted
        default: .observed
        }
    }

    private func openCodeAgentActivity(
        toolState: ProviderToolState,
        isBackground: Bool
    ) -> ProviderAgentActivityKind? {
        switch toolState {
        case .running: .started
        case .completed: isBackground ? .started : .completed
        case .failed: .failed
        case .declined, .interrupted: .interrupted
        case .observed: nil
        }
    }

    private func findString(keys: [String], in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let text = dictionary[key] as? String, !text.isEmpty { return text }
            }
            for child in dictionary.values {
                if let found = findString(keys: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(keys: keys, in: child) { return found }
            }
        }
        return nil
    }
}
