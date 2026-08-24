#if os(macOS)
import Darwin
import Foundation
import LocalAuthentication
import Security

public enum KanameLinkTunnelCredentialError: Error, Equatable, LocalizedError, Sendable {
    case invalidToken
    case credentialNotFound
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The Cloudflare Tunnel connector token is malformed."
        case .credentialNotFound:
            "The Cloudflare Tunnel connector credential is not enrolled on this Mac."
        case let .keychainFailure(status):
            "The Cloudflare Tunnel connector credential could not be accessed securely (Keychain status \(status))."
        }
    }
}

/// Opaque connector credential. It deliberately has no printable description,
/// Codable conformance, or public byte accessor.
public final class KanameLinkTunnelToken: @unchecked Sendable {
    public static let minimumByteCount = 20
    public static let maximumByteCount = 8_192

    private var storage: ContiguousArray<UInt8>

    public init(data: Data) throws {
        let bytes = ContiguousArray(data)
        guard Self.isValid(bytes) else {
            throw KanameLinkTunnelCredentialError.invalidToken
        }
        storage = bytes
    }

    deinit {
        storage.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = memset_s(baseAddress, bytes.count, 0, bytes.count)
        }
    }

    public var byteCount: Int { storage.count }

    func withData(_ body: (Data) throws -> Void) rethrows {
        var data = Data(storage)
        defer {
            data.resetBytes(in: data.startIndex ..< data.endIndex)
        }
        try body(data)
    }

    private static func isValid(_ bytes: ContiguousArray<UInt8>) -> Bool {
        guard bytes.count >= minimumByteCount, bytes.count <= maximumByteCount else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
            case 43, 45, 46, 47, 48 ... 57, 61, 65 ... 90, 95, 97 ... 122, 126:
                true
            default:
                false
            }
        }
    }
}

public protocol KanameLinkTunnelCredentialStoring: Sendable {
    func replaceToken(_ token: KanameLinkTunnelToken) throws
    func loadToken() throws -> KanameLinkTunnelToken
    func deleteToken() throws
}

/// Stores exactly one remotely-managed Tunnel connector token in the local,
/// device-only Data Protection Keychain. The service and account are fixed so
/// callers cannot redirect connector authority into another credential slot.
public struct KeychainKanameLinkTunnelCredentialStore: KanameLinkTunnelCredentialStoring, Sendable {
    public static let service = "com.cyberlane.kaname.link-tunnel"
    public static let account = "cloudflared-connector-token-v1"

    public init() {}

    public func replaceToken(_ token: KanameLinkTunnelToken) throws {
        try token.withData { value in
            let lookup = Self.lookupAttributes()
            let update = SecItemUpdate(
                lookup as CFDictionary,
                [kSecValueData: value] as CFDictionary
            )
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else {
                throw KanameLinkTunnelCredentialError.keychainFailure(update)
            }

            var item = Self.storageAttributes()
            item[kSecValueData] = value
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecSuccess { return }
            if added == errSecDuplicateItem {
                let retried = SecItemUpdate(
                    lookup as CFDictionary,
                    [kSecValueData: value] as CFDictionary
                )
                guard retried == errSecSuccess else {
                    throw KanameLinkTunnelCredentialError.keychainFailure(retried)
                }
                return
            }
            throw KanameLinkTunnelCredentialError.keychainFailure(added)
        }
    }

    public func loadToken() throws -> KanameLinkTunnelToken {
        var query = Self.lookupAttributes()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw KanameLinkTunnelCredentialError.credentialNotFound
        }
        guard status == errSecSuccess else {
            throw KanameLinkTunnelCredentialError.keychainFailure(status)
        }
        guard var data = result as? Data else {
            throw KanameLinkTunnelCredentialError.invalidToken
        }
        result = nil
        defer {
            data.resetBytes(in: data.startIndex ..< data.endIndex)
        }
        return try KanameLinkTunnelToken(data: data)
    }

    /// Deletes only the fixed local Keychain item. This does not rotate or
    /// revoke the corresponding credential at Cloudflare.
    public func deleteToken() throws {
        let status = SecItemDelete(Self.lookupAttributes() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KanameLinkTunnelCredentialError.keychainFailure(status)
        }
    }

    static func lookupAttributes() -> [CFString: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var attributes = storageAttributes()
        attributes[kSecUseAuthenticationContext] = authenticationContext
        return attributes
    }

    static func storageAttributes() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}
#endif
