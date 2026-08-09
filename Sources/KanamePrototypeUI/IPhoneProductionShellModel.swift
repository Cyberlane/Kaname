#if os(iOS)
import Combine
import Foundation
import KanameMobileSync
import SwiftUI

@available(iOS 17.0, *)
@MainActor
final class IPhoneProductionShellModel: ObservableObject {
    @Published private(set) var snapshot: MobileEnrollmentSnapshot
    @Published private(set) var confirmationCode: String?
    @Published private(set) var statusMessage: String?

    private let shell: MobileEnrollmentShell

    init(shell: MobileEnrollmentShell, initialSnapshot: MobileEnrollmentSnapshot) {
        self.shell = shell
        self.snapshot = initialSnapshot
    }

    static func simulator() -> IPhoneProductionShellModel {
        let store = InMemoryMobileSyncPrivateKeyStore()
        let shell = try! MobileEnrollmentShell(
            deviceID: "iphone-simulator",
            displayName: "Kaname iPhone Simulator",
            keyStore: store
        )
        return IPhoneProductionShellModel(
            shell: shell,
            initialSnapshot: MobileEnrollmentSnapshot(deviceID: "iphone-simulator")
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
