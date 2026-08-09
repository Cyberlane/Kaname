import CryptoKit
import Darwin
import Foundation
import KanameMobileSync
import KanameProtocol

private struct AuthorityState: Codable {
    let runID: String
    let macDeviceID: String
    let macKeyID: String
    let phoneDeviceID: String
    let enrollmentID: String
    var phoneKeyID: String?
    var phonePublicKey: Data?
    var phoneKeyGeneration: UInt64
    var processedQueueItems: [String]
    var approvalID: String?
    var approvalFingerprint: Data?
    var currentTargetRevision: String
    var staleApprovalRejected: Bool
    var rotationAccepted: Bool
    var revocationSent: Bool
}

private struct PhoneLaunchConfiguration: Codable {
    let relayURL: URL
    let deviceID: String
    let displayName: String
    let keyID: String
    let enrollmentID: String
    let peerDeviceID: String
    let peerKeyID: String
    let peerPublicKey: Data
    let pushEnvironment: String
}

private enum QualificationError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case invalidCommand
    case invalidRunID
    case invalidConfirmationCode
    case enrollmentMismatch
    case enrollmentExpired
    case notEnrolled
    case noQueueItems
    case noApprovalCommand
    case noRotation
    case unsafeCleanupPath

    var description: String {
        switch self {
        case .missingEnvironment(let name): "missing environment variable \(name)"
        case .invalidCommand: "invalid qualification command"
        case .invalidRunID: "invalid qualification run identifier"
        case .invalidConfirmationCode: "confirmation code did not authenticate the enrollment transcript"
        case .enrollmentMismatch: "relay enrollment does not match this bounded qualification"
        case .enrollmentExpired: "relay enrollment expired before local confirmation"
        case .notEnrolled: "physical device enrollment has not been accepted"
        case .noQueueItems: "no new queue items were received"
        case .noApprovalCommand: "no approval command was received"
        case .noRotation: "no key rotation proposal was received"
        case .unsafeCleanupPath: "refused unsafe qualification cleanup path"
        }
    }
}

@main
@available(macOS 14.0, *)
private enum KanamePhase3Qualification {
    static func main() async {
        await QualificationCommandRunner.execute()
    }
}

@available(macOS 14.0, *)
private enum QualificationCommandRunner {
    static func execute() async {
        do {
            try await run()
        } catch {
            terminate(after: error)
        }
    }

    private static func terminate(after error: Error) -> Never {
        FileHandle.standardError.write(Data("qualification error: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private static func run() async throws {
        let context = try Context()
        guard let command = CommandLine.arguments.dropFirst().first else {
            throw QualificationError.invalidCommand
        }
        switch command {
        case "bootstrap":
            try await context.bootstrap()
        case "accept-enrollment":
            guard CommandLine.arguments.count == 3 else { throw QualificationError.invalidCommand }
            try await context.acceptEnrollment(code: CommandLine.arguments[2])
        case "sync-queue":
            try await context.syncQueue()
        case "send-approval":
            try await context.sendApproval()
        case "advance-target":
            try context.advanceTarget()
        case "reconcile-approval":
            try await context.reconcileApproval()
        case "accept-rotation":
            try await context.acceptRotation()
        case "send-revocation":
            try await context.sendRevocation()
        case "status":
            try context.status()
        case "cleanup":
            try await context.cleanup()
        default:
            throw QualificationError.invalidCommand
        }
    }
}

@available(macOS 14.0, *)
private struct Context {
    private let relayURL: URL
    private let relayToken: String
    private let runID: String
    private let rootURL: URL
    private let stateURL: URL
    private let sessionStateURL: URL
    private let keyStore: KeychainMobileSyncKeyStore
    private let relayClient: MobileEnrollmentRelayClient
    private let transport: HTTPMobileSyncTransport

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let relayURLString = environment["KANAME_RELAY_URL"],
              let relayURL = URL(string: relayURLString) else {
            throw QualificationError.missingEnvironment("KANAME_RELAY_URL")
        }
        guard let relayToken = environment["KANAME_RELAY_TOKEN"] else {
            throw QualificationError.missingEnvironment("KANAME_RELAY_TOKEN")
        }
        guard let runID = environment["KANAME_RUN_ID"] else {
            throw QualificationError.missingEnvironment("KANAME_RUN_ID")
        }
        guard Self.isValidIdentifier(runID), runID.utf8.count <= 40 else {
            throw QualificationError.invalidRunID
        }
        let rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaname", isDirectory: true)
            .appendingPathComponent("Phase3Qualification", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        self.relayURL = relayURL
        self.relayToken = relayToken
        self.runID = runID
        self.rootURL = rootURL
        self.stateURL = rootURL.appendingPathComponent("authority.json")
        self.sessionStateURL = rootURL.appendingPathComponent("sync.json")
        self.keyStore = try KeychainMobileSyncKeyStore(
            service: "com.cyberlane.kaname.phase3.authority",
            useDataProtectionKeychain: false
        )
        self.relayClient = try MobileEnrollmentRelayClient(baseURL: relayURL, bearerToken: relayToken)
        self.transport = try HTTPMobileSyncTransport(baseURL: relayURL, bearerToken: relayToken)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (first >= 48 && first <= 57) || (first >= 65 && first <= 90) || (first >= 97 && first <= 122),
              value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || [45, 46, 58, 95].contains($0)
        }
    }

    func bootstrap() async throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let state = initialState()
        let publicKey: Curve25519.KeyAgreement.PublicKey
        if let existing = try? keyStore.load(keyID: state.macKeyID) {
            publicKey = existing.publicKey
        } else {
            publicKey = try keyStore.generateAndStore(keyID: state.macKeyID)
        }
        _ = try keyStore.load(keyID: state.macKeyID)
        try save(state)
        let launch = PhoneLaunchConfiguration(
            relayURL: relayURL,
            deviceID: state.phoneDeviceID,
            displayName: "Justin's iPhone",
            keyID: "iphone-phase3-key-\(runID)",
            enrollmentID: state.enrollmentID,
            peerDeviceID: state.macDeviceID,
            peerKeyID: state.macKeyID,
            peerPublicKey: publicKey.rawRepresentation,
            pushEnvironment: "sandbox"
        )
        FileHandle.standardOutput.write(try JSONEncoder().encode(launch))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func acceptEnrollment(code: String) async throws {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw QualificationError.invalidConfirmationCode
        }
        var state = try load()
        let record = try await relayClient.enrollment(enrollmentID: state.enrollmentID)
        let challenge = try Kaname_V1_DeviceEnrollmentChallenge(serializedBytes: record.challengeWire)
        guard record.deviceID == state.phoneDeviceID,
              challenge.enrollmentID == state.enrollmentID,
              challenge.proposedDevice.deviceID == state.phoneDeviceID,
              challenge.proposedDevice.platform == "ios",
              challenge.proposedDevice.hpkePublicKey.count == 32 else {
            throw QualificationError.enrollmentMismatch
        }
        guard challenge.expiresAtUnixMillis > nowMillis else {
            throw QualificationError.enrollmentExpired
        }
        var material = Data("kaname.enrollment.v1".utf8)
        material.append(try challenge.proposedDevice.serializedData())
        material.append(challenge.macNonce)
        material.append(Data(code.utf8))
        guard Data(SHA256.hash(data: material)) == challenge.confirmationDigest else {
            throw QualificationError.invalidConfirmationCode
        }
        state.phoneKeyID = challenge.proposedDevice.keyID
        state.phonePublicKey = challenge.proposedDevice.hpkePublicKey
        state.phoneKeyGeneration = challenge.proposedDevice.keyGeneration
        try save(state)
        var receipt = Kaname_V1_DeviceEnrollmentReceipt()
        receipt.enrollmentID = state.enrollmentID
        receipt.deviceID = state.phoneDeviceID
        receipt.state = .active
        receipt.reasonCode = "local_code_confirmed"
        try await relayClient.recordEnrollmentReceipt(receipt)
        print("enrollment_active")
    }

    func syncQueue() async throws {
        var state = try load()
        let session = try makeSession(state)
        try await session.restore()
        let result = try await session.pollIncoming(nowUnixMillis: nowMillis)
        let snapshot = await session.snapshot()
        let fresh = snapshot.receivedQueueCommands
            .filter { !state.processedQueueItems.contains("\($0.itemID):\($0.revision)") }
            .sorted { ($0.position, $0.createdAtUnixMillis) < ($1.position, $1.createdAtUnixMillis) }
        guard !fresh.isEmpty else { throw QualificationError.noQueueItems }
        for (index, command) in fresh.enumerated() {
            var received = Kaname_V1_QueueReceipt()
            received.itemID = command.itemID
            received.state = .receivedByMac
            received.revision = command.revision
            received.recordedAtUnixMillis = nowMillis
            _ = try await session.sendPayload(
                payloadID: "queue-received-\(command.itemID)-\(command.revision)",
                payloadKind: "queue.receipt",
                plaintext: try received.serializedData(),
                nowUnixMillis: nowMillis
            )
            var accepted = received
            accepted.state = .policyAccepted
            accepted.recordedAtUnixMillis = nowMillis + 1
            _ = try await session.sendPayload(
                payloadID: "queue-accepted-\(command.itemID)-\(command.revision)",
                payloadKind: "queue.receipt",
                plaintext: try accepted.serializedData(),
                nowUnixMillis: nowMillis + 1
            )
            var event = Kaname_V1_EventEnvelope()
            event.eventID = "event-\(command.itemID)"
            event.storePosition = UInt64(index + 1)
            event.streamID = command.streamID
            event.streamSequence = UInt64(index + 1)
            event.occurredAtUnixMillis = nowMillis + 2
            event.kind = "thread.message.accepted"
            _ = try await session.sendPayload(
                payloadID: "history-\(command.itemID)-\(command.revision)",
                payloadKind: "event.history",
                plaintext: try event.serializedData(),
                nowUnixMillis: nowMillis + 2
            )
            state.processedQueueItems.append("\(command.itemID):\(command.revision)")
        }
        try save(state)
        print("queue_reconciled applied=\(result.applied) items=\(fresh.count)")
    }

    func sendApproval() async throws {
        var state = try load()
        let session = try makeSession(state)
        try await session.restore()
        let approvalID = "approval-phase3-\(runID)"
        var request = Kaname_V1_ApprovalRequest()
        request.approvalID = approvalID
        request.actionKind = "qualification.workspace_write"
        request.scope.projectID = "coding-ade"
        request.scope.workspaceID = "phase3-qualification"
        request.scope.authorityID = state.macDeviceID
        request.scope.egressClass = "encrypted-relay-only"
        request.scope.destinationDigest = "sha256:bounded-qualification-target"
        request.targetID = "qualification-target-\(runID)"
        request.targetRevision = "revision-1"
        request.effectDigest = Data(SHA256.hash(data: Data("recoverable qualification marker".utf8)))
        request.consequence = "Allow one recoverable marker write in the isolated Phase 3 qualification scope."
        request.reversible = true
        request.expiresAtUnixMillis = nowMillis + 15 * 60 * 1_000
        request.policyReference = "phase3-explicit-current-approval"
        request.approvalPayloadVersion = 1
        request.fingerprint = Data(SHA256.hash(data: try request.serializedData()))
        _ = try await session.sendPayload(
            payloadID: approvalID,
            payloadKind: "approval.request",
            plaintext: try request.serializedData(),
            nowUnixMillis: nowMillis
        )
        state.approvalID = approvalID
        state.approvalFingerprint = request.fingerprint
        state.currentTargetRevision = request.targetRevision
        try save(state)
        print("approval_sent")
    }

    func advanceTarget() throws {
        var state = try load()
        state.currentTargetRevision = "revision-2"
        try save(state)
        print("target_advanced_without_execution")
    }

    func reconcileApproval() async throws {
        var state = try load()
        let session = try makeSession(state)
        try await session.restore()
        _ = try await session.pollIncoming(nowUnixMillis: nowMillis)
        let snapshot = await session.snapshot()
        guard let approvalID = state.approvalID,
              let fingerprint = state.approvalFingerprint,
              let received = snapshot.receivedApprovalCommands.last(where: { $0.approvalID == approvalID }) else {
            throw QualificationError.noApprovalCommand
        }
        let command = try Kaname_V1_ApprovalCommand(serializedBytes: received.exactCommandWire)
        let isCurrent = command.request.targetRevision == state.currentTargetRevision
            && command.currentTargetRevision == state.currentTargetRevision
            && command.resolution.expectedFingerprint == fingerprint
            && command.request.fingerprint == fingerprint
        var receipt = Kaname_V1_ApprovalCommandReceipt()
        receipt.approvalID = approvalID
        receipt.decision = isCurrent ? command.resolution.decision : .reject
        receipt.fingerprint = fingerprint
        receipt.storePosition = 1
        receipt.reasonCode = isCurrent ? "current_target_reconciled" : "stale_target_revision"
        _ = try await session.sendPayload(
            payloadID: "approval-receipt-\(approvalID)",
            payloadKind: "approval.receipt",
            plaintext: try receipt.serializedData(),
            nowUnixMillis: nowMillis
        )
        state.staleApprovalRejected = !isCurrent
        try save(state)
        print(isCurrent ? "approval_current_reconciled" : "approval_stale_rejected_no_execution")
    }

    func acceptRotation() async throws {
        var state = try load()
        let session = try makeSession(state)
        try await session.restore()
        _ = try await session.pollIncoming(nowUnixMillis: nowMillis)
        let snapshot = await session.snapshot()
        guard let rotation = snapshot.receivedKeyRotations.last,
              rotation.deviceID == state.phoneDeviceID,
              rotation.previousKeyID == state.phoneKeyID,
              rotation.nextKeyGeneration == state.phoneKeyGeneration + 1 else {
            throw QualificationError.noRotation
        }
        var receipt = Kaname_V1_SyncReceipt()
        receipt.envelopeID = rotation.envelopeID
        receipt.senderDeviceID = state.phoneDeviceID
        receipt.senderSequence = snapshot.incomingSequence
        receipt.state = .policyAccepted
        receipt.reasonCode = "key_rotation_accepted"
        receipt.macStorePosition = snapshot.relayCursor
        receipt.recordedAtUnixMillis = nowMillis
        _ = try await session.sendPayload(
            payloadID: "rotation-receipt-\(rotation.nextKeyID)",
            payloadKind: "sync.receipt",
            plaintext: try receipt.serializedData(),
            nowUnixMillis: nowMillis
        )
        state.phoneKeyID = rotation.nextKeyID
        state.phonePublicKey = rotation.nextPublicKey
        state.phoneKeyGeneration = rotation.nextKeyGeneration
        state.rotationAccepted = true
        try save(state)
        print("rotation_accepted_old_key_retirement_authorized")
    }

    func sendRevocation() async throws {
        var state = try load()
        let session = try makeSession(state)
        try await session.restore()
        guard let phoneKeyID = state.phoneKeyID else { throw QualificationError.notEnrolled }
        var revocation = Kaname_V1_DeviceRevocation()
        revocation.deviceID = state.phoneDeviceID
        revocation.keyID = phoneKeyID
        revocation.revokedAtUnixMillis = nowMillis
        revocation.reasonCode = "qualification_lost_device_recovery"
        _ = try await session.sendPayload(
            payloadID: "revocation-phase3-\(runID)",
            payloadKind: "device.revocation",
            plaintext: try revocation.serializedData(),
            nowUnixMillis: nowMillis
        )
        state.revocationSent = true
        try save(state)
        print("revocation_sent")
    }

    func status() throws {
        let state = try load()
        let summary: [String: Bool] = [
            "enrolled": state.phonePublicKey != nil,
            "queueReconciled": !state.processedQueueItems.isEmpty,
            "staleApprovalRejected": state.staleApprovalRejected,
            "rotationAccepted": state.rotationAccepted,
            "revocationSent": state.revocationSent,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func cleanup() async throws {
        let state = try load()
        guard rootURL.lastPathComponent == runID,
              rootURL.path.contains("/Kaname/Phase3Qualification/") else {
            throw QualificationError.unsafeCleanupPath
        }
        try await relayClient.deleteQualificationData()
        try? keyStore.remove(keyID: state.macKeyID)
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        print("qualification_data_deleted")
    }

    private func initialState() -> AuthorityState {
        AuthorityState(
            runID: runID,
            macDeviceID: "mac-phase3-\(runID)",
            macKeyID: "mac-phase3-key-\(runID)",
            phoneDeviceID: "iphone-phase3-\(runID)",
            enrollmentID: "enrollment-phase3-\(runID)",
            phoneKeyID: nil,
            phonePublicKey: nil,
            phoneKeyGeneration: 0,
            processedQueueItems: [],
            approvalID: nil,
            approvalFingerprint: nil,
            currentTargetRevision: "revision-0",
            staleApprovalRejected: false,
            rotationAccepted: false,
            revocationSent: false
        )
    }

    private func makeSession(_ state: AuthorityState) throws -> MobileSyncSession {
        guard let phoneKeyID = state.phoneKeyID,
              let phonePublicKey = state.phonePublicKey else {
            throw QualificationError.notEnrolled
        }
        let configuration = try MobileSyncEndpointConfiguration(
            deviceID: state.macDeviceID,
            keyID: state.macKeyID,
            peerDeviceID: state.phoneDeviceID,
            peerKeyID: phoneKeyID,
            peerPublicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKey)
        )
        return try MobileSyncSession(
            configuration: configuration,
            keyStore: keyStore,
            transport: transport,
            stateStore: ProtectedFileMobileSyncStateStore(fileURL: sessionStateURL)
        )
    }

    private func load() throws -> AuthorityState {
        try JSONDecoder().decode(AuthorityState.self, from: Data(contentsOf: stateURL))
    }

    private func save(_ state: AuthorityState) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtection])
        _ = chmod(stateURL.path, S_IRUSR | S_IWUSR)
    }

    private var nowMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
