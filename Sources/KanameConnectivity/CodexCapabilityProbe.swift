@preconcurrency import Foundation
import KanameDomain

private final class JSONLineAccumulator: @unchecked Sendable {
    private var buffered = Data()

    func append(_ chunk: Data) -> [Data] {
        buffered.append(chunk)
        var lines: [Data] = []
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = buffered.prefix(upTo: newline)
            buffered.removeSubrange(...newline)
            lines.append(Data(line))
        }
        return lines
    }

    func finish() -> Data? {
        guard !buffered.isEmpty else { return nil }
        defer { buffered.removeAll(keepingCapacity: false) }
        return buffered
    }
}

enum JSONLineStream {
    static func make(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let accumulator = JSONLineAccumulator()
            handle.readabilityHandler = { readableHandle in
                let chunk = readableHandle.availableData
                guard !chunk.isEmpty else {
                    if let finalLine = accumulator.finish() {
                        continuation.yield(finalLine)
                    }
                    continuation.finish()
                    readableHandle.readabilityHandler = nil
                    return
                }

                for line in accumulator.append(chunk) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

/// The native Codex app-server protocol is newline-delimited JSON-RPC. This
/// intentionally mirrors T3's transport shape: concurrent request tracking,
/// explicit timeout cleanup, and a response to unexpected server requests so a
/// capability probe cannot leave a child process blocked on stdin.
private actor CodexAppServerConnection {
    private let process: RunningLocalProcess
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int: _Concurrency.Task<Void, Never>] = [:]
    private var readerTask: _Concurrency.Task<Void, Never>?
    private var closed = false

    init(process: RunningLocalProcess) {
        self.process = process
    }

    static func start(configuration: ProviderProbeConfiguration) async throws -> CodexAppServerConnection {
        var environment: [String: String] = [:]
        if let home = configuration.codexHome {
            environment["CODEX_HOME"] = home.path()
        }

        let process = try LocalProcess.start(
            executable: configuration.executable,
            arguments: ["app-server"] + configuration.codexLaunchArguments,
            workingDirectory: configuration.workingDirectory,
            environmentOverrides: environment
        )
        let connection = CodexAppServerConnection(process: process)
        await connection.beginReading()
        return connection
    }

    func request(method: String, parameters: [String: Any] = [:], timeout: Duration) async throws -> Data {
        guard !closed else {
            throw ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: process.process.terminationStatus,
                detail: "The app-server process is no longer available."
            )
        }

        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            timeoutTasks[requestID] = _Concurrency.Task { [weak self] in
                try? await _Concurrency.Task.sleep(for: timeout)
                await self?.expireRequest(id: requestID, method: method)
            }

            do {
                try write([
                    "id": requestID,
                    "method": method,
                    "params": parameters,
                ])
            } catch {
                resolve(requestID, with: .failure(error))
            }
        }
    }

    func notify(method: String, parameters: [String: Any] = [:]) throws {
        try write([
            "method": method,
            "params": parameters,
        ])
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        readerTask = nil
        process.standardOutput.readabilityHandler = nil
        for requestID in pending.keys {
            resolve(requestID, with: .failure(ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: process.process.terminationStatus,
                detail: "The capability probe ended."
            )))
        }
        try? process.standardInput.close()
        process.terminate()
    }

    private func beginReading() {
        readerTask = _Concurrency.Task { [weak self, output = process.standardOutput] in
            for await line in JSONLineStream.make(from: output) {
                await self?.receive(line)
            }
            await self?.finishReading()
        }
    }

    private func receive(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let message = object as? [String: Any]
        else {
            return
        }

        if let numericID = message["id"] as? NSNumber {
            let requestID = numericID.intValue
            if message["result"] != nil || message["error"] != nil {
                if let error = message["error"] {
                    resolve(requestID, with: .failure(ProviderConnectivityError.malformedProtocol(
                        "Codex app-server returned an error for request \(requestID): \(Self.compactJSON(error))."
                    )))
                } else if let result = message["result"],
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    resolve(requestID, with: .success(data))
                } else {
                    resolve(requestID, with: .failure(ProviderConnectivityError.malformedProtocol(
                        "Codex app-server returned an unreadable result for request \(requestID)."
                    )))
                }
                return
            }

            // T3 routes server requests to a handler. A read-only probe owns no
            // approval or tool handlers, so fail the request explicitly instead of
            // silently stalling the child process.
            try? write([
                "id": requestID,
                "error": [
                    "code": -32601,
                    "message": "Kaname capability probe has no handler for \(message["method"] as? String ?? "server request").",
                ],
            ])
        }
    }

    private func finishReading() {
        guard !closed else { return }
        closed = true
        for requestID in pending.keys {
            resolve(requestID, with: .failure(ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: process.process.terminationStatus,
                detail: "The app-server input stream ended."
            )))
        }
    }

    private func expireRequest(id: Int, method: String) {
        resolve(id, with: .failure(ProviderConnectivityError.processTimedOut(
            "Timed out waiting for Codex app-server method '\(method)'."
        )))
    }

    private func resolve(_ id: Int, with result: Result<Data, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try process.standardInput.write(contentsOf: data + Data([0x0A]))
    }

    private static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "unstructured error"
        }
        return text
    }
}

enum CodexCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        let connection = try await CodexAppServerConnection.start(configuration: configuration)
        do {
            let initialize = try await object(
                connection.request(
                    method: "initialize",
                    parameters: [
                        "clientInfo": [
                            "name": "kaname",
                            "title": "Kaname",
                            "version": "phase-0",
                        ],
                        "capabilities": ["experimentalApi": true],
                    ],
                    timeout: configuration.timeout
                )
            )
            try await connection.notify(method: "initialized")

            let account = try await object(connection.request(
                method: "account/read",
                timeout: configuration.timeout
            ))
            let hasAccount = account["account"] is [String: Any]
            // T3 gives a returned account precedence over the legacy
            // requiresOpenaiAuth flag. Current Codex builds can include both.
            let requiresAuthentication = !hasAccount && account["requiresOpenaiAuth"] as? Bool == true
            let authentication: ProviderAuthenticationState = hasAccount ? .authenticated : (requiresAuthentication ? .unauthenticated : .unknown)

            let models: [ProviderModel]
            let skills: [String]
            if requiresAuthentication {
                models = []
                skills = []
            } else {
                async let fetchedModels = fetchModels(connection: connection, timeout: configuration.timeout)
                async let fetchedSkills = fetchSkills(
                    connection: connection,
                    workingDirectory: configuration.workingDirectory,
                    timeout: configuration.timeout
                )
                models = try await fetchedModels
                skills = try await fetchedSkills
            }

            await connection.shutdown()
            return ProviderCapabilitySnapshot(
                instance: configuration.instance,
                state: requiresAuthentication ? .authenticationRequired : .ready,
                installed: true,
                version: version(from: initialize),
                authentication: authentication,
                models: models,
                skills: skills,
                detail: requiresAuthentication ? "Codex CLI is installed but requires authentication." : nil
            )
        } catch {
            await connection.shutdown()
            throw error
        }
    }

    private static func fetchModels(connection: CodexAppServerConnection, timeout: Duration) async throws -> [ProviderModel] {
        var cursor: String?
        var models: [ProviderModel] = []
        var pages = 0
        repeat {
            pages += 1
            let response = try await object(connection.request(
                method: "model/list",
                parameters: cursor.map { ["cursor": $0] } ?? [:],
                timeout: timeout
            ))
            let entries = response["data"] as? [[String: Any]] ?? []
            models.append(contentsOf: entries.compactMap { entry in
                guard let id = entry["model"] as? String else { return nil }
                return ProviderModel(
                    id: id,
                    displayName: entry["displayName"] as? String ?? id,
                    isDefault: entry["isDefault"] as? Bool ?? false
                )
            })
            cursor = response["nextCursor"] as? String
        } while cursor != nil && pages < 20
        return models
    }

    private static func fetchSkills(
        connection: CodexAppServerConnection,
        workingDirectory: URL,
        timeout: Duration
    ) async throws -> [String] {
        let response = try await object(connection.request(
            method: "skills/list",
            parameters: ["cwds": [workingDirectory.path()]],
            timeout: timeout
        ))
        let entries = response["data"] as? [[String: Any]] ?? []
        return entries.flatMap { ($0["skills"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
            .sorted()
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderConnectivityError.malformedProtocol("Provider returned an object with an unexpected shape.")
        }
        return object
    }

    private static func version(from initialize: [String: Any]) -> String? {
        guard let userAgent = initialize["userAgent"] as? String,
              let slash = userAgent.lastIndex(of: "/")
        else {
            return nil
        }
        return String(userAgent[userAgent.index(after: slash)...].split(separator: " ").first ?? "")
    }
}
