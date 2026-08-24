import Foundation
import KanameLinkProtocol
import SwiftProtobuf
import Testing

@Suite("Kaname Link protocol boundary")
struct LinkProtocolContractTests {
    @Test("invitation artifact round trips with external-only capabilities")
    func invitationRoundTrip() throws {
        var version = Kaname_Link_V1_SchemaVersion()
        version.major = 1
        var invitation = Kaname_Link_V1_InvitationArtifact()
        invitation.schemaVersion = version
        invitation.invitationID = "invite-synthetic-01"
        invitation.publicEndpoint = "https://kaname-tunnel.cyber-lane.com"
        invitation.hostDisplayName = "Synthetic host"
        invitation.hostNoiseStaticPublicKey = Data(repeating: 0x31, count: 32)
        invitation.spaceID = "space-synthetic-01"
        invitation.spaceDisplayName = "Synthetic pilot"
        invitation.capabilities = [
            .discussionRead,
            .discussionCreate,
            .messageSend,
            .statusRead,
            .receiptWrite,
        ]
        invitation.expiresAtUnixMillis = 1_800_000_000_000
        invitation.inviteSecret = Data(repeating: 0x42, count: 32)

        let decoded = try Kaname_Link_V1_InvitationArtifact(
            serializedBytes: invitation.serializedData()
        )
        #expect(decoded == invitation)
        #expect(decoded.capabilities.allSatisfy { $0 != .unspecified })
        #expect(decoded.hostNoiseStaticPublicKey.count == 32)
        #expect(decoded.inviteSecret.count == 32)
    }

    @Test("wire surface cannot express trusted Kaname authority")
    func forbiddenAuthorityAbsent() throws {
        let descriptor = Kaname_Link_V1_ClientFrame.protoMessageName
            + Kaname_Link_V1_ServerFrame.protoMessageName
        let forbidden = [
            "approval", "tool", "provider", "workflow", "filesystem",
            "computer", "terminal", "prompt", "reasoning", "credential",
        ]
        for word in forbidden {
            #expect(!descriptor.lowercased().contains(word))
        }

        var frame = Kaname_Link_V1_ClientFrame()
        frame.schemaVersion.major = 1
        frame.requestID = "request-synthetic-01"
        frame.sync.spaceID = "space-synthetic-01"
        frame.sync.limit = 50
        let roundTrip = try Kaname_Link_V1_ClientFrame(
            serializedBytes: frame.serializedData()
        )
        #expect(roundTrip.payload == .sync(frame.sync))
    }

    @Test("receipt states distinguish transport from work completion")
    func receiptSemanticsRemainDistinct() {
        #expect(Kaname_Link_V1_ReceiptState.sentToHost != .receivedByHost)
        #expect(Kaname_Link_V1_ReceiptState.receivedByHost != .publishedResult)
        #expect(Kaname_Link_V1_ReceiptState.seen != .publishedResult)
    }
}
