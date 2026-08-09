import Foundation
import Security

public enum MobileRelayCredentialStoreError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidToken
    case tokenNotFound
    case keychainFailure(OSStatus)
}

/// Stores the opaque hosted-relay bearer token in the device-only data
/// protection Keychain. The token is never synchronized or migrated.
public struct KeychainMobileRelayCredentialStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String = "relay-bearer-token") throws {
        guard MobileSyncIdentifier.isValid(service),
              MobileSyncIdentifier.isValid(account) else {
            throw MobileRelayCredentialStoreError.invalidIdentifier
        }
        self.service = service
        self.account = account
    }

    public func replace(token: String) throws {
        guard token.utf8.count >= 32, token.utf8.count <= 512 else {
            throw MobileRelayCredentialStoreError.invalidToken
        }
        let value = Data(token.utf8)
        let lookup = Self.lookupAttributes(service: service, account: account)
        let update: [CFString: Any] = [kSecValueData: value]
        let updated = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw MobileRelayCredentialStoreError.keychainFailure(updated)
        }
        var attributes = MobileSyncKeychainProtection.storageAttributes(
            service: service,
            account: account
        )
        attributes[kSecValueData] = value
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw MobileRelayCredentialStoreError.keychainFailure(added)
        }
    }

    public func load() throws -> String {
        var query = Self.lookupAttributes(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw MobileRelayCredentialStoreError.tokenNotFound
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              token.utf8.count >= 32,
              token.utf8.count <= 512 else {
            throw status == errSecSuccess
                ? MobileRelayCredentialStoreError.invalidToken
                : MobileRelayCredentialStoreError.keychainFailure(status)
        }
        return token
    }

    public func remove() throws {
        let status = SecItemDelete(
            Self.lookupAttributes(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileRelayCredentialStoreError.keychainFailure(status)
        }
    }

    private static func lookupAttributes(
        service: String,
        account: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
