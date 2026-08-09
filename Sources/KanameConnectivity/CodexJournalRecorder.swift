import Foundation
import KanameDomain
import KanameLocalCore
import KanameProtocol
import SwiftProtobuf

/// Stable Kaname identities are supplied by the control plane. Native Codex
/// IDs are retained only as provider metadata, never used as product identity.
public struct CodexJournalContext: Equatable, Sendable {
    public let projectID: KanameID
    public let threadID: KanameID
    public let runID: KanameID
    public let providerInstance: ProviderInstance

    public init(
        projectID: KanameID,
        threadID: KanameID,
        runID: KanameID,
        providerInstance: ProviderInstance
    ) {
        self.projectID = projectID
        self.threadID = threadID
        self.runID = runID
        self.providerInstance = providerInstance
    }

    var streamID: String {
        "thread:project:\(projectID.rawValue):\(threadID.rawValue)"
    }
}

/// The local control service, rather than the provider process or UI, assigns
/// store and stream ordering. Retry keeps the same ordinal until receipt.
public actor CodexJournalRecorder {
    private let runner: LocalCoreRunner
    private let context: CodexJournalContext
    private var nextOrdinal: UInt64 = 1

    public init(runner: LocalCoreRunner, context: CodexJournalContext) {
        self.runner = runner
        self.context = context
    }

    public func record(
        _ observation: CodexRunEvent,
        occurredAt: Date = Date()
    ) async throws -> LocalCoreEventAppendReport {
        let event = observation.journalEnvelope(
            context: context,
            ordinal: nextOrdinal,
            occurredAt: occurredAt
        )
        let receipt = try await runner.appendEventWire(event.serializedData())
        nextOrdinal += 1
        return receipt
    }
}

private struct CodexJournalMetadata: Codable, Equatable, Sendable {
    let nativeKind: String
    let nativeType: String
    let nativeThreadID: String?
    let nativeTurnID: String?
    let approvalID: String?
    let textByteCount: Int
    let rawPayloadByteCount: Int
    let payloadWasTruncated: Bool
}

extension CodexRunEvent {
    func journalEnvelope(
        context: CodexJournalContext,
        ordinal: UInt64,
        occurredAt: Date
    ) -> Kaname_V1_EventEnvelope {
        let metadata = CodexJournalMetadata(
            nativeKind: kind.rawValue,
            nativeType: nativeType,
            nativeThreadID: threadID,
            nativeTurnID: turnID,
            approvalID: approvalID,
            textByteCount: text?.lengthOfBytes(using: .utf8) ?? 0,
            rawPayloadByteCount: payload?.count ?? 0,
            payloadWasTruncated: payloadWasTruncated
        )
        let metadataData = (try? JSONEncoder().encode(metadata)) ?? Data()

        var envelope = Kaname_V1_EventEnvelope()
        var schemaVersion = Kaname_V1_SchemaVersion()
        schemaVersion.major = 1
        schemaVersion.minor = 0
        envelope.schemaVersion = schemaVersion
        envelope.eventID = "codex-\(context.runID.rawValue)-\(ordinal)"
        envelope.streamID = context.streamID
        envelope.occurredAtUnixMillis = Int64((occurredAt.timeIntervalSince1970 * 1_000).rounded())
        envelope.kind = journalKind
        var payload = Kaname_V1_OpaqueTypedPayload()
        payload.typeURL = "kaname.codex.redacted-observation.v1"
        payload.contentType = "application/json"
        payload.value = metadataData
        payload.payloadVersion = 1
        envelope.payload = payload
        var provenance = Kaname_V1_EventProvenance()
        provenance.sourceKind = "provider"
        provenance.providerInstanceID = context.providerInstance.id.rawValue
        provenance.nativeType = nativeType
        provenance.retentionClass = .none
        envelope.provenance = provenance
        envelope.causationID = approvalID ?? ""
        envelope.correlationID = context.runID.rawValue
        return envelope
    }

    private var journalKind: String {
        switch kind {
        case .runStarted: "run.started"
        case .providerCompleted: "run.provider_completed"
        case .runFailed: "run.failed"
        case .runInterrupted: "run.interrupted"
        case .approvalRequested: "approval.requested"
        case .approvalAccepted: "approval.approved"
        case .approvalRejected: "approval.rejected"
        case .questionRequested: "question.requested"
        case .questionAnswered: "question.answered"
        case .sessionStarted, .messageDelta, .itemStarted, .itemCompleted, .planUpdated, .toolActivity, .diffUpdated, .nativeProviderEvent:
            "provider.native_event_observed"
        }
    }
}
