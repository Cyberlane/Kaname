import CryptoKit
import Foundation
import KanameProtocol

public enum MobileQueueDeliveryState: String, Codable, Equatable, Sendable {
    case savedOnPhone
    case relayAccepted
    case receivedByMac
    case policyAccepted
    case providerDispatchAccepted
    case runStarted
    case rejected
    case resyncRequired
}

public struct MobileQueuedCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var position: Int
    public var streamID: String
    public var threadTitle: String
    public var body: String
    public var createdLabel: String
    public var createdAtUnixMillis: Int64
    public var revision: UInt64
    public var deliveryState: MobileQueueDeliveryState
    public var reasonCode: String?

    public init(
        id: UUID,
        position: Int,
        streamID: String? = nil,
        threadTitle: String,
        body: String,
        createdLabel: String,
        createdAtUnixMillis: Int64 = 1,
        revision: UInt64 = 1,
        deliveryState: MobileQueueDeliveryState = .savedOnPhone,
        reasonCode: String? = nil
    ) {
        self.id = id
        self.position = position
        self.streamID = streamID ?? "thread-\(id.uuidString.lowercased())"
        self.threadTitle = threadTitle
        self.body = body
        self.createdLabel = createdLabel
        self.createdAtUnixMillis = createdAtUnixMillis
        self.revision = revision
        self.deliveryState = deliveryState
        self.reasonCode = reasonCode
    }
}

public struct MobileCachedHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let streamID: String
    public let storePosition: UInt64
    public let streamSequence: UInt64
    public let kind: String
    public let occurredAtUnixMillis: Int64
    public let exactEventWire: Data
}

public struct MobileSyncReceiptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let subjectID: String
    public let state: MobileQueueDeliveryState
    public let reasonCode: String
    public let recordedAtUnixMillis: Int64
}

public struct MobileSyncSessionSnapshot: Equatable, Sendable {
    public let queuedCommands: [MobileQueuedCommand]
    public let recentHistory: [MobileCachedHistoryRecord]
    public let receipts: [MobileSyncReceiptRecord]
    public let outgoingSequence: UInt64
    public let incomingSequence: UInt64
    public let relayCursor: UInt64
    public let resyncExpectedSequence: UInt64?
    public let readOnlyReason: String?
}

public struct MobileSyncEndpointConfiguration: Sendable {
    public let deviceID: String
    public let keyID: String
    public let peerDeviceID: String
    public let peerKeyID: String
    public let peerPublicKey: Curve25519.KeyAgreement.PublicKey

    public init(
        deviceID: String,
        keyID: String,
        peerDeviceID: String,
        peerKeyID: String,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey
    ) throws {
        guard MobileSyncIdentifier.isValid(deviceID),
              MobileSyncIdentifier.isValid(keyID),
              MobileSyncIdentifier.isValid(peerDeviceID),
              MobileSyncIdentifier.isValid(peerKeyID),
              deviceID != peerDeviceID else {
            throw MobileSyncError.invalidIdentity
        }
        self.deviceID = deviceID
        self.keyID = keyID
        self.peerDeviceID = peerDeviceID
        self.peerKeyID = peerKeyID
        self.peerPublicKey = peerPublicKey
    }
}

public protocol MobileSyncStateStore: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public actor InMemoryMobileSyncStateStore: MobileSyncStateStore {
    private var data: Data?

    public init(initialData: Data? = nil) {
        self.data = initialData
    }

    public func load() -> Data? {
        data
    }

    public func save(_ data: Data) {
        self.data = data
    }
}

public actor ProtectedFileMobileSyncStateStore: MobileSyncStateStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#endif
    }
}

public enum MobileSyncSessionError: Error, Equatable, Sendable {
    case invalidQueue
    case queueItemNotFound
    case queueItemAlreadyStaged
    case invalidPayload
    case payloadIDReused
    case unsupportedPayloadKind
    case replayDetected
    case chainMismatch
    case resyncRequired(expectedSequence: UInt64)
    case stateTooLarge
    case stateMalformed
    case readOnly(String)
}

public struct MobileSyncPollResult: Equatable, Sendable {
    public let applied: Int
    public let duplicates: Int
    public let relayCursor: UInt64
    public let resyncExpectedSequence: UInt64?
}

@available(macOS 14.0, iOS 17.0, *)
public actor MobileSyncSession {
    private struct OutboundEnvelope: Codable, Equatable, Sendable {
        let payloadID: String
        let payloadKind: String
        let payloadDigest: Data
        let envelopeID: String
        let senderSequence: UInt64
        let envelopeWire: Data
        let envelopeDigest: Data
        var relayAccepted: Bool
    }

    private struct PersistedState: Codable, Equatable, Sendable {
        var queuedCommands: [MobileQueuedCommand] = []
        var recentHistory: [MobileCachedHistoryRecord] = []
        var receipts: [MobileSyncReceiptRecord] = []
        var outbox: [OutboundEnvelope] = []
        var outgoingSequence: UInt64 = 0
        var outgoingEnvelopeDigest = Data()
        var incomingSequence: UInt64 = 0
        var incomingEnvelopeDigest = Data()
        var incomingEnvelopeDigests: [String: Data] = [:]
        var relayCursor: UInt64 = 0
        var resyncExpectedSequence: UInt64?
        var readOnlyReason: String?
    }

    private static let maximumPersistedStateBytes = 4 * 1024 * 1024
    private static let maximumQueueItems = 500
    private static let maximumReceipts = 1_000

    private let configuration: MobileSyncEndpointConfiguration
    private let keyStore: any MobileSyncPrivateKeyStore
    private let transport: any MobileSyncTransport
    private let stateStore: any MobileSyncStateStore
    private let historyLimit: Int
    private var state = PersistedState()

    public init(
        configuration: MobileSyncEndpointConfiguration,
        keyStore: any MobileSyncPrivateKeyStore,
        transport: any MobileSyncTransport,
        stateStore: any MobileSyncStateStore,
        historyLimit: Int = 200
    ) throws {
        guard historyLimit > 0, historyLimit <= 2_000 else {
            throw MobileSyncSessionError.invalidPayload
        }
        self.configuration = configuration
        self.keyStore = keyStore
        self.transport = transport
        self.stateStore = stateStore
        self.historyLimit = historyLimit
    }

    public func restore() async throws {
        guard let data = try await stateStore.load() else { return }
        guard data.count <= Self.maximumPersistedStateBytes else {
            throw MobileSyncSessionError.stateTooLarge
        }
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            throw MobileSyncSessionError.stateMalformed
        }
        try validatePersistedState()
    }

    public func snapshot() -> MobileSyncSessionSnapshot {
        MobileSyncSessionSnapshot(
            queuedCommands: state.queuedCommands.sorted { $0.position < $1.position },
            recentHistory: state.recentHistory,
            receipts: state.receipts,
            outgoingSequence: state.outgoingSequence,
            incomingSequence: state.incomingSequence,
            relayCursor: state.relayCursor,
            resyncExpectedSequence: state.resyncExpectedSequence,
            readOnlyReason: state.readOnlyReason
        )
    }

    public func replaceQueuedCommands(_ commands: [MobileQueuedCommand]) async throws {
        try requireWritable()
        guard commands.count <= Self.maximumQueueItems,
              Set(commands.map(\.id)).count == commands.count,
              commands.allSatisfy({
                  MobileSyncIdentifier.isValid($0.streamID)
                      && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.body.utf8.count <= MobileSyncCipher.maximumPlaintextBytes / 2
              }) else {
            throw MobileSyncSessionError.invalidQueue
        }
        let existing = Dictionary(uniqueKeysWithValues: state.queuedCommands.map { ($0.id, $0) })
        var normalized: [MobileQueuedCommand] = []
        for (offset, proposed) in commands.enumerated() {
            if let current = existing[proposed.id] {
                guard current.deliveryState == .savedOnPhone,
                      !state.outbox.contains(where: { $0.payloadID == Self.queuePayloadID(proposed.id) }) else {
                    throw MobileSyncSessionError.queueItemAlreadyStaged
                }
                var changed = proposed
                changed.position = offset + 1
                changed.revision = current.revision + (
                    current.body == changed.body && current.position == changed.position ? 0 : 1
                )
                normalized.append(changed)
            } else {
                var added = proposed
                added.position = offset + 1
                added.revision = max(added.revision, 1)
                added.deliveryState = .savedOnPhone
                normalized.append(added)
            }
        }
        for removed in state.queuedCommands where !commands.contains(where: { $0.id == removed.id }) {
            guard removed.deliveryState == .savedOnPhone,
                  !state.outbox.contains(where: { $0.payloadID == Self.queuePayloadID(removed.id) }) else {
                throw MobileSyncSessionError.queueItemAlreadyStaged
            }
        }
        state.queuedCommands = normalized
        try await persist()
    }

    @discardableResult
    public func sendPayload(
        payloadID: String,
        payloadKind: String,
        plaintext: Data,
        nowUnixMillis: Int64
    ) async throws -> MobileRelaySendReceipt {
        try requireWritable()
        guard MobileSyncIdentifier.isValid(payloadID),
              MobileSyncIdentifier.isValid(payloadKind),
              !plaintext.isEmpty,
              plaintext.count <= MobileSyncCipher.maximumPlaintextBytes else {
            throw MobileSyncSessionError.invalidPayload
        }
        let payloadDigest = Data(SHA256.hash(data: plaintext))
        let outbound: OutboundEnvelope
        if let existing = state.outbox.first(where: { $0.payloadID == payloadID }) {
            guard existing.payloadKind == payloadKind,
                  existing.payloadDigest == payloadDigest else {
                throw MobileSyncSessionError.payloadIDReused
            }
            outbound = existing
        } else {
            outbound = try await stagePayload(
                payloadID: payloadID,
                payloadKind: payloadKind,
                payloadDigest: payloadDigest,
                plaintext: plaintext,
                nowUnixMillis: nowUnixMillis
            )
        }
        let receipt = try await transport.send(
            envelopeWire: outbound.envelopeWire,
            nowUnixMillis: nowUnixMillis
        )
        if let index = state.outbox.firstIndex(where: { $0.payloadID == payloadID }) {
            state.outbox[index].relayAccepted = true
        }
        try await persist()
        return receipt
    }

    public func dispatchQueuedCommands(nowUnixMillis: Int64) async throws {
        for command in state.queuedCommands.sorted(by: { $0.position < $1.position })
            where command.deliveryState == .savedOnPhone {
            var wire = Kaname_V1_QueueItem()
            wire.itemID = command.id.uuidString.lowercased()
            wire.streamID = command.streamID
            wire.revision = command.revision
            wire.position = UInt64(command.position)
            wire.body = command.body
            wire.authorID = configuration.deviceID
            wire.createdAtUnixMillis = command.createdAtUnixMillis
            wire.disposition = "queued"
            _ = try await sendPayload(
                payloadID: Self.queuePayloadID(command.id),
                payloadKind: "queue.enqueue",
                plaintext: try wire.serializedData(),
                nowUnixMillis: nowUnixMillis
            )
            if let index = state.queuedCommands.firstIndex(where: { $0.id == command.id }) {
                state.queuedCommands[index].deliveryState = .relayAccepted
                state.queuedCommands[index].reasonCode = "ciphertext_relay_accepted"
            }
            try await persist()
        }
    }

    public func retryPendingPayloads(nowUnixMillis: Int64) async throws {
        let pending = state.outbox.filter { !$0.relayAccepted }
        for outbound in pending {
            _ = try await transport.send(
                envelopeWire: outbound.envelopeWire,
                nowUnixMillis: nowUnixMillis
            )
            if let outboxIndex = state.outbox.firstIndex(where: { $0.payloadID == outbound.payloadID }) {
                state.outbox[outboxIndex].relayAccepted = true
            }
            if outbound.payloadID.hasPrefix("queue-"),
               let queueIndex = state.queuedCommands.firstIndex(where: {
                   Self.queuePayloadID($0.id) == outbound.payloadID
               }) {
                state.queuedCommands[queueIndex].deliveryState = .relayAccepted
                state.queuedCommands[queueIndex].reasonCode = "ciphertext_relay_accepted"
            }
            try await persist()
        }
    }

    public func pollIncoming(nowUnixMillis: Int64, limit: Int = 50) async throws -> MobileSyncPollResult {
        try requireWritable()
        let page = try await transport.pull(
            recipientDeviceID: configuration.deviceID,
            afterPosition: state.relayCursor,
            limit: limit
        )
        var applied = 0
        var duplicates = 0
        for delivery in page.deliveries {
            let outcome = try await applyIncoming(delivery, nowUnixMillis: nowUnixMillis)
            switch outcome {
            case .applied: applied += 1
            case .duplicate: duplicates += 1
            }
            try await transport.acknowledge(
                deliveryID: delivery.deliveryID,
                recipientDeviceID: configuration.deviceID
            )
            state.relayCursor = max(state.relayCursor, delivery.relayPosition)
            try await persist()
        }
        return MobileSyncPollResult(
            applied: applied,
            duplicates: duplicates,
            relayCursor: state.relayCursor,
            resyncExpectedSequence: state.resyncExpectedSequence
        )
    }

    public func enterReadOnly(reason: String) async throws {
        guard !reason.isEmpty, reason.utf8.count <= 128 else {
            throw MobileSyncSessionError.invalidPayload
        }
        state.readOnlyReason = reason
        try await persist()
    }

    public func leaveReadOnlyForRecovery() async throws {
        state.readOnlyReason = nil
        try await persist()
    }

    private enum IncomingOutcome {
        case applied
        case duplicate
    }

    private func applyIncoming(
        _ delivery: MobileRelayDelivery,
        nowUnixMillis: Int64
    ) async throws -> IncomingOutcome {
        guard let envelope = try? Kaname_V1_EncryptedSyncEnvelope(
            serializedBytes: delivery.envelopeWire
        ),
        let header = try? Kaname_V1_SyncAuthenticatedHeader(
            serializedBytes: envelope.authenticatedHeader
        ),
        header.senderDeviceID == configuration.peerDeviceID,
        header.senderKeyID == configuration.peerKeyID else {
            throw MobileSyncSessionError.invalidPayload
        }
        let exactDigest = Data(SHA256.hash(data: delivery.envelopeWire))
        let expectedSequence = state.incomingSequence + 1
        if header.senderSequence < expectedSequence {
            guard state.incomingEnvelopeDigests[header.envelopeID] == exactDigest else {
                throw MobileSyncSessionError.replayDetected
            }
            return .duplicate
        }
        if header.senderSequence > expectedSequence {
            state.resyncExpectedSequence = expectedSequence
            try await persist()
            throw MobileSyncSessionError.resyncRequired(expectedSequence: expectedSequence)
        }
        if header.senderSequence == 1 {
            guard header.previousEnvelopeDigest.isEmpty else {
                throw MobileSyncSessionError.chainMismatch
            }
        } else if header.previousEnvelopeDigest != state.incomingEnvelopeDigest {
            throw MobileSyncSessionError.chainMismatch
        }
        let privateKey = try await keyStore.privateKey(keyID: configuration.keyID)
        let opened = try MobileSyncCipher.open(
            envelope,
            recipientPrivateKey: privateKey,
            senderPublicKey: configuration.peerPublicKey,
            expectedRecipientDeviceID: configuration.deviceID,
            expectedRecipientKeyID: configuration.keyID,
            nowUnixMillis: nowUnixMillis
        )
        try applyPlaintext(
            opened.plaintext,
            payloadKind: opened.header.payloadKind,
            nowUnixMillis: nowUnixMillis
        )
        state.incomingSequence = opened.header.senderSequence
        state.incomingEnvelopeDigest = exactDigest
        state.incomingEnvelopeDigests[opened.header.envelopeID] = exactDigest
        state.resyncExpectedSequence = nil
        try await persist()
        return .applied
    }

    private func applyPlaintext(
        _ plaintext: Data,
        payloadKind: String,
        nowUnixMillis: Int64
    ) throws {
        switch payloadKind {
        case "queue.receipt":
            let receipt = try Kaname_V1_QueueReceipt(serializedBytes: plaintext)
            guard let itemID = UUID(uuidString: receipt.itemID),
                  let index = state.queuedCommands.firstIndex(where: { $0.id == itemID }),
                  receipt.revision == state.queuedCommands[index].revision else {
                throw MobileSyncSessionError.queueItemNotFound
            }
            let mapped = Self.queueState(receipt.state)
            state.queuedCommands[index].deliveryState = mapped
            state.queuedCommands[index].reasonCode = "mac_queue_receipt"
            appendReceipt(
                subjectID: receipt.itemID,
                state: mapped,
                reasonCode: "mac_queue_receipt",
                recordedAtUnixMillis: receipt.recordedAtUnixMillis
            )
        case "sync.receipt":
            let receipt = try Kaname_V1_SyncReceipt(serializedBytes: plaintext)
            let mapped: MobileQueueDeliveryState = switch receipt.state {
            case .received, .decrypted: .receivedByMac
            case .policyAccepted, .applied: .policyAccepted
            case .resyncRequired: .resyncRequired
            default: .rejected
            }
            appendReceipt(
                subjectID: receipt.envelopeID,
                state: mapped,
                reasonCode: receipt.reasonCode,
                recordedAtUnixMillis: receipt.recordedAtUnixMillis
            )
        case "event.history":
            let event = try Kaname_V1_EventEnvelope(serializedBytes: plaintext)
            guard MobileSyncIdentifier.isValid(event.eventID),
                  MobileSyncIdentifier.isValid(event.streamID),
                  event.storePosition > 0,
                  event.streamSequence > 0,
                  !event.kind.isEmpty else {
                throw MobileSyncSessionError.invalidPayload
            }
            if !state.recentHistory.contains(where: { $0.eventID == event.eventID }) {
                state.recentHistory.append(
                    MobileCachedHistoryRecord(
                        eventID: event.eventID,
                        streamID: event.streamID,
                        storePosition: event.storePosition,
                        streamSequence: event.streamSequence,
                        kind: event.kind,
                        occurredAtUnixMillis: event.occurredAtUnixMillis,
                        exactEventWire: plaintext
                    )
                )
                state.recentHistory.sort { $0.storePosition < $1.storePosition }
                if state.recentHistory.count > historyLimit {
                    state.recentHistory.removeFirst(state.recentHistory.count - historyLimit)
                }
            }
        case "approval.receipt":
            let receipt = try Kaname_V1_ApprovalCommandReceipt(serializedBytes: plaintext)
            let mapped: MobileQueueDeliveryState = receipt.decision == .approve
                ? .policyAccepted
                : .rejected
            appendReceipt(
                subjectID: receipt.approvalID,
                state: mapped,
                reasonCode: receipt.reasonCode,
                recordedAtUnixMillis: nowUnixMillis
            )
        default:
            throw MobileSyncSessionError.unsupportedPayloadKind
        }
    }

    private func appendReceipt(
        subjectID: String,
        state receiptState: MobileQueueDeliveryState,
        reasonCode: String,
        recordedAtUnixMillis: Int64
    ) {
        let identity = "\(subjectID):\(receiptState.rawValue):\(reasonCode)"
        guard !state.receipts.contains(where: { $0.id == identity }) else { return }
        state.receipts.append(
            MobileSyncReceiptRecord(
                id: identity,
                subjectID: subjectID,
                state: receiptState,
                reasonCode: reasonCode,
                recordedAtUnixMillis: recordedAtUnixMillis
            )
        )
        if state.receipts.count > Self.maximumReceipts {
            state.receipts.removeFirst(state.receipts.count - Self.maximumReceipts)
        }
    }

    private func stagePayload(
        payloadID: String,
        payloadKind: String,
        payloadDigest: Data,
        plaintext: Data,
        nowUnixMillis: Int64
    ) async throws -> OutboundEnvelope {
        let sequence = state.outgoingSequence + 1
        let envelopeID = "\(configuration.deviceID)-envelope-\(sequence)"
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        var header = Kaname_V1_SyncAuthenticatedHeader()
        header.schemaVersion = version
        header.envelopeID = envelopeID
        header.senderDeviceID = configuration.deviceID
        header.senderKeyID = configuration.keyID
        header.recipientDeviceID = configuration.peerDeviceID
        header.recipientKeyID = configuration.peerKeyID
        header.senderSequence = sequence
        header.previousEnvelopeDigest = state.outgoingEnvelopeDigest
        header.sentAtUnixMillis = nowUnixMillis
        header.expiresAtUnixMillis = nowUnixMillis + 5 * 60 * 1_000
        header.payloadKind = payloadKind
        header.contentType = "application/x-protobuf"
        let privateKey = try await keyStore.privateKey(keyID: configuration.keyID)
        let envelope = try MobileSyncCipher.seal(
            plaintext,
            header: header,
            senderPrivateKey: privateKey,
            recipientPublicKey: configuration.peerPublicKey,
            nowUnixMillis: nowUnixMillis
        )
        let envelopeWire = try envelope.serializedData()
        let envelopeDigest = Data(SHA256.hash(data: envelopeWire))
        let outbound = OutboundEnvelope(
            payloadID: payloadID,
            payloadKind: payloadKind,
            payloadDigest: payloadDigest,
            envelopeID: envelopeID,
            senderSequence: sequence,
            envelopeWire: envelopeWire,
            envelopeDigest: envelopeDigest,
            relayAccepted: false
        )
        state.outbox.append(outbound)
        state.outgoingSequence = sequence
        state.outgoingEnvelopeDigest = envelopeDigest
        try await persist()
        return outbound
    }

    private func validatePersistedState() throws {
        guard state.queuedCommands.count <= Self.maximumQueueItems,
              Set(state.queuedCommands.map(\.id)).count == state.queuedCommands.count,
              Set(state.queuedCommands.map(\.position)).count == state.queuedCommands.count,
              state.queuedCommands.allSatisfy({
                  $0.position > 0
                      && $0.revision > 0
                      && MobileSyncIdentifier.isValid($0.streamID)
                      && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              state.recentHistory.count <= historyLimit,
              state.receipts.count <= Self.maximumReceipts,
              state.outbox.count <= Self.maximumQueueItems + Self.maximumReceipts,
              Set(state.outbox.map(\.payloadID)).count == state.outbox.count,
              state.outbox.allSatisfy({ $0.senderSequence > 0 }),
              state.outbox.map(\.senderSequence).max() ?? 0 <= state.outgoingSequence,
              state.incomingEnvelopeDigests.count <= state.incomingSequence else {
            throw MobileSyncSessionError.stateMalformed
        }
    }

    private func persist() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumPersistedStateBytes else {
            throw MobileSyncSessionError.stateTooLarge
        }
        try await stateStore.save(data)
    }

    private func requireWritable() throws {
        if let reason = state.readOnlyReason {
            throw MobileSyncSessionError.readOnly(reason)
        }
    }

    private static func queuePayloadID(_ id: UUID) -> String {
        "queue-\(id.uuidString.lowercased())"
    }

    private static func queueState(
        _ state: Kaname_V1_QueueReceiptState
    ) -> MobileQueueDeliveryState {
        switch state {
        case .savedOnPhone: .savedOnPhone
        case .receivedByMac: .receivedByMac
        case .policyAccepted: .policyAccepted
        case .providerDispatchAccepted: .providerDispatchAccepted
        case .runStarted: .runStarted
        default: .rejected
        }
    }
}
