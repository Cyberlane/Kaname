import Darwin
import Foundation

@objc(XPCQualificationService)
protocol XPCQualificationService {
    func roundTrip(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func crash()
}

private final class ReplayService: NSObject, XPCQualificationService {
    private let core: QualificationCore

    init(core: QualificationCore) {
        self.core = core
    }

    func roundTrip(_ request: Data, reply: @escaping (Data?, String) -> Void) {
        guard request.count <= QualificationCore.maximumRequestBytes else {
            reply(nil, "request_too_large")
            return
        }

        do {
            reply(try core.roundTrip(request), "")
        } catch let error as QualificationError {
            reply(nil, error.code)
        } catch {
            reply(nil, "core_failed")
        }
    }

    func crash() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) {
            exit(0)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: QualificationCore

    init(core: QualificationCore) {
        self.core = core
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: XPCQualificationService.self)
        newConnection.exportedObject = ReplayService(core: core)
        newConnection.activate()
        return true
    }
}

private enum QualificationError: Error {
    case usage
    case missingRequirement
    case missingMachService
    case missingCore
    case requestFailed(String)
    case unexpectedResponse(String)
    case childFailed(mode: String, status: Int32)
    case rejectedClientWasAccepted

    var code: String {
        switch self {
        case .usage: "usage"
        case .missingRequirement: "missing_requirement"
        case .missingMachService: "missing_mach_service"
        case .missingCore: "missing_core"
        case let .requestFailed(code): code
        case let .unexpectedResponse(code): code
        case .childFailed: "child_failed"
        case .rejectedClientWasAccepted: "rejected_client_accepted"
        }
    }
}

private struct Arguments {
    let mode: String
    let requirement: String
    let machService: String?
    let coreExecutable: URL?

    init(_ arguments: [String]) throws {
        guard let mode = arguments.dropFirst().first else { throw QualificationError.usage }
        guard let requirement = Self.value(after: "--requirement", in: arguments) else {
            throw QualificationError.missingRequirement
        }
        self.mode = mode
        self.requirement = requirement
        machService = Self.value(after: "--mach-service", in: arguments)
        coreExecutable = Self.value(after: "--core-executable", in: arguments).map(URL.init(fileURLWithPath:))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

@main
private enum KanameXPCQualification {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            switch arguments.mode {
            case "--run":
                try run(requirement: arguments.requirement, core: try requireCore(arguments.coreExecutable))
            case "--host":
                try host(
                    machService: try requireMachService(arguments.machService),
                    requirement: arguments.requirement,
                    core: try requireCore(arguments.coreExecutable)
                )
            case "--client":
                try qualifiedClient(
                    machService: try requireMachService(arguments.machService),
                    requirement: arguments.requirement
                )
            case "--reconnect-client":
                try reconnectClient(
                    machService: try requireMachService(arguments.machService),
                    requirement: arguments.requirement
                )
            case "--unqualified-client":
                try rejectedClient(
                    machService: try requireMachService(arguments.machService),
                    requirement: arguments.requirement
                )
            default:
                throw QualificationError.usage
            }
        } catch let error as QualificationError {
            FileHandle.standardError.write(Data("error: \(error.code)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: unexpected_failure\n".utf8))
            exit(1)
        }
    }

    private static func requireMachService(_ value: String?) throws -> String {
        guard let value else { throw QualificationError.missingMachService }
        return value
    }

    private static func requireCore(_ value: URL?) throws -> URL {
        guard let value else { throw QualificationError.missingCore }
        return value
    }

    private static func host(machService: String, requirement: String, core: URL) throws {
        let listener = NSXPCListener(machServiceName: machService)
        let delegate = ListenerDelegate(core: QualificationCore(executable: core))
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.activate()
        withExtendedLifetime(delegate) { dispatchMain() }
    }

    private static func run(requirement: String, core: URL) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let launchAgent = try LaunchAgent.start(executable: executable, requirement: requirement, core: core)
        defer { launchAgent.stop() }

        do {
            try runChild(
                executable: executable,
                mode: "--client",
                machService: launchAgent.machService,
                requirement: requirement,
                mustSucceed: true
            )
        } catch {
            launchAgent.writeDiagnostics()
            throw error
        }

        try launchAgent.restart()
        try runChild(
            executable: executable,
            mode: "--reconnect-client",
            machService: launchAgent.machService,
            requirement: requirement,
            mustSucceed: true
        )

        let unqualifiedClient = try makeAdHocSignedCopy(of: executable)
        defer { try? FileManager.default.removeItem(at: unqualifiedClient.deletingLastPathComponent()) }
        try runChild(
            executable: unqualifiedClient,
            mode: "--unqualified-client",
            machService: launchAgent.machService,
            requirement: requirement,
            mustSucceed: true
        )

        print("PASS: signed admission, crash/reconnect, opaque Rust protobuf round trips, unknown type preservation, and bounds")
    }

    private static func qualifiedClient(machService: String, requirement: String) throws {
        let known = QualificationEnvelope(
            schemaMajor: 1,
            typeURL: "kaname.event.run.started.v1",
            payload: Data([0x08, 0x01]),
            cursor: Data("cursor-v1".utf8),
            operation: "replay"
        )
        let knownResponse = try invoke(machService: machService, requirement: requirement, request: known.encoded())
        guard try QualificationEnvelope.decode(knownResponse) == known else {
            throw QualificationError.unexpectedResponse("known_semantics_changed")
        }

        let unknown = QualificationEnvelope(
            schemaMajor: 1,
            typeURL: "kaname.event.future.unsupported.v9",
            payload: Data([0x08, 0x96, 0x01]),
            cursor: Data("future-cursor".utf8),
            operation: "replay"
        )
        let unknownResponse = try invoke(machService: machService, requirement: requirement, request: unknown.encoded())
        guard try QualificationEnvelope.decode(unknownResponse) == unknown else {
            throw QualificationError.unexpectedResponse("unknown_payload_not_preserved")
        }

        try expectError(
            machService: machService,
            requirement: requirement,
            request: Data([0x80]),
            expected: "malformed_envelope"
        )
        try expectError(
            machService: machService,
            requirement: requirement,
            request: QualificationEnvelope(
                schemaMajor: 2, typeURL: known.typeURL, payload: known.payload, cursor: known.cursor, operation: "replay"
            ).encoded(),
            expected: "unsupported_protocol_major"
        )
        try expectError(
            machService: machService,
            requirement: requirement,
            request: QualificationEnvelope(
                schemaMajor: 1, typeURL: known.typeURL, payload: known.payload, cursor: Data("expired".utf8), operation: "replay"
            ).encoded(),
            expected: "expired_cursor"
        )
        try expectError(
            machService: machService,
            requirement: requirement,
            request: QualificationEnvelope(
                schemaMajor: 1, typeURL: known.typeURL, payload: known.payload, cursor: known.cursor, operation: "wait_for_change"
            ).encoded(),
            expected: "unsupported_operation"
        )
        try expectError(
            machService: machService,
            requirement: requirement,
            request: Data(repeating: 0, count: QualificationCore.maximumRequestBytes + 1),
            expected: "request_too_large"
        )

        try benchmark(machService: machService, requirement: requirement, request: known.encoded())
        try assertCrashInterruption(machService: machService, requirement: requirement)
    }

    private static func reconnectClient(machService: String, requirement: String) throws {
        let request = QualificationEnvelope.fixture.encoded()
        let response = try invoke(machService: machService, requirement: requirement, request: request)
        guard try QualificationEnvelope.decode(response) == QualificationEnvelope.fixture else {
            throw QualificationError.unexpectedResponse("reconnect_changed_replay")
        }
    }

    private static func rejectedClient(machService: String, requirement: String) throws {
        do {
            _ = try invoke(
                machService: machService,
                requirement: requirement,
                request: QualificationEnvelope.fixture.encoded()
            )
            throw QualificationError.rejectedClientWasAccepted
        } catch let error as QualificationError where error.code == "connection_error" || error.code == "connection_invalidated" {
            return
        } catch let error as QualificationError {
            throw QualificationError.unexpectedResponse("unqualified_client_\(error.code)")
        }
    }

    private static func expectError(
        machService: String,
        requirement: String,
        request: Data,
        expected: String
    ) throws {
        do {
            _ = try invoke(machService: machService, requirement: requirement, request: request)
            throw QualificationError.unexpectedResponse("missing_\(expected)")
        } catch let error as QualificationError where error.code == expected {
            return
        } catch let error as QualificationError {
            throw QualificationError.unexpectedResponse("expected_\(expected)_received_\(error.code)")
        }
    }

    private static func assertCrashInterruption(machService: String, requirement: String) throws {
        let connection = makeConnection(machService: machService, requirement: requirement)
        let interruption = DispatchSemaphore(value: 0)
        connection.interruptionHandler = { interruption.signal() }
        connection.invalidationHandler = { interruption.signal() }
        connection.activate()

        guard let service = connection.remoteObjectProxyWithErrorHandler({ _ in interruption.signal() }) as? XPCQualificationService else {
            throw QualificationError.requestFailed("missing_remote_interface")
        }
        service.crash()
        guard interruption.wait(timeout: .now() + 2) == .success else {
            connection.invalidate()
            throw QualificationError.requestFailed("missing_interruption")
        }
        connection.invalidate()
    }

    private static func benchmark(machService: String, requirement: String, request: Data) throws {
        var samples: [Double] = []
        samples.reserveCapacity(25)
        for _ in 0..<25 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try invoke(machService: machService, requirement: requirement, request: request)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            samples.append(elapsed)
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let p99 = samples[Int(Double(samples.count - 1) * 0.99)]
        print("MEASURE: Q-01 XPC+Rust one-envelope replay n=25 p50=\(format(samples[12]))ms p95=\(format(p95))ms p99=\(format(p99))ms")
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }

    private static func invoke(machService: String, requirement: String, request: Data) throws -> Data {
        let connection = makeConnection(machService: machService, requirement: requirement)
        let result = LockedResult<Data>()
        let completion = DispatchSemaphore(value: 0)
        connection.invalidationHandler = { result.setFailure("connection_invalidated"); completion.signal() }
        connection.activate()

        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            result.setFailure("connection_error")
            completion.signal()
        }) as? XPCQualificationService else {
            connection.invalidate()
            throw QualificationError.requestFailed("missing_remote_interface")
        }
        service.roundTrip(request) { response, errorCode in
            if let response {
                result.setSuccess(response)
            } else {
                result.setFailure(errorCode.isEmpty ? "missing_response" : errorCode)
            }
            completion.signal()
        }

        guard completion.wait(timeout: .now() + 3) == .success else {
            connection.invalidate()
            throw QualificationError.requestFailed("timeout")
        }
        connection.invalidate()
        switch result.value {
        case let .success(response): return response
        case let .failure(code): throw QualificationError.requestFailed(code)
        case nil: throw QualificationError.requestFailed("missing_result")
        }
    }

    private static func makeConnection(machService: String, requirement: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: XPCQualificationService.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    private static func runChild(
        executable: URL,
        mode: String,
        machService: String,
        requirement: String,
        mustSucceed: Bool
    ) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = [mode, "--mach-service", machService, "--requirement", requirement]
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let diagnostic = standardError.fileHandleForReading.readDataToEndOfFile()
        guard (process.terminationStatus == 0) == mustSucceed else {
            if !diagnostic.isEmpty { FileHandle.standardError.write(diagnostic) }
            throw QualificationError.childFailed(mode: mode, status: process.terminationStatus)
        }
    }

    private static func makeAdHocSignedCopy(of executable: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-xpc-qualification-\(UUID().uuidString)", isDirectory: true)
        let copy = directory.appendingPathComponent("unqualified-client")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: copy)
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", copy.path]
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw QualificationError.childFailed(mode: "ad_hoc_signing", status: codesign.terminationStatus)
        }
        return copy
    }
}

private final class QualificationCore {
    static let maximumRequestBytes = 64 * 1024
    private let executable: URL

    init(executable: URL) {
        self.executable = executable
    }

    func roundTrip(_ request: Data) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["round-trip"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        var frame = withUnsafeBytes(of: UInt32(request.count).bigEndian) { Data($0) }
        frame.append(request)
        input.fileHandleForWriting.write(frame)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let status = response.first else {
            throw QualificationError.requestFailed("core_failed")
        }
        if status == 0 { return response.dropFirst() }
        let code = String(decoding: response.dropFirst(), as: UTF8.self)
        throw QualificationError.requestFailed(code.isEmpty ? "core_failed" : code)
    }
}

private struct QualificationEnvelope: Equatable {
    let schemaMajor: UInt64
    let typeURL: String
    let payload: Data
    let cursor: Data
    let operation: String

    static let fixture = QualificationEnvelope(
        schemaMajor: 1,
        typeURL: "kaname.event.run.started.v1",
        payload: Data([0x08, 0x01]),
        cursor: Data("cursor-v1".utf8),
        operation: "replay"
    )

    func encoded() -> Data {
        var data = Data()
        appendVarint(field: 1, value: schemaMajor, to: &data)
        appendBytes(field: 2, value: Data(typeURL.utf8), to: &data)
        appendBytes(field: 3, value: payload, to: &data)
        appendBytes(field: 4, value: cursor, to: &data)
        appendBytes(field: 5, value: Data(operation.utf8), to: &data)
        return data
    }

    static func decode(_ data: Data) throws -> QualificationEnvelope {
        var offset = 0
        var schemaMajor: UInt64?
        var typeURL: String?
        var payload: Data?
        var cursor: Data?
        var operation: String?

        while offset < data.count {
            let key = try readVarint(data, offset: &offset)
            let field = Int(key >> 3)
            let wireType = key & 7
            switch (field, wireType) {
            case (1, 0): schemaMajor = try readVarint(data, offset: &offset)
            case (2, 2): typeURL = try readString(data, offset: &offset)
            case (3, 2): payload = try readBytes(data, offset: &offset)
            case (4, 2): cursor = try readBytes(data, offset: &offset)
            case (5, 2): operation = try readString(data, offset: &offset)
            default: try skip(wireType: wireType, data: data, offset: &offset)
            }
        }
        guard let schemaMajor, let typeURL, let payload, let cursor, let operation else {
            throw QualificationError.requestFailed("malformed_envelope")
        }
        return QualificationEnvelope(
            schemaMajor: schemaMajor, typeURL: typeURL, payload: payload, cursor: cursor, operation: operation
        )
    }

    private func appendVarint(field: UInt64, value: UInt64, to data: inout Data) {
        appendRawVarint(field << 3, to: &data)
        appendRawVarint(value, to: &data)
    }

    private func appendBytes(field: UInt64, value: Data, to data: inout Data) {
        appendRawVarint((field << 3) | 2, to: &data)
        appendRawVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private func appendRawVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    private static func readVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw QualificationError.requestFailed("malformed_envelope") }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return result }
        }
        throw QualificationError.requestFailed("malformed_envelope")
    }

    private static func readBytes(_ data: Data, offset: inout Int) throws -> Data {
        let count = try readVarint(data, offset: &offset)
        guard count <= UInt64(data.count - offset), count <= UInt64(QualificationCore.maximumRequestBytes) else {
            throw QualificationError.requestFailed("malformed_envelope")
        }
        let end = offset + Int(count)
        defer { offset = end }
        return data[offset..<end]
    }

    private static func readString(_ data: Data, offset: inout Int) throws -> String {
        guard let value = String(data: try readBytes(data, offset: &offset), encoding: .utf8) else {
            throw QualificationError.requestFailed("malformed_envelope")
        }
        return value
    }

    private static func skip(wireType: UInt64, data: Data, offset: inout Int) throws {
        switch wireType {
        case 0: _ = try readVarint(data, offset: &offset)
        case 2: _ = try readBytes(data, offset: &offset)
        default: throw QualificationError.requestFailed("malformed_envelope")
        }
    }
}

private struct LaunchAgent {
    let label: String
    let machService: String
    private let plist: URL
    private let errorLog: URL

    static func start(executable: URL, requirement: String, core: URL) throws -> LaunchAgent {
        let label = "com.cyberlane.kaname.xpcqualification.\(UUID().uuidString.lowercased())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(label, isDirectory: true)
        let plist = directory.appendingPathComponent("\(label).plist")
        let errorLog = directory.appendingPathComponent("host.stderr.log")
        let arguments = [
            executable.path, "--host", "--mach-service", label,
            "--requirement", requirement, "--core-executable", core.path,
        ]
        let propertyList: [String: Any] = [
            "Label": label, "MachServices": [label: true], "ProgramArguments": arguments,
            "KeepAlive": true,
            "StandardErrorPath": errorLog.path,
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        return LaunchAgent(label: label, machService: label, plist: plist, errorLog: errorLog)
    }

    func stop() {
        try? Self.launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist.deletingLastPathComponent())
    }

    func restart() throws {
        Thread.sleep(forTimeInterval: 0.1)
        try Self.launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    func writeDiagnostics() {
        guard let data = try? Data(contentsOf: errorLog), !data.isEmpty else { return }
        FileHandle.standardError.write(data)
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw QualificationError.childFailed(mode: "launchctl", status: process.terminationStatus)
        }
    }
}

private enum XPCResult<Value> { case success(Value), failure(String) }

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: XPCResult<Value>?
    var value: XPCResult<Value>? { lock.withLock { storage } }
    func setSuccess(_ value: Value) { lock.withLock { storage = .success(value) } }
    func setFailure(_ message: String) {
        lock.withLock { if storage == nil { storage = .failure(message) } }
    }
}
