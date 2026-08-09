import CryptoKit
import Foundation
import KanameProtocol
import SwiftProtobuf

public enum MobileSyncError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidIdentity
    case invalidKey
    case payloadTooLarge
    case expired
    case recipientMismatch
    case plaintextDigestMismatch
    case malformedEnvelope
    case authenticationFailed
}

/// The first mobile-sync cryptographic boundary. It uses authenticated
/// RFC 9180 HPKE so both confidentiality and sender-key possession are checked.
/// Device private keys are supplied by the caller and are never serialized by
/// this type; production callers must load them from the platform Keychain.
@available(macOS 14.0, iOS 17.0, *)
public enum MobileSyncCipher {
    public static let maximumPlaintextBytes = 64 * 1024
    public static let maximumHeaderBytes = 4 * 1024
    public static let maximumCiphertextBytes = maximumPlaintextBytes + 256

    private static let info = Data("kaname.sync.hpke.auth.v1".utf8)
    private static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public static func seal(
        _ plaintext: Data,
        header proposedHeader: Kaname_V1_SyncAuthenticatedHeader,
        senderPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        nowUnixMillis: Int64
    ) throws -> Kaname_V1_EncryptedSyncEnvelope {
        guard !plaintext.isEmpty, plaintext.count <= maximumPlaintextBytes else {
            throw MobileSyncError.payloadTooLarge
        }
        var header = proposedHeader
        header.plaintextDigest = Data(SHA256.hash(data: plaintext))
        try validate(header: header, nowUnixMillis: nowUnixMillis)

        let authenticatedHeader = try header.serializedData()
        guard authenticatedHeader.count <= maximumHeaderBytes else {
            throw MobileSyncError.invalidHeader
        }
        do {
            var sender = try HPKE.Sender(
                recipientKey: recipientPublicKey,
                ciphersuite: ciphersuite,
                info: info,
                authenticatedBy: senderPrivateKey
            )
            let ciphertext = try sender.seal(plaintext, authenticating: authenticatedHeader)
            guard ciphertext.count <= maximumCiphertextBytes else {
                throw MobileSyncError.payloadTooLarge
            }
            var envelope = Kaname_V1_EncryptedSyncEnvelope()
            envelope.authenticatedHeader = authenticatedHeader
            envelope.encapsulatedKey = sender.encapsulatedKey
            envelope.ciphertext = ciphertext
            return envelope
        } catch let error as MobileSyncError {
            throw error
        } catch {
            throw MobileSyncError.authenticationFailed
        }
    }

    public static func open(
        _ envelope: Kaname_V1_EncryptedSyncEnvelope,
        recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        senderPublicKey: Curve25519.KeyAgreement.PublicKey,
        expectedRecipientDeviceID: String,
        expectedRecipientKeyID: String,
        nowUnixMillis: Int64
    ) throws -> (header: Kaname_V1_SyncAuthenticatedHeader, plaintext: Data) {
        guard !envelope.authenticatedHeader.isEmpty,
              envelope.authenticatedHeader.count <= maximumHeaderBytes,
              !envelope.encapsulatedKey.isEmpty,
              !envelope.ciphertext.isEmpty,
              envelope.ciphertext.count <= maximumCiphertextBytes,
              let header = try? Kaname_V1_SyncAuthenticatedHeader(
                serializedBytes: envelope.authenticatedHeader
              ) else {
            throw MobileSyncError.malformedEnvelope
        }
        try validate(header: header, nowUnixMillis: nowUnixMillis)
        guard header.recipientDeviceID == expectedRecipientDeviceID,
              header.recipientKeyID == expectedRecipientKeyID else {
            throw MobileSyncError.recipientMismatch
        }

        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: recipientPrivateKey,
                ciphersuite: ciphersuite,
                info: info,
                encapsulatedKey: envelope.encapsulatedKey,
                authenticatedBy: senderPublicKey
            )
            plaintext = try recipient.open(
                envelope.ciphertext,
                authenticating: envelope.authenticatedHeader
            )
        } catch {
            throw MobileSyncError.authenticationFailed
        }
        guard plaintext.count <= maximumPlaintextBytes else {
            throw MobileSyncError.payloadTooLarge
        }
        guard Data(SHA256.hash(data: plaintext)) == header.plaintextDigest else {
            throw MobileSyncError.plaintextDigestMismatch
        }
        return (header, plaintext)
    }

    public static func publicIdentity(
        deviceID: String,
        keyID: String,
        displayName: String,
        platform: String,
        keyGeneration: UInt64,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        createdAtUnixMillis: Int64,
        expiresAtUnixMillis: Int64
    ) throws -> Kaname_V1_DevicePublicIdentity {
        guard MobileSyncIdentifier.isValid(deviceID),
              MobileSyncIdentifier.isValid(keyID),
              !displayName.isEmpty,
              displayName.utf8.count <= 128,
              ["ios", "macos"].contains(platform),
              keyGeneration > 0,
              expiresAtUnixMillis > createdAtUnixMillis else {
            throw MobileSyncError.invalidIdentity
        }
        var identity = Kaname_V1_DevicePublicIdentity()
        identity.deviceID = deviceID
        identity.keyID = keyID
        identity.displayName = displayName
        identity.platform = platform
        identity.hpkePublicKey = publicKey.rawRepresentation
        identity.keyGeneration = keyGeneration
        identity.createdAtUnixMillis = createdAtUnixMillis
        identity.expiresAtUnixMillis = expiresAtUnixMillis
        return identity
    }

    public static func decodePublicKey(
        from identity: Kaname_V1_DevicePublicIdentity
    ) throws -> Curve25519.KeyAgreement.PublicKey {
        guard identity.hpkePublicKey.count == 32 else {
            throw MobileSyncError.invalidKey
        }
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: identity.hpkePublicKey)
        } catch {
            throw MobileSyncError.invalidKey
        }
    }

    private static func validate(
        header: Kaname_V1_SyncAuthenticatedHeader,
        nowUnixMillis: Int64
    ) throws {
        guard header.schemaVersion.major == 1,
              MobileSyncIdentifier.isValid(header.envelopeID),
              MobileSyncIdentifier.isValid(header.senderDeviceID),
              MobileSyncIdentifier.isValid(header.senderKeyID),
              MobileSyncIdentifier.isValid(header.recipientDeviceID),
              MobileSyncIdentifier.isValid(header.recipientKeyID),
              header.senderDeviceID != header.recipientDeviceID,
              header.senderSequence > 0,
              header.sentAtUnixMillis > 0,
              header.expiresAtUnixMillis > header.sentAtUnixMillis,
              !header.payloadKind.isEmpty,
              header.payloadKind.utf8.count <= 128,
              header.plaintextDigest.count == SHA256.byteCount,
              header.contentType == "application/x-protobuf" else {
            throw MobileSyncError.invalidHeader
        }
        guard header.expiresAtUnixMillis > nowUnixMillis else {
            throw MobileSyncError.expired
        }
        if header.senderSequence == 1 {
            guard header.previousEnvelopeDigest.isEmpty else {
                throw MobileSyncError.invalidHeader
            }
        } else if header.previousEnvelopeDigest.count != SHA256.byteCount {
            throw MobileSyncError.invalidHeader
        }
    }

}
