import CryptoKit
import Foundation
import Security

public enum MobileSyncKeyStoreError: Error, Equatable, Sendable {
    case invalidIdentifier
    case duplicateKey
    case keyNotFound
    case malformedKey
    case keychainFailure(OSStatus)
}

/// Device-only private-key custody for mobile sync. The selected accessibility
/// class permits background reconciliation after the first device unlock while
/// preventing migration through backups or iCloud Keychain synchronization.
public struct KeychainMobileSyncKeyStore: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) throws {
        guard Self.validIdentifier(service),
              accessGroup.map(Self.validIdentifier) ?? true else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        self.service = service
        self.accessGroup = accessGroup
    }

    public func generateAndStore(keyID: String) throws -> Curve25519.KeyAgreement.PublicKey {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try store(privateKey, keyID: keyID)
        return privateKey.publicKey
    }

    public func store(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        keyID: String
    ) throws {
        guard Self.validIdentifier(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.storageAttributes(service: service, keyID: keyID)
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        query[kSecValueData] = privateKey.rawRepresentation
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw MobileSyncKeyStoreError.duplicateKey
        default:
            throw MobileSyncKeyStoreError.keychainFailure(status)
        }
    }

    public func load(keyID: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard Self.validIdentifier(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.lookupAttributes(service: service, keyID: keyID)
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw MobileSyncKeyStoreError.keyNotFound
        }
        guard status == errSecSuccess else {
            throw MobileSyncKeyStoreError.keychainFailure(status)
        }
        guard let data = result as? Data,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            throw MobileSyncKeyStoreError.malformedKey
        }
        return privateKey
    }

    public func remove(keyID: String) throws {
        guard Self.validIdentifier(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.lookupAttributes(service: service, keyID: keyID)
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileSyncKeyStoreError.keychainFailure(status)
        }
    }

    /// Exposed for non-mutating contract tests. It deliberately contains no
    /// key bytes and no synchronizable or migratable storage class.
    public static func storageAttributes(
        service: String,
        keyID: String
    ) -> [CFString: Any] {
        var attributes = lookupAttributes(service: service, keyID: keyID)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable] = kCFBooleanFalse
        return attributes
    }

    private static func lookupAttributes(
        service: String,
        keyID: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || (48...57).contains(byte)
                    || byte == 45
                    || byte == 46
                    || byte == 58
            }
    }
}
