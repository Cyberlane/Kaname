import Foundation
import Network

/// Fail-closed localhost MCP HTTP bridge that exposes only curated
/// `kaname-preview` tools after an explicit coding.preview_mcp_grant.
public actor KanamePreviewMCPHTTPServer {
    public struct Binding: Sendable, Equatable {
        public let url: URL
        public let bearerToken: String
        public let port: UInt16

        public init(url: URL, bearerToken: String, port: UInt16) {
            self.url = url
            self.bearerToken = bearerToken
            self.port = port
        }
    }

    private var listener: NWListener?
    private var binding: Binding?
    private let queue = DispatchQueue(label: "com.cyberlane.kaname.preview-mcp")

    public init() {}

    public func currentBinding() -> Binding? { binding }

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
                    guard let port = listener.port else {
                        listener.cancel()
                        continuation.resume(throwing: CodexLiveSessionError.malformedResponse("preview MCP port unavailable"))
                        return
                    }
                    let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                    guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/mcp") else {
                        listener.cancel()
                        continuation.resume(throwing: CodexLiveSessionError.malformedResponse("preview MCP URL unavailable"))
                        return
                    }
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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
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
                let headerData = next[..<headerEnd.lowerBound]
                let bodyStart = headerEnd.upperBound
                let headers = String(decoding: headerData, as: UTF8.self)
                let contentLength = Self.contentLength(in: headers) ?? 0
                let body = next[bodyStart...]
                if body.count >= contentLength {
                    let requestBody = Data(body.prefix(contentLength))
                    _Concurrency.Task {
                        let response = await self.handleHTTP(headers: headers, body: requestBody)
                        Self.send(response, on: connection)
                    }
                    return
                }
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: next)
        }
    }

    private func handleHTTP(headers: String, body: Data) -> Data {
        guard headers.hasPrefix("POST "),
              headers.lowercased().contains("authorization: bearer "),
              let binding,
              headers.lowercased().contains(binding.bearerToken.lowercased()) else {
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
                "serverInfo": ["name": CodingPreviewMCPGrant.curatedServerName, "version": "1"],
            ] as [String: Any]
        case "notifications/initialized", "initialized":
            return Self.httpResponse(status: 204, body: Data())
        case "tools/list":
            result = [
                "tools": CodingPreviewMCPGrant.curatedToolAllowlist.map { name in
                    [
                        "name": name,
                        "description": "Curated Kaname preview tool \(name)",
                        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
                    ] as [String: Any]
                },
            ] as [String: Any]
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            guard CodingPreviewMCPGrant.curatedToolAllowlist.contains(name) else {
                let errorBody: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "error": ["code": -32_601, "message": "tool not allowlisted"],
                ]
                let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
                return Self.httpResponse(status: 200, body: data)
            }
            result = [
                "content": [
                    ["type": "text", "text": "Kaname curated tool \(name) acknowledged (desktop preview broker)."],
                ],
                "isError": false,
            ] as [String: Any]
        default:
            let errorBody: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id as Any,
                "error": ["code": -32_601, "message": "method not found"],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: errorBody)) ?? Data()
            return Self.httpResponse(status: 200, body: data)
        }
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { payload["id"] = id }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"jsonrpc":"2.0","result":{}}"#.utf8)
        return Self.httpResponse(status: 200, body: data)
    }

    private static func contentLength(in headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0].lowercased() == "content-length",
                  let value = Int(parts[1]) else { continue }
            return max(0, value)
        }
        return nil
    }

    private static func httpResponse(status: Int, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 401: reason = "Unauthorized"
        default: reason = "Bad Request"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if status != 204 {
            header += "Content-Type: application/json\r\n"
        }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

extension CodexMCPIsolation {
    /// Writes an ephemeral Codex config that enables only `kaname-preview`.
    static func writeCuratedPreviewMCPConfig(
        home: URL,
        binding: KanamePreviewMCPHTTPServer.Binding
    ) throws {
        let config = """
        # Generated by Kaname. Do not copy into ~/.codex.
        [mcp_servers.\(CodingPreviewMCPGrant.curatedServerName)]
        url = "\(binding.url.absoluteString)"
        bearer_token_env_key = "KANAME_PREVIEW_MCP_TOKEN"
        """
        try config.write(
            to: home.appending(path: "config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func curatedPreviewEnvironment(
        home: URL?,
        binding: KanamePreviewMCPHTTPServer.Binding?
    ) -> [String: String] {
        var environment = codexEnvironment(home: home)
        if let binding {
            environment["KANAME_PREVIEW_MCP_TOKEN"] = binding.bearerToken
        }
        return environment
    }
}
