import Foundation
import KanameDesignSystem

struct LinkConnectionCapabilities: Equatable, Sendable {
    let canRequestEnrollment: Bool
    let canQueueMessage: Bool
}

enum LinkConnectionState: Equatable, Sendable {
    case hostOnline
    case connecting
    case hostOffline
    case enrollmentRequired
    case revoked
    case unrecognized(String)

    init(wireValue: String) {
        self = switch wireValue {
        case "hostOnline": .hostOnline
        case "connecting": .connecting
        case "hostOffline": .hostOffline
        case "enrollmentRequired": .enrollmentRequired
        case "revoked": .revoked
        default: .unrecognized(wireValue)
        }
    }

    var wireValue: String {
        switch self {
        case .hostOnline: "hostOnline"
        case .connecting: "connecting"
        case .hostOffline: "hostOffline"
        case .enrollmentRequired: "enrollmentRequired"
        case .revoked: "revoked"
        case let .unrecognized(value): value
        }
    }

    var kindKey: String {
        switch self {
        case .hostOnline: "hostOnline"
        case .connecting: "connecting"
        case .hostOffline: "hostOffline"
        case .enrollmentRequired: "enrollmentRequired"
        case .revoked: "revoked"
        case .unrecognized: "unrecognized"
        }
    }

    var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .hostOnline:
            (label, tone, accessibilityLabel) = (
                "Host online",
                .success,
                "Connection status: Host online"
            )
        case .connecting:
            (label, tone, accessibilityLabel) = (
                "Connecting",
                .active,
                "Connection status: Connecting"
            )
        case .hostOffline:
            (label, tone, accessibilityLabel) = (
                "Host offline",
                .warning,
                "Connection status: Host offline"
            )
        case .enrollmentRequired:
            (label, tone, accessibilityLabel) = (
                "Enrollment required",
                .external,
                "Connection status: Enrollment required"
            )
        case .revoked:
            (label, tone, accessibilityLabel) = (
                "Access revoked",
                .blocked,
                "Connection status: Access revoked"
            )
        case .unrecognized:
            (label, tone, accessibilityLabel) = (
                "Connection state unavailable",
                .blocked,
                "Connection status: Connection state unavailable"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }

    var capabilities: LinkConnectionCapabilities {
        switch self {
        case .hostOnline:
            LinkConnectionCapabilities(canRequestEnrollment: false, canQueueMessage: true)
        case .hostOffline:
            LinkConnectionCapabilities(
                canRequestEnrollment: false,
                // macOS currently requires a live host before accepting composer input.
                canQueueMessage: false
            )
        case .enrollmentRequired:
            LinkConnectionCapabilities(canRequestEnrollment: true, canQueueMessage: false)
        case .connecting, .revoked, .unrecognized:
            LinkConnectionCapabilities(canRequestEnrollment: false, canQueueMessage: false)
        }
    }
}

extension LinkConnectionState: Codable {
    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum LinkDiscussionStatus: Equatable, Sendable {
    case actionRequired
    case waitingForHost
    case upToDate
    case delivered
    case unrecognized(String)

    init(wireValue: String) {
        self = switch wireValue {
        case "Waiting for you": .actionRequired
        case "Waiting for host": .waitingForHost
        case "Up to date": .upToDate
        case "Delivered": .delivered
        default: .unrecognized(wireValue)
        }
    }

    var wireValue: String {
        switch self {
        case .actionRequired: "Waiting for you"
        case .waitingForHost: "Waiting for host"
        case .upToDate: "Up to date"
        case .delivered: "Delivered"
        case let .unrecognized(value): value
        }
    }

    var kindKey: String {
        switch self {
        case .actionRequired: "actionRequired"
        case .waitingForHost: "waitingForHost"
        case .upToDate: "upToDate"
        case .delivered: "delivered"
        case .unrecognized: "unrecognized"
        }
    }

    var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .actionRequired:
            (label, tone, accessibilityLabel) = (
                "Waiting for you",
                .attention,
                "Discussion status: Waiting for you. Action required."
            )
        case .waitingForHost:
            (label, tone, accessibilityLabel) = (
                "Waiting for host",
                .active,
                "Discussion status: Waiting for host"
            )
        case .upToDate:
            (label, tone, accessibilityLabel) = (
                "Up to date",
                .success,
                "Discussion status: Up to date"
            )
        case .delivered:
            (label, tone, accessibilityLabel) = (
                "Delivered",
                .success,
                "Discussion status: Delivered"
            )
        case .unrecognized:
            (label, tone, accessibilityLabel) = (
                "Outcome uncertain",
                .warning,
                "Discussion status: Outcome uncertain"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

extension LinkDiscussionStatus: Codable {
    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum LinkReceiptStatus: Equatable, Sendable {
    case localStored
    case queued
    case gatewayAccepted
    case published
    case delivered
    case failed
    case outcomeUncertain
    case unrecognized(String)

    init(wireValue: String) {
        self = switch wireValue {
        case "Stored locally": .localStored
        case "Queued locally", "Queued on this device": .queued
        case "Received by host": .gatewayAccepted
        case "Published by host", "Published result": .published
        case "Delivered": .delivered
        case "Observed failure": .failed
        case "Outcome uncertain": .outcomeUncertain
        default: .unrecognized(wireValue)
        }
    }

    var wireValue: String {
        switch self {
        case .localStored: "Stored locally"
        case .queued: "Queued locally"
        case .gatewayAccepted: "Received by host"
        case .published: "Published by host"
        case .delivered: "Delivered"
        case .failed: "Observed failure"
        case .outcomeUncertain: "Outcome uncertain"
        case let .unrecognized(value): value
        }
    }

    var kindKey: String {
        switch self {
        case .localStored: "localStored"
        case .queued: "queued"
        case .gatewayAccepted: "gatewayAccepted"
        case .published: "published"
        case .delivered: "delivered"
        case .failed: "failed"
        case .outcomeUncertain: "outcomeUncertain"
        case .unrecognized: "unrecognized"
        }
    }

    var kanameState: KanameReceiptState {
        switch self {
        case .localStored: .localStored
        case .queued: .queued
        case .gatewayAccepted: .gatewayAccepted
        case .published: .published
        case .delivered: .delivered
        case .failed: .failed
        case .outcomeUncertain, .unrecognized: .outcomeUncertain
        }
    }

    var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .localStored:
            (label, tone, accessibilityLabel) = (
                "Stored locally",
                .informational,
                "Message status: Stored locally"
            )
        case .queued:
            (label, tone, accessibilityLabel) = (
                "Queued locally",
                .active,
                "Message status: Queued locally"
            )
        case .gatewayAccepted:
            (label, tone, accessibilityLabel) = (
                "Received by host",
                .informational,
                "Message status: Received by host"
            )
        case .published:
            (label, tone, accessibilityLabel) = (
                "Published by host",
                .external,
                "Message status: Published by host"
            )
        case .delivered:
            (label, tone, accessibilityLabel) = (
                "Delivered",
                .success,
                "Message status: Delivered"
            )
        case .failed:
            (label, tone, accessibilityLabel) = (
                "Observed failure",
                .danger,
                "Message status: Observed failure"
            )
        case .outcomeUncertain, .unrecognized:
            (label, tone, accessibilityLabel) = (
                "Outcome uncertain",
                .warning,
                "Message status: Outcome uncertain"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

extension LinkReceiptStatus: Codable {
    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum LinkParticipantRole: Equatable, Sendable {
    case host
    case collaborator
    case unrecognized(String)

    init(wireValue: String) {
        self = switch wireValue {
        case "host": .host
        case "collaborator": .collaborator
        default: .unrecognized(wireValue)
        }
    }

    var wireValue: String {
        switch self {
        case .host: "host"
        case .collaborator: "collaborator"
        case let .unrecognized(value): value
        }
    }

    var kindKey: String {
        switch self {
        case .host: "host"
        case .collaborator: "collaborator"
        case .unrecognized: "unrecognized"
        }
    }

    var isLocalPrincipal: Bool { self == .collaborator }

    var kanameRole: KanameMessageParticipantRole? {
        switch self {
        case .host: .host
        case .collaborator: .collaborator
        case .unrecognized: nil
        }
    }

    var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .host:
            (label, tone, accessibilityLabel) = ("Host", .informational, "Participant: Host")
        case .collaborator:
            (label, tone, accessibilityLabel) = (
                "External collaborator",
                .external,
                "Participant: External collaborator"
            )
        case .unrecognized:
            (label, tone, accessibilityLabel) = (
                "External participant",
                .blocked,
                "Participant: Unrecognized external participant"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

extension LinkParticipantRole: Codable {
    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum LinkHostVerificationState: Sendable {
    case verified
    case approvalPending

    init(verified: Bool) {
        self = verified ? .verified : .approvalPending
    }

    var kindKey: String {
        switch self {
        case .verified: "verified"
        case .approvalPending: "approvalPending"
        }
    }

    var presentation: KanameStatusPresentation {
        let label: String
        let tone: KanameStatusTone
        let accessibilityLabel: String
        switch self {
        case .verified:
            (label, tone, accessibilityLabel) = (
                "Verified host",
                .success,
                "Host verification: Verified"
            )
        case .approvalPending:
            (label, tone, accessibilityLabel) = (
                "Verification needed",
                .attention,
                "Host verification: Approval pending"
            )
        }
        return KanameStatusPresentation(
            label: label,
            tone: tone,
            symbolName: tone.symbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

enum LinkStatusContractVerifier {
    static func verify(at path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let contract = try JSONDecoder().decode(StatusContract.self, from: data)
        try require(contract.schemaVersion == 1, "schema_version")
        try require(contract.privacyClass == "synthetic-public", "privacy_class")
        try require(
            contract.semanticTones == KanameStatusTone.allCases.map(\.rawValue),
            "semantic_tones"
        )

        for expected in contract.connections {
            let status = LinkConnectionState(wireValue: expected.wireValue)
            try verify(status.kindKey, status.presentation, against: expected)
        }
        for expected in contract.discussions {
            let status = LinkDiscussionStatus(wireValue: expected.wireValue)
            try verify(status.kindKey, status.presentation, against: expected)
        }
        for expected in contract.receipts {
            let status = LinkReceiptStatus(wireValue: expected.wireValue)
            try verify(status.kindKey, status.presentation, against: expected)
        }
        for expected in contract.participants {
            let role = LinkParticipantRole(wireValue: expected.wireValue)
            try verify(role.kindKey, role.presentation, against: expected)
            try require(
                role.isLocalPrincipal == expected.isLocalPrincipal,
                "participant_local:\(expected.wireValue)"
            )
        }
        for expected in contract.hostVerifications {
            let state = LinkHostVerificationState(verified: expected.verified)
            try require(state.kindKey == expected.kind, "host_verification_kind")
            try require(state.presentation.tone.rawValue == expected.tone, "host_verification_tone")
            try require(
                state.presentation.accessibilityLabel == expected.accessibilityLabel,
                "host_verification_accessibility"
            )
        }

        let unknownConnection = LinkConnectionState(wireValue: "future-connection")
        try require(unknownConnection.kindKey == "unrecognized", "unknown_connection_kind")
        try require(unknownConnection.presentation.tone == .blocked, "unknown_connection_tone")
        try require(!unknownConnection.capabilities.canQueueMessage, "unknown_connection_queue")
        try require(
            LinkDiscussionStatus(wireValue: "future-discussion").presentation.tone == .warning,
            "unknown_discussion"
        )
        try require(
            LinkReceiptStatus(wireValue: "future-receipt").presentation.label == "Outcome uncertain",
            "unknown_receipt"
        )
        try require(
            !LinkParticipantRole(wireValue: "future-participant").isLocalPrincipal,
            "unknown_participant"
        )
        try require(
            !LinkConnectionState.hostOffline.capabilities.canQueueMessage,
            "macos_offline_queue_policy"
        )
    }

    private static func verify(
        _ kind: String,
        _ presentation: KanameStatusPresentation,
        against expected: StatusContractEntry
    ) throws {
        let scope = "\(kind):\(expected.wireValue)"
        try require(kind == expected.kind, "\(scope):kind")
        try require(presentation.label == expected.label, "\(scope):label")
        try require(presentation.tone.rawValue == expected.tone, "\(scope):tone")
        try require(
            presentation.accessibilityLabel == expected.accessibilityLabel,
            "\(scope):accessibility"
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ field: String) throws {
        guard condition() else { throw LinkStatusContractError.mismatch(field) }
    }

    private struct StatusContract: Decodable {
        let schemaVersion: Int
        let privacyClass: String
        let semanticTones: [String]
        let connections: [StatusContractEntry]
        let discussions: [StatusContractEntry]
        let receipts: [StatusContractEntry]
        let participants: [ParticipantContractEntry]
        let hostVerifications: [HostVerificationContractEntry]
    }

    private struct StatusContractEntry: Decodable {
        let wireValue: String
        let kind: String
        let label: String
        let tone: String
        let accessibilityLabel: String
    }

    private struct ParticipantContractEntry: Decodable {
        let wireValue: String
        let kind: String
        let label: String
        let tone: String
        let accessibilityLabel: String
        let isLocalPrincipal: Bool
    }

    private struct HostVerificationContractEntry: Decodable {
        let verified: Bool
        let kind: String
        let tone: String
        let accessibilityLabel: String
    }

    private static func verify(
        _ kind: String,
        _ presentation: KanameStatusPresentation,
        against expected: ParticipantContractEntry
    ) throws {
        try verify(
            kind,
            presentation,
            against: StatusContractEntry(
                wireValue: expected.wireValue,
                kind: expected.kind,
                label: expected.label,
                tone: expected.tone,
                accessibilityLabel: expected.accessibilityLabel
            )
        )
    }
}

enum LinkStatusContractError: LocalizedError {
    case mismatch(String)

    var errorDescription: String? {
        switch self {
        case let .mismatch(field): "Kaname Link status contract mismatch: \(field)"
        }
    }
}
