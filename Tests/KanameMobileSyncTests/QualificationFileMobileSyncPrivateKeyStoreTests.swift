import Foundation
@testable import KanameMobileSync
import Testing

struct QualificationFileMobileSyncPrivateKeyStoreTests {
    @Test
    func qualificationKeySurvivesExecutableRestartWithoutLoginKeychain() async throws {
        guard #available(macOS 14.0, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-qualification-key-\(UUID().uuidString)")
        let file = root.appendingPathComponent("mac-private-key.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = QualificationFileMobileSyncPrivateKeyStore(
            expectedKeyID: "mac-phase3-key-test",
            fileURL: file
        )

        let created = try await first.createKey(keyID: "mac-phase3-key-test")
        let firstLoad = try await first.privateKey(keyID: "mac-phase3-key-test")
        let restarted = QualificationFileMobileSyncPrivateKeyStore(
            expectedKeyID: "mac-phase3-key-test",
            fileURL: file
        )
        let restartedLoad = try await restarted.privateKey(keyID: "mac-phase3-key-test")
        let rootMode = try #require(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )

        #expect(created.rawRepresentation == firstLoad.publicKey.rawRepresentation)
        #expect(firstLoad.rawRepresentation == restartedLoad.rawRepresentation)
        #expect(rootMode.intValue == 0o700)
        #expect(fileMode.intValue == 0o600)

        try await restarted.deleteKey(keyID: "mac-phase3-key-test")
        await #expect(throws: MobileSyncKeyStoreError.keyNotFound) {
            try await restarted.privateKey(keyID: "mac-phase3-key-test")
        }
    }

    @Test
    func qualificationKeyStoreRejectsUnexpectedIdentityAndDuplicateCreation() async throws {
        guard #available(macOS 14.0, *) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-qualification-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QualificationFileMobileSyncPrivateKeyStore(
            expectedKeyID: "mac-phase3-key-test",
            fileURL: root.appendingPathComponent("mac-private-key.bin")
        )

        await #expect(throws: MobileSyncKeyStoreError.invalidIdentifier) {
            try await store.createKey(keyID: "other-key")
        }
        _ = try await store.createKey(keyID: "mac-phase3-key-test")
        await #expect(throws: MobileSyncKeyStoreError.duplicateKey) {
            try await store.createKey(keyID: "mac-phase3-key-test")
        }
    }
}
