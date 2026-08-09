import CryptoKit
import Foundation
import KanameProtocol

public enum MobileEnrollmentPhase: String, Equatable, Sendable {
    case unenrolled
    case awaitingLocalConfirmation
    case active
    case rejected
    case revoked
}

public enum MobileReachability: String, Equatable, Sendable {
    case unavailable
    case checking
    case reachable
    case degraded
}

public struct MobileEnrollmentSnapshot: Equatable, Sendable {
    public var phase: MobileEnrollmentPhase
    public var reachability: MobileReachability
    public var deviceID: String
    public var keyID: String?
    public var keyGeneration: UInt64
    public var enrollmentID: String?
    public var reasonCode: String?

    public init(deviceID: String) {
        self.phase = .unenrolled
        self.reachability = .unavailable
        self.deviceID = deviceID
        self.keyID = nil
        self.keyGeneration = 0
        self.enrollmentID = nil
        self.reasonCode = nil
    }
}

public struct MobileEnrollmentProposal: Sendable {
    public let challenge: Kaname_V1_DeviceEnrollmentChallenge
    /// Ephemeral human-comparison value. It is deliberately absent from the
    /// protobuf challenge and from `MobileEnrollmentSnapshot`.
    public let confirmationCode: String

    public init(
        challenge: Kaname_V1_DeviceEnrollmentChallenge,
        confirmationCode: String
    ) {
        self.challenge = challenge
        self.confirmationCode = confirmationCode
    }
}

@available(macOS 14.0, iOS 17.0, *)
public protocol MobileSyncPrivateKeyStore: Sendable {
    func createKey(keyID: String) async throws -> Curve25519.KeyAgreement.PublicKey
    func privateKey(keyID: String) async throws -> Curve25519.KeyAgreement.PrivateKey
    func deleteKey(keyID: String) async throws
}

@available(macOS 14.0, iOS 17.0, *)
public actor InMemoryMobileSyncPrivateKeyStore: MobileSyncPrivateKeyStore {
    private var keys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]

    public init() {}

    public func createKey(keyID: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        guard keys[keyID] == nil else {
            throw MobileSyncKeyStoreError.duplicateKey
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        keys[keyID] = privateKey
        return privateKey.publicKey
    }

    public func privateKey(keyID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        guard let key = keys[keyID] else {
            throw MobileSyncKeyStoreError.keyNotFound
        }
        return key
    }

    public func deleteKey(keyID: String) throws {
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        keys.removeValue(forKey: keyID)
    }

    public func storedKeyIDs() -> [String] {
        keys.keys.sorted()
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension KeychainMobileSyncKeyStore: MobileSyncPrivateKeyStore {
    public func createKey(keyID: String) async throws -> Curve25519.KeyAgreement.PublicKey {
        try generateAndStore(keyID: keyID)
    }

    public func privateKey(keyID: String) async throws -> Curve25519.KeyAgreement.PrivateKey {
        try load(keyID: keyID)
    }

    public func deleteKey(keyID: String) async throws {
        try remove(keyID: keyID)
    }
}

public protocol MobileEnrollmentEntropy: Sendable {
    func nonce(count: Int) throws -> Data
    func confirmationCode() -> String
}

public struct SystemMobileEnrollmentEntropy: MobileEnrollmentEntropy {
    public init() {}

    public func nonce(count: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public func confirmationCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0 ... 999_999, using: &generator))
    }
}

public enum MobileEnrollmentShellError: Error, Equatable, Sendable {
    case enrollmentAlreadyPending
    case invalidConfirmationCode
    case receiptMismatch
    case unsupportedReceiptState
}

@available(macOS 14.0, iOS 17.0, *)
public actor MobileEnrollmentShell {
    private let keyStore: any MobileSyncPrivateKeyStore
    private let entropy: any MobileEnrollmentEntropy
    private let displayName: String
    private var state: MobileEnrollmentSnapshot

    public init(
        deviceID: String,
        displayName: String,
        keyStore: any MobileSyncPrivateKeyStore,
        entropy: any MobileEnrollmentEntropy = SystemMobileEnrollmentEntropy()
    ) throws {
        guard MobileSyncIdentifier.isValid(deviceID),
              !displayName.isEmpty,
              displayName.utf8.count <= 128 else {
            throw MobileSyncError.invalidIdentity
        }
        self.keyStore = keyStore
        self.entropy = entropy
        self.displayName = displayName
        self.state = MobileEnrollmentSnapshot(deviceID: deviceID)
    }

    public func snapshot() -> MobileEnrollmentSnapshot {
        state
    }

    public func setReachability(_ reachability: MobileReachability, reasonCode: String? = nil) {
        state.reachability = reachability
        state.reasonCode = reasonCode
    }

    public func prepareEnrollment(
        enrollmentID: String,
        keyID: String,
        keyGeneration: UInt64,
        createdAtUnixMillis: Int64,
        expiresAtUnixMillis: Int64
    ) async throws -> MobileEnrollmentProposal {
        guard state.phase != .awaitingLocalConfirmation else {
            throw MobileEnrollmentShellError.enrollmentAlreadyPending
        }
        let publicKey = try await keyStore.createKey(keyID: keyID)
        do {
            let identity = try MobileSyncCipher.publicIdentity(
                deviceID: state.deviceID,
                keyID: keyID,
                displayName: displayName,
                platform: "ios",
                keyGeneration: keyGeneration,
                publicKey: publicKey,
                createdAtUnixMillis: createdAtUnixMillis,
                expiresAtUnixMillis: expiresAtUnixMillis
            )
            let macNonce = try entropy.nonce(count: 32)
            let confirmationCode = entropy.confirmationCode()
            guard confirmationCode.count == 6,
                  confirmationCode.allSatisfy(\.isNumber) else {
                throw MobileEnrollmentShellError.invalidConfirmationCode
            }
            let identityWire = try identity.serializedData()
            var confirmationMaterial = Data("kaname.enrollment.v1".utf8)
            confirmationMaterial.append(identityWire)
            confirmationMaterial.append(macNonce)
            confirmationMaterial.append(Data(confirmationCode.utf8))

            var version = Kaname_V1_SchemaVersion()
            version.major = 1
            var challenge = Kaname_V1_DeviceEnrollmentChallenge()
            challenge.schemaVersion = version
            challenge.enrollmentID = enrollmentID
            challenge.proposedDevice = identity
            challenge.macNonce = macNonce
            challenge.confirmationDigest = Data(SHA256.hash(data: confirmationMaterial))
            challenge.expiresAtUnixMillis = expiresAtUnixMillis

            state.phase = .awaitingLocalConfirmation
            state.keyID = keyID
            state.keyGeneration = keyGeneration
            state.enrollmentID = enrollmentID
            state.reasonCode = "pending_local_confirmation"
            return MobileEnrollmentProposal(
                challenge: challenge,
                confirmationCode: confirmationCode
            )
        } catch {
            try? await keyStore.deleteKey(keyID: keyID)
            throw error
        }
    }

    public func applyEnrollmentReceipt(_ receipt: Kaname_V1_DeviceEnrollmentReceipt) throws {
        guard receipt.enrollmentID == state.enrollmentID,
              receipt.deviceID == state.deviceID else {
            throw MobileEnrollmentShellError.receiptMismatch
        }
        switch receipt.state {
        case .pending:
            state.phase = .awaitingLocalConfirmation
        case .active:
            state.phase = .active
        case .rejected:
            state.phase = .rejected
        case .revoked:
            state.phase = .revoked
            state.reachability = .unavailable
        default:
            throw MobileEnrollmentShellError.unsupportedReceiptState
        }
        state.reasonCode = receipt.reasonCode
    }

    public func resetLocalEnrollment() async throws {
        if let keyID = state.keyID {
            try await keyStore.deleteKey(keyID: keyID)
        }
        state = MobileEnrollmentSnapshot(deviceID: state.deviceID)
    }
}
