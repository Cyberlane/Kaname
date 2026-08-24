import Foundation

public enum KanameLinkAdminOperation: String, Codable, Sendable {
    case hostSnapshot
    case createInvite
    case approve
    case deny
    case publish
}

public enum KanameLinkAdminPayload: Equatable, Sendable, Encodable {
    case empty
    case createInvite(
        spaceID: String,
        spaceName: String,
        gatewayURL: String,
        expiresInSeconds: UInt64
    )
    case device(deviceID: String)
    case publish(spaceID: String, body: String, messageID: String)

    private enum CodingKeys: String, CodingKey {
        case spaceID
        case spaceName
        case gatewayURL = "gatewayUrl"
        case expiresInSeconds
        case deviceID
        case body
        case messageID
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            break
        case let .createInvite(spaceID, spaceName, gatewayURL, expiresInSeconds):
            try values.encode(spaceID, forKey: .spaceID)
            try values.encode(spaceName, forKey: .spaceName)
            try values.encode(gatewayURL, forKey: .gatewayURL)
            try values.encode(expiresInSeconds, forKey: .expiresInSeconds)
        case let .device(deviceID):
            try values.encode(deviceID, forKey: .deviceID)
        case let .publish(spaceID, body, messageID):
            try values.encode(spaceID, forKey: .spaceID)
            try values.encode(body, forKey: .body)
            try values.encode(messageID, forKey: .messageID)
        }
    }
}

/// Exact `GatewayAdminRequest` envelope accepted by the canonical Rust shell.
public struct KanameLinkAdminRequest: Equatable, Sendable, Encodable {
    public let schemaVersion: Int
    public let requestID: String
    public let operation: KanameLinkAdminOperation
    public let payload: KanameLinkAdminPayload

    public static func hostSnapshot(
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> KanameLinkAdminRequest {
        try KanameLinkAdminRequest(
            requestID: requestID,
            operation: .hostSnapshot,
            payload: .empty
        )
    }

    public static func createInvite(
        requestID: String = UUID().uuidString.lowercased(),
        request: KanameLinkInvitationRequest,
        gatewayURL: String
    ) throws -> KanameLinkAdminRequest {
        try KanameLinkAdminRequest(
            requestID: requestID,
            operation: .createInvite,
            payload: .createInvite(
                spaceID: request.spaceID,
                spaceName: request.spaceName,
                gatewayURL: gatewayURL,
                expiresInSeconds: request.expiresInSeconds
            )
        )
    }

    public static func deviceDecision(
        requestID: String = UUID().uuidString.lowercased(),
        deviceID: String,
        decision: KanameLinkDeviceDecision
    ) throws -> KanameLinkAdminRequest {
        try KanameLinkSnapshotContract.validatePublicIdentifier(deviceID)
        return try KanameLinkAdminRequest(
            requestID: requestID,
            operation: decision == .approve ? .approve : .deny,
            payload: .device(deviceID: deviceID)
        )
    }

    public static func publish(
        requestID: String = UUID().uuidString.lowercased(),
        spaceID: String,
        body: String,
        messageID: String
    ) throws -> KanameLinkAdminRequest {
        try KanameLinkSnapshotContract.validatePublicIdentifier(spaceID)
        try KanameLinkSnapshotContract.validatePublicIdentifier(messageID)
        try KanameLinkSnapshotContract.validateReplyBody(body)
        return try KanameLinkAdminRequest(
            requestID: requestID,
            operation: .publish,
            payload: .publish(spaceID: spaceID, body: body, messageID: messageID)
        )
    }

    private init(
        requestID: String,
        operation: KanameLinkAdminOperation,
        payload: KanameLinkAdminPayload
    ) throws {
        try KanameLinkSnapshotContract.validatePublicIdentifier(requestID)
        schemaVersion = 1
        self.requestID = requestID
        self.operation = operation
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestID
        case operation
        case payload
    }
}

public struct KanameLinkAdminFailure: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

public struct KanameLinkAdminResponse<Result: Codable & Equatable & Sendable>:
    Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let ok: Bool
    public let result: Result?
    public let errorCode: String?
    public let error: KanameLinkAdminFailure?

    public init(
        schemaVersion: Int = 1,
        requestID: String,
        ok: Bool,
        result: Result? = nil,
        errorCode: String? = nil,
        error: KanameLinkAdminFailure? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.errorCode = errorCode
        self.error = error
    }
}

public protocol KanameLinkAdminCommandRunning: Sendable {
    /// Returns one already size-bounded response document. Interpretation is
    /// operation-specific and remains in `KanameLinkProcessGatewayService`.
    func execute(_ request: KanameLinkAdminRequest) async throws -> Data
}

public actor KanameLinkProcessGatewayService: KanameLinkGatewayService {
    public static let gatewayURL = "https://kaname-tunnel.cyber-lane.com"

    private let runner: any KanameLinkAdminCommandRunning
    private let nowUnixMillis: @Sendable () -> Int64

    public init(
        runner: any KanameLinkAdminCommandRunning,
        nowUnixMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.runner = runner
        self.nowUnixMillis = nowUnixMillis
    }

    public func fetchSnapshot() async throws -> KanameLinkGatewaySnapshot {
        let request = try KanameLinkAdminRequest.hostSnapshot()
        let raw: RustHostShellSnapshot = try await execute(request, as: RustHostShellSnapshot.self)
        return try Self.map(raw, observedAtUnixMillis: nowUnixMillis())
    }

    public func createInvitation(
        request invitationRequest: KanameLinkInvitationRequest
    ) async throws -> KanameLinkInvitationArtifact {
        let request = try KanameLinkAdminRequest.createInvite(
            request: invitationRequest,
            gatewayURL: Self.gatewayURL
        )
        let invitation: KanameLinkInvitationArtifact = try await execute(
            request,
            as: KanameLinkInvitationArtifact.self
        )
        guard invitation.spaceID == invitationRequest.spaceID,
              invitation.spaceName == invitationRequest.spaceName,
              invitation.gatewayURL == Self.gatewayURL,
              invitation.expiresAtUnixMillis > nowUnixMillis() else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
        return invitation
    }

    public func decidePendingDevice(
        id: String,
        decision: KanameLinkDeviceDecision
    ) async throws {
        let request = try KanameLinkAdminRequest.deviceDecision(
            deviceID: id,
            decision: decision
        )
        let device: RustDeviceSummary = try await execute(request, as: RustDeviceSummary.self)
        guard device.deviceID == id,
              device.state == (decision == .approve ? "approved" : "revoked") else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
    }

    public func publishReply(
        spaceID: String,
        body: String
    ) async throws -> KanameLinkReplyReceipt {
        let messageID = "message-\(UUID().uuidString.lowercased())"
        let request = try KanameLinkAdminRequest.publish(
            spaceID: spaceID,
            body: body,
            messageID: messageID
        )
        let receipt: KanameLinkReplyReceipt = try await execute(
            request,
            as: KanameLinkReplyReceipt.self
        )
        guard receipt.messageID == messageID,
              !receipt.state.isEmpty,
              receipt.state.utf8.count <= 64 else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
        return receipt
    }

    private func execute<Result: Codable & Equatable & Sendable>(
        _ request: KanameLinkAdminRequest,
        as _: Result.Type
    ) async throws -> Result {
        let responseData = try await runner.execute(request)
        let response: KanameLinkAdminResponse<Result>
        do {
            response = try JSONDecoder().decode(
                KanameLinkAdminResponse<Result>.self,
                from: responseData
            )
        } catch {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
        guard response.schemaVersion == 1,
              response.requestID == request.requestID else {
            throw KanameLinkProcessRunnerError.responseCorrelationMismatch
        }
        if response.ok {
            guard response.errorCode == nil,
                  response.error == nil,
                  let result = response.result else {
                throw KanameLinkProcessRunnerError.malformedResponse
            }
            return result
        }
        guard response.result == nil,
              let code = response.errorCode,
              let error = response.error,
              error.code == code,
              !code.isEmpty,
              code.utf8.count <= 64 else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
        throw KanameLinkGatewayServiceError.gatewayRejected(
            code: code,
            message: "The bundled Link gateway rejected this bounded operation."
        )
    }

    private static func map(
        _ raw: RustHostShellSnapshot,
        observedAtUnixMillis: Int64
    ) throws -> KanameLinkGatewaySnapshot {
        guard raw.schemaVersion == 1,
              raw.status.schemaVersion == 1,
              raw.status.spaceCount == UInt64(raw.spaces.count),
              raw.status.pendingDeviceCount == UInt64(raw.pendingDevices.count),
              raw.spaces.count <= KanameLinkSnapshotContract.maximumSpaces,
              raw.pendingDevices.count <= KanameLinkSnapshotContract.maximumPendingDevices,
              raw.inbox.count <= KanameLinkSnapshotContract.maximumInboxMessages else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }

        var names: [String: String] = [:]
        for space in raw.spaces {
            guard names.updateValue(space.name, forKey: space.spaceID) == nil else {
                throw KanameLinkProcessRunnerError.malformedResponse
            }
        }
        let pendingCounts = Dictionary(grouping: raw.pendingDevices, by: \.spaceID)
            .mapValues(\.count)
        let inboxBySpace = Dictionary(grouping: raw.inbox, by: \.spaceID)
        let lastActivityBySpace = inboxBySpace.compactMapValues { messages in
            messages.map(\.hostReceivedAtUnixMillis).max()
        }

        let spaces = try raw.spaces.map { space in
            try KanameLinkSnapshotContract.validatePublicIdentifier(space.spaceID)
            try KanameLinkSnapshotContract.validateSpaceName(space.name)
            let deviceCount = try checkedInt(space.deviceCount)
            let messageCount = try checkedInt(space.messageCount)
            let externalCount = inboxBySpace[space.spaceID]?.count ?? 0
            guard externalCount <= messageCount,
                  (pendingCounts[space.spaceID] ?? 0) <= deviceCount else {
                throw KanameLinkProcessRunnerError.malformedResponse
            }
            return KanameLinkSpaceSummary(
                id: space.spaceID,
                name: space.name,
                deviceCount: deviceCount,
                messageCount: messageCount,
                pendingDeviceCount: pendingCounts[space.spaceID] ?? 0,
                externalInboxCount: externalCount,
                lastActivityUnixMillis: lastActivityBySpace[space.spaceID]
            )
        }

        let pendingDevices = try raw.pendingDevices.map { device in
            guard device.state == "pending",
                  device.createdAtUnixMillis >= 0,
                  let spaceName = names[device.spaceID] else {
                throw KanameLinkProcessRunnerError.malformedResponse
            }
            return KanameLinkPendingDevice(
                id: device.deviceID,
                spaceID: device.spaceID,
                spaceName: spaceName,
                collaboratorDisplayName: device.displayName,
                deviceLabel: "Platform not reported",
                verificationCode: device.verificationCode,
                requestedAtUnixMillis: device.createdAtUnixMillis
            )
        }

        let externalInbox = try raw.inbox.map { message in
            guard message.sender == "collaborator",
                  message.queuedAtUnixMillis >= 0,
                  message.hostReceivedAtUnixMillis >= 0,
                  let spaceName = names[message.spaceID] else {
                throw KanameLinkProcessRunnerError.malformedResponse
            }
            return KanameLinkExternalMessage(
                id: message.messageID,
                spaceID: message.spaceID,
                spaceName: spaceName,
                senderDisplayName: "External collaborator",
                body: message.text,
                receivedAtUnixMillis: message.hostReceivedAtUnixMillis
            )
        }

        let snapshot = KanameLinkGatewaySnapshot(
            gateway: KanameLinkGatewayStatus(
                lifecycle: .ready,
                mode: .bundledAdminCLI,
                detail: "Bundled Link gateway is healthy on loopback. Public tunnel reachability is not verified here.",
                hostKeyFingerprint: raw.status.hostKeyFingerprint,
                observedAtUnixMillis: observedAtUnixMillis
            ),
            spaces: spaces,
            pendingDevices: pendingDevices,
            externalInbox: externalInbox,
            publicationPreviews: [],
            receipts: []
        )
        try KanameLinkSnapshotContract.validate(snapshot)
        return snapshot
    }

    private static func checkedInt(_ value: UInt64) throws -> Int {
        guard let result = Int(exactly: value) else {
            throw KanameLinkProcessRunnerError.malformedResponse
        }
        return result
    }
}

struct RustHostShellSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let status: RustGatewayStatus
    let spaces: [RustSpaceSummary]
    let pendingDevices: [RustDeviceSummary]
    let inbox: [RustLinkMessage]
}

struct RustGatewayStatus: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let hostKeyFingerprint: String
    let spaceCount: UInt64
    let pendingDeviceCount: UInt64
    let approvedDeviceCount: UInt64
    let messageCount: UInt64
}

struct RustSpaceSummary: Codable, Equatable, Sendable {
    let spaceID: String
    let name: String
    let deviceCount: UInt64
    let messageCount: UInt64

    private enum CodingKeys: String, CodingKey {
        case spaceID = "spaceId"
        case name
        case deviceCount
        case messageCount
    }
}

struct RustDeviceSummary: Codable, Equatable, Sendable {
    let deviceID: String
    let displayName: String
    let spaceID: String
    let state: String
    let verificationCode: String?
    let createdAtUnixMillis: Int64
    let approvedAtUnixMillis: Int64?
    let revokedAtUnixMillis: Int64?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case displayName
        case spaceID = "spaceId"
        case state
        case verificationCode
        case createdAtUnixMillis
        case approvedAtUnixMillis
        case revokedAtUnixMillis
    }
}

struct RustLinkMessage: Codable, Equatable, Sendable {
    let position: UInt64
    let messageID: String
    let spaceID: String
    let sender: String
    let text: String
    let queuedAtUnixMillis: Int64
    let hostReceivedAtUnixMillis: Int64

    private enum CodingKeys: String, CodingKey {
        case position
        case messageID = "messageId"
        case spaceID = "spaceId"
        case sender
        case text
        case queuedAtUnixMillis
        case hostReceivedAtUnixMillis
    }
}
