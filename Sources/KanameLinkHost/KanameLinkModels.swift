import Foundation

/// Collaborators represented by Link are external principals. These values are
/// intentionally independent from Kaname's trusted device and conversation models.
public enum KanameLinkGatewayLifecycle: String, Codable, Sendable, CaseIterable {
    case offline
    case connecting
    case ready
    case degraded
}

public enum KanameLinkGatewayMode: String, Codable, Sendable {
    case syntheticFixture = "synthetic_fixture"
    case bundledAdminCLI = "bundled_admin_cli"
}

public struct KanameLinkGatewayStatus: Codable, Equatable, Sendable {
    public var lifecycle: KanameLinkGatewayLifecycle
    public var mode: KanameLinkGatewayMode
    public var detail: String
    public var version: String?
    public var hostKeyFingerprint: String?
    public var observedAtUnixMillis: Int64

    public init(
        lifecycle: KanameLinkGatewayLifecycle,
        mode: KanameLinkGatewayMode,
        detail: String,
        version: String? = nil,
        hostKeyFingerprint: String? = nil,
        observedAtUnixMillis: Int64
    ) {
        self.lifecycle = lifecycle
        self.mode = mode
        self.detail = detail
        self.version = version
        self.hostKeyFingerprint = hostKeyFingerprint
        self.observedAtUnixMillis = observedAtUnixMillis
    }
}

public struct KanameLinkSpaceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var deviceCount: Int
    public var messageCount: Int
    public var pendingDeviceCount: Int
    public var externalInboxCount: Int
    public var lastActivityUnixMillis: Int64?

    public init(
        id: String,
        name: String,
        deviceCount: Int,
        messageCount: Int,
        pendingDeviceCount: Int,
        externalInboxCount: Int,
        lastActivityUnixMillis: Int64?
    ) {
        self.id = id
        self.name = name
        self.deviceCount = deviceCount
        self.messageCount = messageCount
        self.pendingDeviceCount = pendingDeviceCount
        self.externalInboxCount = externalInboxCount
        self.lastActivityUnixMillis = lastActivityUnixMillis
    }
}

public struct KanameLinkPendingDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let spaceID: String
    public var spaceName: String
    public var collaboratorDisplayName: String
    public var deviceLabel: String
    public var verificationCode: String?
    public var requestedAtUnixMillis: Int64

    public init(
        id: String,
        spaceID: String,
        spaceName: String,
        collaboratorDisplayName: String,
        deviceLabel: String,
        verificationCode: String?,
        requestedAtUnixMillis: Int64
    ) {
        self.id = id
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.collaboratorDisplayName = collaboratorDisplayName
        self.deviceLabel = deviceLabel
        self.verificationCode = verificationCode
        self.requestedAtUnixMillis = requestedAtUnixMillis
    }
}

public enum KanameLinkDeviceDecision: String, Codable, Sendable {
    case approve
    case deny
}

public enum KanameLinkContentTrust: String, Codable, Sendable {
    case externalUntrusted = "external_untrusted"
}

public struct KanameLinkExternalMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let spaceID: String
    public var spaceName: String
    public var senderDisplayName: String
    public var body: String
    public var receivedAtUnixMillis: Int64
    public let trust: KanameLinkContentTrust

    public init(
        id: String,
        spaceID: String,
        spaceName: String,
        senderDisplayName: String,
        body: String,
        receivedAtUnixMillis: Int64,
        trust: KanameLinkContentTrust = .externalUntrusted
    ) {
        self.id = id
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.receivedAtUnixMillis = receivedAtUnixMillis
        self.trust = trust
    }
}

public enum KanameLinkPublicationState: String, Codable, Sendable {
    case preview
    case gatewayAccepted = "gateway_accepted"
    case withdrawn
}

/// An immutable, collaborator-visible projection. It carries no private Kaname
/// thread, project, workspace, provider, tool, or filesystem identifier.
public struct KanameLinkPublicationPreview: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let spaceID: String
    public var spaceName: String
    public var title: String
    public var summary: String
    public var audienceDescription: String
    public var revision: Int
    public var contentDigest: String
    public var expiresAtUnixMillis: Int64?
    public var state: KanameLinkPublicationState

    public init(
        id: String,
        spaceID: String,
        spaceName: String,
        title: String,
        summary: String,
        audienceDescription: String,
        revision: Int,
        contentDigest: String,
        expiresAtUnixMillis: Int64? = nil,
        state: KanameLinkPublicationState = .preview
    ) {
        self.id = id
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.title = title
        self.summary = summary
        self.audienceDescription = audienceDescription
        self.revision = revision
        self.contentDigest = contentDigest
        self.expiresAtUnixMillis = expiresAtUnixMillis
        self.state = state
    }
}

public enum KanameLinkReceiptStage: String, Codable, Sendable {
    case savedLocally = "saved_locally"
    case gatewayAccepted = "gateway_accepted"
    case relayAccepted = "relay_accepted"
    case delivered
    case opened
    case failed
}

public struct KanameLinkReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let spaceID: String
    public var spaceName: String
    public var stage: KanameLinkReceiptStage
    public var summary: String
    public var detail: String
    public var recordedAtUnixMillis: Int64

    public init(
        id: String,
        spaceID: String,
        spaceName: String,
        stage: KanameLinkReceiptStage,
        summary: String,
        detail: String,
        recordedAtUnixMillis: Int64
    ) {
        self.id = id
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.stage = stage
        self.summary = summary
        self.detail = detail
        self.recordedAtUnixMillis = recordedAtUnixMillis
    }
}

public struct KanameLinkGatewaySnapshot: Codable, Equatable, Sendable {
    public var gateway: KanameLinkGatewayStatus
    public var spaces: [KanameLinkSpaceSummary]
    public var pendingDevices: [KanameLinkPendingDevice]
    public var externalInbox: [KanameLinkExternalMessage]
    public var publicationPreviews: [KanameLinkPublicationPreview]
    public var receipts: [KanameLinkReceipt]

    public init(
        gateway: KanameLinkGatewayStatus,
        spaces: [KanameLinkSpaceSummary],
        pendingDevices: [KanameLinkPendingDevice],
        externalInbox: [KanameLinkExternalMessage],
        publicationPreviews: [KanameLinkPublicationPreview],
        receipts: [KanameLinkReceipt]
    ) {
        self.gateway = gateway
        self.spaces = spaces
        self.pendingDevices = pendingDevices
        self.externalInbox = externalInbox
        self.publicationPreviews = publicationPreviews
        self.receipts = receipts
    }

    public var externalInboxCount: Int {
        externalInbox.count
    }
}

public struct KanameLinkInvitationRequest: Equatable, Sendable {
    public let spaceID: String
    public let spaceName: String
    public let expiresInSeconds: UInt64

    public init(spaceID: String, spaceName: String, expiresInSeconds: UInt64) throws {
        try KanameLinkSnapshotContract.validatePublicIdentifier(spaceID)
        try KanameLinkSnapshotContract.validateSpaceName(spaceName)
        try KanameLinkSnapshotContract.validateInviteLifetime(expiresInSeconds)
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.expiresInSeconds = expiresInSeconds
    }

    public static func newSpace(
        name: String,
        expiresInSeconds: UInt64
    ) throws -> KanameLinkInvitationRequest {
        try KanameLinkInvitationRequest(
            spaceID: "space-\(UUID().uuidString.lowercased())",
            spaceName: name,
            expiresInSeconds: expiresInSeconds
        )
    }
}

/// The invitation secret is deliberately absent from snapshots and textual
/// descriptions. It is exposed only through explicitly named copy/transfer APIs.
public struct KanameLinkInvitationArtifact: Codable, Equatable, Identifiable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let schemaVersion: Int
    public let inviteID: String
    public let spaceID: String
    public let spaceName: String
    public let gatewayURL: String
    public let hostStaticPublicKey: String
    private let inviteSecret: String
    public let expiresAtUnixMillis: Int64

    public var id: String { inviteID }
    public var description: String { "KanameLinkInvitationArtifact(inviteID: \(inviteID), secret: <redacted>)" }
    public var debugDescription: String { description }

    public init(
        schemaVersion: Int,
        inviteID: String,
        spaceID: String,
        spaceName: String,
        gatewayURL: String,
        hostStaticPublicKey: String,
        inviteSecret: String,
        expiresAtUnixMillis: Int64
    ) throws {
        guard schemaVersion == 1 else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("unsupported invitation schema")
        }
        try KanameLinkSnapshotContract.validatePublicIdentifier(inviteID)
        try KanameLinkSnapshotContract.validatePublicIdentifier(spaceID)
        try KanameLinkSnapshotContract.validateSpaceName(spaceName)
        try KanameLinkSnapshotContract.validateInvitationField(
            gatewayURL,
            field: "gateway URL",
            maximumBytes: 512
        )
        try KanameLinkSnapshotContract.validateInvitationField(
            hostStaticPublicKey,
            field: "host public key",
            maximumBytes: 512
        )
        try KanameLinkSnapshotContract.validateInvitationField(
            inviteSecret,
            field: "invitation secret",
            maximumBytes: 512
        )
        self.schemaVersion = schemaVersion
        self.inviteID = inviteID
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.gatewayURL = gatewayURL
        self.hostStaticPublicKey = hostStaticPublicKey
        self.inviteSecret = inviteSecret
        self.expiresAtUnixMillis = expiresAtUnixMillis
    }

    public func invitationDocumentForExplicitCopy() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public func secretForExplicitCopy() -> String { inviteSecret }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inviteID = "inviteId"
        case spaceID = "spaceId"
        case spaceName
        case gatewayURL = "gatewayUrl"
        case hostStaticPublicKey
        case inviteSecret
        case expiresAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            inviteID: values.decode(String.self, forKey: .inviteID),
            spaceID: values.decode(String.self, forKey: .spaceID),
            spaceName: values.decode(String.self, forKey: .spaceName),
            gatewayURL: values.decode(String.self, forKey: .gatewayURL),
            hostStaticPublicKey: values.decode(String.self, forKey: .hostStaticPublicKey),
            inviteSecret: values.decode(String.self, forKey: .inviteSecret),
            expiresAtUnixMillis: values.decode(Int64.self, forKey: .expiresAtUnixMillis)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(inviteID, forKey: .inviteID)
        try values.encode(spaceID, forKey: .spaceID)
        try values.encode(spaceName, forKey: .spaceName)
        try values.encode(gatewayURL, forKey: .gatewayURL)
        try values.encode(hostStaticPublicKey, forKey: .hostStaticPublicKey)
        try values.encode(inviteSecret, forKey: .inviteSecret)
        try values.encode(expiresAtUnixMillis, forKey: .expiresAtUnixMillis)
    }
}

public struct KanameLinkReplyReceipt: Codable, Equatable, Sendable {
    public let messageID: String
    public let state: String
    public let queuedAtUnixMillis: Int64
    public let hostReceivedAtUnixMillis: Int64?
    public let position: UInt64?
    public let duplicate: Bool

    public init(
        messageID: String,
        state: String,
        queuedAtUnixMillis: Int64,
        hostReceivedAtUnixMillis: Int64?,
        position: UInt64?,
        duplicate: Bool
    ) {
        self.messageID = messageID
        self.state = state
        self.queuedAtUnixMillis = queuedAtUnixMillis
        self.hostReceivedAtUnixMillis = hostReceivedAtUnixMillis
        self.position = position
        self.duplicate = duplicate
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case state
        case queuedAtUnixMillis
        case hostReceivedAtUnixMillis
        case position
        case duplicate
    }
}

public enum KanameLinkGatewayServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case pendingDeviceNotFound
    case publicationNotFound
    case spaceNotFound
    case invalidSpaceName
    case invalidInviteLifetime
    case invalidReply
    case syntheticOperationUnavailable
    case gatewayUnavailable
    case malformedSnapshot(String)
    case gatewayRejected(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The Link request did not contain a valid public Link identifier."
        case .pendingDeviceNotFound:
            "That pending Link device is no longer available."
        case .publicationNotFound:
            "That Link publication preview is no longer available."
        case .spaceNotFound:
            "That Link space is no longer available."
        case .invalidSpaceName:
            "The Link space name is empty, oversized, or contains control characters."
        case .invalidInviteLifetime:
            "Link invitations must expire between one minute and seven days."
        case .invalidReply:
            "The Link reply is empty, oversized, or contains invalid content."
        case .syntheticOperationUnavailable:
            "The screenshot fixture cannot create a real invitation or expose a secret."
        case .gatewayUnavailable:
            "The app-owned Link gateway is not running and healthy."
        case let .malformedSnapshot(reason):
            "The Link gateway returned an invalid bounded snapshot: \(reason)"
        case let .gatewayRejected(code, message):
            "The Link gateway rejected the request (\(code)): \(message)"
        }
    }
}

public protocol KanameLinkGatewayService: Sendable {
    func fetchSnapshot() async throws -> KanameLinkGatewaySnapshot
    func createInvitation(
        request: KanameLinkInvitationRequest
    ) async throws -> KanameLinkInvitationArtifact
    func decidePendingDevice(
        id: String,
        decision: KanameLinkDeviceDecision
    ) async throws
    func publishReply(spaceID: String, body: String) async throws -> KanameLinkReplyReceipt
}

public enum KanameLinkSnapshotContract {
    public static let maximumSpaces = 100
    public static let maximumPendingDevices = 100
    public static let maximumInboxMessages = 200
    public static let maximumPublicationPreviews = 50
    public static let maximumReceipts = 200
    public static let maximumExternalBodyBytes = 8 * 1024
    public static let maximumReplyBodyBytes = 16 * 1024
    public static let minimumInviteLifetimeSeconds: UInt64 = 60
    public static let maximumInviteLifetimeSeconds: UInt64 = 7 * 24 * 60 * 60

    public static func validate(_ snapshot: KanameLinkGatewaySnapshot) throws {
        guard snapshot.spaces.count <= maximumSpaces else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("too many spaces")
        }
        guard snapshot.pendingDevices.count <= maximumPendingDevices else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("too many pending devices")
        }
        guard snapshot.externalInbox.count <= maximumInboxMessages else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("too many inbox messages")
        }
        guard snapshot.publicationPreviews.count <= maximumPublicationPreviews else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("too many publication previews")
        }
        guard snapshot.receipts.count <= maximumReceipts else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("too many receipts")
        }

        try bounded(snapshot.gateway.detail, field: "gateway detail", maximumBytes: 1_024)
        if let version = snapshot.gateway.version {
            try bounded(version, field: "gateway version", maximumBytes: 128)
        }
        if let fingerprint = snapshot.gateway.hostKeyFingerprint {
            try bounded(fingerprint, field: "host key fingerprint", maximumBytes: 256)
        }
        try unique(snapshot.spaces.map(\.id), field: "space")
        try unique(snapshot.pendingDevices.map(\.id), field: "pending device")
        try unique(snapshot.externalInbox.map(\.id), field: "external message")
        try unique(snapshot.publicationPreviews.map(\.id), field: "publication")
        try unique(snapshot.receipts.map(\.id), field: "receipt")
        let spaceNames = Dictionary(uniqueKeysWithValues: snapshot.spaces.map { ($0.id, $0.name) })
        for space in snapshot.spaces {
            try identifier(space.id)
            try bounded(space.name, field: "space name", maximumBytes: 160)
            guard space.deviceCount >= 0,
                  space.messageCount >= 0,
                  space.pendingDeviceCount >= 0,
                  space.externalInboxCount >= 0 else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("negative space count")
            }
        }
        for pending in snapshot.pendingDevices {
            try identifier(pending.id)
            try identifier(pending.spaceID)
            guard spaceNames[pending.spaceID] == pending.spaceName else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("pending device references an unknown space")
            }
            try bounded(pending.spaceName, field: "pending space name", maximumBytes: 160)
            try bounded(pending.collaboratorDisplayName, field: "collaborator name", maximumBytes: 160)
            try bounded(pending.deviceLabel, field: "device label", maximumBytes: 160)
            if let verificationCode = pending.verificationCode {
                try bounded(verificationCode, field: "verification code", maximumBytes: 128)
            }
        }
        for message in snapshot.externalInbox {
            try identifier(message.id)
            try identifier(message.spaceID)
            guard spaceNames[message.spaceID] == message.spaceName else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("external message references an unknown space")
            }
            guard message.trust == .externalUntrusted else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("external content lost its untrusted label")
            }
            try bounded(message.spaceName, field: "message space name", maximumBytes: 160)
            try bounded(message.senderDisplayName, field: "sender name", maximumBytes: 160)
            try bounded(message.body, field: "external message body", maximumBytes: maximumExternalBodyBytes)
        }
        for publication in snapshot.publicationPreviews {
            try identifier(publication.id)
            try identifier(publication.spaceID)
            guard spaceNames[publication.spaceID] == publication.spaceName else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("publication references an unknown space")
            }
            try bounded(publication.spaceName, field: "publication space name", maximumBytes: 160)
            try bounded(publication.title, field: "publication title", maximumBytes: 240)
            try bounded(publication.summary, field: "publication summary", maximumBytes: 8 * 1024)
            try bounded(publication.audienceDescription, field: "publication audience", maximumBytes: 512)
            try bounded(publication.contentDigest, field: "publication digest", maximumBytes: 128)
            let digest = publication.contentDigest
            guard digest.hasPrefix("sha256:"),
                  digest.dropFirst(7).count == 64,
                  digest.dropFirst(7).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("publication digest is not canonical SHA-256")
            }
            guard publication.revision > 0 else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("publication revision must be positive")
            }
        }
        for receipt in snapshot.receipts {
            try identifier(receipt.id)
            try identifier(receipt.spaceID)
            guard spaceNames[receipt.spaceID] == receipt.spaceName else {
                throw KanameLinkGatewayServiceError.malformedSnapshot("receipt references an unknown space")
            }
            try bounded(receipt.spaceName, field: "receipt space name", maximumBytes: 160)
            try bounded(receipt.summary, field: "receipt summary", maximumBytes: 240)
            try bounded(receipt.detail, field: "receipt detail", maximumBytes: 1_024)
        }
    }

    public static func validatePublicIdentifier(_ value: String) throws {
        try identifier(value)
    }

    public static func validateSpaceName(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw KanameLinkGatewayServiceError.invalidSpaceName
        }
    }

    public static func validateInviteLifetime(_ value: UInt64) throws {
        guard (minimumInviteLifetimeSeconds...maximumInviteLifetimeSeconds).contains(value) else {
            throw KanameLinkGatewayServiceError.invalidInviteLifetime
        }
    }

    public static func validateReplyBody(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumReplyBodyBytes,
              !value.contains("\0") else {
            throw KanameLinkGatewayServiceError.invalidReply
        }
    }

    public static func validateInvitationField(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        try bounded(value, field: field, maximumBytes: maximumBytes)
    }

    private static func identifier(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
                      || value == 45 || value == 46 || value == 58 || value == 95
              }) else {
            throw KanameLinkGatewayServiceError.invalidIdentifier
        }
    }

    private static func unique(_ identifiers: [String], field: String) throws {
        guard Set(identifiers).count == identifiers.count else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("duplicate \(field) identifier")
        }
    }

    private static func bounded(_ value: String, field: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw KanameLinkGatewayServiceError.malformedSnapshot("\(field) is empty or oversized")
        }
    }
}
