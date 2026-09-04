import CryptoKit
import Darwin
import Foundation
import KanameLocalCore
import Network

private enum ServiceError: Error {
    case usage
    case missingMachService
    case missingRequirement
    case missingCore
    case launchFailure
}

private struct Arguments {
    enum Mode { case host, install }

    let mode: Mode
    let machService: String
    let requirement: String
    let coreExecutable: URL
    let journalDirectory: URL
    let launchAgentPlist: URL?
    let localDeviceID: String?
    let localKeyID: String?

    init(_ arguments: [String]) throws {
        switch arguments.dropFirst().first {
        case "--host": mode = .host
        case "--install": mode = .install
        default: throw ServiceError.usage
        }
        guard let machService = Self.value(after: "--mach-service", in: arguments), !machService.isEmpty else {
            throw ServiceError.missingMachService
        }
        guard let requirement = Self.value(after: "--requirement", in: arguments), !requirement.isEmpty else {
            throw ServiceError.missingRequirement
        }
        guard let core = Self.value(after: "--core-executable", in: arguments) else {
            throw ServiceError.missingCore
        }
        guard let journalDirectory = Self.value(after: "--journal-directory", in: arguments) else {
            throw ServiceError.usage
        }
        self.machService = machService
        self.requirement = requirement
        coreExecutable = URL(fileURLWithPath: core)
        self.journalDirectory = URL(fileURLWithPath: journalDirectory, isDirectory: true)
        launchAgentPlist = Self.value(after: "--launch-agent-plist", in: arguments).map(URL.init(fileURLWithPath:))
        let localDeviceID = Self.value(after: "--local-device-id", in: arguments)
        let localKeyID = Self.value(after: "--local-key-id", in: arguments)
        guard (localDeviceID == nil) == (localKeyID == nil) else {
            throw ServiceError.usage
        }
        self.localDeviceID = localDeviceID
        self.localKeyID = localKeyID
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        zip(arguments, arguments.dropFirst())
            .first(where: { current, _ in current == flag })?
            .1
    }
}

private final class LocalControlService: NSObject, LocalCoreControlService {
    private let coreExecutable: URL
    private let journalDirectory: URL
    private let localDeviceID: String?
    private let localKeyID: String?

    init(
        coreExecutable: URL,
        journalDirectory: URL,
        localDeviceID: String?,
        localKeyID: String?
    ) {
        (self.coreExecutable, self.journalDirectory) = (coreExecutable, journalDirectory)
        (self.localDeviceID, self.localKeyID) = (localDeviceID, localKeyID)
    }

    /// `<Application Support>/Kaname…`, two levels above `LocalCore/journal`.
    var applicationSupportRoot: URL {
        journalDirectory.deletingLastPathComponent().deletingLastPathComponent()
    }

    func runScenario(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard request.count == LocalCoreRunner.maximumFixtureIDLength,
              let fixtureID = String(data: request, encoding: .utf8),
              fixtureID.range(of: "^F-[0-9]{2}$", options: .regularExpression) != nil else {
            reply(nil, "invalid_fixture")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("\(fixtureID).sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: ["scenario-store", fixtureID, journal.path],
                journal: journal,
                standardInput: nil,
                timeout: 5
            )
            _ = try LocalCoreRunner.decodeScenarioReport(response)
            reply(response, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    func appendEvent(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard !request.isEmpty, request.count <= LocalCoreRunner.maximumResponseBytes else {
            reply(nil, "invalid_event")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("live-provider.sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: [
                    "append-event",
                    journal.path,
                ],
                journal: journal,
                standardInput: request,
                timeout: 5
            )
            _ = try LocalCoreRunner.decodeEventAppendReport(response)
            reply(response, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    func authorizeAction(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("authorize-action", request: request, reply: reply)
    }

    func recordReview(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("record-review", request: request, reply: reply)
    }

    func replay(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("replay", request: request, reply: reply)
    }

    func proposeMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("mobile-propose", request: request, reply: reply)
    }

    func decideMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation("mobile-decide", request: request, reply: reply)
    }

    func recordAuthenticatedMobileSync(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard let localDeviceID, let localKeyID else {
            reply(nil, "mobile_not_configured")
            return
        }
        runWireOperation(
            "mobile-admit",
            request: request,
            extraArguments: [localDeviceID, localKeyID],
            reply: reply
        )
    }

    func queryWorkflowLibrary(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation("workflow-library-query", request: request, reply: reply)
    }

    func setWorkflowActivation(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation("workflow-library-activate", request: request, reply: reply)
    }

    func importFrozenWorkspace(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWorkflowLibraryOperation(
            "workflow-library-import-frozen",
            request: request,
            maximumRequestBytes: LocalCoreRunner.maximumWorkflowLibraryRequestBytes,
            reply: reply
        )
    }

    func inspectWorkflowRuns(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-run-inspect",
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    func startWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        // Runs may wait on model calls and connectors; the run itself is
        // durable, so a long deadline here only bounds this one attempt.
        runWireOperation(
            "workflow-run-start",
            request: request,
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: projection,
            timeout: 600,
            reply: reply
        )
    }

    func fanOutWorkflowEvent(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-event-fanout",
            request: request,
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: projection,
            timeout: 600,
            reply: reply
        )
    }

    func publishWorkflow(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        runWireOperation(
            "workflow-library-publish",
            request: request,
            extraArguments: [applicationSupportRoot.path],
            maximumRequestBytes: LocalCoreRunner.maximumWorkflowLibraryRequestBytes,
            timeout: 30,
            reply: reply
        )
    }

    func evaluateWorkflowNodeAvailability(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        runWireOperation(
            "workflow-node-availability",
            request: request,
            maximumRequestBytes: LocalCoreRunner.maximumWorkflowLibraryRequestBytes,
            timeout: 10,
            reply: reply
        )
    }

    func authorizeWorkflowEffect(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-effect-authorize",
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    /// Fires due interval schedules. Called by the host timer; the core
    /// derives every run identity from the scheduled instant, so a repeated
    /// tick is idempotent.
    func runScheduleTick() {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        let schedules = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("schedules.json")
        guard FileManager.default.fileExists(atPath: schedules.path) else { return }
        runWireOperation(
            "workflow-schedule-tick",
            request: Data("{}".utf8),
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: projection,
            timeout: 600
        ) { _, _ in }
    }

    func purgeWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            "workflow-run-purge",
            request: request,
            extraArguments: [projection.path, applicationSupportRoot.path],
            permissionTarget: applicationSupportRoot
                .appendingPathComponent("Objects", isDirectory: true)
                .appendingPathComponent("workflow-storage.sqlite"),
            reply: reply
        )
    }

    func beginWorkflowConnectorObservation(
        _ request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        runWorkflowConnectorObservationOperation(
            "workflow-connector-observation-begin", request: request, reply: reply
        )
    }

    func settleWorkflowConnectorObservation(
        _ request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        runWorkflowConnectorObservationOperation(
            "workflow-connector-observation-settle", request: request, reply: reply
        )
    }

    private func runWorkflowConnectorObservationOperation(
        _ operation: String,
        request: Data,
        reply: @escaping (Data?, String) -> Void
    ) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projection = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("workflow-run-projection.sqlite")
        runWireOperation(
            operation,
            request: request,
            extraArguments: [projection.path],
            permissionTarget: projection,
            reply: reply
        )
    }

    private func runWorkflowLibraryOperation(
        _ operation: String,
        request: Data,
        maximumRequestBytes: Int = LocalCoreRunner.maximumResponseBytes,
        reply: @escaping (Data?, String) -> Void
    ) {
        let applicationSupportRoot = journalDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        runWireOperation(
            operation,
            request: request,
            maximumRequestBytes: maximumRequestBytes,
            storageArgument: applicationSupportRoot,
            permissionTarget: applicationSupportRoot
                .appendingPathComponent("Workflows", isDirectory: true)
                .appendingPathComponent("workflow-library.sqlite"),
            reply: reply
        )
    }

    private func runWireOperation(
        _ operation: String,
        request: Data,
        extraArguments: [String] = [],
        maximumRequestBytes: Int = LocalCoreRunner.maximumResponseBytes,
        storageArgument: URL? = nil,
        permissionTarget: URL? = nil,
        timeout: TimeInterval = 5,
        reply: @escaping (Data?, String) -> Void
    ) {
        guard !request.isEmpty, request.count <= maximumRequestBytes else {
            reply(nil, "invalid_request")
            return
        }
        do {
            let journal = journalDirectory.appendingPathComponent("live-provider.sqlite")
            let response = try Self.runCore(
                executable: coreExecutable,
                arguments: [
                    operation,
                    (storageArgument ?? journal).path,
                ] + extraArguments,
                journal: journal,
                permissionTarget: permissionTarget ?? journal,
                standardInput: request,
                timeout: timeout
            )
            guard let wire = Self.decodeHexResponse(response) else {
                reply(nil, "core_failed")
                return
            }
            reply(wire, "")
        } catch let error as LocalCoreRunnerError {
            switch error {
            case .timedOut: reply(nil, "core_timed_out")
            default: reply(nil, "core_failed")
            }
        } catch {
            reply(nil, "core_failed")
        }
    }

    private static func decodeHexResponse(_ response: Data) -> Data? {
        let text = String(decoding: response, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }

    private static func runCore(
        executable: URL,
        arguments: [String],
        journal: URL,
        permissionTarget: URL? = nil,
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> Data {
        let applicationSupportRoot = journal
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recoveryLock = try KanameRuntimeRecoveryFileLock.acquireShared(
            applicationSupportRoot: applicationSupportRoot
        )
        defer { withExtendedLifetime(recoveryLock) {} }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalCoreRunnerError.unavailable
        }
        let journalDirectory = journal.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        guard chmod(journalDirectory.path, 0o700) == 0 else {
            throw LocalCoreRunnerError.unavailable
        }
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = input
        // The workflow LLM host ships beside the core; the executor only uses it
        // when this variable names an executable that describes a model class.
        var environment = ProcessInfo.processInfo.environment
        let llmHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowLlmHost")
        if FileManager.default.isExecutableFile(atPath: llmHost.path) {
            environment["KANAME_WORKFLOW_LLM_COMMAND"] = llmHost.path
        }
        let capabilityHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowCapabilityHost")
        if FileManager.default.isExecutableFile(atPath: capabilityHost.path) {
            environment["KANAME_WORKFLOW_CAPABILITY_COMMAND"] = capabilityHost.path
        }
        let connectorHost = executable.deletingLastPathComponent().appendingPathComponent("KanameWorkflowConnectorHost")
        if FileManager.default.isExecutableFile(atPath: connectorHost.path) {
            environment["KANAME_WORKFLOW_EFFECT_COMMAND"] = connectorHost.path
        }
        process.environment = environment
        let timedOut = LockedFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        timer.resume()
        defer { timer.cancel() }
        try process.run()
        if let standardInput {
            try input.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        _ = standardError.fileHandleForReading.readDataToEndOfFile()
        if timedOut.value { throw LocalCoreRunnerError.timedOut }
        guard process.terminationStatus == 0 else {
            throw LocalCoreRunnerError.failed(code: "core_failed")
        }
        let permissionTarget = permissionTarget ?? journal
        guard chmod(permissionTarget.path, 0o600) == 0 else {
            throw LocalCoreRunnerError.failed(code: "journal_permissions")
        }
        return output
    }
}

/// Loopback HTTP endpoint that turns `POST /hook/<eventContract>` into a
/// `trigger.event` fan-out on the Rust executor. Runs inside the launchd
/// agent, so it accepts events while the desktop app is closed. The port and
/// bearer token persist in `Workflows/webhook-endpoint.json` so the URL stays
/// stable across restarts and the app can show it. Loopback only: anything
/// outside this Mac reaches it through a tunnel the owner sets up.
private final class WebhookListener: @unchecked Sendable {
    private struct Endpoint: Codable {
        var port: UInt16
        var token: String
    }

    private let service: LocalControlService
    private let endpointURL: URL
    private let queue = DispatchQueue(label: "com.cyberlane.kaname.webhooks")
    private let workQueue = DispatchQueue(label: "com.cyberlane.kaname.webhooks.fanout", qos: .utility)
    private var listener: NWListener?
    private var endpoint: Endpoint?
    private static let maximumBodyBytes = 1_048_576

    init(service: LocalControlService, applicationSupportRoot: URL) {
        self.service = service
        endpointURL = applicationSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("webhook-endpoint.json")
    }

    func start() {
        let stored = loadEndpoint()
        let token = stored?.token ?? Self.freshToken()
        if let stored, bind(port: stored.port, token: token) { return }
        _ = bind(port: 0, token: token)
    }

    private func loadEndpoint() -> Endpoint? {
        guard let data = try? Data(contentsOf: endpointURL) else { return nil }
        return try? JSONDecoder().decode(Endpoint.self, from: data)
    }

    private func saveEndpoint(_ endpoint: Endpoint) {
        let directory = endpointURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(endpoint) else { return }
        try? data.write(to: endpointURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)
    }

    private static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bind(port: UInt16, token: String) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let requested = NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
        guard let listener = try? NWListener(using: parameters) else { return false }
        let ready = DispatchSemaphore(value: 0)
        let outcome = BindOutcome()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                if let bound = listener.port?.rawValue {
                    let endpoint = Endpoint(port: bound, token: token)
                    self.endpoint = endpoint
                    self.saveEndpoint(endpoint)
                    outcome.succeeded = true
                }
                ready.signal()
            case .failed, .cancelled:
                listener.stateUpdateHandler = nil
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if outcome.succeeded {
            self.listener = listener
        } else {
            listener.cancel()
        }
        return outcome.succeeded
    }

    /// Written once on the listener queue before the semaphore is signalled.
    private final class BindOutcome: @unchecked Sendable {
        var succeeded = false
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
                if contentLength > Self.maximumBodyBytes {
                    Self.send(Self.httpResponse(status: 413, body: Data(#"{"error":"payload too large"}"#.utf8)), on: connection)
                    return
                }
                let body = next[headerEnd.upperBound...]
                if body.count >= contentLength {
                    let response = self.handle(headers: headers, body: Data(body.prefix(contentLength)))
                    Self.send(response, on: connection)
                    return
                }
            }
            if isComplete || next.count > Self.maximumBodyBytes + 65_536 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: next)
        }
    }

    private func handle(headers: String, body: Data) -> Data {
        guard let requestLine = headers.split(separator: "\r\n").first else {
            return Self.httpResponse(status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else {
            return Self.httpResponse(status: 405, body: Data(#"{"error":"POST /hook/<eventContract> only"}"#.utf8))
        }
        guard let token = endpoint?.token,
              headers.lowercased().contains("authorization: bearer \(token)") else {
            return Self.httpResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        guard path.hasPrefix("/hook/") else {
            return Self.httpResponse(status: 404, body: Data(#"{"error":"unknown path"}"#.utf8))
        }
        let contract = String(path.dropFirst("/hook/".count)).removingPercentEncoding ?? ""
        guard Self.isEventContract(contract) else {
            return Self.httpResponse(status: 400, body: Data(#"{"error":"event contract must match ^[a-z][a-z0-9.-]{0,239}$"}"#.utf8))
        }
        var input: [String: Any]
        if body.isEmpty {
            input = [:]
        } else if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            input = object
        } else if let array = try? JSONSerialization.jsonObject(with: body) {
            input = ["payload": array]
        } else {
            input = ["payloadText": String(decoding: body.prefix(65_536), as: UTF8.self)]
        }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let eventID = (input["eventId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "webhook:\(contract):\(digest)"
        let contractKey = (input["contractKey"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? eventID
        input["receivedAtUnixMillis"] = Int64(Date().timeIntervalSince1970 * 1_000)
        input["source"] = "webhook"
        let requestID = "workflow-event-\(UUID().uuidString.lowercased())"
        let request: [String: Any] = [
            "requestId": requestID,
            "eventContract": contract,
            "eventId": eventID,
            "contractKey": contractKey,
            "input": input,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return Self.httpResponse(status: 400, body: Data(#"{"error":"body is not JSON"}"#.utf8))
        }
        // The fan-out can take a while (it starts runs); answer now and let it run.
        workQueue.async { [service] in
            service.fanOutWorkflowEvent(data) { _, _ in }
        }
        let accepted: [String: Any] = ["accepted": true, "eventContract": contract, "eventId": eventID]
        return Self.httpResponse(status: 202, body: (try? JSONSerialization.data(withJSONObject: accepted)) ?? Data())
    }

    private static func isEventContract(_ value: String) -> Bool {
        value.range(of: "^[a-z][a-z0-9.-]{0,239}$", options: .regularExpression) != nil
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
        case 202: "Accepted"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Bad Request"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        header += "Content-Type: application/json\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Polls the authenticated `gh` user's notification inbox every three minutes
/// and offers each new or updated entry to the executor as a
/// `github.notification.received` event. Lives in the launchd agent so it
/// keeps working with the desktop app closed; `gh` holds its own login. Seen
/// entries persist in `Workflows/github-cursors.json`; the first poll only
/// records what already exists. Skips the network entirely until a workflow
/// library exists.
private final class GitHubNotificationPoller: @unchecked Sendable {
    static let eventContract = "github.notification.received"

    private let service: LocalControlService
    private let cursorsURL: URL
    private let libraryURL: URL
    private let queue = DispatchQueue(label: "com.cyberlane.kaname.github-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isPolling = false

    init(service: LocalControlService, applicationSupportRoot: URL) {
        self.service = service
        let workflows = applicationSupportRoot.appendingPathComponent("Workflows", isDirectory: true)
        cursorsURL = workflows.appendingPathComponent("github-cursors.json")
        libraryURL = workflows.appendingPathComponent("workflow-library.sqlite")
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 90, repeating: 180)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private static var ghExecutable: URL? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private struct Notification: Decodable {
        struct Subject: Decodable {
            let title: String?
            let url: String?
            let type: String?
        }
        struct Repository: Decodable { let full_name: String? }
        let id: String
        let reason: String?
        let unread: Bool?
        let updated_at: String?
        let subject: Subject?
        let repository: Repository?
    }

    private func poll() {
        guard !isPolling, FileManager.default.fileExists(atPath: libraryURL.path), let gh = Self.ghExecutable else { return }
        isPolling = true
        defer { isPolling = false }
        guard let data = runGh(gh, arguments: ["api", "notifications?per_page=50&all=true"]),
              let notifications = try? JSONDecoder().decode([Notification].self, from: data) else { return }
        let seen = loadCursors()
        let baseline = seen.isEmpty
        var next: [String: String] = [:]
        for notification in notifications {
            let updatedAt = notification.updated_at ?? ""
            next[notification.id] = updatedAt
            guard !baseline, seen[notification.id] != updatedAt else { continue }
            let subjectURL = notification.subject?.url ?? ""
            let eventID = "github:notification:\(notification.id):\(updatedAt)"
            let request: [String: Any] = [
                "requestId": "workflow-event-\(UUID().uuidString.lowercased())",
                "eventContract": Self.eventContract,
                "eventId": eventID,
                "contractKey": subjectURL.isEmpty ? notification.id : subjectURL,
                "input": [
                    "notificationId": notification.id,
                    "reason": notification.reason ?? "",
                    "unread": notification.unread ?? false,
                    "updatedAt": updatedAt,
                    "repository": notification.repository?.full_name ?? "",
                    "subjectTitle": notification.subject?.title ?? "",
                    "subjectType": notification.subject?.type ?? "",
                    "subjectUrl": subjectURL,
                    "provider": "github",
                    "source": "control-service",
                ] as [String: Any],
            ]
            guard let payload = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else { continue }
            let done = DispatchSemaphore(value: 0)
            service.fanOutWorkflowEvent(payload) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 600)
        }
        next["_baseline"] = seen["_baseline"] ?? ISO8601DateFormatter().string(from: Date())
        saveCursors(next)
    }

    private func runGh(_ executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = environment
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        defer { timer.cancel() }
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 4 * 1_048_576 else { return nil }
        return data
    }

    private func loadCursors() -> [String: String] {
        guard let data = try? Data(contentsOf: cursorsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    private func saveCursors(_ cursors: [String: String]) {
        let directory = cursorsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONSerialization.data(withJSONObject: cursors, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: cursorsURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorsURL.path)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: LocalControlService

    init(service: LocalControlService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        configure(connection)
        return true
    }

    private func configure(_ connection: NSXPCConnection) {
        connection.exportedInterface = NSXPCInterface(with: LocalCoreControlService.self)
        connection.exportedObject = service
        connection.activate()
    }
}

@main
private enum KanameLocalControlServiceMain {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            switch arguments.mode {
            case .host:
                let listener = NSXPCListener(machServiceName: arguments.machService)
                let service = LocalControlService(
                    coreExecutable: arguments.coreExecutable,
                    journalDirectory: arguments.journalDirectory,
                    localDeviceID: arguments.localDeviceID,
                    localKeyID: arguments.localKeyID
                )
                let delegate = ListenerDelegate(service: service)
                listener.delegate = delegate
                listener.setConnectionCodeSigningRequirement(arguments.requirement)
                listener.activate()
                // Scheduled workflows run from this long-lived agent, so they
                // fire even when the desktop app is closed.
                let scheduler = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.cyberlane.kaname.scheduler"))
                scheduler.schedule(deadline: .now() + 30, repeating: 60)
                scheduler.setEventHandler { service.runScheduleTick() }
                scheduler.resume()
                // Webhooks land here too, so external systems can start
                // workflows while the desktop app is closed.
                let webhooks = WebhookListener(service: service, applicationSupportRoot: service.applicationSupportRoot)
                webhooks.start()
                // GitHub notifications poll from here as well: gh keeps its own
                // credentials, so no app session is needed.
                let github = GitHubNotificationPoller(service: service, applicationSupportRoot: service.applicationSupportRoot)
                github.start()
                withExtendedLifetime((delegate, scheduler, webhooks, github)) { dispatchMain() }
            case .install:
                try LaunchAgent.install(arguments)
            }
        } catch {
            FileHandle.standardError.write(Data("kaname-local-control-service: configuration failed\n".utf8))
            exit(64)
        }
    }
}

private enum LaunchAgent {
    static func install(_ arguments: Arguments) throws {
        guard let plist = arguments.launchAgentPlist else { throw ServiceError.usage }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let errorLog = plist.deletingLastPathComponent().appendingPathComponent("kaname-local-control-service.stderr.log")
        var programArguments = [
            executable.path, "--host", "--mach-service", arguments.machService,
            "--requirement", arguments.requirement,
            "--core-executable", arguments.coreExecutable.path,
            "--journal-directory", arguments.journalDirectory.path,
        ]
        if let localDeviceID = arguments.localDeviceID,
           let localKeyID = arguments.localKeyID {
            programArguments += [
                "--local-device-id", localDeviceID,
                "--local-key-id", localKeyID,
            ]
        }
        let propertyList: [String: Any] = [
            "Label": arguments.machService,
            "MachServices": [arguments.machService: true],
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardErrorPath": errorLog.path,
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try? launchctl(["bootout", "gui/\(getuid())/\(arguments.machService)"])
        try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ServiceError.launchFailure }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func set() { lock.withLock { storage = true } }
}
