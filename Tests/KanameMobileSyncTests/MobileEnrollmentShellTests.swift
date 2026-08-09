import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import Testing

struct MobileEnrollmentShellTests {
    private let now: Int64 = 1_786_220_000_000

    @Test
    func proposalKeepsConfirmationCodeOutOfDurableStateAndWire() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let keyStore = InMemoryMobileSyncPrivateKeyStore()
        let shell = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: keyStore,
            entropy: FixedEnrollmentEntropy()
        )

        let proposal = try await shell.prepareEnrollment(
            enrollmentID: "enrollment-1",
            keyID: "iphone-key-1",
            keyGeneration: 1,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 60_000
        )
        let snapshot = await shell.snapshot()
        let wire = try proposal.challenge.serializedData()

        #expect(proposal.confirmationCode == "204681")
        #expect(snapshot.phase == .awaitingLocalConfirmation)
        #expect(snapshot.enrollmentID == "enrollment-1")
        #expect(snapshot.keyID == "iphone-key-1")
        #expect(!wire.contains(Data("204681".utf8)))
        #expect(proposal.challenge.confirmationDigest.count == 32)
        #expect(await keyStore.storedKeyIDs() == ["iphone-key-1"])
    }

    @Test
    func authorityReceiptAndReachabilityDriveExplicitShellState() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let shell = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: InMemoryMobileSyncPrivateKeyStore(),
            entropy: FixedEnrollmentEntropy()
        )
        _ = try await shell.prepareEnrollment(
            enrollmentID: "enrollment-1",
            keyID: "iphone-key-1",
            keyGeneration: 1,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 60_000
        )
        await shell.setReachability(.reachable)

        var receipt = Kaname_V1_DeviceEnrollmentReceipt()
        receipt.enrollmentID = "enrollment-1"
        receipt.deviceID = "iphone-justin"
        receipt.state = .active
        receipt.reasonCode = "enrollment_activated"
        try await shell.applyEnrollmentReceipt(receipt)

        let snapshot = await shell.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.reachability == .reachable)
        #expect(snapshot.reasonCode == "enrollment_activated")
    }

    @Test
    func mismatchedReceiptCannotActivateAnotherDevice() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let shell = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: InMemoryMobileSyncPrivateKeyStore(),
            entropy: FixedEnrollmentEntropy()
        )
        _ = try await shell.prepareEnrollment(
            enrollmentID: "enrollment-1",
            keyID: "iphone-key-1",
            keyGeneration: 1,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 60_000
        )
        var receipt = Kaname_V1_DeviceEnrollmentReceipt()
        receipt.enrollmentID = "enrollment-other"
        receipt.deviceID = "iphone-justin"
        receipt.state = .active

        await #expect(throws: MobileEnrollmentShellError.receiptMismatch) {
            try await shell.applyEnrollmentReceipt(receipt)
        }
        #expect(await shell.snapshot().phase == .awaitingLocalConfirmation)
    }

    @Test
    func acceptedRotationRetiresTheOldDeviceOnlyKey() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let keyStore = InMemoryMobileSyncPrivateKeyStore()
        let shell = try await activeShell(keyStore: keyStore)

        let proposal = try await shell.prepareKeyRotation(
            nextKeyID: "iphone-key-2",
            nextGeneration: 2,
            rotatedAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )
        #expect(proposal.rotation.previousKeyID == "iphone-key-1")
        #expect(proposal.rotation.nextIdentity.keyID == "iphone-key-2")
        #expect(proposal.rotation.transcriptDigest.count == 32)
        #expect(await keyStore.storedKeyIDs() == ["iphone-key-1", "iphone-key-2"])

        try await shell.finalizeKeyRotation(
            acceptedNextIdentityDigest: proposal.nextIdentityDigest
        )

        let snapshot = await shell.snapshot()
        #expect(snapshot.keyID == "iphone-key-2")
        #expect(snapshot.keyGeneration == 2)
        #expect(snapshot.reasonCode == "key_rotation_accepted")
        #expect(await keyStore.storedKeyIDs() == ["iphone-key-2"])
        await #expect(throws: MobileSyncKeyStoreError.keyNotFound) {
            try await keyStore.privateKey(keyID: "iphone-key-1")
        }
    }

    @Test
    func pendingRotationCanResumeAfterShellRestart() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let keyStore = InMemoryMobileSyncPrivateKeyStore()
        let original = try await activeShell(keyStore: keyStore)
        let proposal = try await original.prepareKeyRotation(
            nextKeyID: "iphone-key-2",
            nextGeneration: 2,
            rotatedAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )
        let enrollment = await original.snapshot()
        let pending = try #require(await original.pendingKeyRotationSnapshot())
        let restored = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: keyStore,
            initialSnapshot: enrollment
        )

        try await restored.restorePendingKeyRotation(pending)
        try await restored.finalizeKeyRotation(
            acceptedNextIdentityDigest: proposal.nextIdentityDigest
        )

        #expect(await restored.snapshot().keyID == "iphone-key-2")
        #expect(await restored.pendingKeyRotationSnapshot() == nil)
        #expect(await keyStore.storedKeyIDs() == ["iphone-key-2"])
    }

    @Test
    func pendingRotationRestoreRequiresTheProtectedNextKey() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let keyStore = InMemoryMobileSyncPrivateKeyStore()
        let original = try await activeShell(keyStore: keyStore)
        _ = try await original.prepareKeyRotation(
            nextKeyID: "iphone-key-2",
            nextGeneration: 2,
            rotatedAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )
        let enrollment = await original.snapshot()
        let pending = try #require(await original.pendingKeyRotationSnapshot())
        try await keyStore.deleteKey(keyID: "iphone-key-2")
        let restored = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: keyStore,
            initialSnapshot: enrollment
        )

        await #expect(throws: MobileSyncKeyStoreError.keyNotFound) {
            try await restored.restorePendingKeyRotation(pending)
        }
        #expect(await restored.pendingKeyRotationSnapshot() == nil)
    }

    @Test
    func lostDeviceRevocationDeletesLocalKeysAndBlocksReenrollment() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let keyStore = InMemoryMobileSyncPrivateKeyStore()
        let shell = try await activeShell(keyStore: keyStore)
        var revocation = Kaname_V1_DeviceRevocation()
        revocation.deviceID = "iphone-justin"
        revocation.keyID = "iphone-key-1"
        revocation.revokedAtUnixMillis = now
        revocation.reasonCode = "lost_device"

        try await shell.applyRevocation(revocation)

        let snapshot = await shell.snapshot()
        #expect(snapshot.phase == .revoked)
        #expect(snapshot.reachability == .unavailable)
        #expect(snapshot.reasonCode == "lost_device")
        #expect(await keyStore.storedKeyIDs().isEmpty)
        await #expect(throws: MobileEnrollmentShellError.enrollmentNotAllowed) {
            try await shell.prepareEnrollment(
                enrollmentID: "enrollment-after-revoke",
                keyID: "iphone-key-3",
                keyGeneration: 3,
                createdAtUnixMillis: now,
                expiresAtUnixMillis: now + 60_000
            )
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func activeShell(
        keyStore: InMemoryMobileSyncPrivateKeyStore
    ) async throws -> MobileEnrollmentShell {
        let shell = try MobileEnrollmentShell(
            deviceID: "iphone-justin",
            displayName: "Justin's iPhone",
            keyStore: keyStore,
            entropy: FixedEnrollmentEntropy()
        )
        _ = try await shell.prepareEnrollment(
            enrollmentID: "enrollment-1",
            keyID: "iphone-key-1",
            keyGeneration: 1,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 60_000
        )
        var receipt = Kaname_V1_DeviceEnrollmentReceipt()
        receipt.enrollmentID = "enrollment-1"
        receipt.deviceID = "iphone-justin"
        receipt.state = .active
        receipt.reasonCode = "enrollment_activated"
        try await shell.applyEnrollmentReceipt(receipt)
        return shell
    }
}

private struct FixedEnrollmentEntropy: MobileEnrollmentEntropy {
    func nonce(count: Int) throws -> Data {
        Data(repeating: 0x4d, count: count)
    }

    func confirmationCode() -> String {
        "204681"
    }
}
