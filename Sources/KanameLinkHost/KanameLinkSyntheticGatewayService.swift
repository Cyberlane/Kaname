import Foundation

public actor KanameLinkSyntheticGatewayService: KanameLinkGatewayService {
    private var current: KanameLinkGatewaySnapshot
    private var nextReceiptSequence: Int

    public init(snapshot: KanameLinkGatewaySnapshot) throws {
        try KanameLinkSnapshotContract.validate(snapshot)
        current = snapshot
        nextReceiptSequence = snapshot.receipts.count + 1
    }

    public static func fixture() -> KanameLinkSyntheticGatewayService {
        // Fixed values keep screenshots and tests deterministic. This fixture
        // performs no network, filesystem, provider, tool, or conversation work.
        try! KanameLinkSyntheticGatewayService(snapshot: fixtureSnapshot)
    }

    public func fetchSnapshot() async throws -> KanameLinkGatewaySnapshot {
        current
    }

    public func createInvitation(
        request: KanameLinkInvitationRequest
    ) async throws -> KanameLinkInvitationArtifact {
        // Screenshot fixtures never create or retain invitation secrets.
        throw KanameLinkGatewayServiceError.syntheticOperationUnavailable
    }

    public func decidePendingDevice(
        id: String,
        decision: KanameLinkDeviceDecision
    ) async throws {
        try KanameLinkSnapshotContract.validatePublicIdentifier(id)
        guard let index = current.pendingDevices.firstIndex(where: { $0.id == id }) else {
            throw KanameLinkGatewayServiceError.pendingDeviceNotFound
        }
        let pending = current.pendingDevices.remove(at: index)
        if let spaceIndex = current.spaces.firstIndex(where: { $0.id == pending.spaceID }) {
            current.spaces[spaceIndex].pendingDeviceCount = max(
                0,
                current.spaces[spaceIndex].pendingDeviceCount - 1
            )
        }
        appendReceipt(
            spaceID: pending.spaceID,
            spaceName: pending.spaceName,
            stage: .gatewayAccepted,
            summary: decision == .approve ? "Device approval recorded" : "Device request denied",
            detail: "The synthetic gateway accepted the decision locally; relay delivery was not attempted."
        )
    }

    public func publishReply(
        spaceID: String,
        body: String
    ) async throws -> KanameLinkReplyReceipt {
        try KanameLinkSnapshotContract.validatePublicIdentifier(spaceID)
        try KanameLinkSnapshotContract.validateReplyBody(body)
        guard let spaceIndex = current.spaces.firstIndex(where: { $0.id == spaceID }) else {
            throw KanameLinkGatewayServiceError.spaceNotFound
        }
        let space = current.spaces[spaceIndex]
        current.spaces[spaceIndex].messageCount += 1
        appendReceipt(
            spaceID: space.id,
            spaceName: space.name,
            stage: .gatewayAccepted,
            summary: "Reply accepted by synthetic gateway",
            detail: "The fixture recorded a local acceptance only; no external delivery occurred."
        )
        return KanameLinkReplyReceipt(
            messageID: "message-synthetic-\(nextReceiptSequence)",
            state: "hostReceived",
            queuedAtUnixMillis: 1_787_544_000_000 + Int64(nextReceiptSequence),
            hostReceivedAtUnixMillis: 1_787_544_000_000 + Int64(nextReceiptSequence),
            position: UInt64(current.spaces[spaceIndex].messageCount),
            duplicate: false
        )
    }

    private func appendReceipt(
        spaceID: String,
        spaceName: String,
        stage: KanameLinkReceiptStage,
        summary: String,
        detail: String
    ) {
        let sequence = nextReceiptSequence
        nextReceiptSequence += 1
        current.receipts.insert(
            KanameLinkReceipt(
                id: "receipt-synthetic-\(sequence)",
                spaceID: spaceID,
                spaceName: spaceName,
                stage: stage,
                summary: summary,
                detail: detail,
                recordedAtUnixMillis: 1_787_544_000_000 + Int64(sequence)
            ),
            at: 0
        )
        if current.receipts.count > KanameLinkSnapshotContract.maximumReceipts {
            current.receipts.removeLast(current.receipts.count - KanameLinkSnapshotContract.maximumReceipts)
        }
    }

    public static let fixtureSnapshot = KanameLinkGatewaySnapshot(
        gateway: KanameLinkGatewayStatus(
            lifecycle: .ready,
            mode: .syntheticFixture,
            detail: "Synthetic local fixture. No relay or tunnel connection is active.",
            version: "fixture-1",
            observedAtUnixMillis: 1_787_544_000_000
        ),
        spaces: [
            KanameLinkSpaceSummary(
                id: "space-design-partners",
                name: "Design partners",
                deviceCount: 2,
                messageCount: 2,
                pendingDeviceCount: 1,
                externalInboxCount: 2,
                lastActivityUnixMillis: 1_787_543_400_000
            ),
            KanameLinkSpaceSummary(
                id: "space-release-review",
                name: "Release review",
                deviceCount: 1,
                messageCount: 0,
                pendingDeviceCount: 0,
                externalInboxCount: 0,
                lastActivityUnixMillis: 1_787_536_800_000
            ),
        ],
        pendingDevices: [
            KanameLinkPendingDevice(
                id: "device-request-maya-tablet",
                spaceID: "space-design-partners",
                spaceName: "Design partners",
                collaboratorDisplayName: "Maya Chen",
                deviceLabel: "Platform not reported",
                verificationCode: "RIVER-PINE",
                requestedAtUnixMillis: 1_787_542_800_000
            ),
        ],
        externalInbox: [
            KanameLinkExternalMessage(
                id: "external-message-2",
                spaceID: "space-design-partners",
                spaceName: "Design partners",
                senderDisplayName: "Maya Chen",
                body: "The collaborator preview is clear. Could the expiry time also appear beside the revision?",
                receivedAtUnixMillis: 1_787_543_400_000
            ),
            KanameLinkExternalMessage(
                id: "external-message-1",
                spaceID: "space-design-partners",
                spaceName: "Design partners",
                senderDisplayName: "Alex Rivera",
                body: "Reviewed the shared summary. No private repository details were visible.",
                receivedAtUnixMillis: 1_787_541_600_000
            ),
        ],
        publicationPreviews: [
            KanameLinkPublicationPreview(
                id: "publication-link-plan-r3",
                spaceID: "space-design-partners",
                spaceName: "Design partners",
                title: "Kaname Link delivery outline",
                summary: "A collaborator-visible outline covering Link spaces, device approval, encrypted delivery, and explicit publication receipts. Private conversations, repositories, tools, credentials, and local files are excluded.",
                audienceDescription: "All approved members of Design partners",
                revision: 3,
                contentDigest: "sha256:90cb98ce274d8d95f0cdbb19ba649561b58db015bf9098d3a8d1c67141fa6d21",
                expiresAtUnixMillis: 1_788_062_400_000
            ),
        ],
        receipts: [
            KanameLinkReceipt(
                id: "receipt-synthetic-2",
                spaceID: "space-design-partners",
                spaceName: "Design partners",
                stage: .gatewayAccepted,
                summary: "Publication accepted by gateway",
                detail: "Synthetic gateway acceptance only; no relay delivery or collaborator open is claimed.",
                recordedAtUnixMillis: 1_787_540_400_000
            ),
            KanameLinkReceipt(
                id: "receipt-synthetic-1",
                spaceID: "space-release-review",
                spaceName: "Release review",
                stage: .delivered,
                summary: "Shared release summary delivered",
                detail: "The fixture records delivery, not that the collaborator opened or reviewed it.",
                recordedAtUnixMillis: 1_787_457_600_000
            ),
        ]
    )
}
