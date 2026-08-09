import Foundation
import KanameProtocol
import SwiftProtobuf

public struct LocalCoreScenarioReport: Codable, Equatable, Sendable {
    public let fixtureID: String
    public let taskState: String
    public let attention: String
    public let health: String
    public let effectCount: UInt64
    public let eventCount: Int
    public let unsupportedEventCount: UInt64

    enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case taskState = "task_state"
        case attention
        case health
        case effectCount = "effect_count"
        case eventCount = "event_count"
        case unsupportedEventCount = "unsupported_event_count"
    }
}

/// A bounded receipt from the Rust authority after it assigns durable ordering
/// to one locally-produced provider event.
public struct LocalCoreEventAppendReport: Codable, Equatable, Sendable {
    public let eventID: String
    public let streamID: String
    public let storePosition: UInt64
    public let streamSequence: UInt64
    public let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case streamID = "stream_id"
        case storePosition = "store_position"
        case streamSequence = "stream_sequence"
        case duplicate
    }
}

public enum LocalCoreRunnerError: Error, Equatable, Sendable {
    case unavailable
    case invalidFixtureID
    case timedOut
    case failed(code: String)
    case malformedReport
    case malformedAppendReport
}

/// The native client and its local Mach service exchange opaque bounded Data.
/// The service owns process dispatch; this client never invokes the Rust core
/// directly or turns a fixture response into authority for a real provider.
#if os(macOS)
@objc(KanameLocalCoreControlService)
public protocol LocalCoreControlService {
    func runScenario(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func appendEvent(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func authorizeAction(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func recordReview(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func replay(_ request: Data, reply: @escaping (Data?, String) -> Void)
}
#endif

public struct LocalCoreRunner: Sendable {
    public static let maximumFixtureIDLength = 4
    public static let maximumResponseBytes = 64 * 1024

    public let machService: String
    public let serviceRequirement: String

    public init(machService: String, serviceRequirement: String) {
        self.machService = machService
        self.serviceRequirement = serviceRequirement
    }

    public static func bundled() -> LocalCoreRunner? {
        guard let machService = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreMachService") as? String,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "KanameLocalCoreServiceRequirement") as? String,
              !machService.isEmpty,
              !requirement.isEmpty else {
            return nil
        }
        return LocalCoreRunner(machService: machService, serviceRequirement: requirement)
    }

    public func runScenario(_ fixtureID: String, timeout: TimeInterval = 5) async throws -> LocalCoreScenarioReport {
        guard fixtureID.range(of: "^F-[0-9]{2}$", options: .regularExpression) != nil,
              fixtureID.count == Self.maximumFixtureIDLength else {
            throw LocalCoreRunnerError.invalidFixtureID
        }
#if os(macOS)
        let output = try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: Data(fixtureID.utf8),
                timeout: timeout
            )
        }.value
        return try Self.decodeScenarioReport(output)
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    /// The request is a generated protobuf wire envelope. The local service,
    /// not SwiftUI or the provider adapter, owns durable ordering and SQLite
    /// mutation. This preserves the same signed-XPC boundary used for Phase 1.
    public func appendEventWire(_ eventWire: Data, timeout: TimeInterval = 5) async throws -> LocalCoreEventAppendReport {
        guard !eventWire.isEmpty, eventWire.count <= Self.maximumResponseBytes else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
#if os(macOS)
        let output = try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: eventWire,
                timeout: timeout,
                operation: .appendEvent
            )
        }.value
        return try Self.decodeEventAppendReport(output)
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    public func authorizeAction(
        _ command: Kaname_V1_ApprovalCommand,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_ApprovalCommandReceipt {
#if os(macOS)
        let output = try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: try command.serializedData(),
                timeout: timeout,
                operation: .authorizeAction
            )
        }.value
        guard output.count <= Self.maximumResponseBytes,
              let receipt = try? Kaname_V1_ApprovalCommandReceipt(serializedBytes: output),
              !receipt.approvalID.isEmpty,
              !receipt.fingerprint.isEmpty,
              receipt.storePosition > 0 else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return receipt
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    public func recordReview(
        _ command: Kaname_V1_CommandEnvelope,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_CommandOutcome {
#if os(macOS)
        let output = try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: try command.serializedData(),
                timeout: timeout,
                operation: .recordReview
            )
        }.value
        guard output.count <= Self.maximumResponseBytes,
              let outcome = try? Kaname_V1_CommandOutcome(serializedBytes: output),
              !outcome.commandID.isEmpty,
              outcome.storePosition > 0 else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return outcome
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    public func replay(
        _ request: Kaname_V1_ReplayRequest,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_ReplayResponse {
#if os(macOS)
        let output = try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: try request.serializedData(),
                timeout: timeout,
                operation: .replay
            )
        }.value
        guard output.count <= Self.maximumResponseBytes,
              let response = try? Kaname_V1_ReplayResponse(serializedBytes: output) else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return response
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    public static func decodeScenarioReport(_ data: Data) throws -> LocalCoreScenarioReport {
        guard data.count <= Self.maximumResponseBytes,
              let report = try? JSONDecoder().decode(LocalCoreScenarioReport.self, from: data),
              report.fixtureID.range(of: "^F-[0-9]{2}$", options: .regularExpression) != nil,
              report.eventCount >= 0 else {
            throw LocalCoreRunnerError.malformedReport
        }
        return report
    }

    public static func decodeEventAppendReport(_ data: Data) throws -> LocalCoreEventAppendReport {
        guard data.count <= Self.maximumResponseBytes,
              let report = try? JSONDecoder().decode(LocalCoreEventAppendReport.self, from: data),
              !report.eventID.isEmpty,
              !report.streamID.isEmpty,
              report.storePosition > 0,
              report.streamSequence > 0 else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return report
    }
}

#if os(macOS)
private enum LocalCoreServiceOperation {
    case scenario
    case appendEvent
    case authorizeAction
    case recordReview
    case replay
}

private func runBoundedService(
    machService: String,
    requirement: String,
    request: Data,
    timeout: TimeInterval,
    operation: LocalCoreServiceOperation = .scenario
) throws -> Data {
    let connection = NSXPCConnection(machServiceName: machService, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: LocalCoreControlService.self)
    connection.setCodeSigningRequirement(requirement)
    let result = LockedResult<Data>()
    let completion = DispatchSemaphore(value: 0)
    connection.interruptionHandler = {
        result.setFailure("connection_interrupted")
        completion.signal()
    }
    connection.invalidationHandler = {
        result.setFailure("connection_invalidated")
        completion.signal()
    }
    connection.activate()
    guard let service = connection.remoteObjectProxyWithErrorHandler({ _ in
        result.setFailure("connection_error")
        completion.signal()
    }) as? LocalCoreControlService else {
        connection.invalidate()
        throw LocalCoreRunnerError.unavailable
    }
    let reply: (Data?, String) -> Void = { response, code in
        if let response, response.count <= LocalCoreRunner.maximumResponseBytes {
            result.setSuccess(response)
        } else {
            result.setFailure(code.isEmpty ? "malformed_response" : code)
        }
        completion.signal()
    }
    switch operation {
    case .scenario: service.runScenario(request, reply: reply)
    case .appendEvent: service.appendEvent(request, reply: reply)
    case .authorizeAction: service.authorizeAction(request, reply: reply)
    case .recordReview: service.recordReview(request, reply: reply)
    case .replay: service.replay(request, reply: reply)
    }
    guard completion.wait(timeout: .now() + timeout) == .success else {
        connection.invalidate()
        throw LocalCoreRunnerError.timedOut
    }
    connection.invalidate()
    switch result.value {
    case let .success(response): return response
    case let .failure(code): throw LocalCoreRunnerError.failed(code: code)
    case nil: throw LocalCoreRunnerError.failed(code: "missing_response")
    }
}

private enum XPCResult<Value> { case success(Value), failure(String) }

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: XPCResult<Value>?

    var value: XPCResult<Value>? { lock.withLock { storage } }

    func setSuccess(_ value: Value) {
        lock.withLock {
            if storage == nil { storage = .success(value) }
        }
    }

    func setFailure(_ code: String) {
        lock.withLock {
            if storage == nil { storage = .failure(code) }
        }
    }
}
#endif
