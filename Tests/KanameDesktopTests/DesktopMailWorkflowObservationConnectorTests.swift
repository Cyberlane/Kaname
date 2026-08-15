import CryptoKit
import Foundation
import KanameConnectivity
import KanameProtocol
import KanameWorkflowHost
import Testing

@Suite("Durable mail connector observation")
struct DesktopMailWorkflowObservationConnectorTests {
    @Test("restart resumes the same read and terminal replay never calls the provider again")
    func restartAndTerminalReplay() async throws {
        let transport = ObservationTransport()
        let adapter = MetadataAdapter()
        let connector = DesktopMailWorkflowObservationConnector(
            transport: transport, adapter: adapter
        )
        let first = try await connector.observe(
            scope(), startedAtUnixMillis: 2_000, requestID: "observation:first"
        )
        #expect(first.status == "succeeded")
        #expect(first.settlement.receipt.observedFields == [
            "headers.date", "headers.from", "labels", "metadata",
        ])
        #expect(await adapter.readCount == 1)

        let second = try await connector.observe(
            scope(), startedAtUnixMillis: 2_000, requestID: "observation:restart"
        )
        #expect(second.duplicate)
        #expect(second.status == "succeeded")
        #expect(second.settlement == first.settlement)
        #expect(await adapter.readCount == 1)
        #expect(await transport.settlementCount == 1)
    }

    @Test("provider failure journals a typed failure without body or attachment data")
    func boundedFailure() async throws {
        let transport = ObservationTransport()
        let adapter = MetadataAdapter(fails: true)
        let connector = DesktopMailWorkflowObservationConnector(
            transport: transport, adapter: adapter
        )
        await #expect(throws: DesktopMailWorkflowObservationError.providerReadFailed) {
            try await connector.observe(
                scope(), startedAtUnixMillis: 2_000, requestID: "observation:failed"
            )
        }
        let settlement = try #require(await transport.latestSettlement)
        #expect(settlement.outcome == .failed)
        #expect(settlement.errorCode == "connector.read.failed")
        #expect(!settlement.hasOutput)
        #expect(!settlement.hasReceipt)
        let wire = String(decoding: try settlement.serializedData(), as: UTF8.self).lowercased()
        #expect(!wire.contains("message body"))
        #expect(!wire.contains("attachment-name"))
    }

    private func scope() -> DesktopMailWorkflowObservationScope {
        DesktopMailWorkflowObservationScope(
            runID: "run-mail-observation",
            runTokenID: "token-mail-observation",
            observationID: "observation-mail-thread",
            accountBindingID: "binding-mail-private",
            bindingID: "binding-installation-mail-private",
            connectorVersion: "1.0.0",
            installationDigest: String(repeating: "8", count: 64),
            accountID: "account-private",
            conversationID: "conversation-private",
            selectedHeaders: ["From", "Date"]
        )
    }
}

private actor ObservationTransport: DesktopWorkflowConnectorObservationTransport {
    private var started: Kaname_V1_WorkflowConnectorObservationStarted?
    private var settlement: Kaname_V1_WorkflowConnectorObservationSettled?
    private(set) var settlementCount = 0

    var latestSettlement: Kaname_V1_WorkflowConnectorObservationSettled? { settlement }

    func beginWorkflowConnectorObservation(
        _ request: Kaname_V1_BeginWorkflowConnectorObservationRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_BeginWorkflowConnectorObservationResponse {
        if started == nil {
            var admitted = Kaname_V1_WorkflowConnectorObservationStarted()
            admitted.intent = request.intent
            admitted.registration = request.registration
            admitted.intentDigest = Self.sha256(try request.intent.serializedData())
            admitted.deadlineUnixMillis = request.startedAtUnixMillis + 60_000
            started = admitted
        }
        var response = Kaname_V1_BeginWorkflowConnectorObservationResponse()
        response.schemaVersion = request.schemaVersion
        response.requestID = request.requestID
        response.started = started!
        response.duplicate = settlement != nil
        response.status = settlement == nil ? "started" : "succeeded"
        response.storePosition = settlement == nil ? 2 : 3
        if let settlement { response.settlement = settlement }
        return response
    }

    func settleWorkflowConnectorObservation(
        _ request: Kaname_V1_SettleWorkflowConnectorObservationRequest,
        timeout _: TimeInterval
    ) async throws -> Kaname_V1_SettleWorkflowConnectorObservationResponse {
        settlementCount += 1
        settlement = request.settlement
        var response = Kaname_V1_SettleWorkflowConnectorObservationResponse()
        response.schemaVersion = request.schemaVersion
        response.requestID = request.requestID
        response.settlement = request.settlement
        response.status = request.settlement.outcome == .succeeded ? "succeeded" : "failed"
        response.storePosition = 3
        return response
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor MetadataAdapter: MailProviderMetadataAdapter {
    nonisolated let identity = MailProviderIdentity(
        id: "synthetic.mail", kind: "mail", displayName: "Synthetic mail"
    )
    private let fails: Bool
    private(set) var readCount = 0

    init(fails: Bool = false) { self.fails = fails }

    func conversationMetadata(
        accountID: String,
        conversationID: String,
        selectedHeaders: [String]
    ) async throws -> MailConversationMetadataSnapshot {
        readCount += 1
        if fails { throw FixtureError.failed }
        return MailConversationMetadataSnapshot(
            id: conversationID,
            account: MailAccountIdentity(providerID: identity.id, localID: accountID),
            cursor: "cursor-private",
            messages: [.init(
                id: "message-private",
                conversationID: conversationID,
                headers: Dictionary(uniqueKeysWithValues: selectedHeaders.map { ($0, "fixture") }),
                resourceIDs: ["INBOX"]
            )]
        )
    }

    private enum FixtureError: Error { case failed }
}
