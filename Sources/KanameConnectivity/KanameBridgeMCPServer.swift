import Foundation
import KanameLocalCore
import Network

/// Kaname Bridge: a loopback MCP server injected into every provider run so
/// the agent can talk to Kaname directly instead of through Markdown
/// conventions. Tool calls are turned into `CodexRunEvent`s and appended to
/// the same run stream the desktop already consumes, so the Plan tab,
/// Evidence tab, and Knowledge lane update live.
///
/// Tools: `plan_update`, `finding_record`, `knowledge_search`,
/// `knowledge_read`, `knowledge_propose`. Knowledge access is limited to the
/// vault scopes the desktop granted for this run.
public actor KanameBridgeMCPServer {
    public static let serverName = "kaname"

    public struct Binding: Sendable, Equatable {
        public let url: URL
        public let bearerToken: String
        public let port: UInt16

        /// Inline `--mcp-config` JSON for Claude Code.
        /// Inline OpenCode config (`OPENCODE_CONFIG_CONTENT`): merges over the
        /// user's global and project config, so nothing is written into the repo.
        public var openCodeMCPConfigJSON: String {
            let object: [String: Any] = [
                "mcp": [
                    KanameBridgeMCPServer.serverName: [
                        "type": "remote",
                        "url": url.absoluteString,
                        "enabled": true,
                        "headers": ["Authorization": "Bearer \(bearerToken)"],
                    ],
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        public var claudeMCPConfigJSON: String {
            let object: [String: Any] = [
                "mcpServers": [
                    KanameBridgeMCPServer.serverName: [
                        "type": "http",
                        "url": url.absoluteString,
                        "headers": ["Authorization": "Bearer \(bearerToken)"],
                    ],
                ],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public typealias Emit = @Sendable (CodexRunEvent) async -> Void

    private var knowledge: ObsidianVaultService?
    private var readableScopes: [String]
    private var writableScopes: [String]
    private var memory: [KanameBridgeMemoryEntry]
    private var workflowPublisher: LocalCoreRunner?
    private let emit: Emit
    private var listener: NWListener?
    private var binding: Binding?
    private let queue = DispatchQueue(label: "com.cyberlane.kaname.bridge-mcp")

    public init(
        knowledge: ObsidianVaultService?,
        readableScopes: [String],
        writableScopes: [String] = [],
        memory: [KanameBridgeMemoryEntry] = [],
        emit: @escaping Emit
    ) {
        self.knowledge = knowledge
        self.readableScopes = readableScopes
        self.writableScopes = writableScopes
        self.memory = memory
        self.emit = emit
    }

    /// Replaces the recallable thread history for the next run.
    public func updateMemory(_ entries: [KanameBridgeMemoryEntry]) {
        memory = entries
    }

    /// Enables `workflow_publish` through the signed local core.
    public func updateWorkflowPublisher(_ runner: LocalCoreRunner?) {
        workflowPublisher = runner
    }

    /// Compact authoring guide for Kaname's v1 workflow graph. Kept in sync by
    /// hand with Schema/Workflow/v1; the compiler is the authority and returns
    /// diagnostics on publish.
    static let workflowAuthoringGuide = """
    # Kaname workflow v1 authoring guide

    A workflow is one JSON document:
    {"formatVersion":1,"workflowId":"<uuid v7>","packageId":"<dot.separated.id>","name":"…","summary":"…",
     "graph":{"entrypoints":[{"id":"<uuid>","nodeId":"<trigger node id>"}],"nodes":[…],"edges":[…]},
     "interfaces":{},"resources":{},"policies":{},"storage":{},"metadata":{}}
    Every id is a UUID v7 shape: 8-4-4-4-12 hex with the third group starting with 7 and the fourth with 8, 9, a, or b
    (example 018f5000-0101-7000-8000-000000000101). Keys are lowercase kebab-case (^[a-z][a-z0-9-]{0,63}$).

    Node: {"id","key","name","type","typeVersion":1,"config":{…}}. Edge: {"id","from":{"nodeId","portId"},"to":{"nodeId","portId"},"mappingId":"<uuid>","mapping":<expression>}.
    Expression forms: {"whole":true} | {"select":{"root":"input"|"value"|"item"|"error","pointer":"/json/pointer"}} | {"literal":{"type":"string"|"number"|"boolean"|"null"|"json","value":…}} | {"object":{"field":<expr>,…}} | {"array":[<expr>,…]} | {"coalesce":[<expr>,…]} | {"format":{"template":"…{name}…","values":{"name":<expr>}}}.

    Node types, config keys, and ports:
    - trigger.manual {} → out: success. Optional config.inputSchemaRef.
    - trigger.schedule {"scheduleKey":"<key>","misfirePolicy":"skip"|"run-once"} → out: success. Cadence is set by the user in Kaname, not in the graph.
    - trigger.event {"eventContract":"<contract>","deduplication":"event-id"|"contract-key"} → out: success. Contracts Kaname emits: mail.message.received {accountBindingId, accountId, accountAddress, messageId, conversationId, destinationFingerprint (64-hex digest mail effects require), resourceIds, labelIds, sender, recipients, subject, date, snippet, bodyExcerpt (≤4 KB), attachmentCount, listUnsubscribe, cursor, provider} so a compute.llm node can classify the mail from the trigger input alone; calendar.event.changed {accountId, calendarId, calendarName, eventId, recurringEventId, title, startAtUnixMillis, endAtUnixMillis, timeZone, isAllDay, revision}; github.notification.received {notificationId, reason, unread, updatedAt, repository, subjectTitle, subjectType, subjectUrl}; any custom contract posted to the local webhook (POST http://127.0.0.1:<port>/hook/<contract> with the bearer token shown in Run history; the JSON body becomes the input, optional eventId and contractKey keys drive deduplication).
    - data.validate {"schemaRef":"<schema id in schemaBundle>"} in: input → out: success, error.
    - data.map {"mapping":<expression>} in: input → out: success, error.
    - control.decision {"when":{"compare":{"left":<expr>,"operator":"equal"|"not-equal"|"greater"|"less"|"contains"|"exists","right":<expr>}}} in: input → out: matched, not-matched, error.
    - control.match {"value":<expr>,"hitPolicy":"first"|"all","cases":[{"id","key","label","when":{"compare":…}}],"otherwise":{"id","key","label"}} in: input → out: case-<caseId> per case (and otherwise), error.
    - control.parallel {"branches":N} in: input → out: branch ports, error. control.join {"policy":"all"|"any"|"quorum","cancelRemaining":bool} in: branches → out: success, error.
    - control.for-each {"items":<expr>,"as":"item","maximumItems":N,"maximumConcurrency":N,"failurePolicy":"fail-fast"|"continue"} in: input → out: item (per item), success, error.
    - control.retry {"maximumAttempts":N,"retryOn":["timed_out","crashed"],"backoff":{"initialMilliseconds":N,"multiplier":2,"maximumMilliseconds":N}} in: error → out: retry, exhausted.
    - control.wait {"kind":"timer"|"reply"|"event","correlation":[<value refs>],"expirySeconds":N} in: input → out: resumed, expired, error.
    - control.human-review {"proposal":<expr>,"authorityPolicy":"owner-approval","expirySeconds":N,"staleCheck":"digest"|"revision"} in: input → out: approved, rejected, expired.
    - control.reconcile {"effect":"<effect node id>","maximumChecks":N} in: unknown → out: success, failure, still-unknown.
    - compute.llm {"modelClass":"fast"|"balanced"|"reasoning","instructions":"…","prompt":<expr>,"context":[],"tools":[],"outputSchemaRef":"<schema id>","reasoningEffort":"low"|"medium"|"high","temperatureMilli":0,"maximumContextBytes":65536,"maximumOutputTokens":1024} in: input → out: success, error. The model answers JSON matching outputSchemaRef.
    - compute.capability {"capabilityId":"…","version":"…","input":<expr>,"outputSchemaRef":"…"} in: input → out: success, error.
    - effect.connector {"connectorClass":"dev.kaname.mail","action":"send"|"draft"|"archive"|"label"|"trash"|"mark-read","input":<expr producing {accountBindingId, accountId, destinationFingerprint, conversationIds?, addLabelIds?, removeLabelIds?, recipients?, subject?, body?}>,"previewContract":"…","reconciliationContract":"…","idempotency":"required"} in: input → out: success, error. The user approves each effect in Run history unless a standing rule exists. Every effect node also needs "policyRefs":{"authority":"<policy key>"} pointing at a top-level policy {"key":"<policy key>","type":"authority","typeVersion":1,"config":{"authorityClass":"local-user","approval":"always","reversible":true}} in the document's "policies" map, and the publish call needs dependencyLockJson pinning {"kind":"connector","id":"dev.kaname.mail","digest":"sha256:…"}.
    Downstream nodes only see the value on their incoming edge, so when a compute.llm result must be acted on, make its output schema include the ids the effect needs (conversationId, accountId, and destinationFingerprint with pattern ^[0-9a-f]{64}$) and tell the model to copy them from the input character for character.
    - storage.read/write/promote for durable scoped values; terminal.complete {"output":<expr>?}, terminal.fail {"error":<expr>}, terminal.cancel {"reason":…} in: input.

    schemaBundleJson: {"bundleVersion":1,"schemas":[{"id":"<schema id>","schema":{…JSON Schema…}}]} for every schemaRef and outputSchemaRef you use.
    Start small: trigger → validate → decision/match → terminal. Publish, run with input JSON, read Run history, iterate.
    """

    public func currentBinding() -> Binding? { binding }

    /// Re-scopes knowledge access for the next run on a long-lived session.
    public func updateScopes(readable: [String], writable: [String]) {
        readableScopes = readable + writable
        writableScopes = writable
        knowledge = (readable.isEmpty && writable.isEmpty)
            ? nil
            : try? ObsidianVaultService(readableScopes: readable + writable, writableScopes: writable)
    }

    public func start() async throws -> Binding {
        if let binding { return binding }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            _Concurrency.Task { await self.accept(connection) }
        }
        let started: Binding = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/mcp") else {
                        listener.cancel()
                        continuation.resume(throwing: CodexLiveSessionError.malformedResponse("bridge MCP port unavailable"))
                        return
                    }
                    let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                    continuation.resume(returning: Binding(url: url, bearerToken: token, port: port.rawValue))
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        binding = started
        return started
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        binding = nil
    }

    // MARK: Transport

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: next[..<headerEnd.lowerBound], as: UTF8.self)
                let contentLength = Self.contentLength(in: headers) ?? 0
                let body = next[headerEnd.upperBound...]
                if body.count >= contentLength {
                    let requestBody = Data(body.prefix(contentLength))
                    _Concurrency.Task {
                        let response = await self.handle(headers: headers, body: requestBody)
                        Self.send(response, on: connection)
                    }
                    return
                }
            }
            if isComplete || next.count > 4 * 1_048_576 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: next)
        }
    }

    private func handle(headers: String, body: Data) async -> Data {
        guard headers.hasPrefix("POST "),
              let bearerToken = binding?.bearerToken,
              headers.lowercased().contains("authorization: bearer \(bearerToken.lowercased())") else {
            return Self.httpResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = object["method"] as? String else {
            return Self.httpResponse(status: 400, body: Data(#"{"error":"invalid json-rpc"}"#.utf8))
        }
        let id = object["id"]
        let result: Any
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.serverName, "version": "1"],
            ] as [String: Any]
        case "notifications/initialized", "initialized":
            return Self.httpResponse(status: 204, body: Data())
        case "ping":
            result = [:] as [String: Any]
        case "tools/list":
            result = ["tools": Self.toolDefinitions] as [String: Any]
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            result = await call(name: name, arguments: arguments)
        default:
            return Self.jsonRPCError(id: id, code: -32_601, message: "method not found")
        }
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { payload["id"] = id }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"jsonrpc":"2.0","result":{}}"#.utf8)
        return Self.httpResponse(status: 200, body: data)
    }

    // MARK: Tools

    static var toolDefinitions: [[String: Any]] {
        [
        [
            "name": "plan_update",
            "description": "Replace Kaname's Plan tab with the current implementation plan. Call it whenever the plan changes. Send the whole plan, not a delta.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "steps": [
                        "type": "array",
                        "description": "Ordered implementation steps.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "step": ["type": "string"],
                                "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]],
                            ],
                            "required": ["step"],
                        ],
                    ],
                    "plan_markdown": ["type": "string", "description": "Optional full plan as Markdown (context, approach, risks)."],
                ],
                "required": ["steps"],
            ],
        ],
        [
            "name": "finding_record",
            "description": "Record one thing you learned while investigating or debugging: what you checked, what you observed, what you concluded. Shown in Kaname's Evidence tab.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "One-line conclusion."],
                    "detail": ["type": "string", "description": "What was checked and observed."],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "knowledge_search",
            "description": "Search the user's Obsidian notes that Kaname has granted for this project. Returns note paths with matching context.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "knowledge_read",
            "description": "Read one granted Obsidian note by vault-relative path.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
            ],
        ],
        [
            "name": "history_search",
            "description": "Search Kaname's earlier coding threads (titles, summaries, plans, decisions, findings), this project first and recent threads from the user's other projects labelled by project. Use it before re-deriving something the user may have decided before.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 20],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "history_read",
            "description": "Read one earlier thread's plan, decisions, and findings by thread id from history_search.",
            "inputSchema": [
                "type": "object",
                "properties": ["threadId": ["type": "string"]],
                "required": ["threadId"],
            ],
        ],
        [
            "name": "workflow_schema",
            "description": "Returns the authoring guide for Kaname automation workflows (node types, config keys, ports, expression forms, document shape). Call before writing a workflow graph.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "workflow_publish",
            "description": "Publish a complete Kaname workflow v1 JSON document into the durable library as an active revision so the user can run or schedule it. Returns the revision, whether it compiled as executable, or the compiler's error.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "summary": ["type": "string"],
                    "workflowJson": ["type": "string", "description": "The full workflow document as a JSON string."],
                    "schemaBundleJson": ["type": "string", "description": "Optional schema bundle JSON string for schemaRef and outputSchemaRef ids."],
                    "dependencyLockJson": ["type": "string", "description": "Optional dependency lock JSON: {\"lockVersion\":1,\"dependencies\":[{\"kind\":\"connector\",\"id\":\"dev.kaname.mail\",\"digest\":\"sha256:…\"}]}. Required when the graph has effect.connector, compute.capability, control.subflow, or compute.llm tools."],
                    "activate": ["type": "boolean"],
                ],
                "required": ["name", "workflowJson"],
            ],
        ],
        [
            "name": "knowledge_propose",
            "description": "Propose a new or updated Obsidian note for the user to review. Nothing is written until the user approves in Kaname.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Vault-relative path ending in .md"],
                    "content": ["type": "string", "description": "Full proposed note content."],
                    "rationale": ["type": "string", "description": "Why this note should change."],
                ],
                "required": ["path", "content"],
            ],
        ],
    ]
    }

    private func call(name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "plan_update":
            guard let rawSteps = arguments["steps"] as? [[String: Any]] else {
                return Self.toolText("plan_update needs a steps array.", isError: true)
            }
            let steps: [[String: String]] = rawSteps.compactMap { entry in
                guard let step = (entry["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty else { return nil }
                return ["step": String(step.prefix(2_000)), "status": (entry["status"] as? String ?? "pending").lowercased()]
            }
            guard !steps.isEmpty else { return Self.toolText("plan_update needs at least one non-empty step.", isError: true) }
            var payload: [String: Any] = ["plan": Array(steps.prefix(128))]
            if let markdown = arguments["plan_markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["planText"] = String(markdown.prefix(64 * 1_024))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return Self.toolText("plan_update could not encode the plan.", isError: true)
            }
            await emit(CodexRunEvent(kind: .planUpdated, nativeType: "kaname/plan_update", text: payload["planText"] as? String, payload: data))
            return Self.toolText("Plan updated in Kaname with \(steps.count) steps.")
        case "finding_record":
            guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return Self.toolText("finding_record needs a title.", isError: true)
            }
            let detail = (arguments["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = detail.isEmpty ? title : "\(title)\n\(detail)"
            await emit(CodexRunEvent(kind: .nativeProviderEvent, nativeType: "kaname/finding", text: String(text.prefix(4_000))))
            return Self.toolText("Finding recorded.")
        case "knowledge_search":
            guard let knowledge, !readableScopes.isEmpty else {
                return Self.toolText("No Obsidian notes are granted for this project. Ask the user to add a knowledge scope in Kaname.", isError: true)
            }
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Self.toolText("knowledge_search needs a query.", isError: true)
            }
            let limit = min(max((arguments["limit"] as? Int) ?? 10, 1), 50)
            var lines: [String] = []
            for scope in readableScopes {
                guard let results = try? await knowledge.search(query: query, scope: scope, limit: limit) else { continue }
                for result in results {
                    lines.append("- \(result.path): \(result.context.replacingOccurrences(of: "\n", with: " ").prefix(240))")
                    if lines.count >= limit { break }
                }
                if lines.count >= limit { break }
            }
            return Self.toolText(lines.isEmpty ? "No notes matched \"\(query)\" in the granted scopes." : lines.joined(separator: "\n"))
        case "knowledge_read":
            guard let knowledge else {
                return Self.toolText("No Obsidian notes are granted for this project.", isError: true)
            }
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return Self.toolText("knowledge_read needs a path.", isError: true)
            }
            do {
                let document = try await knowledge.inspect(path: path)
                let content = document.content.utf8.count > 32 * 1_024
                    ? String(decoding: Array(document.content.utf8.prefix(32 * 1_024)), as: UTF8.self) + "\n\n[truncated]"
                    : document.content
                await emit(CodexRunEvent(kind: .nativeProviderEvent, nativeType: "kaname/knowledge_read", text: document.path))
                return Self.toolText("# \(document.path)\n\n\(content)")
            } catch {
                return Self.toolText("Could not read \(path): \(error.localizedDescription)", isError: true)
            }
        case "history_search":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                return Self.toolText("history_search needs a query.", isError: true)
            }
            guard !memory.isEmpty else {
                return Self.toolText("No earlier threads exist yet.")
            }
            let limit = min(max((arguments["limit"] as? Int) ?? 5, 1), 20)
            let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
            func score(_ entry: KanameBridgeMemoryEntry) -> Int {
                let haystack = ([entry.title, entry.summary] + entry.plan + entry.decisions + entry.findings).joined(separator: "\n").lowercased()
                return terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            }
            var scored: [(entry: KanameBridgeMemoryEntry, hits: Int)] = []
            for entry in memory {
                let hits = score(entry)
                if hits > 0 { scored.append((entry, hits)) }
            }
            scored.sort { lhs, rhs in
                if lhs.hits != rhs.hits { return lhs.hits > rhs.hits }
                return lhs.entry.updatedAtUnixMillis > rhs.entry.updatedAtUnixMillis
            }
            let ranked = Array(scored.prefix(limit))
            guard !ranked.isEmpty else { return Self.toolText("No earlier thread matched \"\(query)\".") }
            var lines: [String] = []
            for item in ranked {
                let matches = item.hits == 1 ? "match" : "matches"
                let summary = String(item.entry.summary.prefix(200))
                let project = item.entry.projectName.map { " · project \($0)" } ?? ""
                lines.append("- [\(item.entry.threadID)] \(item.entry.title) · \(item.entry.outcome)\(project) · \(item.hits) \(matches)\n  \(summary)")
            }
            return Self.toolText(lines.joined(separator: "\n"))
        case "history_read":
            guard let threadID = arguments["threadId"] as? String, let entry = memory.first(where: { $0.threadID == threadID }) else {
                return Self.toolText("No earlier thread with that id is in this project's history.", isError: true)
            }
            let text = [
                "# \(entry.title)",
                "Outcome: \(entry.outcome)",
                entry.summary.isEmpty ? nil : "Summary: \(entry.summary)",
                entry.plan.isEmpty ? nil : "## Plan\n" + entry.plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                entry.decisions.isEmpty ? nil : "## Decisions\n" + entry.decisions.map { "- \($0)" }.joined(separator: "\n"),
                entry.findings.isEmpty ? nil : "## Findings\n" + entry.findings.map { "- \($0)" }.joined(separator: "\n"),
            ].compactMap { $0 }.joined(separator: "\n\n")
            return Self.toolText(text)
        case "workflow_schema":
            return Self.toolText(Self.workflowAuthoringGuide)
        case "workflow_publish":
            guard let publisher = workflowPublisher else {
                return Self.toolText("Publishing is unavailable in this run (no local core).", isError: true)
            }
            guard let workflowJSON = arguments["workflowJson"] as? String,
                  let data = workflowJSON.data(using: .utf8),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workflowID = document["workflowId"] as? String, !workflowID.isEmpty else {
                return Self.toolText("workflow_publish needs workflowJson containing a parseable document with a workflowId.", isError: true)
            }
            let name = (arguments["name"] as? String) ?? (document["name"] as? String) ?? "Workflow"
            let summary = (arguments["summary"] as? String) ?? (document["summary"] as? String) ?? ""
            let packageID = (document["packageId"] as? String) ?? "dev.kaname.authored"
            let schemaBundle = (arguments["schemaBundleJson"] as? String) ?? ""
            let dependencyLock = (arguments["dependencyLockJson"] as? String) ?? ""
            let activate = (arguments["activate"] as? Bool) ?? true
            do {
                let result = try await publisher.publishWorkflow(
                    workflowID: workflowID,
                    packageID: packageID,
                    name: name,
                    summary: summary,
                    workflowJSON: workflowJSON,
                    schemaBundleJSON: schemaBundle,
                    dependencyLockJSON: dependencyLock,
                    activate: activate
                )
                await emit(CodexRunEvent(
                    kind: .nativeProviderEvent,
                    nativeType: "kaname/workflow_publish",
                    text: "\(name) → revision \(result.revisionID) (\(result.executionSupport))\(result.activated ? ", active" : "")"
                ))
                return Self.toolText("Published \(name) as revision \(result.revisionID); executionSupport=\(result.executionSupport); activated=\(result.activated). If executionSupport is not executable, fix the node configuration and publish again under a new workflowId or ask the user to run it from Automations › Run history.")
            } catch {
                return Self.toolText("Publish failed: \(error.localizedDescription). Check ids (uuid v7 shape), keys (kebab-case), port ids, and schemaRefs against workflow_schema, then retry with a new workflowId.", isError: true)
            }
        case "knowledge_propose":
            guard let path = arguments["path"] as? String, path.hasSuffix(".md"),
                  let content = arguments["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.toolText("knowledge_propose needs a .md path and content.", isError: true)
            }
            guard !writableScopes.isEmpty else {
                return Self.toolText("The user has not granted a writable Obsidian scope, so no note can be proposed. Mention this in your reply instead.", isError: true)
            }
            guard writableScopes.contains(where: { scope in path == scope || path.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/") }) else {
                return Self.toolText("Path must be inside a writable scope: \(writableScopes.joined(separator: ", ")).", isError: true)
            }
            let payload: [String: Any] = [
                "path": path,
                "content": String(content.prefix(32 * 1_024)),
                "rationale": String(((arguments["rationale"] as? String) ?? "").prefix(2_000)),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return Self.toolText("knowledge_propose could not encode the proposal.", isError: true)
            }
            await emit(CodexRunEvent(kind: .nativeProviderEvent, nativeType: "kaname/knowledge_proposal", text: path, payload: data))
            return Self.toolText("Proposal for \(path) queued for the user's review. It is not written yet.")
        default:
            return Self.toolText("Unknown Kaname tool \(name).", isError: true)
        }
    }

    // MARK: Helpers

    private static func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { body["id"] = id }
        return httpResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private static func contentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts[0].lowercased() == "content-length", let value = Int(parts[1]) else { continue }
            return max(0, value)
        }
        return nil
    }

    private static func httpResponse(status: Int, body: Data) -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 204: "No Content"
        case 401: "Unauthorized"
        default: "Bad Request"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if status != 204 { header += "Content-Type: application/json\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
