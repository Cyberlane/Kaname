#if os(macOS)
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import KanameLinkTunnelHost

@Suite(.serialized)
struct KanameLinkTunnelCredentialTests {
    @Test
    func enrollmentBoundsAndNormalizesOneAnonymousInputValue() throws {
        let store = InMemoryTunnelCredentialStore()
        let enrollment = KanameLinkTunnelTokenEnrollment(credentialStore: store)
        let value = Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ+=\r\n".utf8)

        try enrollment.enroll(from: StubTunnelTokenInput(data: value))

        #expect(store.replacedTokenData == Data(value.dropLast(2)))
        #expect(store.deleteCount == 0)
    }

    @Test
    func liveInputBoundaryAcceptsOnlyAnUnlinkedAnonymousPipe() throws {
        let store = InMemoryTunnelCredentialStore()
        let enrollment = KanameLinkTunnelTokenEnrollment(credentialStore: store)
        let token = Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: token)
        try pipe.fileHandleForWriting.close()

        try enrollment.enrollFromAnonymousPipe(readingHandle: pipe.fileHandleForReading)

        #expect(store.replacedTokenData == token)
        #expect(throws: KanameLinkTunnelEnrollmentError.inputIsNotAnonymousPipe) {
            try enrollment.enrollFromAnonymousPipe(readingHandle: .nullDevice)
        }
    }

    @Test
    func enrollmentRejectsOversizedOrMultipleValuesBeforeStoreMutation() throws {
        let store = InMemoryTunnelCredentialStore()
        let enrollment = KanameLinkTunnelTokenEnrollment(credentialStore: store)
        let oversized = Data(
            repeating: 65,
            count: KanameLinkTunnelToken.maximumByteCount + 3
        )

        #expect(throws: KanameLinkTunnelEnrollmentError.inputTooLarge(
            limit: KanameLinkTunnelToken.maximumByteCount + 2
        )) {
            try enrollment.enroll(from: StubTunnelTokenInput(data: oversized))
        }
        #expect(throws: KanameLinkTunnelCredentialError.invalidToken) {
            try enrollment.enroll(
                from: StubTunnelTokenInput(
                    data: Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==\nsecond".utf8)
                )
            )
        }
        #expect(store.replaceCount == 0)
        #expect(store.deleteCount == 0)
    }

    @Test
    func fixedKeychainIdentityIsDeviceOnlyAndNonSynchronizing() {
        #expect(KeychainKanameLinkTunnelCredentialStore.service ==
            "com.cyberlane.kaname.link-tunnel")
        #expect(KeychainKanameLinkTunnelCredentialStore.account ==
            "cloudflared-connector-token-v1")
        let attributes = KeychainKanameLinkTunnelCredentialStore.lookupAttributes()
        #expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService] as? String ==
            KeychainKanameLinkTunnelCredentialStore.service)
        #expect(attributes[kSecAttrAccount] as? String ==
            KeychainKanameLinkTunnelCredentialStore.account)
        #expect(attributes[kSecAttrSynchronizable] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(attributes[kSecAttrAccessible] as? String ==
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let context = attributes[kSecUseAuthenticationContext] as? LAContext
        #expect(context?.interactionNotAllowed == true)
    }

    @Test
    func explicitLocalDeleteIsDependencyInjectedAndNeverPartOfEnrollment() throws {
        let store = InMemoryTunnelCredentialStore()
        let enrollment = KanameLinkTunnelTokenEnrollment(credentialStore: store)
        let token = Data("eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwifQ==".utf8)
        try enrollment.enroll(from: StubTunnelTokenInput(data: token))
        #expect(store.deleteCount == 0)

        try enrollment.deleteLocalCredential()

        #expect(store.deleteCount == 1)
    }
}

private struct StubTunnelTokenInput: KanameLinkTunnelTokenInputReading, Sendable {
    let data: Data

    func readBounded(maximumBytes: Int) throws -> Data {
        guard data.count <= maximumBytes else {
            throw KanameLinkTunnelEnrollmentError.inputTooLarge(limit: maximumBytes)
        }
        return data
    }
}

private final class InMemoryTunnelCredentialStore:
    KanameLinkTunnelCredentialStoring, @unchecked Sendable
{
    private(set) var replacedTokenData: Data?
    private(set) var replaceCount = 0
    private(set) var deleteCount = 0

    func replaceToken(_ token: KanameLinkTunnelToken) throws {
        token.withData { replacedTokenData = Data($0) }
        replaceCount += 1
    }

    func loadToken() throws -> KanameLinkTunnelToken {
        guard let replacedTokenData else {
            throw KanameLinkTunnelCredentialError.credentialNotFound
        }
        return try KanameLinkTunnelToken(data: replacedTokenData)
    }

    func deleteToken() throws {
        replacedTokenData = nil
        deleteCount += 1
    }
}
#endif
