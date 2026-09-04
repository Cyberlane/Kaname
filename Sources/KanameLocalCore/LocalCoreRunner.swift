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
    func proposeMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func decideMobileDevice(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func recordAuthenticatedMobileSync(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func queryWorkflowLibrary(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func setWorkflowActivation(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func importFrozenWorkspace(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func inspectWorkflowRuns(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func purgeWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func beginWorkflowConnectorObservation(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func settleWorkflowConnectorObservation(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func startWorkflowRun(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func authorizeWorkflowEffect(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func publishWorkflow(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func fanOutWorkflowEvent(_ request: Data, reply: @escaping (Data?, String) -> Void)
    func evaluateWorkflowNodeAvailability(_ request: Data, reply: @escaping (Data?, String) -> Void)
}
#endif

public struct LocalCoreRunner: Sendable {
    public static let maximumFixtureIDLength = 4
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumWorkflowLibraryResponseBytes = 3 * 1024 * 1024
    public static let maximumWorkflowLibraryRequestBytes = 2 * 1024 * 1024

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
        return try await decodedServiceResponse(
            request: Data(fixtureID.utf8),
            timeout: timeout,
            operation: .scenario,
            decode: Self.decodeScenarioReport
        )
    }

    /// The request is a generated protobuf wire envelope. The local service,
    /// not SwiftUI or the provider adapter, owns durable ordering and SQLite
    /// mutation. This preserves the same signed-XPC boundary used for Phase 1.
    public func appendEventWire(_ eventWire: Data, timeout: TimeInterval = 5) async throws -> LocalCoreEventAppendReport {
        guard !eventWire.isEmpty, eventWire.count <= Self.maximumResponseBytes else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return try await decodedServiceResponse(
            request: eventWire,
            timeout: timeout,
            operation: .appendEvent,
            decode: Self.decodeEventAppendReport
        )
    }

    public func authorizeAction(
        _ command: Kaname_V1_ApprovalCommand,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_ApprovalCommandReceipt {
        try await decodedServiceResponse(
            request: command.serializedData(),
            timeout: timeout,
            operation: .authorizeAction,
            decode: Self.decodeApprovalReceipt
        )
    }

    public func recordReview(
        _ command: Kaname_V1_CommandEnvelope,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_CommandOutcome {
        try await decodedServiceResponse(
            request: command.serializedData(),
            timeout: timeout,
            operation: .recordReview,
            decode: Self.decodeCommandOutcome
        )
    }

    public func replay(
        _ request: Kaname_V1_ReplayRequest,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_ReplayResponse {
        try await decodedServiceResponse(
            request: request.serializedData(),
            timeout: timeout,
            operation: .replay,
            decode: Self.decodeReplayResponse
        )
    }

    public func proposeMobileDevice(
        _ challenge: Kaname_V1_DeviceEnrollmentChallenge,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_DeviceEnrollmentReceipt {
        try await decodedServiceResponse(
            request: challenge.serializedData(),
            timeout: timeout,
            operation: .proposeMobileDevice,
            decode: Self.decodeEnrollmentReceipt
        )
    }

    public func decideMobileDevice(
        _ decision: Kaname_V1_DeviceEnrollmentDecision,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_DeviceEnrollmentReceipt {
        try await decodedServiceResponse(
            request: decision.serializedData(),
            timeout: timeout,
            operation: .decideMobileDevice,
            decode: Self.decodeEnrollmentReceipt
        )
    }

    public func recordAuthenticatedMobileSync(
        _ envelope: Kaname_V1_EncryptedSyncEnvelope,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_SyncReceipt {
        try await decodedServiceResponse(
            request: envelope.serializedData(),
            timeout: timeout,
            operation: .recordAuthenticatedMobileSync,
            decode: Self.decodeSyncReceipt
        )
    }

    public func queryWorkflowLibrary(
        _ request: Kaname_V1_WorkflowLibraryQueryRequest,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_WorkflowLibraryQueryResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .queryWorkflowLibrary,
            as: Kaname_V1_WorkflowLibraryQueryResponse.self
        )
    }

    public func setWorkflowActivation(
        _ request: Kaname_V1_SetWorkflowActivationRequest,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_SetWorkflowActivationResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .setWorkflowActivation,
            as: Kaname_V1_SetWorkflowActivationResponse.self
        )
    }

    public func importFrozenWorkspace(
        _ request: Kaname_V1_ImportFrozenWorkspaceRequest,
        timeout: TimeInterval = 15
    ) async throws -> Kaname_V1_ImportFrozenWorkspaceResponse {
        let wire = try request.serializedData()
        guard wire.count <= Self.maximumWorkflowLibraryRequestBytes else {
            throw LocalCoreRunnerError.malformedReport
        }
        return try await workflowLibraryResponse(
            request: wire,
            requestID: request.requestID,
            timeout: timeout,
            operation: .importFrozenWorkspace,
            as: Kaname_V1_ImportFrozenWorkspaceResponse.self
        )
    }

    public func inspectWorkflowRuns(
        _ request: Kaname_V1_WorkflowRunInspectionQuery,
        timeout: TimeInterval = 5
    ) async throws -> Kaname_V1_WorkflowRunInspectionResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .inspectWorkflowRuns,
            as: Kaname_V1_WorkflowRunInspectionResponse.self
        )
    }

    /// Result of starting a durable workflow run on the Rust executor.
    public struct WorkflowRunStartResult: Decodable, Equatable, Sendable {
        public let requestID: String
        public let runID: String
        public let runTokenID: String
        public let outcome: String
        public let eventCount: Int
        public let nextAttemptAtUnixMillis: Int64?
        public let llmHost: String?
        public let capabilityHost: String?
        public let effectHost: String?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case runID = "run_id"
            case runTokenID = "run_token_id"
            case outcome
            case eventCount = "event_count"
            case nextAttemptAtUnixMillis = "next_attempt_at_unix_millis"
            case llmHost = "llm_host"
            case capabilityHost = "capability_host"
            case effectHost = "effect_host"
        }
    }

    public struct WorkflowEffectAuthorizeResult: Decodable, Equatable, Sendable {
        public let requestID: String
        public let effectID: String
        public let status: String
        public let duplicate: Bool

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case effectID = "effect_id"
            case status
            case duplicate
        }
    }

    public struct WorkflowEventFanoutReceipt: Decodable, Equatable, Sendable {
        public let workflowID: String
        public let revisionID: String
        public let runID: String
        public let admission: String
        public let outcome: String

        enum CodingKeys: String, CodingKey {
            case workflowID = "workflowId", revisionID = "revisionId", runID = "runId", admission, outcome
        }
    }

    public struct WorkflowEventFanoutResult: Decodable, Equatable, Sendable {
        public let requestID: String
        public let matched: Int
        public let receipts: [WorkflowEventFanoutReceipt]
        public let errors: [String]

        enum CodingKeys: String, CodingKey {
            case requestID = "requestId", matched, receipts, errors
        }
    }

    /// Offers one external event to every active workflow whose entrypoint is
    /// `trigger.event` with this contract. Deduplicated by the executor.
    public func fanOutWorkflowEvent(
        contract: String,
        eventID: String,
        contractKey: String,
        input: [String: Any],
        timeout: TimeInterval = 600
    ) async throws -> WorkflowEventFanoutResult {
        let requestID = "workflow-event-\(UUID().uuidString.lowercased())"
        let request: [String: Any] = [
            "requestId": requestID,
            "eventContract": contract,
            "eventId": eventID,
            "contractKey": contractKey,
            "input": input,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await serviceResponse(request: data, timeout: timeout, operation: .fanOutWorkflowEvent)
        guard output.count <= Self.maximumWorkflowLibraryResponseBytes,
              let result = try? JSONDecoder().decode(WorkflowEventFanoutResult.self, from: output),
              result.requestID == requestID else {
            throw LocalCoreRunnerError.malformedReport
        }
        return result
    }

    public struct WorkflowPublishResult: Decodable, Equatable, Sendable {
        public let requestID: String
        public let workflowID: String
        public let revisionID: String
        public let packageDigest: String
        public let executionSupport: String
        public let activated: Bool
        public let activationGeneration: Int64

        enum CodingKeys: String, CodingKey {
            case requestID = "requestId", workflowID = "workflowId", revisionID = "revisionId"
            case packageDigest, executionSupport, activated, activationGeneration
        }
    }

    /// Publishes a complete v1 workflow document into the Rust library as a new
    /// revision and optionally activates it.
    public func publishWorkflow(
        workflowID: String,
        packageID: String,
        name: String,
        summary: String,
        workflowJSON: String,
        schemaBundleJSON: String = "",
        dependencyLockJSON: String = "",
        activate: Bool = true,
        timeout: TimeInterval = 30
    ) async throws -> WorkflowPublishResult {
        let requestID = "workflow-publish-\(UUID().uuidString.lowercased())"
        let request: [String: Any] = [
            "requestId": requestID,
            "workflowId": workflowID,
            "packageId": packageID,
            "name": name,
            "summary": summary,
            "workflowJson": workflowJSON,
            "schemaBundleJson": schemaBundleJSON,
            "dependencyLockJson": dependencyLockJSON,
            "activate": activate,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await serviceResponse(request: data, timeout: timeout, operation: .publishWorkflow)
        guard output.count <= Self.maximumWorkflowLibraryResponseBytes,
              let result = try? JSONDecoder().decode(WorkflowPublishResult.self, from: output),
              result.requestID == requestID else {
            throw LocalCoreRunnerError.malformedReport
        }
        return result
    }

    public struct WorkflowNodeAvailabilityQuery: Encodable, Equatable, Sendable {
        public let nodeID: String
        public let type: String
        /// Canonical JSON of the node configuration object.
        public let configJSON: String

        public init(nodeID: String, type: String, configJSON: String) {
            self.nodeID = nodeID
            self.type = type
            self.configJSON = configJSON
        }
    }

    public struct WorkflowNodeAvailabilityDecision: Decodable, Equatable, Sendable {
        public let nodeID: String
        /// `executable` or `schema-only`, as the compiler records it.
        public let availability: String
        /// Compiler condition code when the node is schema-only.
        public let downgradeCondition: String?

        public var isExecutable: Bool { availability == "executable" }

        enum CodingKeys: String, CodingKey {
            case nodeID = "nodeId", availability, downgradeCondition
        }
    }

    private struct WorkflowNodeAvailabilityResult: Decodable {
        let requestId: String
        let nodes: [WorkflowNodeAvailabilityDecision]
    }

    /// Asks the compiler whether each node, as configured, would execute or
    /// stay schema-only, and why. Nothing is published or stored.
    public func evaluateWorkflowNodeAvailability(
        _ nodes: [WorkflowNodeAvailabilityQuery],
        timeout: TimeInterval = 10
    ) async throws -> [WorkflowNodeAvailabilityDecision] {
        guard !nodes.isEmpty else { return [] }
        let requestID = "workflow-node-availability-\(UUID().uuidString.lowercased())"
        let nodeObjects: [[String: Any]] = try nodes.map { node in
            let configData = Data(node.configJSON.utf8)
            let config = (try? JSONSerialization.jsonObject(with: configData)) ?? [String: Any]()
            return ["nodeId": node.nodeID, "type": node.type, "config": config]
        }
        let request: [String: Any] = ["requestId": requestID, "nodes": nodeObjects]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await serviceResponse(request: data, timeout: timeout, operation: .evaluateWorkflowNodeAvailability)
        guard output.count <= Self.maximumWorkflowLibraryResponseBytes,
              let result = try? JSONDecoder().decode(WorkflowNodeAvailabilityResult.self, from: output),
              result.requestId == requestID else {
            throw LocalCoreRunnerError.malformedReport
        }
        return result.nodes
    }

    /// Records the owner's decision for a proposed workflow effect. The run
    /// continues on its next start; nothing is dispatched here.
    public func authorizeWorkflowEffect(
        effectID: String,
        approvalID: String,
        approvalFingerprint: Data,
        approve: Bool,
        timeout: TimeInterval = 10
    ) async throws -> WorkflowEffectAuthorizeResult {
        let requestID = "workflow-effect:\(UUID().uuidString.lowercased())"
        let request: [String: Any] = [
            "request_id": requestID,
            "effect_id": effectID,
            "approval_id": approvalID,
            "fingerprint_hex": approvalFingerprint.map { String(format: "%02x", $0) }.joined(),
            "decision": approve ? "approve" : "reject",
            "actor_id": "local-owner",
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await serviceResponse(request: data, timeout: timeout, operation: .authorizeWorkflowEffect)
        guard output.count <= Self.maximumResponseBytes,
              let result = try? JSONDecoder().decode(WorkflowEffectAuthorizeResult.self, from: output),
              result.requestID == requestID else {
            throw LocalCoreRunnerError.malformedReport
        }
        return result
    }

    /// Starts a manual run of an active, executable workflow revision.
    public func startWorkflowRun(
        workflowID: String,
        revisionID: String,
        runID: String? = nil,
        inputs: [String: Any] = [:],
        timeout: TimeInterval = 600
    ) async throws -> WorkflowRunStartResult {
        let requestID = "workflow-run:\(UUID().uuidString.lowercased())"
        var request: [String: Any] = [
            "request_id": requestID,
            "workflow_id": workflowID,
            "revision_id": revisionID,
            "inputs": inputs,
        ]
        if let runID { request["run_id"] = runID }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let output = try await serviceResponse(request: data, timeout: timeout, operation: .startWorkflowRun)
        guard output.count <= Self.maximumResponseBytes,
              let result = try? JSONDecoder().decode(WorkflowRunStartResult.self, from: output),
              result.requestID == requestID else {
            throw LocalCoreRunnerError.malformedReport
        }
        return result
    }

    public func purgeWorkflowRun(
        _ request: Kaname_V1_PurgeWorkflowRunRequest,
        timeout: TimeInterval = 15
    ) async throws -> Kaname_V1_PurgeWorkflowRunResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .purgeWorkflowRun,
            as: Kaname_V1_PurgeWorkflowRunResponse.self
        )
    }

    public func beginWorkflowConnectorObservation(
        _ request: Kaname_V1_BeginWorkflowConnectorObservationRequest,
        timeout: TimeInterval = 15
    ) async throws -> Kaname_V1_BeginWorkflowConnectorObservationResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .beginWorkflowConnectorObservation,
            as: Kaname_V1_BeginWorkflowConnectorObservationResponse.self
        )
    }

    public func settleWorkflowConnectorObservation(
        _ request: Kaname_V1_SettleWorkflowConnectorObservationRequest,
        timeout: TimeInterval = 15
    ) async throws -> Kaname_V1_SettleWorkflowConnectorObservationResponse {
        try await workflowLibraryResponse(
            request: request.serializedData(),
            requestID: request.requestID,
            timeout: timeout,
            operation: .settleWorkflowConnectorObservation,
            as: Kaname_V1_SettleWorkflowConnectorObservationResponse.self
        )
    }

    private func serviceResponse(
        request: Data,
        timeout: TimeInterval,
        operation: LocalCoreServiceOperation
    ) async throws -> Data {
#if os(macOS)
        return try await Task.detached(priority: .userInitiated) {
            try runBoundedService(
                machService: machService,
                requirement: serviceRequirement,
                request: request,
                timeout: timeout,
                operation: operation
            )
        }.value
#else
        throw LocalCoreRunnerError.unavailable
#endif
    }

    private func decodedServiceResponse<Response>(
        request: Data,
        timeout: TimeInterval,
        operation: LocalCoreServiceOperation,
        decode: (Data) throws -> Response
    ) async throws -> Response {
        try decode(await serviceResponse(request: request, timeout: timeout, operation: operation))
    }

    private func workflowLibraryResponse<Response: WorkflowLibraryWireResponse>(
        request: Data,
        requestID: String,
        timeout: TimeInterval,
        operation: LocalCoreServiceOperation,
        as _: Response.Type
    ) async throws -> Response {
        let output = try await serviceResponse(
            request: request,
            timeout: timeout,
            operation: operation
        )
        guard output.count <= operation.maximumResponseBytes,
              let response = try? Response(serializedBytes: output),
              response.requestID == requestID,
              response.schemaVersion.major == 1 else {
            throw LocalCoreRunnerError.malformedReport
        }
        return response
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

    private static func decodeApprovalReceipt(_ data: Data) throws -> Kaname_V1_ApprovalCommandReceipt {
        guard data.count <= Self.maximumResponseBytes,
              let receipt = try? Kaname_V1_ApprovalCommandReceipt(serializedBytes: data),
              !receipt.approvalID.isEmpty,
              !receipt.fingerprint.isEmpty,
              receipt.storePosition > 0 else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return receipt
    }

    private static func decodeCommandOutcome(_ data: Data) throws -> Kaname_V1_CommandOutcome {
        guard data.count <= Self.maximumResponseBytes,
              let outcome = try? Kaname_V1_CommandOutcome(serializedBytes: data),
              !outcome.commandID.isEmpty,
              outcome.storePosition > 0 else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return outcome
    }

    private static func decodeReplayResponse(_ data: Data) throws -> Kaname_V1_ReplayResponse {
        guard data.count <= Self.maximumResponseBytes,
              let response = try? Kaname_V1_ReplayResponse(serializedBytes: data) else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return response
    }

    public static func decodeEnrollmentReceipt(
        _ data: Data
    ) throws -> Kaname_V1_DeviceEnrollmentReceipt {
        guard data.count <= Self.maximumResponseBytes,
              let receipt = try? Kaname_V1_DeviceEnrollmentReceipt(serializedBytes: data),
              !receipt.enrollmentID.isEmpty,
              !receipt.deviceID.isEmpty,
              receipt.state != .unspecified else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return receipt
    }

    public static func decodeSyncReceipt(_ data: Data) throws -> Kaname_V1_SyncReceipt {
        guard data.count <= Self.maximumResponseBytes,
              let receipt = try? Kaname_V1_SyncReceipt(serializedBytes: data),
              !receipt.envelopeID.isEmpty,
              !receipt.senderDeviceID.isEmpty,
              receipt.senderSequence > 0,
              receipt.state != .unspecified else {
            throw LocalCoreRunnerError.malformedAppendReport
        }
        return receipt
    }
}

private protocol WorkflowLibraryWireResponse: Message {
    var schemaVersion: Kaname_V1_SchemaVersion { get }
    var requestID: String { get }
}

extension Kaname_V1_WorkflowLibraryQueryResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_SetWorkflowActivationResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_ImportFrozenWorkspaceResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_WorkflowRunInspectionResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_PurgeWorkflowRunResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_BeginWorkflowConnectorObservationResponse: WorkflowLibraryWireResponse {}
extension Kaname_V1_SettleWorkflowConnectorObservationResponse: WorkflowLibraryWireResponse {}

#if os(macOS)
private enum LocalCoreServiceOperation {
    case scenario
    case appendEvent
    case authorizeAction
    case recordReview
    case replay
    case proposeMobileDevice
    case decideMobileDevice
    case recordAuthenticatedMobileSync
    case queryWorkflowLibrary
    case setWorkflowActivation
    case importFrozenWorkspace
    case inspectWorkflowRuns
    case purgeWorkflowRun
    case beginWorkflowConnectorObservation
    case settleWorkflowConnectorObservation
    case startWorkflowRun
    case authorizeWorkflowEffect
    case publishWorkflow
    case fanOutWorkflowEvent
    case evaluateWorkflowNodeAvailability

    var maximumResponseBytes: Int {
        switch self {
        case .queryWorkflowLibrary, .importFrozenWorkspace, .inspectWorkflowRuns,
             .purgeWorkflowRun:
            LocalCoreRunner.maximumWorkflowLibraryResponseBytes
        default: LocalCoreRunner.maximumResponseBytes
        }
    }
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
        if let response, response.count <= operation.maximumResponseBytes {
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
    case .proposeMobileDevice: service.proposeMobileDevice(request, reply: reply)
    case .decideMobileDevice: service.decideMobileDevice(request, reply: reply)
    case .recordAuthenticatedMobileSync: service.recordAuthenticatedMobileSync(request, reply: reply)
    case .queryWorkflowLibrary: service.queryWorkflowLibrary(request, reply: reply)
    case .setWorkflowActivation: service.setWorkflowActivation(request, reply: reply)
    case .importFrozenWorkspace: service.importFrozenWorkspace(request, reply: reply)
    case .inspectWorkflowRuns: service.inspectWorkflowRuns(request, reply: reply)
    case .purgeWorkflowRun: service.purgeWorkflowRun(request, reply: reply)
    case .beginWorkflowConnectorObservation:
        service.beginWorkflowConnectorObservation(request, reply: reply)
    case .settleWorkflowConnectorObservation:
        service.settleWorkflowConnectorObservation(request, reply: reply)
    case .startWorkflowRun:
        service.startWorkflowRun(request, reply: reply)
    case .authorizeWorkflowEffect:
        service.authorizeWorkflowEffect(request, reply: reply)
    case .publishWorkflow:
        service.publishWorkflow(request, reply: reply)
    case .fanOutWorkflowEvent:
        service.fanOutWorkflowEvent(request, reply: reply)
    case .evaluateWorkflowNodeAvailability:
        service.evaluateWorkflowNodeAvailability(request, reply: reply)
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
