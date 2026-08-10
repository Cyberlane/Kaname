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
enum CodexAppServerRequestID: Sendable, Equatable {
    case integer(Int)
    case string(String)

    var jsonValue: Any {
        switch self {
        case let .integer(value): value
        case let .string(value): value
        }
    }

    var stableValue: String {
        switch self {
        case let .integer(value): "integer-\(value)"
        case let .string(value): "string-\(value)"
        }
    }
}

enum CodexAppServerIncomingMessage: Sendable {
    case notification(method: String, parameters: Data)
    case serverRequest(id: CodexAppServerRequestID, method: String, parameters: Data)
    case processExited(status: Int32, standardError: String)
}

actor CodexAppServerConnection {
    private let process: RunningLocalProcess
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int: _Concurrency.Task<Void, Never>] = [:]
    private var readerTask: _Concurrency.Task<Void, Never>?
    private var messageContinuations: [UUID: AsyncStream<CodexAppServerIncomingMessage>.Continuation] = [:]
    private var closed = false
    private var messageStreamOverflowed = false
    private var unsafeMCPStartupObserved = false

    init(process: RunningLocalProcess) {
        self.process = process
    }

    static func start(configuration: ProviderProbeConfiguration) async throws -> CodexAppServerConnection {
        let environment = processEnvironment(codexHome: configuration.codexHome)

        let process = try LocalProcess.start(
            executable: configuration.executable,
            arguments: ["app-server"] + configuration.codexLaunchArguments,
            workingDirectory: configuration.workingDirectory,
            environmentOverrides: environment,
            environmentRemovals: CodexMCPIsolation.inheritedEnvironmentRemovals()
        )
        let connection = CodexAppServerConnection(process: process)
        await connection.beginReading()
        return connection
    }

    static func processEnvironment(codexHome: URL?) -> [String: String] {
        codexHome.map { ["CODEX_HOME": $0.path] } ?? [:]
    }

    func request(
        method: String,
        parameters: [String: Any] = [:],
        notificationAfterSend: String? = nil,
        timeout: Duration
    ) async throws -> Data {
        guard !closed else {
            throw ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: -1,
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
                try writeEncoded(Self.encodedRequestSequence(
                    method: method,
                    parameters: parameters,
                    requestID: requestID,
                    notificationAfterSend: notificationAfterSend
                ))
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

    func messages() -> AsyncStream<CodexAppServerIncomingMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CodexAppServerIncomingMessage.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        messageContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            _Concurrency.Task { await self?.removeMessageContinuation(id) }
        }
        return stream
    }

    func didMessageStreamOverflow() -> Bool {
        messageStreamOverflowed
    }

    func didObserveUnsafeMCPStartup() -> Bool {
        unsafeMCPStartupObserved
    }

    func respond(id: CodexAppServerRequestID, result: [String: Any]) throws {
        try write([
            "id": id.jsonValue,
            "result": result,
        ])
    }

    func reject(id: CodexAppServerRequestID, method: String) throws {
        try write([
            "id": id.jsonValue,
            "error": [
                "code": -32601,
                "message": "Kaname has no handler for \(method).",
            ],
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
                status: -1,
                detail: "The capability probe ended."
            )))
        }
        finishMessageStreams()
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

        if let requestID = Self.requestID(from: message["id"]) {
            if message["result"] != nil || message["error"] != nil {
                guard case let .integer(localRequestID) = requestID else { return }
                if let error = message["error"] {
                    resolve(localRequestID, with: .failure(ProviderConnectivityError.malformedProtocol(
                        "Codex app-server returned an error for request \(localRequestID): \(Self.compactJSON(error))."
                    )))
                } else if let result = message["result"],
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    resolve(localRequestID, with: .success(data))
                } else {
                    resolve(localRequestID, with: .failure(ProviderConnectivityError.malformedProtocol(
                        "Codex app-server returned an unreadable result for request \(localRequestID)."
                    )))
                }
                return
            }

            guard let method = message["method"] as? String else { return }
            guard !messageContinuations.isEmpty else {
                // Capability discovery has no consumer for server-initiated
                // requests.  Retain its original fail-closed behaviour rather
                // than letting an unexpected approval/tool callback stall the
                // bounded read-only probe.
                try? reject(id: requestID, method: method)
                return
            }
            publish(.serverRequest(
                id: requestID,
                method: method,
                parameters: Self.encodedParameters(from: message)
            ))
            return
        }

        if let method = message["method"] as? String {
            let parameters = Self.encodedParameters(from: message)
            if CodexMCPIsolation.indicatesUnsafeStartup(method: method, parameters: parameters) {
                unsafeMCPStartupObserved = true
            }
            publish(.notification(
                method: method,
                parameters: parameters
            ))
        }
    }

    private func finishReading() {
        guard !closed else { return }
        closed = true
        process.waitForExit()
        for requestID in pending.keys {
            resolve(requestID, with: .failure(ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: process.process.terminationStatus,
                detail: "The app-server input stream ended."
            )))
        }
        let errorData = process.standardError.availableData
        let standardError = String(decoding: errorData.prefix(8 * 1024), as: UTF8.self)
        publish(.processExited(status: process.process.terminationStatus, standardError: standardError))
        finishMessageStreams()
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

    private func publish(_ message: CodexAppServerIncomingMessage) {
        var dropped = false
        for continuation in messageContinuations.values {
            if case .dropped = continuation.yield(message) {
                dropped = true
            }
        }
        if dropped {
            failForMessageStreamOverflow()
        }
    }

    private func failForMessageStreamOverflow() {
        guard !closed else { return }
        messageStreamOverflowed = true
        closed = true
        readerTask?.cancel()
        readerTask = nil
        process.standardOutput.readabilityHandler = nil
        for requestID in pending.keys {
            resolve(requestID, with: .failure(ProviderConnectivityError.processExited(
                command: "codex app-server",
                status: -1,
                detail: "Kaname stopped Codex because its bounded provider-event buffer overflowed."
            )))
        }
        let failure = CodexAppServerIncomingMessage.processExited(
            status: -1,
            standardError: "Kaname stopped Codex because its bounded provider-event buffer overflowed."
        )
        for continuation in messageContinuations.values {
            _ = continuation.yield(failure)
            continuation.finish()
        }
        messageContinuations.removeAll()
        try? process.standardInput.close()
        process.terminate()
    }

    private func removeMessageContinuation(_ id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    private func finishMessageStreams() {
        for continuation in messageContinuations.values {
            continuation.finish()
        }
        messageContinuations.removeAll()
    }

    private func write(_ object: [String: Any]) throws {
        try writeEncoded(Self.encodedJSONLine(object))
    }

    private func writeEncoded(_ data: Data) throws {
        try process.standardInput.write(contentsOf: data)
    }

    static func encodedRequestSequence(
        method: String,
        parameters: [String: Any],
        requestID: Int,
        notificationAfterSend: String?
    ) throws -> Data {
        var encoded = try encodedJSONLine([
            "id": requestID,
            "method": method,
            "params": parameters,
        ])
        if let notificationAfterSend {
            encoded.append(try encodedJSONLine([
                "method": notificationAfterSend,
                "params": [:],
            ]))
        }
        return encoded
    }

    private static func encodedJSONLine(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data + Data([0x0A])
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

    private static func encodedParameters(from message: [String: Any]) -> Data {
        let parameters = message["params"] ?? [:]
        return (try? JSONSerialization.data(withJSONObject: parameters, options: [])) ?? Data("{}".utf8)
    }

    private static func requestID(from value: Any?) -> CodexAppServerRequestID? {
        if let number = value as? NSNumber {
            return .integer(number.intValue)
        }
        if let string = value as? String, !string.isEmpty {
            return .string(string)
        }
        return nil
    }
}

enum CodexCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        let isolatedHome: CodexEphemeralHome
        do {
            isolatedHome = try CodexEphemeralHome.create(sourceHome: configuration.codexHome)
        } catch {
            throw CodexLiveSessionError.isolatedHomeUnavailable
        }
        defer { try? isolatedHome.cleanup() }
        let launchArguments = try await CodexMCPIsolation.launchArguments(
            executable: configuration.executable,
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout,
            codexHome: isolatedHome.url,
            baseArguments: configuration.codexLaunchArguments
        )
        let isolatedConfiguration = ProviderProbeConfiguration(
            instance: configuration.instance,
            executable: configuration.executable,
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout,
            codexHome: isolatedHome.url,
            codexLaunchArguments: launchArguments,
            openCode: configuration.openCode
        )
        let connection = try await CodexAppServerConnection.start(configuration: isolatedConfiguration)
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
                    notificationAfterSend: "initialized",
                    timeout: configuration.timeout
                )
            )
            try await attestRuntimeIsolation(connection)

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
            try await attestRuntimeIsolation(connection)

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

    private static func attestRuntimeIsolation(_ connection: CodexAppServerConnection) async throws {
        try await _Concurrency.Task.sleep(for: CodexMCPIsolation.attestationObservationWindow)
        guard !(await connection.didMessageStreamOverflow()) else {
            throw ProviderConnectivityError.malformedProtocol(
                "Codex capability events overflowed the bounded observation stream."
            )
        }
        guard !(await connection.didObserveUnsafeMCPStartup()) else {
            throw CodexLiveSessionError.unexpectedMCPActivity
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
            parameters: ["cwds": [workingDirectory.path]],
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
