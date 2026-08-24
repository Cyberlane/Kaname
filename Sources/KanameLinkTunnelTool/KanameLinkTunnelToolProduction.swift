#if os(macOS)
import Darwin
import Dispatch
import Foundation
import KanameLinkTunnelHost

struct KanameLinkTunnelToolKeychainCredentialAccess:
    KanameLinkTunnelToolCredentialAccessing, Sendable
{
    private let store: KeychainKanameLinkTunnelCredentialStore

    init(store: KeychainKanameLinkTunnelCredentialStore = .init()) {
        self.store = store
    }

    func enrollFromAnonymousStandardInput() throws {
        try KanameLinkTunnelTokenEnrollment(credentialStore: store)
            .enrollFromAnonymousStandardInput()
    }

    func credentialIsPresent() throws -> Bool {
        do {
            _ = try store.loadToken()
            return true
        } catch KanameLinkTunnelCredentialError.credentialNotFound {
            return false
        }
    }
}

struct KanameLinkTunnelToolBridgeSupervisorFactory:
    KanameLinkTunnelToolSupervisorCreating, Sendable
{
    private let store: KeychainKanameLinkTunnelCredentialStore

    init(store: KeychainKanameLinkTunnelCredentialStore = .init()) {
        self.store = store
    }

    func makeSupervisor(
        paths: KanameLinkTunnelSupervisorPaths
    ) -> any KanameLinkTunnelToolSupervisorControlling {
        KanameLinkTunnelToolBridgeSupervisor(
            launcher: KanameLinkTunnelSupervisorLauncher(
                paths: paths,
                credentialStore: store
            )
        )
    }
}

private actor KanameLinkTunnelToolBridgeSupervisor:
    KanameLinkTunnelToolSupervisorControlling
{
    private let launcher: KanameLinkTunnelSupervisorLauncher

    init(launcher: KanameLinkTunnelSupervisorLauncher) {
        self.launcher = launcher
    }

    func launch() async throws -> Int32 {
        try await launcher.launch()
    }

    func stop() async {
        await launcher.stop()
    }
}

protocol KanameLinkTunnelToolProcessProbing: Sendable {
    func isRunning(processIdentifier: Int32) -> Bool
}

struct KanameLinkTunnelToolPOSIXProcessProbe: KanameLinkTunnelToolProcessProbing, Sendable {
    func isRunning(processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        errno = 0
        return kill(processIdentifier, 0) == 0 || errno == EPERM
    }
}

struct KanameLinkTunnelToolPOSIXRunLifecycle:
    KanameLinkTunnelToolRunLifecyclePreparing, Sendable
{
    private let processProbe: any KanameLinkTunnelToolProcessProbing
    private let pollingNanoseconds: UInt64

    init(
        processProbe: any KanameLinkTunnelToolProcessProbing =
            KanameLinkTunnelToolPOSIXProcessProbe(),
        pollingNanoseconds: UInt64 = 200_000_000
    ) {
        self.processProbe = processProbe
        self.pollingNanoseconds = pollingNanoseconds
    }

    func prepare() throws -> any KanameLinkTunnelToolPreparedRunLifecycle {
        KanameLinkTunnelToolPOSIXPreparedRunLifecycle(
            processProbe: processProbe,
            pollingNanoseconds: pollingNanoseconds
        )
    }
}

private actor KanameLinkTunnelToolSignalLatch {
    private var receivedSignal = false

    func receive() {
        receivedSignal = true
    }

    func hasReceivedSignal() -> Bool {
        receivedSignal
    }
}

private final class KanameLinkTunnelToolPOSIXPreparedRunLifecycle:
    KanameLinkTunnelToolPreparedRunLifecycle, @unchecked Sendable
{
    private let processProbe: any KanameLinkTunnelToolProcessProbing
    private let pollingNanoseconds: UInt64
    private let signalLatch = KanameLinkTunnelToolSignalLatch()
    private let interruptSource: any DispatchSourceSignal
    private let terminateSource: any DispatchSourceSignal

    init(
        processProbe: any KanameLinkTunnelToolProcessProbing,
        pollingNanoseconds: UInt64
    ) {
        self.processProbe = processProbe
        self.pollingNanoseconds = pollingNanoseconds

        _ = Darwin.signal(SIGINT, SIG_IGN)
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let terminateSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let signalLatch = self.signalLatch
        interruptSource.setEventHandler {
            Task { await signalLatch.receive() }
        }
        terminateSource.setEventHandler {
            Task { await signalLatch.receive() }
        }
        interruptSource.resume()
        terminateSource.resume()
        self.interruptSource = interruptSource
        self.terminateSource = terminateSource
    }

    deinit {
        interruptSource.cancel()
        terminateSource.cancel()
        _ = Darwin.signal(SIGINT, SIG_DFL)
        _ = Darwin.signal(SIGTERM, SIG_DFL)
    }

    func wait(
        forOwnedSupervisor processIdentifier: Int32
    ) async throws -> KanameLinkTunnelToolRunCompletion {
        guard processIdentifier > 0 else {
            throw KanameLinkTunnelToolError.signalSetupFailed
        }
        while true {
            try Task.checkCancellation()
            if await signalLatch.hasReceivedSignal() {
                return .signal
            }
            guard processProbe.isRunning(processIdentifier: processIdentifier) else {
                return .supervisorExited
            }
            try await Task.sleep(nanoseconds: pollingNanoseconds)
        }
    }

    func waitForOwnedSupervisorExit(processIdentifier: Int32) async throws {
        guard processIdentifier > 0 else {
            throw KanameLinkTunnelToolError.signalSetupFailed
        }
        while processProbe.isRunning(processIdentifier: processIdentifier) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollingNanoseconds)
        }
    }
}

enum KanameLinkTunnelToolJSON {
    private struct OperationReceipt: Encodable {
        let ok: Bool
        let operation: String
        let status: String
    }

    private struct SupervisorReceipt: Encodable {
        let pid: Int32
        let status: String
    }

    private struct FailureReceipt: Encodable {
        let ok: Bool
        let error: String
    }

    static func encode(_ event: KanameLinkTunnelToolOutputEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        switch event {
        case .credentialEnrolled:
            encoded = try encoder.encode(OperationReceipt(
                ok: true,
                operation: "enroll-token",
                status: "stored"
            ))
        case let .credentialStatus(present):
            encoded = try encoder.encode(OperationReceipt(
                ok: true,
                operation: "credential-status",
                status: present ? "present" : "missing"
            ))
        case let .supervisor(processIdentifier, status):
            encoded = try encoder.encode(SupervisorReceipt(
                pid: processIdentifier,
                status: status.rawValue
            ))
        }
        return line(encoded)
    }

    static func encodeFailure(code: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return line(try encoder.encode(FailureReceipt(ok: false, error: code)))
    }

    private static func line(_ encoded: Data) -> Data {
        var result = encoded
        result.append(0x0A)
        return result
    }
}

struct KanameLinkTunnelToolJSONLineOutput: KanameLinkTunnelToolOutputWriting,
    @unchecked Sendable
{
    private let handle: FileHandle

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func write(_ event: KanameLinkTunnelToolOutputEvent) throws {
        do {
            try handle.write(contentsOf: KanameLinkTunnelToolJSON.encode(event))
        } catch {
            throw KanameLinkTunnelToolError.outputFailed
        }
    }
}

enum KanameLinkTunnelToolSafeFailure {
    static func code(for error: Error) -> String {
        switch error {
        case KanameLinkTunnelToolError.invalidArguments:
            "invalid_arguments"
        case KanameLinkTunnelToolError.outputFailed:
            "output_failed"
        case KanameLinkTunnelToolError.signalSetupFailed:
            "lifecycle_failed"
        case KanameLinkTunnelCredentialError.invalidToken:
            "invalid_credential"
        case KanameLinkTunnelCredentialError.credentialNotFound:
            "credential_missing"
        case KanameLinkTunnelCredentialError.keychainFailure:
            "credential_access_failed"
        case KanameLinkTunnelEnrollmentError.inputIsNotAnonymousPipe:
            "anonymous_input_required"
        case KanameLinkTunnelEnrollmentError.inputReadFailed:
            "credential_input_failed"
        case KanameLinkTunnelEnrollmentError.inputTooLarge:
            "credential_input_too_large"
        case KanameLinkTunnelEnrollmentError.emptyInput:
            "credential_input_empty"
        case KanameLinkTunnelSupervisorFailure.invalidPath,
             KanameLinkTunnelSupervisorFailure.invalidDigest:
            "runtime_identity_invalid"
        case KanameLinkTunnelSupervisorFailure.artifactUnavailable:
            "runtime_artifact_unavailable"
        case KanameLinkTunnelSupervisorFailure.artifactMismatch,
             KanameLinkTunnelSupervisorFailure.receiptMismatch:
            "runtime_identity_mismatch"
        case KanameLinkTunnelSupervisorFailure.alreadyRunning:
            "supervisor_already_running"
        case KanameLinkTunnelSupervisorFailure.processLaunchFailed:
            "supervisor_launch_failed"
        case KanameLinkTunnelSupervisorFailure.tokenPipeWriteFailed:
            "credential_delivery_failed"
        default:
            "operation_failed"
        }
    }

    static func exitCode(for error: Error) -> Int32 {
        error as? KanameLinkTunnelToolError == .invalidArguments ? EX_USAGE : EXIT_FAILURE
    }
}
#endif
