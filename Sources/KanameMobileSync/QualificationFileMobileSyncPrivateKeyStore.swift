import CryptoKit
import Darwin
import Foundation

#if os(macOS)
package enum QualificationProtectedFile {
    package static func write(_ data: Data, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPermissions(S_IRWXU, on: directory)
        try data.write(to: fileURL, options: .atomic)
        try setPermissions(S_IRUSR | S_IWUSR, on: fileURL)
    }

    private static func setPermissions(_ mode: mode_t, on url: URL) throws {
        guard chmod(url.path, mode) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

/// A single-key, run-scoped store for the disposable Phase 3 Mac authority.
/// Production device keys remain in the device-only Data Protection Keychain.
@available(macOS 14.0, *)
package actor QualificationFileMobileSyncPrivateKeyStore: MobileSyncPrivateKeyStore {
    private let expectedKeyID: String
    private let fileURL: URL

    package init(expectedKeyID: String, fileURL: URL) {
        self.expectedKeyID = expectedKeyID
        self.fileURL = fileURL
    }

    package func createKey(
        keyID: String
    ) throws -> Curve25519.KeyAgreement.PublicKey {
        try validate(keyID)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MobileSyncKeyStoreError.duplicateKey
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try persist(privateKey.rawRepresentation)
        return privateKey.publicKey
    }

    package func privateKey(
        keyID: String
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        try validate(keyID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MobileSyncKeyStoreError.keyNotFound
        }
        return try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(contentsOf: fileURL)
        )
    }

    package func deleteKey(keyID: String) throws {
        try validate(keyID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func validate(_ keyID: String) throws {
        guard keyID == expectedKeyID, MobileSyncIdentifier.isValid(keyID) else {
            throw MobileSyncKeyStoreError.invalidIdentifier
        }
    }

    private func persist(_ data: Data) throws {
        try QualificationProtectedFile.write(data, to: fileURL)
    }
}
#endif
