#if os(iOS)
import Combine
import CryptoKit
import Foundation
import KanameMobileSync
import KanameProtocol
import SwiftUI

@available(iOS 17.0, *)
@MainActor
final class IPhoneProductionShellModel: ObservableObject {
    @Published private(set) var snapshot: MobileEnrollmentSnapshot
    @Published private(set) var confirmationCode: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var queuedCommands: [MobileQueuedCommand]
    @Published private(set) var syncReadOnlyReason: String?
    @Published private(set) var pendingApproval: MobilePendingApproval?
    @Published private(set) var keychainStatus: String?
    @Published private(set) var pushStatus: String?
    @Published private(set) var lastReceipt: MobileSyncReceiptRecord?
    let isLiveQualification: Bool

    private let shell: MobileEnrollmentShell
    private var syncSession: MobileSyncSession?
    private let liveConfiguration: Phase3LiveConfiguration?
    private let relayClient: MobileEnrollmentRelayClient?
    private let liveKeyStore: KeychainMobileSyncKeyStore?
    private let credentialStore: KeychainMobileRelayCredentialStore?
    private var currentKeyID: String?
    private var pendingRotation: PendingRotation?
    private var queueSaveGeneration = 0
    private var pendingQueueSave: Task<Void, Never>?

    private struct PendingRotation {
        let nextKeyID: String
        let nextIdentityDigest: Data
        let envelopeID: String
    }

    private init(
        shell: MobileEnrollmentShell,
        syncSession: MobileSyncSession?,
        initialSnapshot: MobileEnrollmentSnapshot,
        initialQueue: [MobileQueuedCommand],
        seedQueueOnRestore: Bool,
        liveConfiguration: Phase3LiveConfiguration? = nil,
        relayClient: MobileEnrollmentRelayClient? = nil,
        liveKeyStore: KeychainMobileSyncKeyStore? = nil,
        credentialStore: KeychainMobileRelayCredentialStore? = nil
    ) {
        self.shell = shell
        self.syncSession = syncSession
        self.snapshot = initialSnapshot
        self.queuedCommands = initialQueue
        self.liveConfiguration = liveConfiguration
        self.relayClient = relayClient
        self.liveKeyStore = liveKeyStore
        self.credentialStore = credentialStore
        self.currentKeyID = liveConfiguration?.keyID
        self.isLiveQualification = liveConfiguration != nil
        if liveConfiguration == nil {
            Task {
                await restoreQueue(seed: seedQueueOnRestore ? initialQueue : nil)
            }
        }
    }

    static func configured() -> IPhoneProductionShellModel {
        guard let encoded = ProcessInfo.processInfo.environment["KANAME_PHASE3_CONFIG_BASE64"] else {
            return simulator()
        }
        do {
            guard let data = Data(base64Encoded: encoded) else {
                throw Phase3LiveConfigurationError.invalidEncoding
            }
            let configuration = try JSONDecoder().decode(Phase3LiveConfiguration.self, from: data)
            return try live(configuration: configuration)
        } catch {
            let model = simulator()
            model.statusMessage = "Live Phase 3 configuration was rejected safely: \(error)"
            return model
        }
    }

    static func simulator() -> IPhoneProductionShellModel {
        let phoneKey = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        let macKey = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        let store = InMemoryMobileSyncPrivateKeyStore(
            initialKeys: ["iphone-simulator-key": phoneKey]
        )
        let shell = try! MobileEnrollmentShell(
            deviceID: "iphone-simulator",
            displayName: "Kaname iPhone Simulator",
            keyStore: store
        )
        let configuration = try! MobileSyncEndpointConfiguration(
            deviceID: "iphone-simulator",
            keyID: "iphone-simulator-key",
            peerDeviceID: "mac-simulator",
            peerKeyID: "mac-simulator-key",
            peerPublicKey: macKey.publicKey
        )
        let stateURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Kaname", isDirectory: true)
            .appendingPathComponent("mobile-sync-simulator.json")
        let stateStore = ProtectedFileMobileSyncStateStore(fileURL: stateURL)
        let shouldSeedQueue = !FileManager.default.fileExists(atPath: stateURL.path)
        let initialQueue = shouldSeedQueue ? MobileQueuedCommand.simulatorItems : []
        let syncSession = try! MobileSyncSession(
            configuration: configuration,
            keyStore: store,
            transport: LocalCiphertextRelay(),
            stateStore: stateStore
        )
        return IPhoneProductionShellModel(
            shell: shell,
            syncSession: syncSession,
            initialSnapshot: MobileEnrollmentSnapshot(deviceID: "iphone-simulator"),
            initialQueue: initialQueue,
            seedQueueOnRestore: shouldSeedQueue
        )
    }

    private static func live(
        configuration: Phase3LiveConfiguration
    ) throws -> IPhoneProductionShellModel {
        try configuration.validate()
        let credentialStore = try KeychainMobileRelayCredentialStore(
            service: "com.cyberlane.kaname.phase3.relay"
        )
        try credentialStore.replace(token: configuration.bearerToken)
        let storedToken = try credentialStore.load()
        let keyStore = try KeychainMobileSyncKeyStore(
            service: "com.cyberlane.kaname.phase3.mobile-sync"
        )
        let shell = try MobileEnrollmentShell(
            deviceID: configuration.deviceID,
            displayName: configuration.displayName,
            keyStore: keyStore
        )
        let relayClient = try MobileEnrollmentRelayClient(
            baseURL: configuration.relayURL,
            bearerToken: storedToken
        )
        let model = IPhoneProductionShellModel(
            shell: shell,
            syncSession: nil,
            initialSnapshot: MobileEnrollmentSnapshot(deviceID: configuration.deviceID),
            initialQueue: [],
            seedQueueOnRestore: false,
            liveConfiguration: configuration,
            relayClient: relayClient,
            liveKeyStore: keyStore,
            credentialStore: credentialStore
        )
        model.keychainStatus = "Relay credential created and read from the device-only Keychain."
        Task { await model.bootstrapLive() }
        return model
    }

    var isMacReachable: Bool {
        snapshot.reachability == .reachable
    }

    func setSimulatedReachability(_ reachable: Bool) {
        guard !isLiveQualification else {
            statusMessage = "Live reachability is derived from encrypted Mac receipts."
            return
        }
        Task {
            await shell.setReachability(reachable ? .reachable : .unavailable)
            snapshot = await shell.snapshot()
            statusMessage = reachable
                ? "Simulator reachability is available. No network connection was opened."
                : "Simulator reachability is unavailable. Commands remain local."
        }
    }

    func replaceQueuedCommands(_ commands: [MobileQueuedCommand]) {
        queuedCommands = commands
        queueSaveGeneration += 1
        let generation = queueSaveGeneration
        pendingQueueSave?.cancel()
        pendingQueueSave = Task {
            guard let syncSession else {
                statusMessage = "Queue change is waiting for live enrollment to initialize."
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                try await syncSession.replaceQueuedCommands(commands)
                guard generation == queueSaveGeneration else { return }
                queuedCommands = await syncSession.snapshot().queuedCommands
                statusMessage = "The encrypted offline queue was saved with device data protection."
            } catch is CancellationError {
                return
            } catch {
                guard generation == queueSaveGeneration else { return }
                queuedCommands = await syncSession.snapshot().queuedCommands
                statusMessage = "Queue change was rejected safely: \(error)"
            }
        }
    }

    func simulateReadOnlyRecovery() {
        Task {
            do {
                guard let syncSession else { return }
                try await syncSession.enterReadOnly(reason: "simulated_authority_recovery")
                syncReadOnlyReason = await syncSession.snapshot().readOnlyReason
                statusMessage = "Recovery mode preserves visible history and queue state while rejecting sync mutations."
            } catch {
                statusMessage = "Recovery mode failed safely: \(error)"
            }
        }
    }

    func finishSimulatedRecovery() {
        Task {
            do {
                guard let syncSession else { return }
                try await syncSession.leaveReadOnlyForRecovery()
                syncReadOnlyReason = await syncSession.snapshot().readOnlyReason
                statusMessage = "Simulator recovery completed; queue editing is available again."
            } catch {
                statusMessage = "Recovery completion failed safely: \(error)"
            }
        }
    }

    func prepareSimulatorEnrollment(now: Date = Date()) {
        guard !isLiveQualification else {
            Task { await pollEnrollmentAndSync() }
            return
        }
        Task {
            do {
                let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
                let suffix = UUID().uuidString.lowercased()
                let proposal = try await shell.prepareEnrollment(
                    enrollmentID: "enrollment-\(suffix)",
                    keyID: "iphone-key-\(suffix)",
                    keyGeneration: max(snapshot.keyGeneration + 1, 1),
                    createdAtUnixMillis: nowMillis,
                    expiresAtUnixMillis: nowMillis + 15 * 60 * 1_000
                )
                confirmationCode = proposal.confirmationCode
                snapshot = await shell.snapshot()
                statusMessage = "Enrollment proposal prepared in memory. It has not left this simulator."
            } catch {
                statusMessage = "Enrollment preparation failed safely: \(error)"
            }
        }
    }

    func resetSimulatorEnrollment() {
        guard !isLiveQualification else {
            statusMessage = "Live enrollment is removed only by the bounded revocation flow."
            return
        }
        Task {
            do {
                try await shell.resetLocalEnrollment()
                confirmationCode = nil
                snapshot = await shell.snapshot()
                statusMessage = "Ephemeral simulator enrollment was removed."
            } catch {
                statusMessage = "Enrollment reset failed safely: \(error)"
            }
        }
    }

    func pollEnrollmentAndSync(now: Date = Date()) async {
        if isLiveQualification {
            await synchronizeLive(now: now)
        }
    }

    func registerPushToken(_ token: Data) {
        guard let relayClient, let liveConfiguration else { return }
        Task {
            do {
                try await relayClient.registerPushToken(
                    token,
                    deviceID: liveConfiguration.deviceID,
                    environment: liveConfiguration.pushEnvironment
                )
                pushStatus = "APNs token registered through the authenticated relay."
            } catch {
                pushStatus = "APNs token registration failed safely: \(error)"
            }
        }
    }

    func resolvePendingApproval(approve: Bool, now: Date = Date()) {
        guard let pendingApproval, let syncSession, let liveConfiguration else { return }
        Task {
            do {
                let request = try Kaname_V1_ApprovalRequest(
                    serializedBytes: pendingApproval.exactRequestWire
                )
                var resolution = Kaname_V1_ApprovalResolution()
                resolution.approvalID = request.approvalID
                resolution.decision = approve ? .approve : .reject
                resolution.expectedFingerprint = request.fingerprint
                resolution.actorID = "justin"
                resolution.deviceID = liveConfiguration.deviceID
                var command = Kaname_V1_ApprovalCommand()
                command.streamID = "thread-phase3-live"
                command.request = request
                command.resolution = resolution
                command.resolvedAtUnixMillis = now.unixMillis
                command.currentTargetRevision = request.targetRevision
                _ = try await syncSession.sendPayload(
                    payloadID: "approval-command-\(request.approvalID)",
                    payloadKind: "approval.command",
                    plaintext: try command.serializedData(),
                    nowUnixMillis: now.unixMillis
                )
                statusMessage = "Encrypted \(approve ? "approval" : "rejection") queued for Mac authority reconciliation."
            } catch {
                statusMessage = "Approval response failed safely: \(error)"
            }
        }
    }

    func rotateLiveKey(now: Date = Date()) {
        guard isLiveQualification,
              snapshot.phase == .active,
              pendingRotation == nil,
              let syncSession,
              let currentKeyID else { return }
        Task {
            do {
                let generation = snapshot.keyGeneration + 1
                let nextKeyID = "\(snapshot.deviceID)-key-\(generation)"
                let proposal = try await shell.prepareKeyRotation(
                    nextKeyID: nextKeyID,
                    nextGeneration: generation,
                    rotatedAtUnixMillis: now.unixMillis,
                    expiresAtUnixMillis: now.unixMillis + 86_400_000
                )
                let nextSequence = await syncSession.snapshot().outgoingSequence + 1
                let envelopeID = "\(snapshot.deviceID)-envelope-\(nextSequence)"
                _ = try await syncSession.sendPayload(
                    payloadID: "rotation-\(snapshot.deviceID)-\(generation)",
                    payloadKind: "device.rotation",
                    plaintext: try proposal.rotation.serializedData(),
                    nowUnixMillis: now.unixMillis
                )
                pendingRotation = PendingRotation(
                    nextKeyID: nextKeyID,
                    nextIdentityDigest: proposal.nextIdentityDigest,
                    envelopeID: envelopeID
                )
                statusMessage = "New device-only key created; waiting for Mac acceptance before retiring \(currentKeyID)."
            } catch {
                statusMessage = "Key rotation failed safely: \(error)"
            }
        }
    }

    private func bootstrapLive(now: Date = Date()) async {
        guard let liveConfiguration, let relayClient, let liveKeyStore else { return }
        do {
            try? liveKeyStore.remove(keyID: liveConfiguration.keyID)
            let proposal = try await shell.prepareEnrollment(
                enrollmentID: liveConfiguration.enrollmentID,
                keyID: liveConfiguration.keyID,
                keyGeneration: 1,
                createdAtUnixMillis: now.unixMillis,
                expiresAtUnixMillis: now.unixMillis + 15 * 60 * 1_000
            )
            _ = try liveKeyStore.load(keyID: liveConfiguration.keyID)
            keychainStatus = "HPKE private key created and read from the device-only Keychain."
            try await relayClient.createEnrollment(proposal)
            confirmationCode = proposal.confirmationCode
            syncSession = try makeLiveSession(keyID: liveConfiguration.keyID)
            try await syncSession?.restore()
            try await seedLiveQualificationQueueIfNeeded(now: now)
            snapshot = await shell.snapshot()
            statusMessage = "Physical-device enrollment is waiting for the same six-digit code on the Mac."
        } catch {
            await shell.setReachability(.degraded, reasonCode: "live_bootstrap_failed")
            snapshot = await shell.snapshot()
            statusMessage = "Live enrollment bootstrap failed safely: \(error)"
        }
    }

    private func synchronizeLive(now: Date) async {
        guard let relayClient, let liveConfiguration else { return }
        do {
            if snapshot.phase == .awaitingLocalConfirmation {
                let record = try await relayClient.enrollment(
                    enrollmentID: liveConfiguration.enrollmentID
                )
                if let receiptWire = record.receiptWire {
                    let receipt = try Kaname_V1_DeviceEnrollmentReceipt(
                        serializedBytes: receiptWire
                    )
                    try await shell.applyEnrollmentReceipt(receipt)
                    confirmationCode = nil
                    snapshot = await shell.snapshot()
                }
            }
            guard snapshot.phase == .active, let syncSession else {
                statusMessage = "Enrollment is still awaiting Mac confirmation."
                return
            }
            let result = try await syncSession.pollIncoming(nowUnixMillis: now.unixMillis)
            let sessionSnapshot = await syncSession.snapshot()
            queuedCommands = sessionSnapshot.queuedCommands
            pendingApproval = sessionSnapshot.pendingApprovals.first
            lastReceipt = sessionSnapshot.receipts.last
            syncReadOnlyReason = sessionSnapshot.readOnlyReason
            await applyAcceptedRotationIfPresent(sessionSnapshot)
            await applyRevocationIfPresent(sessionSnapshot)
            if snapshot.phase == .active {
                if result.applied > 0 {
                    await shell.setReachability(
                        .reachable,
                        reasonCode: "authenticated_mac_envelope_received"
                    )
                }
                snapshot = await shell.snapshot()
                if snapshot.reachability == .reachable {
                    try await syncSession.dispatchQueuedCommands(nowUnixMillis: now.unixMillis)
                    queuedCommands = await syncSession.snapshot().queuedCommands
                    statusMessage = "Authenticated Mac reachability dispatched the encrypted queue once and applied \(result.applied) incoming item(s)."
                } else {
                    statusMessage = "Relay is reachable, but no authenticated Mac envelope arrived; queued commands remain protected on this iPhone."
                }
            }
        } catch {
            await shell.setReachability(.degraded, reasonCode: "live_reconciliation_failed")
            snapshot = await shell.snapshot()
            statusMessage = "Live reconciliation failed safely: \(error)"
        }
    }

    private func applyAcceptedRotationIfPresent(
        _ sessionSnapshot: MobileSyncSessionSnapshot
    ) async {
        guard let pendingRotation,
              sessionSnapshot.receipts.contains(where: {
                $0.subjectID == pendingRotation.envelopeID
                    && $0.state == .policyAccepted
                    && $0.reasonCode == "key_rotation_accepted"
              }) else { return }
        do {
            try await shell.finalizeKeyRotation(
                acceptedNextIdentityDigest: pendingRotation.nextIdentityDigest
            )
            currentKeyID = pendingRotation.nextKeyID
            self.pendingRotation = nil
            syncSession = try makeLiveSession(keyID: pendingRotation.nextKeyID)
            try await syncSession?.restore()
            snapshot = await shell.snapshot()
            keychainStatus = "Old HPKE key deleted after Mac accepted generation \(snapshot.keyGeneration)."
        } catch {
            statusMessage = "Accepted rotation could not finalize safely: \(error)"
        }
    }

    private func applyRevocationIfPresent(
        _ sessionSnapshot: MobileSyncSessionSnapshot
    ) async {
        guard let currentKeyID,
              let received = sessionSnapshot.receivedRevocations.first(where: {
                $0.deviceID == snapshot.deviceID && $0.keyID == currentKeyID
              }) else { return }
        do {
            let revocation = try Kaname_V1_DeviceRevocation(
                serializedBytes: received.exactRevocationWire
            )
            try await shell.applyRevocation(revocation)
            if let relayClient, let liveConfiguration {
                try? await relayClient.deletePushToken(deviceID: liveConfiguration.deviceID)
            }
            try? credentialStore?.remove()
            syncSession = nil
            pendingApproval = nil
            snapshot = await shell.snapshot()
            keychainStatus = "Revocation deleted the active HPKE key and relay credential from this device."
            statusMessage = "Lost-device revocation applied; mobile sync is disabled."
        } catch {
            statusMessage = "Revocation failed safely: \(error)"
        }
    }

    private func makeLiveSession(keyID: String) throws -> MobileSyncSession {
        guard let liveConfiguration, let liveKeyStore else {
            throw Phase3LiveConfigurationError.invalidConfiguration
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: liveConfiguration.peerPublicKey
        )
        let configuration = try MobileSyncEndpointConfiguration(
            deviceID: liveConfiguration.deviceID,
            keyID: keyID,
            peerDeviceID: liveConfiguration.peerDeviceID,
            peerKeyID: liveConfiguration.peerKeyID,
            peerPublicKey: peerKey
        )
        let token = try credentialStore?.load()
            ?? liveConfiguration.bearerToken
        let transport = try HTTPMobileSyncTransport(
            baseURL: liveConfiguration.relayURL,
            bearerToken: token
        )
        let stateURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Kaname", isDirectory: true)
            .appendingPathComponent("phase3-\(liveConfiguration.deviceID)-sync.json")
        return try MobileSyncSession(
            configuration: configuration,
            keyStore: liveKeyStore,
            transport: transport,
            stateStore: ProtectedFileMobileSyncStateStore(fileURL: stateURL)
        )
    }

    private func seedLiveQualificationQueueIfNeeded(now: Date) async throws {
        guard let syncSession,
              (await syncSession.snapshot()).queuedCommands.isEmpty else { return }
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000003001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000003002")!
        let removedID = UUID(uuidString: "00000000-0000-0000-0000-000000003003")!
        let base = Int64(now.timeIntervalSince1970 * 1_000)
        let initial = [
            MobileQueuedCommand(
                id: firstID,
                position: 1,
                streamID: "thread-phase3-live",
                threadTitle: "Phase 3 qualification",
                body: "First encrypted offline follow-up",
                createdLabel: "Saved off-LAN",
                createdAtUnixMillis: base
            ),
            MobileQueuedCommand(
                id: secondID,
                position: 2,
                streamID: "thread-phase3-live",
                threadTitle: "Phase 3 qualification",
                body: "Second encrypted offline follow-up",
                createdLabel: "Saved off-LAN",
                createdAtUnixMillis: base + 1
            ),
            MobileQueuedCommand(
                id: removedID,
                position: 3,
                streamID: "thread-phase3-live",
                threadTitle: "Phase 3 qualification",
                body: "Remove this before reconciliation",
                createdLabel: "Saved off-LAN",
                createdAtUnixMillis: base + 2
            ),
        ]
        try await syncSession.replaceQueuedCommands(initial)
        var edited = initial[1]
        edited.body = "Second encrypted offline follow-up, edited before reconciliation"
        try await syncSession.replaceQueuedCommands([edited, initial[0]])
        queuedCommands = await syncSession.snapshot().queuedCommands
    }

    private func restoreQueue(seed: [MobileQueuedCommand]?) async {
        guard let syncSession else { return }
        do {
            try await syncSession.restore()
            let snapshot = await syncSession.snapshot()
            let restored = snapshot.queuedCommands
            syncReadOnlyReason = snapshot.readOnlyReason
            if restored.isEmpty, let seed {
                try await syncSession.replaceQueuedCommands(seed)
                queuedCommands = await syncSession.snapshot().queuedCommands
            } else {
                queuedCommands = restored
            }
        } catch {
            queuedCommands = []
            statusMessage = "Protected queue state could not be restored; mobile sync is read-only: \(error)"
            try? await syncSession.enterReadOnly(reason: "protected_state_restore_failed")
            syncReadOnlyReason = "protected_state_restore_failed"
        }
    }
}

private struct Phase3LiveConfiguration: Codable {
    let relayURL: URL
    let bearerToken: String
    let deviceID: String
    let displayName: String
    let keyID: String
    let enrollmentID: String
    let peerDeviceID: String
    let peerKeyID: String
    let peerPublicKey: Data
    let pushEnvironment: String

    func validate() throws {
        guard relayURL.scheme == "https",
              relayURL.host != nil,
              bearerToken.utf8.count >= 32,
              bearerToken.utf8.count <= 512,
              !deviceID.isEmpty,
              !displayName.isEmpty,
              !keyID.isEmpty,
              !enrollmentID.isEmpty,
              !peerDeviceID.isEmpty,
              !peerKeyID.isEmpty,
              peerPublicKey.count == 32,
              ["sandbox", "production"].contains(pushEnvironment) else {
            throw Phase3LiveConfigurationError.invalidConfiguration
        }
    }
}

private enum Phase3LiveConfigurationError: Error {
    case invalidEncoding
    case invalidConfiguration
}

private extension Date {
    var unixMillis: Int64 {
        Int64(timeIntervalSince1970 * 1_000)
    }
}

extension MobileEnrollmentPhase {
    var displayName: String {
        switch self {
        case .unenrolled: "Not enrolled"
        case .awaitingLocalConfirmation: "Awaiting local confirmation"
        case .active: "Enrolled"
        case .rejected: "Enrollment rejected"
        case .revoked: "Device revoked"
        }
    }

    var symbolName: String {
        switch self {
        case .unenrolled: "iphone.slash"
        case .awaitingLocalConfirmation: "lock.badge.clock"
        case .active: "lock.shield.fill"
        case .rejected: "xmark.shield.fill"
        case .revoked: "lock.slash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: Nord.auroraGreen
        case .awaitingLocalConfirmation: Nord.auroraYellow
        case .unenrolled: Nord.frost1
        case .rejected, .revoked: Nord.auroraRed
        }
    }
}

extension MobileReachability {
    var displayName: String {
        switch self {
        case .unavailable: "Unavailable"
        case .checking: "Checking"
        case .reachable: "Reachable"
        case .degraded: "Degraded"
        }
    }
}
#endif
