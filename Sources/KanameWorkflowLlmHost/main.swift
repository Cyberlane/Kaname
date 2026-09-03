import Foundation

// Kaname workflow LLM host.
//
// The Rust executor runs this program as `KanameWorkflowLlmHost describe` once
// and `KanameWorkflowLlmHost invoke` per compute.llm attempt, with one JSON
// request on stdin and one JSON response on stdout. The executor clears the
// environment, so this host rebuilds HOME and PATH itself before it runs the
// Claude Code CLI in non-interactive, tool-less mode.
//
// Model classes map to CLI aliases: fast -> haiku, balanced -> sonnet,
// reasoning -> fable. Output must be JSON; the executor validates it against
// the node's output schema afterwards.

struct HostFailure: Error {
    let outcome: String
    let summary: String
}

enum HostEnvironment {
    static var home: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    static var searchPath: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
    }

    static func resolve(_ name: String) -> String? {
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var userName: String {
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty { return user }
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name { return String(cString: name) }
        return NSUserName()
    }

    /// Claude Code resolves its Keychain login through USER/LOGNAME and its
    /// settings through HOME, so both are rebuilt after the executor's env_clear.
    static var childEnvironment: [String: String] {
        [
            "HOME": home,
            "USER": userName,
            "LOGNAME": userName,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": searchPath.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "CI": "1",
        ]
    }
}

struct ModelClass {
    let id: String
    let alias: String
    let effort: String
}

let modelClasses = [
    ModelClass(id: "fast", alias: "haiku", effort: "low"),
    ModelClass(id: "balanced", alias: "sonnet", effort: "medium"),
    ModelClass(id: "reasoning", alias: "fable", effort: "high"),
]

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func describe() {
    let available = HostEnvironment.resolve("claude") != nil
    let providers: [[String: Any]] = available ? modelClasses.map { model in
        [
            "providerId": "claude-code",
            "modelId": model.alias,
            "modelRevision": "cli",
            "modelClass": model.id,
            "timeoutMilliseconds": 300_000,
            "maximumContextBytes": 400_000,
            "idempotent": false,
            "tools": [] as [Any],
        ]
    } : []
    emit(["providers": providers])
}

func readStandardInput() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func text(fromJSON value: Any?) -> String {
    guard let value else { return "" }
    if let string = value as? String { return string }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        return String(decoding: data, as: UTF8.self)
    }
    return String(describing: value)
}

/// Rebuilds a chat prompt from the compiled, redacted context groups. The
/// executor already bounded and journaled everything here.
func buildPrompt(from request: [String: Any]) -> (system: String, user: String) {
    let groups = (request["contextGroups"] as? [[String: Any]]) ?? []
    let messages = (request["messages"] as? [[String: Any]]) ?? []
    var groupsByID: [String: [String: Any]] = [:]
    for group in groups { if let id = group["groupId"] as? String { groupsByID[id] = group } }
    var system: [String] = []
    var user: [String] = []
    for message in messages.sorted(by: { (($0["sequence"] as? Int) ?? 0) < (($1["sequence"] as? Int) ?? 0) }) {
        let role = (message["role"] as? String) ?? "user"
        let groupID = (message["contextGroupId"] as? String) ?? ""
        let group = groupsByID[groupID]
        let title = (group?["title"] as? String) ?? (message["summary"] as? String) ?? groupID
        let body = text(fromJSON: group?["content"])
        let block = "## \(title)\n\(body)"
        if role == "system" || role == "developer" { system.append(block) } else { user.append(block) }
    }
    if let schema = request["outputSchema"], !(schema is NSNull) {
        system.append("## Output contract\nRespond with exactly one JSON value that matches this JSON Schema and nothing else, no prose, no code fence:\n\(text(fromJSON: schema))")
    }
    if user.isEmpty { user.append("Produce the output described by the contract.") }
    return (system.joined(separator: "\n\n"), user.joined(separator: "\n\n"))
}

/// Extracts the first complete JSON value from model text.
func extractJSON(from text: String) -> Any? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        return value
    }
    var stripped = trimmed
    if stripped.hasPrefix("```") {
        stripped = stripped.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        if let data = stripped.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return value
        }
    }
    for opener: Character in ["{", "["] {
        guard let start = trimmed.firstIndex(of: opener) else { continue }
        let closer: Character = opener == "{" ? "}" : "]"
        guard let end = trimmed.lastIndex(of: closer), end > start else { continue }
        let slice = String(trimmed[start...end])
        if let data = slice.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return value
        }
    }
    return nil
}

func runClaude(model: ModelClass, system: String, user: String, timeoutMilliseconds: UInt64) throws -> (result: [String: Any], elapsed: UInt64) {
    guard let executable = HostEnvironment.resolve("claude") else {
        throw HostFailure(outcome: "crashed", summary: "The claude CLI is not installed in a known location.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [
        "--print",
        "--output-format", "json",
        "--model", model.alias,
        "--effort", model.effort,
        "--max-turns", "1",
        "--permission-mode", "plan",
        "--disallowedTools", "Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "NotebookEdit", "TodoWrite", "ToolSearch",
        "--append-system-prompt", system,
        user,
    ]
    process.environment = HostEnvironment.childEnvironment
    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let output = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = output
    process.standardError = errorPipe
    process.standardInput = FileHandle.nullDevice
    let started = Date()
    try process.run()
    let deadline = DispatchTime.now() + .milliseconds(Int(min(timeoutMilliseconds, 3_600_000)))
    let group = DispatchGroup()
    group.enter()
    var collected = Data()
    DispatchQueue.global().async {
        collected = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        throw HostFailure(outcome: "timed_out", summary: "claude exceeded \(timeoutMilliseconds) ms.")
    }
    let elapsed = UInt64(Date().timeIntervalSince(started) * 1_000)
    let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw HostFailure(outcome: "crashed", summary: "claude exited \(process.terminationStatus): \(stderr.prefix(400))")
    }
    guard let object = try? JSONSerialization.jsonObject(with: collected) as? [String: Any] else {
        throw HostFailure(outcome: "malformed_result", summary: "claude returned non-JSON output.")
    }
    return (object, elapsed)
}

func invoke() {
    let requestData = readStandardInput()
    guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
        emit(["outcome": "malformed_result", "summary": "The invocation request was not valid JSON."])
        return
    }
    let invocationID = (request["invocationId"] as? String) ?? ""
    let settings = (request["settings"] as? [String: Any]) ?? [:]
    let requestedClass = (settings["modelClass"] as? String) ?? "balanced"
    let model = modelClasses.first { $0.id == requestedClass } ?? modelClasses[1]
    let timeout = (request["timeoutMilliseconds"] as? UInt64) ?? 300_000
    let prompt = buildPrompt(from: request)
    do {
        let (result, elapsed) = try runClaude(model: model, system: prompt.system, user: prompt.user, timeoutMilliseconds: timeout)
        let resultText = (result["result"] as? String) ?? ""
        guard let output = extractJSON(from: resultText) else {
            emit([
                "outcome": "malformed_result",
                "summary": "The model reply did not contain a JSON value.",
                "elapsedMilliseconds": elapsed,
                "receiptId": "receipt-\(invocationID)",
            ])
            return
        }
        let usage = (result["usage"] as? [String: Any]) ?? [:]
        let cost = (result["total_cost_usd"] as? Double) ?? 0
        emit([
            "outcome": "succeeded",
            "output": output,
            "elapsedMilliseconds": elapsed,
            "receiptId": "receipt-\(invocationID)",
            "providerRunReference": (result["session_id"] as? String) ?? "",
            "trace": [
                "requestId": invocationID,
                "responseId": (result["session_id"] as? String) ?? "",
                "receiptMetadata": ["model": model.alias, "modelClass": model.id],
                "toolCalls": [] as [Any],
                "responseMessages": [[
                    "messageId": "response-\(invocationID)",
                    "role": "assistant",
                    "kind": "final",
                    "summary": String(resultText.prefix(200)),
                    "content": output,
                ]],
                "usage": [
                    "inputTokens": (usage["input_tokens"] as? Int) ?? 0,
                    "cachedInputTokens": (usage["cache_read_input_tokens"] as? Int) ?? 0,
                    "outputTokens": (usage["output_tokens"] as? Int) ?? 0,
                    "reasoningTokens": 0,
                    "costCurrency": "USD",
                    "inputCostMicros": Int(cost * 1_000_000),
                    "outputCostMicros": 0,
                    "reasoningCostMicros": 0,
                    "toolCostMicros": 0,
                ],
            ],
        ])
    } catch let failure as HostFailure {
        emit(["outcome": failure.outcome, "summary": failure.summary, "receiptId": "receipt-\(invocationID)"])
    } catch {
        emit(["outcome": "crashed", "summary": error.localizedDescription, "receiptId": "receipt-\(invocationID)"])
    }
}

switch CommandLine.arguments.dropFirst().first {
case "describe": describe()
case "invoke": invoke()
default:
    FileHandle.standardError.write(Data("usage: KanameWorkflowLlmHost describe|invoke < request.json\n".utf8))
    exit(64)
}
