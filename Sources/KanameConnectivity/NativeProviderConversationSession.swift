@preconcurrency import Foundation

public enum NativeConversationDriver: String, Codable, CaseIterable, Sendable {
    case claude
    case openCode

    public init?(providerName: String) {
        switch providerName.lowercased() {
        case "claude": self = .claude
        case "opencode", "open code": self = .openCode
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openCode: "OpenCode"
        }
    }
}

public struct NativeConversationRequest: Sendable {
    public let driver: NativeConversationDriver
    public let prompt: String
    public let workspace: URL
    public let model: String?
    public let reasoningEffort: String
    public let resumableSessionID: String?

    public init(
        driver: NativeConversationDriver,
        prompt: String,
        workspace: URL,
        model: String?,
        reasoningEffort: String,
        resumableSessionID: String?
    ) {
        self.driver = driver
        self.prompt = String(prompt.prefix(262_144))
        self.workspace = workspace.standardizedFileURL
        self.model = model
        self.reasoningEffort = reasoningEffort
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
        let command = request.driver == .claude ? "claude" : "opencode"
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
            var arguments = [
                "--print",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--permission-mode", "plan",
                "--max-budget-usd", "2",
                "--effort", request.reasoningEffort,
            ]
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--resume", sessionID]
            } else {
                arguments += ["--session-id", UUID().uuidString.lowercased()]
            }
            arguments.append(request.prompt)
            return arguments
        case .openCode:
            var arguments = [
                "run",
                "--format", "json",
                "--agent", "plan",
                "--dir", request.workspace.path,
                "--variant", request.reasoningEffort,
            ]
            if let model = request.model, !model.isEmpty, model != "Use provider default" {
                arguments += ["--model", model]
            }
            if let sessionID = request.resumableSessionID {
                arguments += ["--session", sessionID]
            }
            arguments.append(request.prompt)
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
    let driver: NativeConversationDriver
    private(set) var sessionID: String?
    private(set) var usageSummary: String?
    private var sawTextDelta = false
    private var emittedSessionStarted = false

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
        case .claude:
            let delta = (object["event"] as? [String: Any])?["delta"] as? [String: Any]
            if let text = delta?["text"] as? String, !text.isEmpty {
                sawTextDelta = true
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            } else if nativeType == "assistant", !sawTextDelta {
                for text in contentTexts(in: object) where !text.isEmpty {
                    events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
                }
            } else if nativeType == "result", !sawTextDelta,
                      let text = object["result"] as? String, !text.isEmpty {
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            }
            for tool in toolNames(in: object) {
                events.append(event(.toolActivity, nativeType: nativeType, text: tool, payload: retained, truncated: truncated))
            }
            if nativeType == "system", sessionID != nil, !emittedSessionStarted {
                emittedSessionStarted = true
                events.append(event(.sessionStarted, nativeType: nativeType, text: "Claude session reconciled.", payload: retained, truncated: truncated))
            }
        case .openCode:
            if let text = openCodeText(in: object), !text.isEmpty {
                sawTextDelta = true
                events.append(event(.messageDelta, nativeType: nativeType, text: text, payload: retained, truncated: truncated))
            }
            if nativeType.localizedCaseInsensitiveContains("tool") {
                events.append(event(.toolActivity, nativeType: nativeType, text: findString(keys: ["tool", "name"], in: object), payload: retained, truncated: truncated))
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
        return events
    }

    private func event(
        _ kind: CodexRunEventKind,
        nativeType: String,
        text: String?,
        payload: Data,
        truncated: Bool
    ) -> CodexRunEvent {
        CodexRunEvent(
            kind: kind,
            nativeType: nativeType,
            threadID: sessionID,
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

    private func toolNames(in object: [String: Any]) -> [String] {
        contentBlocks(in: object).compactMap { block in
            guard (block["type"] as? String) == "tool_use" else { return nil }
            return block["name"] as? String
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
