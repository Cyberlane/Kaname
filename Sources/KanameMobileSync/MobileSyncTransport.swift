import CryptoKit
import Foundation
import KanameProtocol

public enum MobileSyncTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case disconnected
    case unauthorized
    case invalidEnvelope
    case envelopeTooLarge
    case envelopeIDReused
    case invalidCursor
    case invalidPageSize
    case deliveryNotFound
    case recipientMismatch
    case invalidResponse
    case relayRejected(String)
}

public struct MobileRelaySendReceipt: Equatable, Sendable {
    public let deliveryID: String
    public let relayPosition: UInt64
    public let duplicate: Bool
    public let recordedAtUnixMillis: Int64
}

public struct MobileRelayDelivery: Equatable, Sendable {
    public let deliveryID: String
    public let relayPosition: UInt64
    public let recipientDeviceID: String
    public let envelopeWire: Data
}

public struct MobileRelayPage: Equatable, Sendable {
    public let deliveries: [MobileRelayDelivery]
    public let nextPosition: UInt64
    public let hasMore: Bool
}

public struct MobileRelayAuditRecord: Equatable, Sendable {
    public let deliveryID: String
    public let relayPosition: UInt64
    public let envelopeID: String
    public let senderDeviceID: String
    public let recipientDeviceID: String
    public let senderSequence: UInt64
    public let payloadKind: String
    public let authenticatedHeaderBytes: Int
    public let ciphertextBytes: Int
    public let envelopeDigest: Data
    public let acknowledged: Bool
}

public protocol MobileSyncTransport: Sendable {
    func send(
        envelopeWire: Data,
        nowUnixMillis: Int64
    ) async throws -> MobileRelaySendReceipt

    func pull(
        recipientDeviceID: String,
        afterPosition: UInt64,
        limit: Int
    ) async throws -> MobileRelayPage

    func acknowledge(
        deliveryID: String,
        recipientDeviceID: String
    ) async throws
}

public struct MobileRelayEnvelopeRoute: Equatable, Sendable {
    public let envelopeID: String
    public let senderDeviceID: String
    public let recipientDeviceID: String
    public let senderSequence: UInt64
    public let payloadKind: String
    public let authenticatedHeaderBytes: Int
    public let ciphertextBytes: Int

}

public enum MobileRelayEnvelopeRouting {
    public static let maximumEnvelopeBytes = 80 * 1024

    public static func route(_ envelopeWire: Data) throws -> MobileRelayEnvelopeRoute {
        guard !envelopeWire.isEmpty else {
            throw MobileSyncTransportError.invalidEnvelope
        }
        guard envelopeWire.count <= maximumEnvelopeBytes else {
            throw MobileSyncTransportError.envelopeTooLarge
        }
        guard let envelope = try? Kaname_V1_EncryptedSyncEnvelope(serializedBytes: envelopeWire),
              !envelope.authenticatedHeader.isEmpty,
              !envelope.encapsulatedKey.isEmpty,
              !envelope.ciphertext.isEmpty,
              let header = try? Kaname_V1_SyncAuthenticatedHeader(
                serializedBytes: envelope.authenticatedHeader
              ),
              header.schemaVersion.major == 1,
              MobileSyncIdentifier.isValid(header.envelopeID),
              MobileSyncIdentifier.isValid(header.senderDeviceID),
              MobileSyncIdentifier.isValid(header.recipientDeviceID),
              header.senderDeviceID != header.recipientDeviceID,
              header.senderSequence > 0,
              !header.payloadKind.isEmpty,
              header.payloadKind.utf8.count <= 128 else {
            throw MobileSyncTransportError.invalidEnvelope
        }
        return MobileRelayEnvelopeRoute(
            envelopeID: header.envelopeID,
            senderDeviceID: header.senderDeviceID,
            recipientDeviceID: header.recipientDeviceID,
            senderSequence: header.senderSequence,
            payloadKind: header.payloadKind,
            authenticatedHeaderBytes: envelope.authenticatedHeader.count,
            ciphertextBytes: envelope.ciphertext.count
        )
    }
}

/// Provider-neutral, network-free relay used to prove the mobile transport
/// contract before any hosting decision. It stores the exact encrypted wire
/// envelope plus bounded routing metadata. It has no plaintext input, output,
/// cache, log, or inspection path.
public actor LocalCiphertextRelay: MobileSyncTransport {
    public static let maximumEnvelopeBytes = MobileRelayEnvelopeRouting.maximumEnvelopeBytes
    public static let maximumPageSize = 100

    private struct StoredDelivery: Sendable {
        let deliveryID: String
        let relayPosition: UInt64
        let envelopeID: String
        let senderDeviceID: String
        let recipientDeviceID: String
        let senderSequence: UInt64
        let payloadKind: String
        let authenticatedHeaderBytes: Int
        let ciphertextBytes: Int
        let envelopeDigest: Data
        let envelopeWire: Data
        let recordedAtUnixMillis: Int64
        var acknowledged: Bool
    }

    private var connected = true
    private var deliveries: [StoredDelivery] = []
    private var deliveryIndexByEnvelopeID: [String: Int] = [:]

    public init() {}

    public func setConnected(_ connected: Bool) {
        self.connected = connected
    }

    public func send(
        envelopeWire: Data,
        nowUnixMillis: Int64
    ) throws -> MobileRelaySendReceipt {
        guard connected else {
            throw MobileSyncTransportError.disconnected
        }
        let routed = try MobileRelayEnvelopeRouting.route(envelopeWire)
        let envelopeDigest = Data(SHA256.hash(data: envelopeWire))
        if let existingIndex = deliveryIndexByEnvelopeID[routed.envelopeID] {
            let existing = deliveries[existingIndex]
            guard existing.envelopeWire == envelopeWire,
                  existing.envelopeDigest == envelopeDigest else {
                throw MobileSyncTransportError.envelopeIDReused
            }
            return MobileRelaySendReceipt(
                deliveryID: existing.deliveryID,
                relayPosition: existing.relayPosition,
                duplicate: true,
                recordedAtUnixMillis: existing.recordedAtUnixMillis
            )
        }

        let relayPosition = UInt64(deliveries.count + 1)
        let deliveryID = "relay-delivery-\(relayPosition)"
        let stored = StoredDelivery(
            deliveryID: deliveryID,
            relayPosition: relayPosition,
            envelopeID: routed.envelopeID,
            senderDeviceID: routed.senderDeviceID,
            recipientDeviceID: routed.recipientDeviceID,
            senderSequence: routed.senderSequence,
            payloadKind: routed.payloadKind,
            authenticatedHeaderBytes: routed.authenticatedHeaderBytes,
            ciphertextBytes: routed.ciphertextBytes,
            envelopeDigest: envelopeDigest,
            envelopeWire: envelopeWire,
            recordedAtUnixMillis: nowUnixMillis,
            acknowledged: false
        )
        deliveryIndexByEnvelopeID[stored.envelopeID] = deliveries.count
        deliveries.append(stored)
        return MobileRelaySendReceipt(
            deliveryID: deliveryID,
            relayPosition: relayPosition,
            duplicate: false,
            recordedAtUnixMillis: nowUnixMillis
        )
    }

    public func pull(
        recipientDeviceID: String,
        afterPosition: UInt64,
        limit: Int
    ) throws -> MobileRelayPage {
        guard connected else {
            throw MobileSyncTransportError.disconnected
        }
        guard MobileSyncIdentifier.isValid(recipientDeviceID) else {
            throw MobileSyncTransportError.recipientMismatch
        }
        guard afterPosition <= UInt64(deliveries.count) else {
            throw MobileSyncTransportError.invalidCursor
        }
        guard limit > 0, limit <= Self.maximumPageSize else {
            throw MobileSyncTransportError.invalidPageSize
        }

        let matching = deliveries.filter {
            $0.recipientDeviceID == recipientDeviceID
                && $0.relayPosition > afterPosition
                && !$0.acknowledged
        }
        let selected = Array(matching.prefix(limit))
        let nextPosition = selected.last?.relayPosition ?? afterPosition
        return MobileRelayPage(
            deliveries: selected.map {
                MobileRelayDelivery(
                    deliveryID: $0.deliveryID,
                    relayPosition: $0.relayPosition,
                    recipientDeviceID: $0.recipientDeviceID,
                    envelopeWire: $0.envelopeWire
                )
            },
            nextPosition: nextPosition,
            hasMore: matching.count > selected.count
        )
    }

    public func acknowledge(
        deliveryID: String,
        recipientDeviceID: String
    ) throws {
        guard connected else {
            throw MobileSyncTransportError.disconnected
        }
        guard let index = deliveries.firstIndex(where: { $0.deliveryID == deliveryID }) else {
            throw MobileSyncTransportError.deliveryNotFound
        }
        guard deliveries[index].recipientDeviceID == recipientDeviceID else {
            throw MobileSyncTransportError.recipientMismatch
        }
        deliveries[index].acknowledged = true
    }

    public func auditRecords() -> [MobileRelayAuditRecord] {
        deliveries.map {
            MobileRelayAuditRecord(
                deliveryID: $0.deliveryID,
                relayPosition: $0.relayPosition,
                envelopeID: $0.envelopeID,
                senderDeviceID: $0.senderDeviceID,
                recipientDeviceID: $0.recipientDeviceID,
                senderSequence: $0.senderSequence,
                payloadKind: $0.payloadKind,
                authenticatedHeaderBytes: $0.authenticatedHeaderBytes,
                ciphertextBytes: $0.ciphertextBytes,
                envelopeDigest: $0.envelopeDigest,
                acknowledged: $0.acknowledged
            )
        }
    }

}
