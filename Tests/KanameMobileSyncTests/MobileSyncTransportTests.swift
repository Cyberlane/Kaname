import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import Testing

struct MobileSyncTransportTests {
    private let now: Int64 = 1_786_220_000_000

    @Test
    func relayStoresExactCiphertextAndOnlyBoundedRoutingMetadata() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let relay = LocalCiphertextRelay()
        let plaintext = Data("private queued follow-up".utf8)
        let wire = try encryptedWire(plaintext: plaintext, envelopeID: "envelope-1")

        let receipt = try await relay.send(envelopeWire: wire, nowUnixMillis: now)
        let page = try await relay.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 0,
            limit: 10
        )
        let audit = await relay.auditRecords()

        #expect(receipt.deliveryID == "relay-delivery-1")
        #expect(page.deliveries.first?.envelopeWire == wire)
        #expect(!wire.contains(plaintext))
        #expect(audit.count == 1)
        #expect(audit[0].envelopeID == "envelope-1")
        #expect(audit[0].payloadKind == "queue.enqueue")
        #expect(audit[0].envelopeDigest == Data(SHA256.hash(data: wire)))
    }

    @Test
    func disconnectRetryAndDuplicateSendProduceOneStoredDelivery() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let relay = LocalCiphertextRelay()
        let wire = try encryptedWire(
            plaintext: Data("retry once".utf8),
            envelopeID: "envelope-retry"
        )
        await relay.setConnected(false)
        await #expect(throws: MobileSyncTransportError.disconnected) {
            try await relay.send(envelopeWire: wire, nowUnixMillis: now)
        }

        await relay.setConnected(true)
        let first = try await relay.send(envelopeWire: wire, nowUnixMillis: now)
        let duplicate = try await relay.send(envelopeWire: wire, nowUnixMillis: now + 1)

        #expect(!first.duplicate)
        #expect(duplicate.duplicate)
        #expect(duplicate.deliveryID == first.deliveryID)
        #expect(await relay.auditRecords().count == 1)
    }

    @Test
    func pullRetriesUntilRecipientAcknowledgesThenAdvancesCleanly() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let relay = LocalCiphertextRelay()
        let wire = try encryptedWire(
            plaintext: Data("pull retry".utf8),
            envelopeID: "envelope-pull"
        )
        _ = try await relay.send(envelopeWire: wire, nowUnixMillis: now)

        let first = try await relay.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 0,
            limit: 1
        )
        let retry = try await relay.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 0,
            limit: 1
        )
        #expect(retry.deliveries == first.deliveries)

        try await relay.acknowledge(
            deliveryID: first.deliveries[0].deliveryID,
            recipientDeviceID: "mac-authority"
        )
        let afterAck = try await relay.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 0,
            limit: 1
        )
        #expect(afterAck.deliveries.isEmpty)
        #expect(await relay.auditRecords()[0].acknowledged)
    }

    @Test
    func envelopeIdentityCannotBeReusedForDifferentCiphertext() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let relay = LocalCiphertextRelay()
        let first = try encryptedWire(
            plaintext: Data("first".utf8),
            envelopeID: "envelope-collision"
        )
        let changed = try encryptedWire(
            plaintext: Data("changed".utf8),
            envelopeID: "envelope-collision"
        )
        _ = try await relay.send(envelopeWire: first, nowUnixMillis: now)

        await #expect(throws: MobileSyncTransportError.envelopeIDReused) {
            try await relay.send(envelopeWire: changed, nowUnixMillis: now + 1)
        }
        #expect(await relay.auditRecords().count == 1)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func encryptedWire(
        plaintext: Data,
        envelopeID: String
    ) throws -> Data {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        var version = Kaname_V1_SchemaVersion()
        version.major = 1
        var header = Kaname_V1_SyncAuthenticatedHeader()
        header.schemaVersion = version
        header.envelopeID = envelopeID
        header.senderDeviceID = "iphone-justin"
        header.senderKeyID = "iphone-key-1"
        header.recipientDeviceID = "mac-authority"
        header.recipientKeyID = "mac-key-1"
        header.senderSequence = 1
        header.sentAtUnixMillis = now
        header.expiresAtUnixMillis = now + 60_000
        header.payloadKind = "queue.enqueue"
        header.contentType = "application/x-protobuf"
        let envelope = try MobileSyncCipher.seal(
            plaintext,
            header: header,
            senderPrivateKey: phone,
            recipientPublicKey: mac.publicKey,
            nowUnixMillis: now
        )
        return try envelope.serializedData()
    }
}
