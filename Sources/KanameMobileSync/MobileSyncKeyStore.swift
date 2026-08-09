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
    public let useDataProtectionKeychain: Bool

    public init(
        service: String,
        accessGroup: String? = nil,
        useDataProtectionKeychain: Bool = true
    ) throws {
        guard MobileSyncIdentifier.isValid(service),
              accessGroup.map(MobileSyncIdentifier.isValid) ?? true else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
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
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.storageAttributes(
            service: service,
            keyID: keyID,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
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
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.lookupAttributes(
            service: service,
            keyID: keyID,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
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
        guard MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
        var query = Self.lookupAttributes(
            service: service,
            keyID: keyID,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
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
        keyID: String,
        useDataProtectionKeychain: Bool = true
    ) -> [CFString: Any] {
        MobileSyncKeychainProtection.storageAttributes(
            service: service,
            account: keyID,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
    }

    private static func lookupAttributes(
        service: String,
        keyID: String,
        useDataProtectionKeychain: Bool
    ) -> [CFString: Any] {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyID,
        ]
        if useDataProtectionKeychain {
            attributes[kSecUseDataProtectionKeychain] = true
        }
        return attributes
    }

}

public enum MobileSyncKeychainProtection {
    public static func storageAttributes(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool = true
    ) -> [CFString: Any] {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain {
            attributes[kSecUseDataProtectionKeychain] = true
        }
        return attributes
    }
}
