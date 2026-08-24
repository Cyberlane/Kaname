import Foundation
import Testing
@testable import KanameLinkHost

struct KanameLinkHostContractTests {
    @Test
    func syntheticFixtureKeepsExternalPrincipalsSeparateAndContainsNoInvitationSecret() async throws {
        let service = KanameLinkSyntheticGatewayService.fixture()
        let snapshot = try await service.fetchSnapshot()

        #expect(snapshot.gateway.mode == .syntheticFixture)
        #expect(snapshot.gateway.detail.contains("No relay or tunnel"))
        #expect(snapshot.pendingDevices.count == 1)
        #expect(snapshot.externalInbox.count == 2)
        #expect(snapshot.externalInbox.allSatisfy { $0.trust == .externalUntrusted })
        #expect(snapshot.publicationPreviews[0].summary.contains("Private conversations"))
        let fixtureWire = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: fixtureWire, as: UTF8.self).contains("inviteSecret"))

        let invitationRequest = try KanameLinkInvitationRequest(
            spaceID: "space-fixture-test",
            spaceName: "Fixture test",
            expiresInSeconds: 3_600
        )
        await #expect(throws: KanameLinkGatewayServiceError.syntheticOperationUnavailable) {
            try await service.createInvitation(request: invitationRequest)
        }
    }

    @Test
    func syntheticDecisionsAndRepliesRemainLocalAndDeterministic() async throws {
        let service = KanameLinkSyntheticGatewayService.fixture()
        try await service.decidePendingDevice(
            id: "device-request-maya-tablet",
            decision: .approve
        )
        let approved = try await service.fetchSnapshot()

        #expect(approved.pendingDevices.isEmpty)
        #expect(approved.spaces.first { $0.id == "space-design-partners" }?.pendingDeviceCount == 0)
        #expect(approved.receipts.first?.stage == .gatewayAccepted)
        #expect(approved.receipts.first?.detail.contains("relay delivery was not attempted") == true)

        let receipt = try await service.publishReply(
            spaceID: "space-design-partners",
            body: "A bounded fixture reply."
        )
        let replied = try await service.fetchSnapshot()
        #expect(receipt.state == "hostReceived")
        #expect(replied.receipts.first?.stage == .gatewayAccepted)
        #expect(replied.receipts.first?.detail.contains("no external delivery") == true)
    }

    @Test
    func boundedSnapshotRejectsOversizedExternalContent() {
        var snapshot = KanameLinkSyntheticGatewayService.fixtureSnapshot
        snapshot.externalInbox[0].body = String(
            repeating: "x",
            count: KanameLinkSnapshotContract.maximumExternalBodyBytes + 1
        )

        #expect(throws: KanameLinkGatewayServiceError.self) {
            try KanameLinkSnapshotContract.validate(snapshot)
        }
    }

    @Test
    func createInviteEnvelopeMatchesCanonicalRustKeysAndFixedGateway() throws {
        let invitation = try KanameLinkInvitationRequest(
            spaceID: "space-design-partners",
            spaceName: "Design partners",
            expiresInSeconds: 86_400
        )
        let request = try KanameLinkAdminRequest.createInvite(
            requestID: "request-1",
            request: invitation,
            gatewayURL: KanameLinkProcessGatewayService.gatewayURL
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(Set(object.keys) == Set(["schemaVersion", "requestID", "operation", "payload"]))
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["requestID"] as? String == "request-1")
        #expect(object["operation"] as? String == "createInvite")
        #expect(Set(payload.keys) == Set(["spaceID", "spaceName", "gatewayUrl", "expiresInSeconds"]))
        #expect(payload["spaceID"] as? String == "space-design-partners")
        #expect(payload["gatewayUrl"] as? String == "https://kaname-tunnel.cyber-lane.com")
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!json.contains("thread"))
        #expect(!json.contains("provider"))
        #expect(!json.contains("tool"))
        #expect(!json.contains("workspace"))
    }

    @Test
    func hostSnapshotMapsCanonicalRustModelsWithoutInventingAuthorityOrPlatform() async throws {
        let runner = StubLinkAdminRunner { request in
            try hostSnapshotResponse(requestID: request.requestID)
        }
        let service = KanameLinkProcessGatewayService(
            runner: runner,
            nowUnixMillis: { 1_800_000_000_000 }
        )

        let snapshot = try await service.fetchSnapshot()

        #expect(snapshot.gateway.mode == .bundledAdminCLI)
        #expect(snapshot.gateway.lifecycle == .ready)
        #expect(snapshot.gateway.detail.contains("not verified"))
        #expect(snapshot.gateway.hostKeyFingerprint == "sha256:host-key")
        #expect(snapshot.spaces[0].deviceCount == 1)
        #expect(snapshot.spaces[0].messageCount == 1)
        #expect(snapshot.spaces[0].externalInboxCount == 1)
        #expect(snapshot.pendingDevices[0].deviceLabel == "Platform not reported")
        #expect(snapshot.pendingDevices[0].verificationCode == "VERIFY-CODE")
        #expect(snapshot.externalInbox[0].senderDisplayName == "External collaborator")
        #expect(snapshot.externalInbox[0].trust == .externalUntrusted)
        #expect(snapshot.publicationPreviews.isEmpty)
        #expect(snapshot.receipts.isEmpty)
    }

    @Test
    func invitationUsesCanonicalClientWireAndRedactsTextualDescriptions() async throws {
        let runtimeSecret = UUID().uuidString
        let runner = StubLinkAdminRunner { request in
            let invitation = try KanameLinkInvitationArtifact(
                schemaVersion: 1,
                inviteID: "invite-test-1",
                spaceID: "space-new",
                spaceName: "New space",
                gatewayURL: KanameLinkProcessGatewayService.gatewayURL,
                hostStaticPublicKey: "public-key-material",
                inviteSecret: runtimeSecret,
                expiresAtUnixMillis: 1_800_000_086_400
            )
            return try encodedSuccess(requestID: request.requestID, result: invitation)
        }
        let service = KanameLinkProcessGatewayService(
            runner: runner,
            nowUnixMillis: { 1_800_000_000_000 }
        )
        let request = try KanameLinkInvitationRequest(
            spaceID: "space-new",
            spaceName: "New space",
            expiresInSeconds: 86_400
        )

        let invitation = try await service.createInvitation(request: request)
        let transfer = try #require(
            JSONSerialization.jsonObject(
                with: Data(try invitation.invitationDocumentForExplicitCopy().utf8)
            ) as? [String: Any]
        )

        #expect(invitation.description.contains("<redacted>"))
        #expect(!invitation.description.contains(runtimeSecret))
        #expect(!invitation.debugDescription.contains(runtimeSecret))
        #expect(Set(transfer.keys) == Set([
            "schemaVersion", "inviteId", "spaceId", "spaceName", "gatewayUrl",
            "hostStaticPublicKey", "inviteSecret", "expiresAtUnixMillis",
        ]))
        #expect(transfer["inviteId"] as? String == "invite-test-1")
        #expect(transfer["spaceId"] as? String == "space-new")
        #expect(transfer["gatewayUrl"] as? String == KanameLinkProcessGatewayService.gatewayURL)
        #expect(transfer["inviteSecret"] as? String != nil)

        let captured = await runner.requests()
        #expect(captured.count == 1)
        #expect(captured[0].operation == .createInvite)
        guard case let .createInvite(_, _, gatewayURL, expiresInSeconds) = captured[0].payload else {
            Issue.record("Expected createInvite payload")
            return
        }
        #expect(gatewayURL == KanameLinkProcessGatewayService.gatewayURL)
        #expect(expiresInSeconds == 86_400)
    }

    @Test
    func approveDenyAndPublishUseCanonicalOperations() async throws {
        let runner = StubLinkAdminRunner { request in
            switch request.operation {
            case .approve, .deny:
                guard case let .device(deviceID) = request.payload else {
                    throw KanameLinkProcessRunnerError.malformedResponse
                }
                return try encodedSuccess(
                    requestID: request.requestID,
                    result: RustDeviceSummary(
                        deviceID: deviceID,
                        displayName: "External collaborator",
                        spaceID: "space-design-partners",
                        state: request.operation == .approve ? "approved" : "revoked",
                        verificationCode: "VERIFY-CODE",
                        createdAtUnixMillis: 1_700_000_000_000,
                        approvedAtUnixMillis: nil,
                        revokedAtUnixMillis: nil
                    )
                )
            case .publish:
                guard case let .publish(_, _, messageID) = request.payload else {
                    throw KanameLinkProcessRunnerError.malformedResponse
                }
                return try encodedSuccess(
                    requestID: request.requestID,
                    result: KanameLinkReplyReceipt(
                        messageID: messageID,
                        state: "hostReceived",
                        queuedAtUnixMillis: 1_700_000_000_000,
                        hostReceivedAtUnixMillis: 1_700_000_000_001,
                        position: 2,
                        duplicate: false
                    )
                )
            default:
                throw KanameLinkProcessRunnerError.malformedResponse
            }
        }
        let service = KanameLinkProcessGatewayService(runner: runner)

        try await service.decidePendingDevice(id: "device-one", decision: .approve)
        try await service.decidePendingDevice(id: "device-two", decision: .deny)
        let reply = try await service.publishReply(
            spaceID: "space-design-partners",
            body: "Only this bounded text is shared."
        )

        #expect(reply.state == "hostReceived")
        let operations = await runner.requests().map(\.operation)
        #expect(operations == [.approve, .deny, .publish])
    }

    @Test
    func processServiceRejectsResponseFromAnotherRequest() async {
        let runner = StubLinkAdminRunner { _ in
            try hostSnapshotResponse(requestID: "different-request")
        }
        let service = KanameLinkProcessGatewayService(runner: runner)

        await #expect(throws: KanameLinkProcessRunnerError.responseCorrelationMismatch) {
            try await service.fetchSnapshot()
        }
    }

    @Test
    func hostSnapshotRejectsPendingDeviceForUnknownSpace() async {
        let runner = StubLinkAdminRunner { request in
            let raw = RustHostShellSnapshot(
                schemaVersion: 1,
                status: RustGatewayStatus(
                    schemaVersion: 1,
                    hostKeyFingerprint: "sha256:host-key",
                    spaceCount: 0,
                    pendingDeviceCount: 1,
                    approvedDeviceCount: 0,
                    messageCount: 0
                ),
                spaces: [],
                pendingDevices: [
                    RustDeviceSummary(
                        deviceID: "device-orphan",
                        displayName: "External collaborator",
                        spaceID: "space-missing",
                        state: "pending",
                        verificationCode: "VERIFY-CODE",
                        createdAtUnixMillis: 1_700_000_000_000,
                        approvedAtUnixMillis: nil,
                        revokedAtUnixMillis: nil
                    ),
                ],
                inbox: []
            )
            return try encodedSuccess(requestID: request.requestID, result: raw)
        }
        let service = KanameLinkProcessGatewayService(runner: runner)

        await #expect(throws: KanameLinkProcessRunnerError.malformedResponse) {
            try await service.fetchSnapshot()
        }
    }
}

private actor StubLinkAdminRunner: KanameLinkAdminCommandRunning {
    private let handler: @Sendable (KanameLinkAdminRequest) async throws -> Data
    private var captured: [KanameLinkAdminRequest] = []

    init(handler: @escaping @Sendable (KanameLinkAdminRequest) async throws -> Data) {
        self.handler = handler
    }

    func execute(_ request: KanameLinkAdminRequest) async throws -> Data {
        captured.append(request)
        return try await handler(request)
    }

    func requests() -> [KanameLinkAdminRequest] { captured }
}

private func hostSnapshotResponse(requestID: String) throws -> Data {
    try encodedSuccess(
        requestID: requestID,
        result: RustHostShellSnapshot(
            schemaVersion: 1,
            status: RustGatewayStatus(
                schemaVersion: 1,
                hostKeyFingerprint: "sha256:host-key",
                spaceCount: 1,
                pendingDeviceCount: 1,
                approvedDeviceCount: 0,
                messageCount: 1
            ),
            spaces: [
                RustSpaceSummary(
                    spaceID: "space-design-partners",
                    name: "Design partners",
                    deviceCount: 1,
                    messageCount: 1
                ),
            ],
            pendingDevices: [
                RustDeviceSummary(
                    deviceID: "device-pending-one",
                    displayName: "External collaborator",
                    spaceID: "space-design-partners",
                    state: "pending",
                    verificationCode: "VERIFY-CODE",
                    createdAtUnixMillis: 1_700_000_000_000,
                    approvedAtUnixMillis: nil,
                    revokedAtUnixMillis: nil
                ),
            ],
            inbox: [
                RustLinkMessage(
                    position: 1,
                    messageID: "message-external-one",
                    spaceID: "space-design-partners",
                    sender: "collaborator",
                    text: "External data only.",
                    queuedAtUnixMillis: 1_700_000_000_010,
                    hostReceivedAtUnixMillis: 1_700_000_000_020
                ),
            ]
        )
    )
}

private func encodedSuccess<Result: Codable & Equatable & Sendable>(
    requestID: String,
    result: Result
) throws -> Data {
    try JSONEncoder().encode(
        KanameLinkAdminResponse(requestID: requestID, ok: true, result: result)
    )
}
