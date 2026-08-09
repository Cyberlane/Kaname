import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import Testing

struct MobileSyncSessionTests {
    private let now: Int64 = 1_786_220_000_000

    @Test
    func editableOfflineQueuePersistsOrderEditsAndRemoval() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()
        let first = queuedCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            position: 1,
            body: "First follow-up"
        )
        let second = queuedCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            position: 2,
            body: "Second follow-up"
        )
        try await fixture.phone.replaceQueuedCommands([first, second])

        var edited = second
        edited.body = "Edited while the Mac is unreachable"
        try await fixture.phone.replaceQueuedCommands([edited])

        let restored = try fixture.makePhoneSession()
        try await restored.restore()
        let snapshot = await restored.snapshot()

        #expect(snapshot.queuedCommands.count == 1)
        #expect(snapshot.queuedCommands[0].id == second.id)
        #expect(snapshot.queuedCommands[0].position == 1)
        #expect(snapshot.queuedCommands[0].body == edited.body)
        #expect(snapshot.queuedCommands[0].revision == 2)
        #expect(snapshot.queuedCommands[0].deliveryState == .savedOnPhone)
    }

    @Test
    func disconnectedDispatchRetriesTheExactEnvelopeOnceAndInOrder() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()
        let first = queuedCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            position: 1,
            body: "Queue me once"
        )
        try await fixture.phone.replaceQueuedCommands([first])
        await fixture.relay.setConnected(false)

        await #expect(throws: MobileSyncTransportError.disconnected) {
            try await fixture.phone.dispatchQueuedCommands(nowUnixMillis: now)
        }
        let staged = await fixture.phone.snapshot()
        #expect(staged.outgoingSequence == 1)
        #expect(staged.queuedCommands[0].deliveryState == .savedOnPhone)

        await fixture.relay.setConnected(true)
        try await fixture.phone.retryPendingPayloads(nowUnixMillis: now + 1)
        try await fixture.phone.retryPendingPayloads(nowUnixMillis: now + 2)

        let page = try await fixture.relay.pull(
            recipientDeviceID: "mac-authority",
            afterPosition: 0,
            limit: 10
        )
        #expect(page.deliveries.count == 1)
        #expect(await fixture.relay.auditRecords().count == 1)
        let opened = try MobileSyncCipher.open(
            Kaname_V1_EncryptedSyncEnvelope(serializedBytes: page.deliveries[0].envelopeWire),
            recipientPrivateKey: fixture.macKey,
            senderPublicKey: fixture.phoneKey.publicKey,
            expectedRecipientDeviceID: "mac-authority",
            expectedRecipientKeyID: "mac-key-1",
            nowUnixMillis: now + 2
        )
        let queued = try Kaname_V1_QueueItem(serializedBytes: opened.plaintext)
        #expect(queued.itemID == first.id.uuidString.lowercased())
        #expect(queued.position == 1)
        #expect(queued.body == first.body)
        #expect((await fixture.phone.snapshot()).queuedCommands[0].deliveryState == .relayAccepted)

        await #expect(throws: MobileSyncSessionError.queueItemAlreadyStaged) {
            try await fixture.phone.replaceQueuedCommands([])
        }
    }

    @Test
    func encryptedReceiptsAndHistoryReconcileThenSurviveRestart() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()
        let command = queuedCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            position: 1,
            body: "Reconcile this command"
        )
        try await fixture.phone.replaceQueuedCommands([command])
        try await fixture.phone.dispatchQueuedCommands(nowUnixMillis: now)

        var queueReceipt = Kaname_V1_QueueReceipt()
        queueReceipt.itemID = command.id.uuidString.lowercased()
        queueReceipt.state = .receivedByMac
        queueReceipt.revision = command.revision
        queueReceipt.recordedAtUnixMillis = now + 10
        _ = try await fixture.mac.sendPayload(
            payloadID: "receipt-queue-21",
            payloadKind: "queue.receipt",
            plaintext: try queueReceipt.serializedData(),
            nowUnixMillis: now + 10
        )

        var event = Kaname_V1_EventEnvelope()
        event.eventID = "event-21"
        event.storePosition = 21
        event.streamID = command.streamID
        event.streamSequence = 2
        event.occurredAtUnixMillis = now + 11
        event.kind = "thread.message.created"
        _ = try await fixture.mac.sendPayload(
            payloadID: "history-event-21",
            payloadKind: "event.history",
            plaintext: try event.serializedData(),
            nowUnixMillis: now + 11
        )
        let expectedEventWire = try event.serializedData()

        let result = try await fixture.phone.pollIncoming(nowUnixMillis: now + 12)
        let reconciled = await fixture.phone.snapshot()
        #expect(result.applied == 2)
        #expect(reconciled.queuedCommands[0].deliveryState == .receivedByMac)
        #expect(reconciled.receipts.map(\.subjectID) == [command.id.uuidString.lowercased()])
        #expect(reconciled.recentHistory.count == 1)
        #expect(reconciled.recentHistory[0].exactEventWire == expectedEventWire)

        let restored = try fixture.makePhoneSession()
        try await restored.restore()
        let persisted = await restored.snapshot()
        #expect(persisted == reconciled)
        #expect((try await restored.pollIncoming(nowUnixMillis: now + 13)).applied == 0)
    }

    @Test
    func staleApprovalReceiptRemainsRejectedAfterEncryptedReplay() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()
        var receipt = Kaname_V1_ApprovalCommandReceipt()
        receipt.approvalID = "approval-stale-1"
        receipt.decision = .reject
        receipt.fingerprint = Data(repeating: 0x53, count: SHA256.byteCount)
        receipt.storePosition = 33
        receipt.reasonCode = "stale_target_revision"
        _ = try await fixture.mac.sendPayload(
            payloadID: "approval-receipt-stale-1",
            payloadKind: "approval.receipt",
            plaintext: try receipt.serializedData(),
            nowUnixMillis: now
        )

        _ = try await fixture.phone.pollIncoming(nowUnixMillis: now + 1)
        let snapshot = await fixture.phone.snapshot()
        #expect(snapshot.receipts.count == 1)
        #expect(snapshot.receipts[0].subjectID == receipt.approvalID)
        #expect(snapshot.receipts[0].state == .rejected)
        #expect(snapshot.receipts[0].reasonCode == "stale_target_revision")
    }

    @Test
    func encryptedQueueApprovalRotationAndRevocationReachOnlyTheirAuthorityPeer() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()

        var queue = Kaname_V1_QueueItem()
        queue.itemID = "queue-live-1"
        queue.streamID = "thread-live-1"
        queue.revision = 2
        queue.position = 1
        queue.body = "Run the Phase 3 reconciliation check."
        queue.authorID = "iphone-justin"
        queue.createdAtUnixMillis = now
        queue.disposition = "queued"
        _ = try await fixture.phone.sendPayload(
            payloadID: "queue-live-1",
            payloadKind: "queue.enqueue",
            plaintext: try queue.serializedData(),
            nowUnixMillis: now
        )
        _ = try await fixture.mac.pollIncoming(nowUnixMillis: now + 1)
        let receivedQueue = await fixture.mac.snapshot().receivedQueueCommands
        #expect(receivedQueue.map(\.itemID) == ["queue-live-1"])
        #expect(receivedQueue[0].body == queue.body)

        var request = Kaname_V1_ApprovalRequest()
        request.approvalID = "approval-live-1"
        request.actionKind = "codex.workspace_write"
        request.scope.projectID = "coding-ade"
        request.scope.workspaceID = "phase3-worktree"
        request.scope.authorityID = "mac-authority"
        request.scope.egressClass = "encrypted-relay-only"
        request.scope.destinationDigest = "sha256:destination"
        request.targetID = "worktree-phase3"
        request.targetRevision = "revision-1"
        request.effectDigest = Data(repeating: 0x61, count: SHA256.byteCount)
        request.consequence = "Allow one recoverable write in the isolated qualification worktree."
        request.reversible = true
        request.expiresAtUnixMillis = now + 60_000
        request.policyReference = "phase3-mobile-explicit"
        request.fingerprint = Data(repeating: 0x62, count: SHA256.byteCount)
        request.approvalPayloadVersion = 1
        _ = try await fixture.mac.sendPayload(
            payloadID: "approval-live-1",
            payloadKind: "approval.request",
            plaintext: try request.serializedData(),
            nowUnixMillis: now + 2
        )
        _ = try await fixture.phone.pollIncoming(nowUnixMillis: now + 3)
        let pending = try #require(await fixture.phone.snapshot().pendingApprovals.first)
        #expect(pending.targetRevision == "revision-1")
        #expect(pending.egressClass == "encrypted-relay-only")

        var resolution = Kaname_V1_ApprovalResolution()
        resolution.approvalID = request.approvalID
        resolution.decision = .approve
        resolution.expectedFingerprint = request.fingerprint
        resolution.actorID = "justin"
        resolution.deviceID = "iphone-justin"
        var command = Kaname_V1_ApprovalCommand()
        command.streamID = "thread-live-1"
        command.request = request
        command.resolution = resolution
        command.resolvedAtUnixMillis = now + 4
        command.currentTargetRevision = request.targetRevision
        _ = try await fixture.phone.sendPayload(
            payloadID: "approval-command-live-1",
            payloadKind: "approval.command",
            plaintext: try command.serializedData(),
            nowUnixMillis: now + 4
        )
        _ = try await fixture.mac.pollIncoming(nowUnixMillis: now + 5)
        #expect(await fixture.mac.snapshot().receivedApprovalCommands.count == 1)

        let nextPhoneKey = Curve25519.KeyAgreement.PrivateKey()
        let nextIdentity = try MobileSyncCipher.publicIdentity(
            deviceID: "iphone-justin",
            keyID: "iphone-key-2",
            displayName: "Justin's iPhone",
            platform: "ios",
            keyGeneration: 2,
            publicKey: nextPhoneKey.publicKey,
            createdAtUnixMillis: now,
            expiresAtUnixMillis: now + 86_400_000
        )
        var rotation = Kaname_V1_DeviceKeyRotation()
        rotation.deviceID = "iphone-justin"
        rotation.previousKeyID = "iphone-key-1"
        rotation.nextIdentity = nextIdentity
        rotation.transcriptDigest = Data(repeating: 0x63, count: SHA256.byteCount)
        rotation.rotatedAtUnixMillis = now + 6
        _ = try await fixture.phone.sendPayload(
            payloadID: "rotation-live-1",
            payloadKind: "device.rotation",
            plaintext: try rotation.serializedData(),
            nowUnixMillis: now + 6
        )
        _ = try await fixture.mac.pollIncoming(nowUnixMillis: now + 7)
        #expect(await fixture.mac.snapshot().receivedKeyRotations.first?.nextKeyID == "iphone-key-2")

        var revocation = Kaname_V1_DeviceRevocation()
        revocation.deviceID = "iphone-justin"
        revocation.keyID = "iphone-key-1"
        revocation.revokedAtUnixMillis = now + 8
        revocation.reasonCode = "qualification_lost_device"
        _ = try await fixture.mac.sendPayload(
            payloadID: "revocation-live-1",
            payloadKind: "device.revocation",
            plaintext: try revocation.serializedData(),
            nowUnixMillis: now + 8
        )
        _ = try await fixture.phone.pollIncoming(nowUnixMillis: now + 9)
        #expect(await fixture.phone.snapshot().receivedRevocations.first?.reasonCode == "qualification_lost_device")
    }

    @Test
    func protectedStateStoreRoundTripsExactBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("mobile-sync-state.json")
        let store = ProtectedFileMobileSyncStateStore(fileURL: file)
        let expected = Data("bounded protected state".utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.save(expected)

        #expect(try await store.load() == expected)
    }

    @Test
    func readOnlyDegradationPreservesInspectionAndRejectsEveryMutation() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        let fixture = try Fixture()
        let command = queuedCommand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            position: 1,
            body: "Preserve this during recovery"
        )
        try await fixture.phone.replaceQueuedCommands([command])
        try await fixture.phone.enterReadOnly(reason: "authority_backup_recovery")

        let visible = await fixture.phone.snapshot()
        #expect(visible.queuedCommands == [command])
        #expect(visible.readOnlyReason == "authority_backup_recovery")
        await #expect(throws: MobileSyncSessionError.readOnly("authority_backup_recovery")) {
            try await fixture.phone.replaceQueuedCommands([])
        }
        await #expect(throws: MobileSyncSessionError.readOnly("authority_backup_recovery")) {
            try await fixture.phone.sendPayload(
                payloadID: "blocked-during-recovery",
                payloadKind: "sync.receipt",
                plaintext: Data([0x01]),
                nowUnixMillis: now
            )
        }
        await #expect(throws: MobileSyncSessionError.readOnly("authority_backup_recovery")) {
            try await fixture.phone.pollIncoming(nowUnixMillis: now)
        }

        let restored = try fixture.makePhoneSession()
        try await restored.restore()
        #expect((await restored.snapshot()).readOnlyReason == "authority_backup_recovery")
        #expect((await restored.snapshot()).queuedCommands == [command])
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct Fixture {
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let relay = LocalCiphertextRelay()
        let phoneState = InMemoryMobileSyncStateStore()
        let macState = InMemoryMobileSyncStateStore()
        let phoneKeys: InMemoryMobileSyncPrivateKeyStore
        let macKeys: InMemoryMobileSyncPrivateKeyStore
        let phoneConfiguration: MobileSyncEndpointConfiguration
        let macConfiguration: MobileSyncEndpointConfiguration
        let phone: MobileSyncSession
        let mac: MobileSyncSession

        init() throws {
            phoneKeys = InMemoryMobileSyncPrivateKeyStore(initialKeys: ["iphone-key-1": phoneKey])
            macKeys = InMemoryMobileSyncPrivateKeyStore(initialKeys: ["mac-key-1": macKey])
            phoneConfiguration = try MobileSyncEndpointConfiguration(
                deviceID: "iphone-justin",
                keyID: "iphone-key-1",
                peerDeviceID: "mac-authority",
                peerKeyID: "mac-key-1",
                peerPublicKey: macKey.publicKey
            )
            macConfiguration = try MobileSyncEndpointConfiguration(
                deviceID: "mac-authority",
                keyID: "mac-key-1",
                peerDeviceID: "iphone-justin",
                peerKeyID: "iphone-key-1",
                peerPublicKey: phoneKey.publicKey
            )
            phone = try MobileSyncSession(
                configuration: phoneConfiguration,
                keyStore: phoneKeys,
                transport: relay,
                stateStore: phoneState
            )
            mac = try MobileSyncSession(
                configuration: macConfiguration,
                keyStore: macKeys,
                transport: relay,
                stateStore: macState
            )
        }

        func makePhoneSession() throws -> MobileSyncSession {
            try MobileSyncSession(
                configuration: phoneConfiguration,
                keyStore: phoneKeys,
                transport: relay,
                stateStore: phoneState
            )
        }
    }

    private func queuedCommand(
        id: UUID,
        position: Int,
        body: String
    ) -> MobileQueuedCommand {
        MobileQueuedCommand(
            id: id,
            position: position,
            streamID: "thread-phase3",
            threadTitle: "Phase 3",
            body: body,
            createdLabel: "Saved offline",
            createdAtUnixMillis: now
        )
    }
}
