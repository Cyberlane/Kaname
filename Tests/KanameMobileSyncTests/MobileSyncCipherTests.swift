import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import Testing
import Security

struct MobileSyncCipherTests {
    private let now: Int64 = 1_786_220_000_000

    @Test
    func authenticatedHPKERoundTripPreservesExactHeaderAndPayload() throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data("queue-item-protobuf".utf8)
        let proposed = header(sequence: 1)

        let envelope = try MobileSyncCipher.seal(
            plaintext,
            header: proposed,
            senderPrivateKey: phone,
            recipientPublicKey: mac.publicKey,
            nowUnixMillis: now
        )
        let opened = try MobileSyncCipher.open(
            envelope,
            recipientPrivateKey: mac,
            senderPublicKey: phone.publicKey,
            expectedRecipientDeviceID: "mac-authority",
            expectedRecipientKeyID: "mac-key-1",
            nowUnixMillis: now
        )

        #expect(opened.plaintext == plaintext)
        #expect(opened.header.senderSequence == 1)
        #expect(opened.header.plaintextDigest.count == 32)
        #expect(try opened.header.serializedData() == envelope.authenticatedHeader)
    }

    @Test
    func clearRoutingHeaderCannotBeChangedWithoutAuthenticationFailure() throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        var envelope = try MobileSyncCipher.seal(
            Data("approval-resolution".utf8),
            header: header(sequence: 1),
            senderPrivateKey: phone,
            recipientPublicKey: mac.publicKey,
            nowUnixMillis: now
        )
        var changed = try Kaname_V1_SyncAuthenticatedHeader(
            serializedBytes: envelope.authenticatedHeader
        )
        changed.payloadKind = "queue.remove"
        envelope.authenticatedHeader = try changed.serializedData()

        #expect(throws: MobileSyncError.authenticationFailed) {
            try MobileSyncCipher.open(
                envelope,
                recipientPrivateKey: mac,
                senderPublicKey: phone.publicKey,
                expectedRecipientDeviceID: "mac-authority",
                expectedRecipientKeyID: "mac-key-1",
                nowUnixMillis: now
            )
        }
    }

    @Test
    func expiredEnvelopeFailsBeforePlaintextIsReturned() throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try MobileSyncCipher.seal(
            Data("queued-message".utf8),
            header: header(sequence: 1),
            senderPrivateKey: phone,
            recipientPublicKey: mac.publicKey,
            nowUnixMillis: now
        )

        #expect(throws: MobileSyncError.expired) {
            try MobileSyncCipher.open(
                envelope,
                recipientPrivateKey: mac,
                senderPublicKey: phone.publicKey,
                expectedRecipientDeviceID: "mac-authority",
                expectedRecipientKeyID: "mac-key-1",
                nowUnixMillis: now + 60_001
            )
        }
    }

    @Test
    func publicIdentityContainsOnlyPublicKeyMaterial() throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let identity = try MobileSyncCipher.publicIdentity(
            deviceID: "iphone-justin",
            keyID: "iphone-key-1",
            displayName: "Justin's iPhone",
            platform: "ios",
            keyGeneration: 1,
            publicKey: phone.publicKey,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )

        #expect(identity.hpkePublicKey == phone.publicKey.rawRepresentation)
        #expect(try MobileSyncCipher.decodePublicKey(from: identity).rawRepresentation == phone.publicKey.rawRepresentation)
        #expect(identity.unknownFields.data.isEmpty)
    }

    @Test
    func publicIdentityRejectsIdentifiersOutsideTheSharedGrammar() throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let phone = Curve25519.KeyAgreement.PrivateKey()

        #expect(throws: MobileSyncError.invalidIdentity) {
            try MobileSyncCipher.publicIdentity(
                deviceID: "iphone/justin",
                keyID: "iphone-key-1",
                displayName: "Justin's iPhone",
                platform: "ios",
                keyGeneration: 1,
                publicKey: phone.publicKey,
                createdAtUnixMillis: now,
                expiresAtUnixMillis: now + 86_400_000
            )
        }
    }

    @Test
    func keychainContractIsDeviceOnlyAndAvailableAfterFirstUnlock() throws {
        let store = try KeychainMobileSyncKeyStore(service: "com.cyber-lane.kaname.mobile-sync")
        let attributes = KeychainMobileSyncKeyStore.storageAttributes(
            service: store.service,
            keyID: "mac-key-1"
        )
        let accessibility = attributes[kSecAttrAccessible] as! CFString
        let synchronizable = attributes[kSecAttrSynchronizable] as! CFBoolean

        #expect(accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(!CFBooleanGetValue(synchronizable))
        #expect(attributes[kSecValueData] == nil)
        #expect(attributes[kSecUseDataProtectionKeychain] as? Bool == true)
    }

    @Test
    func keychainStoreRejectsIdentifiersOutsideTheSharedGrammar() {
        #expect(throws: MobileSyncKeyStoreError.invalidIdentifier) {
            try KeychainMobileSyncKeyStore(service: "com.cyber-lane.kaname/mobile-sync")
        }
    }

    private func header(sequence: UInt64) -> Kaname_V1_SyncAuthenticatedHeader {
        var version = Kaname_V1_SchemaVersion()
        version.major = 1

        var value = Kaname_V1_SyncAuthenticatedHeader()
        value.schemaVersion = version
        value.envelopeID = "envelope-\(sequence)"
        value.senderDeviceID = "iphone-justin"
        value.senderKeyID = "iphone-key-1"
        value.recipientDeviceID = "mac-authority"
        value.recipientKeyID = "mac-key-1"
        value.senderSequence = sequence
        if sequence > 1 {
            value.previousEnvelopeDigest = Data(repeating: 0x41, count: 32)
        }
        value.sentAtUnixMillis = now
        value.expiresAtUnixMillis = now + 60_000
        value.payloadKind = "queue.enqueue"
        value.contentType = "application/x-protobuf"
        return value
    }
}
