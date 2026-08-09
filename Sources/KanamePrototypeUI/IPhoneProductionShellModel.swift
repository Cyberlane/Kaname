#if os(iOS)
import Combine
import CryptoKit
import Foundation
import KanameMobileSync
import SwiftUI

@available(iOS 17.0, *)
@MainActor
final class IPhoneProductionShellModel: ObservableObject {
    @Published private(set) var snapshot: MobileEnrollmentSnapshot
    @Published private(set) var confirmationCode: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var queuedCommands: [MobileQueuedCommand]
    @Published private(set) var syncReadOnlyReason: String?

    private let shell: MobileEnrollmentShell
    private let syncSession: MobileSyncSession

    init(
        shell: MobileEnrollmentShell,
        syncSession: MobileSyncSession,
        initialSnapshot: MobileEnrollmentSnapshot,
        initialQueue: [MobileQueuedCommand],
        seedQueueOnRestore: Bool
    ) {
        self.shell = shell
        self.syncSession = syncSession
        self.snapshot = initialSnapshot
        self.queuedCommands = initialQueue
        Task {
            await restoreSimulatorQueue(
                seed: seedQueueOnRestore ? initialQueue : nil
            )
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

    var isMacReachable: Bool {
        snapshot.reachability == .reachable
    }

    func setSimulatedReachability(_ reachable: Bool) {
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
        Task {
            do {
                try await syncSession.replaceQueuedCommands(commands)
                queuedCommands = await syncSession.snapshot().queuedCommands
                statusMessage = "The encrypted offline queue was saved with device data protection."
            } catch {
                queuedCommands = await syncSession.snapshot().queuedCommands
                statusMessage = "Queue change was rejected safely: \(error)"
            }
        }
    }

    func simulateReadOnlyRecovery() {
        Task {
            do {
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
                try await syncSession.leaveReadOnlyForRecovery()
                syncReadOnlyReason = await syncSession.snapshot().readOnlyReason
                statusMessage = "Simulator recovery completed; queue editing is available again."
            } catch {
                statusMessage = "Recovery completion failed safely: \(error)"
            }
        }
    }

    func prepareSimulatorEnrollment(now: Date = Date()) {
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

    private func restoreSimulatorQueue(seed: [MobileQueuedCommand]?) async {
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
