import Foundation

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

public enum LocalCoreRunnerError: Error, Equatable, Sendable {
    case unavailable
    case invalidFixtureID
    case timedOut
    case failed(code: String)
    case malformedReport
}

/// The native client and its local Mach service exchange opaque bounded Data.
/// The service owns process dispatch; this client never invokes the Rust core
/// directly or turns a fixture response into authority for a real provider.
#if os(macOS)
@objc(KanameLocalCoreControlService)
public protocol LocalCoreControlService {
    func runScenario(_ request: Data, reply: @escaping (Data?, String) -> Void)
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

    public static func decodeScenarioReport(_ data: Data) throws -> LocalCoreScenarioReport {
        guard data.count <= Self.maximumResponseBytes,
              let report = try? JSONDecoder().decode(LocalCoreScenarioReport.self, from: data),
              report.fixtureID.range(of: "^F-[0-9]{2}$", options: .regularExpression) != nil,
              report.eventCount >= 0 else {
            throw LocalCoreRunnerError.malformedReport
        }
        return report
    }
}

#if os(macOS)
private func runBoundedService(
    machService: String,
    requirement: String,
    request: Data,
    timeout: TimeInterval
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
    service.runScenario(request) { response, code in
        if let response, response.count <= LocalCoreRunner.maximumResponseBytes {
            result.setSuccess(response)
        } else {
            result.setFailure(code.isEmpty ? "malformed_response" : code)
        }
        completion.signal()
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
