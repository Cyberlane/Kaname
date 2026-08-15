import Foundation
import KanameLocalCore
import KanameProtocol

public protocol DesktopWorkflowRunInspectionTransport: Sendable {
    func inspectWorkflowRuns(
        _ request: Kaname_V1_WorkflowRunInspectionQuery,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_WorkflowRunInspectionResponse
}

public protocol DesktopWorkflowRunPurgeTransport: Sendable {
    func purgeWorkflowRun(
        _ request: Kaname_V1_PurgeWorkflowRunRequest,
        timeout: TimeInterval
    ) async throws -> Kaname_V1_PurgeWorkflowRunResponse
}

extension LocalCoreRunner: DesktopWorkflowRunInspectionTransport {}
extension LocalCoreRunner: DesktopWorkflowRunPurgeTransport {}

public enum DesktopWorkflowRunInspectionError: Error, Equatable, Sendable {
    case invalidRequest
    case malformedResponse
}

public struct DesktopWorkflowProjectedValue: Equatable, Sendable {
    public let id: String
    public let contentType: String
    public let byteCount: UInt64
    public let sha256: String
    public let inlineCanonicalJSON: Data?
    public let storageReferenceID: String?
    public let availability: String
    public let storage: DesktopWorkflowStorageValueMetadata?

    public var absenceExplanation: String? {
        guard inlineCanonicalJSON == nil else { return nil }
        if availability == "scoped_handle" {
            return "The value is retained behind an opaque scoped handle. Its host storage path is never exposed."
        }
        return availability == "storage_unavailable"
            ? "The value metadata is retained, but its stored content is not available in this history view."
            : "The value content was not retained."
    }
}

public struct DesktopWorkflowStorageValueMetadata: Equatable, Sendable {
    public let handleID: String?
    public let scope: String
    public let logicalKey: String
    public let versionID: String?
    public let revision: UInt64?
    public let previousVersionID: String?
    public let sourceVersionID: String?
    public let byteCount: UInt64
    public let result: String
}

public struct DesktopWorkflowProjectedAttempt: Identifiable, Equatable, Sendable {
    public let id: String
    public let nodeID: String
    public let number: UInt32
    public let status: String
    public let outcome: String?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let emissionIDs: [String]
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let startedStorePosition: UInt64
    public let settledStorePosition: UInt64?
    public let executionTokenID: String?

    public init(
        id: String, nodeID: String, number: UInt32, status: String, outcome: String?,
        errorCode: String?, error: DesktopWorkflowProjectedValue?, emissionIDs: [String],
        startedAtUnixMillis: Int64, settledAtUnixMillis: Int64?,
        startedStorePosition: UInt64, settledStorePosition: UInt64?,
        executionTokenID: String? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.number = number
        self.status = status
        self.outcome = outcome
        self.errorCode = errorCode
        self.error = error
        self.emissionIDs = emissionIDs
        self.startedAtUnixMillis = startedAtUnixMillis
        self.settledAtUnixMillis = settledAtUnixMillis
        self.startedStorePosition = startedStorePosition
        self.settledStorePosition = settledStorePosition
        self.executionTokenID = executionTokenID
    }
}

public struct DesktopWorkflowProjectedNode: Identifiable, Equatable, Sendable {
    public var id: String { nodeID }
    public let nodeID: String
    public let status: String
    public let latestAttemptID: String
    public let latestAttemptNumber: UInt32
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let lastStorePosition: UInt64
}

public struct DesktopWorkflowProjectedEmission: Identifiable, Equatable, Sendable {
    public let id: String
    public let attemptID: String
    public let nodeID: String
    public let portID: String
    public let value: DesktopWorkflowProjectedValue
    public let eventID: String
    public let emittedAtUnixMillis: Int64
    public let storePosition: UInt64
    public let executionTokenID: String?

    public init(
        id: String, attemptID: String, nodeID: String, portID: String,
        value: DesktopWorkflowProjectedValue, eventID: String,
        emittedAtUnixMillis: Int64, storePosition: UInt64,
        executionTokenID: String? = nil
    ) {
        self.id = id
        self.attemptID = attemptID
        self.nodeID = nodeID
        self.portID = portID
        self.value = value
        self.eventID = eventID
        self.emittedAtUnixMillis = emittedAtUnixMillis
        self.storePosition = storePosition
        self.executionTokenID = executionTokenID
    }
}

public struct DesktopWorkflowProjectedEdge: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let edgeID: String
    public let emissionID: String
    public let targetNodeID: String
    public let targetPortID: String
    public let state: String
    public let checkpointedAtUnixMillis: Int64
    public let storePosition: UInt64
    public let executionTokenID: String?

    public init(
        eventID: String, edgeID: String, emissionID: String, targetNodeID: String,
        targetPortID: String, state: String, checkpointedAtUnixMillis: Int64,
        storePosition: UInt64, executionTokenID: String? = nil
    ) {
        self.eventID = eventID
        self.edgeID = edgeID
        self.emissionID = emissionID
        self.targetNodeID = targetNodeID
        self.targetPortID = targetPortID
        self.state = state
        self.checkpointedAtUnixMillis = checkpointedAtUnixMillis
        self.storePosition = storePosition
        self.executionTokenID = executionTokenID
    }
}

public struct DesktopWorkflowProjectedExecutionToken: Identifiable, Equatable, Sendable {
    public var id: String { executionTokenID }
    public let executionTokenID: String
    public let parentExecutionTokenID: String?
    public let forkNodeID: String?
    public let branchID: String?
    public let branchPortID: String?
    public let joinNodeID: String?
    public let sourceEmissionID: String?
    public let status: String
    public let outcome: String?
    public let terminalNodeID: String?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let finalEmissionIDs: [String]
    public let createdStorePosition: UInt64
    public let settledStorePosition: UInt64?
    public let iterationNodeID: String?
    public let iterationIndex: UInt32?
    public let iterationCount: UInt32?
    public let resumeNodeID: String?
    public let resumeReason: String?
}

public struct DesktopWorkflowProjectedJoin: Identifiable, Equatable, Sendable {
    public var id: String { "\(forkNodeID):\(joinNodeID)" }
    public let joinNodeID: String
    public let forkNodeID: String
    public let resumedExecutionTokenID: String
    public let policy: String
    public let threshold: UInt32
    public let decision: String
    public let expectedExecutionTokenIDs: [String]
    public let arrivedExecutionTokenIDs: [String]
    public let failedExecutionTokenIDs: [String]
    public let pendingExecutionTokenIDs: [String]
    public let cancelRemaining: Bool
    public let errorCode: String?
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedIteration: Identifiable, Equatable, Sendable {
    public var id: String { "\(iterationNodeID):\(parentExecutionTokenID)" }
    public let iterationNodeID: String
    public let parentExecutionTokenID: String
    public let controllerAttemptID: String
    public let inputValueID: String
    public let inputSHA256: String
    public let itemCount: UInt32
    public let maximumItems: UInt32
    public let maximumConcurrency: UInt32
    public let failurePolicy: String
    public let decision: String?
    public let resumedExecutionTokenID: String?
    public let expectedExecutionTokenIDs: [String]
    public let succeededExecutionTokenIDs: [String]
    public let failedExecutionTokenIDs: [String]
    public let pendingExecutionTokenIDs: [String]
    public let errorCode: String?
    public let output: DesktopWorkflowProjectedValue?
    public let plannedStorePosition: UInt64
    public let evaluatedStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedRetry: Identifiable, Equatable, Sendable {
    public var id: String { controllerAttemptID }
    public let retryNodeID: String
    public let executionTokenID: String
    public let controllerAttemptID: String
    public let failedAttemptID: String
    public let targetNodeID: String
    public let errorCode: String
    public let decision: String
    public let nextAttemptNumber: UInt32
    public let maximumAttempts: UInt32
    public let delayMilliseconds: UInt64
    public let eligibleAtUnixMillis: Int64?
    public let retryInput: DesktopWorkflowProjectedValue
    public let error: DesktopWorkflowProjectedValue
    public let storePosition: UInt64
}

public struct DesktopWorkflowWaitCorrelation: Equatable, Sendable {
    public let key: String
    public let sha256: String
}

public struct DesktopWorkflowProjectedWait: Identifiable, Equatable, Sendable {
    public var id: String { subscriptionID }
    public let subscriptionID: String
    public let waitNodeID: String
    public let executionTokenID: String
    public let controllerAttemptID: String
    public let workflowID: String
    public let revisionID: String
    public let packageDigest: String
    public let kind: String
    public let ownerKind: String
    public let ownerID: String
    public let correlation: [DesktopWorkflowWaitCorrelation]
    public let inputValueID: String
    public let inputSHA256: String
    public let status: String
    public let decision: String?
    public let resolvingSignalID: String?
    public let output: DesktopWorkflowProjectedValue?
    public let reasonCode: String?
    public let expiresAtUnixMillis: Int64
    public let subscribedStorePosition: UInt64
    public let resolvedStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedWaitSignal: Identifiable, Equatable, Sendable {
    public var id: String { signalID }
    public let signalID: String
    public let signalCommandID: String
    public let kind: String
    public let ownerKind: String
    public let ownerID: String
    public let correlation: [DesktopWorkflowWaitCorrelation]
    public let value: DesktopWorkflowProjectedValue
    public let recordedAtUnixMillis: Int64
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedInputBinding: Equatable, Sendable {
    public let portID: String
    public let value: DesktopWorkflowProjectedValue
}

public struct DesktopWorkflowProjectedCaseEpisode: Identifiable, Equatable, Sendable {
    public var id: String { episodeID }
    public let installationID: String
    public let caseID: String
    public let episodeID: String
    public let ordinal: UInt32
    public let kind: String
    public let priorEpisodeID: String?
    public let triggerKind: String
    public let triggerEventID: String?
    public let inputs: [DesktopWorkflowProjectedInputBinding]
    public let compiledContext: DesktopWorkflowProjectedValue
    public let sourceEpisodeIDs: [String]
    public let sourceEventIDs: [String]
    public let startedStorePosition: UInt64
}

public struct DesktopWorkflowProjectedSubflow: Identifiable, Equatable, Sendable {
    public var id: String { invocationID }
    public let invocationID: String
    public let attemptID: String
    public let executionTokenID: String
    public let nodeID: String
    public let childRunID: String
    public let childWorkflowID: String
    public let childRevisionID: String
    public let childPackageID: String
    public let childPackageDigest: String
    public let entrypoint: String
    public let input: DesktopWorkflowProjectedValue
    public let status: String
    public let outcome: String?
    public let output: DesktopWorkflowProjectedValue?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let childFinalEmissionIDs: [String]
    public let childCommandID: String
    public let calledAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let calledStorePosition: UInt64
    public let settledStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedCapabilityLog: Identifiable, Equatable, Sendable {
    public var id: UInt32 { sequence }
    public let sequence: UInt32
    public let level: String
    public let message: String
    public let offsetMilliseconds: UInt64
}

public struct DesktopWorkflowProjectedCapabilityArtifact: Identifiable, Equatable, Sendable {
    public var id: String { handleID }
    public let handleID: String
    public let role: String
    public let value: DesktopWorkflowProjectedValue
}

public struct DesktopWorkflowProjectedCapabilityAttempt: Identifiable, Equatable, Sendable {
    public var id: String { invocationID }
    public let invocationID: String
    public let attemptID: String
    public let executionTokenID: String
    public let nodeID: String
    public let capabilityID: String
    public let version: String
    public let packageDigest: String
    public let configurationContractDigest: String
    public let inputSchemaDigest: String
    public let outputSchemaDigest: String
    public let outputSchemaRef: String
    public let configuration: DesktopWorkflowProjectedValue
    public let input: DesktopWorkflowProjectedValue
    public let artifactInputs: [DesktopWorkflowProjectedCapabilityArtifact]
    public let status: String
    public let outcome: String?
    public let output: DesktopWorkflowProjectedValue?
    public let artifactOutputs: [DesktopWorkflowProjectedCapabilityArtifact]
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let logs: [DesktopWorkflowProjectedCapabilityLog]
    public let timeoutMilliseconds: UInt64
    public let deadlineUnixMillis: Int64
    public let elapsedMilliseconds: UInt64?
    public let receiptID: String?
    public let providerRunReference: String?
    public let idempotencyKey: String?
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let startedStorePosition: UInt64
    public let settledStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedLlmSettings: Equatable, Sendable {
    public let modelClass: String
    public let providerID: String
    public let modelID: String
    public let modelRevision: String
    public let reasoningEffort: String
    public let temperatureMilli: UInt32
    public let maximumContextBytes: UInt64
    public let maximumOutputTokens: UInt32
    public let conversationScope: String
}

public struct DesktopWorkflowProjectedLlmContextGroup: Identifiable, Equatable, Sendable {
    public var id: String { groupID }
    public let groupID: String
    public let kind: String
    public let title: String
    public let provenance: String
    public let content: DesktopWorkflowProjectedValue
    public let originalByteCount: UInt64
    public let retainedByteCount: UInt64
    public let redactionCount: UInt32
    public let truncated: Bool
    public let sourceEpisodeIDs: [String]
}

public struct DesktopWorkflowProjectedLlmMessage: Identifiable, Equatable, Sendable {
    public var id: String { messageID }
    public let messageID: String
    public let sequence: UInt32
    public let role: String
    public let contextGroupID: String
    public let summary: String
    public let content: DesktopWorkflowProjectedValue
    public let estimatedTokens: UInt64
    public let redactionCount: UInt32
    public let truncated: Bool
}

public struct DesktopWorkflowProjectedLlmCompilationReport: Equatable, Sendable {
    public let originalGroupCount: UInt32
    public let retainedGroupCount: UInt32
    public let originalByteCount: UInt64
    public let retainedByteCount: UInt64
    public let redactionCount: UInt32
    public let truncatedGroupIDs: [String]
    public let droppedGroupIDs: [String]
    public let redactionReasons: [String]
}

public struct DesktopWorkflowProjectedLlmToolDefinition: Identifiable, Equatable, Sendable {
    public var id: String { toolID }
    public let toolID: String
    public let version: String
    public let packageDigest: String
    public let description: String
    public let inputSchemaRef: String
    public let inputSchemaDigest: String
    public let outputSchemaRef: String
    public let outputSchemaDigest: String
}

public struct DesktopWorkflowProjectedLlmToolCall: Identifiable, Equatable, Sendable {
    public var id: String { callID }
    public let callID: String
    public let sequence: UInt32
    public let toolID: String
    public let status: String
    public let input: DesktopWorkflowProjectedValue
    public let output: DesktopWorkflowProjectedValue?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let durationMilliseconds: UInt64
}

public struct DesktopWorkflowProjectedLlmResponseMessage: Identifiable, Equatable, Sendable {
    public var id: String { messageID }
    public let messageID: String
    public let sequence: UInt32
    public let role: String
    public let kind: String
    public let summary: String
    public let content: DesktopWorkflowProjectedValue
    public let toolCallID: String?
}

public struct DesktopWorkflowProjectedLlmUsage: Equatable, Sendable {
    public let inputTokens: UInt64
    public let cachedInputTokens: UInt64
    public let outputTokens: UInt64
    public let reasoningTokens: UInt64
    public let totalTokens: UInt64
    public let toolCallCount: UInt32
    public let costCurrency: String?
    public let inputCostMicros: UInt64
    public let outputCostMicros: UInt64
    public let reasoningCostMicros: UInt64
    public let toolCostMicros: UInt64
    public let totalCostMicros: UInt64
}

public struct DesktopWorkflowProjectedLlmResponseValidation: Equatable, Sendable {
    public let status: String
    public let schemaRef: String
    public let schemaDigest: String
    public let diagnostics: [String]
    public let diagnosticsTruncated: Bool
}

public struct DesktopWorkflowProjectedLlmProviderReceipt: Equatable, Sendable {
    public let requestID: String
    public let responseID: String
    public let receiptID: String
    public let providerRunReference: String?
    public let metadataDigest: String
}

public enum DesktopWorkflowLlmInspectionLayout: Equatable, Sendable {
    case compact
    case wide
}

public enum DesktopWorkflowLlmInspectionPresentation {
    public static let compactWidthThreshold = 1_050.0

    public static func layout(for width: Double) -> DesktopWorkflowLlmInspectionLayout {
        width < compactWidthThreshold ? .compact : .wide
    }

    public static func isGroupExpanded(
        groupID: String,
        explicitlyExpandedGroupIDs: Set<String>,
        searchText: String
    ) -> Bool {
        !searchText.isEmpty || explicitlyExpandedGroupIDs.contains(groupID)
    }

    public static func includes(searchText: String, fields: [String]) -> Bool {
        searchText.isEmpty
            || fields.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
    }

    public static func structuredText(_ value: DesktopWorkflowProjectedValue) -> String {
        value.inlineCanonicalJSON.map { String(decoding: $0, as: UTF8.self) }
            ?? value.absenceExplanation
            ?? "Value content unavailable."
    }
}

public struct DesktopWorkflowProjectedLlmAttempt: Identifiable, Equatable, Sendable {
    public var id: String { invocationID }
    public let invocationID: String
    public let attemptID: String
    public let executionTokenID: String
    public let nodeID: String
    public let settings: DesktopWorkflowProjectedLlmSettings
    public let contextDigest: String
    public let contextGroups: [DesktopWorkflowProjectedLlmContextGroup]
    public let messages: [DesktopWorkflowProjectedLlmMessage]
    public let priorEpisodeIDs: [String]
    public let attachments: [DesktopWorkflowProjectedCapabilityArtifact]
    public let compilationReport: DesktopWorkflowProjectedLlmCompilationReport
    public let outputSchemaRef: String
    public let outputSchemaDigest: String
    public let input: DesktopWorkflowProjectedValue
    public let status: String
    public let outcome: String?
    public let output: DesktopWorkflowProjectedValue?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let timeoutMilliseconds: UInt64
    public let deadlineUnixMillis: Int64
    public let elapsedMilliseconds: UInt64?
    public let receiptID: String?
    public let providerRunReference: String?
    public let idempotencyKey: String?
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let startedStorePosition: UInt64
    public let settledStorePosition: UInt64?
    public let toolDefinitions: [DesktopWorkflowProjectedLlmToolDefinition]
    public let toolCalls: [DesktopWorkflowProjectedLlmToolCall]
    public let responseMessages: [DesktopWorkflowProjectedLlmResponseMessage]
    public let usage: DesktopWorkflowProjectedLlmUsage?
    public let validation: DesktopWorkflowProjectedLlmResponseValidation?
    public let providerReceipt: DesktopWorkflowProjectedLlmProviderReceipt?
}

public struct DesktopWorkflowProjectedMatchTrace: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let attemptID: String
    public let nodeID: String
    public let inputValueID: String
    public let evaluatedCaseIDs: [String]
    public let matchedCaseIDs: [String]
    public let emittedPortIDs: [String]
    public let trace: DesktopWorkflowProjectedValue
    public let recordedAtUnixMillis: Int64
    public let storePosition: UInt64
}

public struct DesktopWorkflowProjectedEvent: Identifiable, Equatable, Sendable {
    public var id: String { eventID }
    public let eventID: String
    public let kind: String
    public let storePosition: UInt64
    public let streamSequence: UInt64
    public let occurredAtUnixMillis: Int64
}

public struct DesktopWorkflowRunRetentionPolicy: Equatable, Sendable {
    public let mode: String
    public let days: UInt32?

    public init(mode: String, days: UInt32?) {
        self.mode = mode
        self.days = days
    }

    public var summary: String {
        switch mode {
        case "duration": "Keep for \(days ?? 30) days"
        case "delete-after-success": "Delete after success"
        case "forever": "Keep forever"
        default: mode
        }
    }
}

public struct DesktopWorkflowRunPurgePreview: Equatable, Sendable {
    public let manualEligible: Bool
    public let automaticEligible: Bool
    public let protectedReason: String?
    public let automaticEligibleAtUnixMillis: Int64?
    public let affectedAttemptIDs: [String]
    public let affectedValueIDs: [String]
    public let affectedFileHandleIDs: [String]
    public let retainedPromotedHandleIDs: [String]
    public let affectedValueBytes: UInt64
    public let affectedEffectIDs: [String]
    public let evidenceDigest: String

    public init(
        manualEligible: Bool,
        automaticEligible: Bool,
        protectedReason: String?,
        automaticEligibleAtUnixMillis: Int64?,
        affectedAttemptIDs: [String],
        affectedValueIDs: [String],
        affectedFileHandleIDs: [String],
        retainedPromotedHandleIDs: [String],
        affectedValueBytes: UInt64,
        affectedEffectIDs: [String],
        evidenceDigest: String
    ) {
        self.manualEligible = manualEligible
        self.automaticEligible = automaticEligible
        self.protectedReason = protectedReason
        self.automaticEligibleAtUnixMillis = automaticEligibleAtUnixMillis
        self.affectedAttemptIDs = affectedAttemptIDs
        self.affectedValueIDs = affectedValueIDs
        self.affectedFileHandleIDs = affectedFileHandleIDs
        self.retainedPromotedHandleIDs = retainedPromotedHandleIDs
        self.affectedValueBytes = affectedValueBytes
        self.affectedEffectIDs = affectedEffectIDs
        self.evidenceDigest = evidenceDigest
    }
}

public struct DesktopWorkflowProjectedEffectAuthority: Identifiable, Equatable, Sendable {
    public var id: String { effectID }
    public let effectID: String
    public let nodeID: String
    public let connectorClass: String
    public let action: String
    public let accountBindingID: String
    public let destinationFingerprint: String
    public let inputDigest: String
    public let intentDigest: String
    public let previewDigest: String
    public let idempotencyKey: String
    public let approvalID: String
    public let approvalFingerprint: Data
    public let status: String
    public let consequence: String
    public let reversible: Bool
    public let expiresAtUnixMillis: Int64
    public let grantID: String?
    public let actorID: String?
    public let deviceID: String?
    public let proposedAtUnixMillis: Int64
    public let authorizedAtUnixMillis: Int64?
    public let proposedStorePosition: UInt64
    public let authorizedStorePosition: UInt64?
    public let dispatch: DesktopWorkflowProjectedEffectDispatch?
    public let reconciliation: DesktopWorkflowProjectedEffectReconciliation?
}

public struct DesktopWorkflowProjectedEffectConnectorRegistration: Equatable, Sendable {
    public let connectorClass: String
    public let version: String
    public let packageDigest: String
    public let bindingID: String
    public let accountBindingID: String
    public let allowedActions: [String]
    public let registrationDigest: String
}

public struct DesktopWorkflowProjectedEffectReceipt: Equatable, Sendable {
    public let receiptID: String
    public let providerReference: String?
    public let outcome: String
    public let evidenceDigest: String
}

public struct DesktopWorkflowProjectedEffectDispatch: Equatable, Sendable {
    public let dispatchID: String
    public let registration: DesktopWorkflowProjectedEffectConnectorRegistration
    public let deadlineUnixMillis: Int64
    public let outcome: String?
    public let errorCode: String?
    public let receipt: DesktopWorkflowProjectedEffectReceipt?
    public let elapsedMilliseconds: UInt64?
    public let startedAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let startedStorePosition: UInt64
    public let settledStorePosition: UInt64?
}

public struct DesktopWorkflowProjectedEffectReconciliation: Equatable, Sendable {
    public let reconciliationID: String
    public let outcome: String
    public let errorCode: String?
    public let receipt: DesktopWorkflowProjectedEffectReceipt
    public let elapsedMilliseconds: UInt64
    public let reconciledAtUnixMillis: Int64
    public let storePosition: UInt64
    public let observationCount: UInt32
}

public struct DesktopDurableWorkflowRun: Identifiable, Equatable, Sendable {
    public var id: String { runID }
    public let runID: String
    public let workflowID: String
    public let revisionID: String
    public let packageDigest: String
    public let status: String
    public let outcome: String?
    public let errorCode: String?
    public let error: DesktopWorkflowProjectedValue?
    public let createdAtUnixMillis: Int64
    public let settledAtUnixMillis: Int64?
    public let firstStorePosition: UInt64
    public let lastStorePosition: UInt64
    public let attempts: [DesktopWorkflowProjectedAttempt]
    public let nodes: [DesktopWorkflowProjectedNode]
    public let emissions: [DesktopWorkflowProjectedEmission]
    public let edges: [DesktopWorkflowProjectedEdge]
    public let matchTraces: [DesktopWorkflowProjectedMatchTrace]
    public let events: [DesktopWorkflowProjectedEvent]
    public let executionTokens: [DesktopWorkflowProjectedExecutionToken]
    public let joins: [DesktopWorkflowProjectedJoin]
    public let iterations: [DesktopWorkflowProjectedIteration]
    public let retries: [DesktopWorkflowProjectedRetry]
    public let waits: [DesktopWorkflowProjectedWait]
    public let waitSignals: [DesktopWorkflowProjectedWaitSignal]
    public let episode: DesktopWorkflowProjectedCaseEpisode?
    public let subflows: [DesktopWorkflowProjectedSubflow]
    public let capabilityAttempts: [DesktopWorkflowProjectedCapabilityAttempt]
    public let llmAttempts: [DesktopWorkflowProjectedLlmAttempt]
    public let effectAuthorities: [DesktopWorkflowProjectedEffectAuthority]
    public let retentionPolicy: DesktopWorkflowRunRetentionPolicy
    public let purgePreview: DesktopWorkflowRunPurgePreview

    public init(
        runID: String, workflowID: String, revisionID: String, packageDigest: String,
        status: String, outcome: String?, errorCode: String?, error: DesktopWorkflowProjectedValue?,
        createdAtUnixMillis: Int64, settledAtUnixMillis: Int64?, firstStorePosition: UInt64,
        lastStorePosition: UInt64, attempts: [DesktopWorkflowProjectedAttempt],
        nodes: [DesktopWorkflowProjectedNode], emissions: [DesktopWorkflowProjectedEmission],
        edges: [DesktopWorkflowProjectedEdge], matchTraces: [DesktopWorkflowProjectedMatchTrace],
        events: [DesktopWorkflowProjectedEvent],
        executionTokens: [DesktopWorkflowProjectedExecutionToken] = [],
        joins: [DesktopWorkflowProjectedJoin] = [],
        iterations: [DesktopWorkflowProjectedIteration] = [],
        retries: [DesktopWorkflowProjectedRetry] = [],
        waits: [DesktopWorkflowProjectedWait] = [],
        waitSignals: [DesktopWorkflowProjectedWaitSignal] = [],
        episode: DesktopWorkflowProjectedCaseEpisode? = nil,
        subflows: [DesktopWorkflowProjectedSubflow] = [],
        capabilityAttempts: [DesktopWorkflowProjectedCapabilityAttempt] = [],
        llmAttempts: [DesktopWorkflowProjectedLlmAttempt] = [],
        effectAuthorities: [DesktopWorkflowProjectedEffectAuthority] = [],
        retentionPolicy: DesktopWorkflowRunRetentionPolicy = .init(mode: "duration", days: 30),
        purgePreview: DesktopWorkflowRunPurgePreview = .init(
            manualEligible: false, automaticEligible: false, protectedReason: "not_loaded",
            automaticEligibleAtUnixMillis: nil, affectedAttemptIDs: [], affectedValueIDs: [],
            affectedFileHandleIDs: [], retainedPromotedHandleIDs: [], affectedValueBytes: 0,
            affectedEffectIDs: [],
            evidenceDigest: String(repeating: "0", count: 64)
        )
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.revisionID = revisionID
        self.packageDigest = packageDigest
        self.status = status
        self.outcome = outcome
        self.errorCode = errorCode
        self.error = error
        self.createdAtUnixMillis = createdAtUnixMillis
        self.settledAtUnixMillis = settledAtUnixMillis
        self.firstStorePosition = firstStorePosition
        self.lastStorePosition = lastStorePosition
        self.attempts = attempts
        self.nodes = nodes
        self.emissions = emissions
        self.edges = edges
        self.matchTraces = matchTraces
        self.events = events
        self.executionTokens = executionTokens
        self.joins = joins
        self.iterations = iterations
        self.retries = retries
        self.waits = waits
        self.waitSignals = waitSignals
        self.episode = episode
        self.subflows = subflows
        self.capabilityAttempts = capabilityAttempts
        self.llmAttempts = llmAttempts
        self.effectAuthorities = effectAuthorities
        self.retentionPolicy = retentionPolicy
        self.purgePreview = purgePreview
    }

    public func attempt(for nodeID: String) -> DesktopWorkflowProjectedAttempt? {
        attempts.filter { $0.nodeID == nodeID }.max { $0.number < $1.number }
    }

    public func inputs(for nodeID: String) -> [DesktopWorkflowProjectedEmission] {
        let emissionIDs = Set(edges.filter {
            $0.targetNodeID == nodeID && $0.state == "admitted"
        }.map(\.emissionID))
        return emissions.filter { emissionIDs.contains($0.id) }
    }

    public func outputs(for nodeID: String) -> [DesktopWorkflowProjectedEmission] {
        emissions.filter { $0.nodeID == nodeID }
    }

    public func traces(for nodeID: String) -> [DesktopWorkflowProjectedMatchTrace] {
        matchTraces.filter { $0.nodeID == nodeID }
    }

    public func capabilities(for nodeID: String) -> [DesktopWorkflowProjectedCapabilityAttempt] {
        capabilityAttempts.filter { $0.nodeID == nodeID }
    }

    public func llmAttempts(for nodeID: String) -> [DesktopWorkflowProjectedLlmAttempt] {
        llmAttempts.filter { $0.nodeID == nodeID }
    }
}

public struct DesktopWorkflowRunInspectionPage: Equatable, Sendable {
    public let projectionHighWaterMark: UInt64
    public let runs: [DesktopDurableWorkflowRun]
    public let absenceReason: String?
}

public struct DesktopWorkflowHistoricalNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let name: String
    public let type: String
    public let configurationJSON: Data
    public let x: Double
    public let y: Double
}

public struct DesktopWorkflowHistoricalEdge: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceNodeID: String
    public let sourcePortID: String
    public let targetNodeID: String
    public let targetPortID: String
}

public struct DesktopWorkflowHistoricalGraph: Equatable, Sendable {
    public let name: String
    public let nodes: [DesktopWorkflowHistoricalNode]
    public let edges: [DesktopWorkflowHistoricalEdge]
}

public struct DesktopWorkflowRunSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { run.id }
    public let run: DesktopDurableWorkflowRun
    public let revision: DesktopWorkflowV2RevisionContent?
    public let graph: DesktopWorkflowHistoricalGraph?
    public let revisionAbsenceReason: String?
}

public struct DesktopWorkflowRunHistorySnapshot: Equatable, Sendable {
    public let projectionHighWaterMark: UInt64
    public let runs: [DesktopWorkflowRunSnapshot]
    public let absenceReason: String?
}

public struct DesktopWorkflowRunHistoryLoader: Sendable {
    private let inspection: DesktopWorkflowRunInspectionClient
    private let library: DesktopWorkflowV2LibraryClient

    public init(
        inspection: DesktopWorkflowRunInspectionClient,
        library: DesktopWorkflowV2LibraryClient
    ) {
        self.inspection = inspection
        self.library = library
    }

    public func load(limit: UInt32 = 30, requestID: String) async throws -> DesktopWorkflowRunHistorySnapshot {
        let page = try await inspection.runs(limit: limit, requestID: requestID)
        var revisions: [String: DesktopWorkflowV2RevisionContent?] = [:]
        var snapshots: [DesktopWorkflowRunSnapshot] = []
        for (index, run) in page.runs.enumerated() {
            let content: DesktopWorkflowV2RevisionContent?
            if let cached = revisions[run.revisionID] {
                content = cached
            } else {
                content = try? await library.revision(
                    revisionID: run.revisionID,
                    requestID: "\(requestID):revision:\(index)"
                )
                revisions[run.revisionID] = content
            }
            let valid = content.flatMap { revision in
                revision.summary.workflowID == run.workflowID
                    && revision.summary.revisionID == run.revisionID
                    && revision.summary.packageDigest == run.packageDigest ? revision : nil
            }
            snapshots.append(DesktopWorkflowRunSnapshot(
                run: run,
                revision: valid,
                graph: valid.flatMap(Self.historicalGraph),
                revisionAbsenceReason: valid == nil
                    ? "The immutable workflow revision for this run is unavailable or failed its identity check."
                    : nil
            ))
        }
        return DesktopWorkflowRunHistorySnapshot(
            projectionHighWaterMark: page.projectionHighWaterMark,
            runs: snapshots,
            absenceReason: page.absenceReason
        )
    }

    private static func historicalGraph(
        _ revision: DesktopWorkflowV2RevisionContent
    ) -> DesktopWorkflowHistoricalGraph? {
        guard let root = try? JSONSerialization.jsonObject(with: revision.workflowJSON) as? [String: Any],
              let graph = root["graph"] as? [String: Any],
              let rawNodes = graph["nodes"] as? [[String: Any]],
              let rawEdges = graph["edges"] as? [[String: Any]] else { return nil }
        let positions = layoutPositions(revision.layoutJSON)
        let nodes = rawNodes.compactMap { node -> DesktopWorkflowHistoricalNode? in
            guard let id = node["id"] as? String,
                  let type = node["type"] as? String else { return nil }
            let configuration = node["config"] ?? [:]
            guard JSONSerialization.isValidJSONObject(configuration),
                  let configurationJSON = try? JSONSerialization.data(
                    withJSONObject: configuration,
                    options: [.sortedKeys]
                  ) else { return nil }
            let position = positions[id] ?? (Double(nodesFallbackIndex(id, in: rawNodes)) * 280 + 80, 110)
            return DesktopWorkflowHistoricalNode(
                id: id,
                key: node["key"] as? String ?? id,
                name: node["name"] as? String ?? type,
                type: type,
                configurationJSON: configurationJSON,
                x: position.0,
                y: position.1
            )
        }
        let edges = rawEdges.compactMap { edge -> DesktopWorkflowHistoricalEdge? in
            guard let id = edge["id"] as? String,
                  let from = edge["from"] as? [String: Any],
                  let to = edge["to"] as? [String: Any],
                  let sourceNodeID = from["nodeId"] as? String,
                  let sourcePortID = from["portId"] as? String,
                  let targetNodeID = to["nodeId"] as? String,
                  let targetPortID = to["portId"] as? String else { return nil }
            return DesktopWorkflowHistoricalEdge(
                id: id,
                sourceNodeID: sourceNodeID,
                sourcePortID: sourcePortID,
                targetNodeID: targetNodeID,
                targetPortID: targetPortID
            )
        }
        guard nodes.count == rawNodes.count, edges.count == rawEdges.count else { return nil }
        return DesktopWorkflowHistoricalGraph(
            name: root["name"] as? String ?? "Workflow",
            nodes: nodes,
            edges: edges
        )
    }

    private static func layoutPositions(_ data: Data) -> [String: (Double, Double)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let rawNodes: [[String: Any]]
        if let object = root as? [String: Any] {
            rawNodes = object["nodes"] as? [[String: Any]] ?? []
        } else {
            rawNodes = root as? [[String: Any]] ?? []
        }
        return Dictionary(uniqueKeysWithValues: rawNodes.compactMap { node in
            guard let id = (node["nodeId"] ?? node["id"]) as? String,
                  let x = numeric(node["x"]), let y = numeric(node["y"]) else { return nil }
            return (id, (x, y))
        })
    }

    private static func numeric(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func nodesFallbackIndex(_ id: String, in nodes: [[String: Any]]) -> Int {
        nodes.firstIndex { $0["id"] as? String == id } ?? 0
    }
}

public struct DesktopWorkflowRunInspectionClient: Sendable {
    private let transport: any DesktopWorkflowRunInspectionTransport
    private let timeout: TimeInterval

    public init(
        transport: any DesktopWorkflowRunInspectionTransport,
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func runs(
        workflowID: String? = nil,
        runID: String? = nil,
        limit: UInt32 = 30,
        asOfUnixMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        requestID: String
    ) async throws -> DesktopWorkflowRunInspectionPage {
        guard !requestID.isEmpty,
              limit > 0, limit <= 100,
              asOfUnixMillis >= 0,
              workflowID?.count ?? 0 <= 128,
              runID?.count ?? 0 <= 128 else {
            throw DesktopWorkflowRunInspectionError.invalidRequest
        }
        var request = Kaname_V1_WorkflowRunInspectionQuery()
        request.schemaVersion.major = 1
        request.requestID = requestID
        request.workflowID = workflowID ?? ""
        request.runID = runID ?? ""
        request.limit = limit
        request.asOfUnixMillis = asOfUnixMillis
        let response = try await transport.inspectWorkflowRuns(request, timeout: timeout)
        guard response.schemaVersion.major == 1,
              response.requestID == requestID else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowRunInspectionPage(
            projectionHighWaterMark: response.projectionHighWaterMark,
            runs: try response.runs.map(Self.run),
            absenceReason: response.absenceReason.nilIfEmpty
        )
    }

    private static func run(_ run: Kaname_V1_WorkflowProjectedRun) throws -> DesktopDurableWorkflowRun {
        guard !run.runID.isEmpty,
              !run.workflowID.isEmpty,
              !run.revisionID.isEmpty,
              run.packageDigest.count == 64,
              !run.status.isEmpty,
              run.hasRetentionPolicy,
              run.hasPurgePreview,
              run.firstStorePosition > 0,
              run.lastStorePosition >= run.firstStorePosition else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopDurableWorkflowRun(
            runID: run.runID,
            workflowID: run.workflowID,
            revisionID: run.revisionID,
            packageDigest: run.packageDigest,
            status: run.status,
            outcome: run.outcome.nilIfEmpty,
            errorCode: run.errorCode.nilIfEmpty,
            error: try run.hasError ? value(run.error) : nil,
            createdAtUnixMillis: run.createdAtUnixMillis,
            settledAtUnixMillis: run.settledAtUnixMillis > 0 ? run.settledAtUnixMillis : nil,
            firstStorePosition: run.firstStorePosition,
            lastStorePosition: run.lastStorePosition,
            attempts: try run.attempts.map(attempt),
            nodes: try run.nodes.map(node),
            emissions: try run.emissions.map(emission),
            edges: try run.edges.map(edge),
            matchTraces: try run.matchTraces.map(matchTrace),
            events: try run.events.map(event),
            executionTokens: try run.executionTokens.map(executionToken),
            joins: try run.joins.map(join),
            iterations: try run.iterations.map(iteration),
            retries: try run.retries.map(retry),
            waits: try run.waits.map(wait),
            waitSignals: try run.waitSignals.map(waitSignal),
            episode: try run.hasEpisode ? episode(run.episode) : nil,
            subflows: try run.subflows.map(subflow),
            capabilityAttempts: try run.capabilityAttempts.map(capabilityAttempt),
            llmAttempts: try run.llmAttempts.map(llmAttempt),
            effectAuthorities: try run.effectAuthorities.map(effectAuthority),
            retentionPolicy: try retentionPolicy(run.retentionPolicy),
            purgePreview: try purgePreview(run.purgePreview)
        )
    }

    private static func retentionPolicy(
        _ policy: Kaname_V1_WorkflowRunRetentionPolicy
    ) throws -> DesktopWorkflowRunRetentionPolicy {
        switch policy.mode {
        case .duration:
            guard (1...3_650).contains(policy.days) else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return .init(mode: "duration", days: policy.days)
        case .deleteAfterSuccess:
            guard policy.days == 0 else { throw DesktopWorkflowRunInspectionError.malformedResponse }
            return .init(mode: "delete-after-success", days: nil)
        case .forever:
            guard policy.days == 0 else { throw DesktopWorkflowRunInspectionError.malformedResponse }
            return .init(mode: "forever", days: nil)
        default:
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
    }

    private static func effectAuthority(
        _ item: Kaname_V1_WorkflowProjectedEffectAuthority
    ) throws -> DesktopWorkflowProjectedEffectAuthority {
        guard item.hasProposal, item.proposal.hasIntent, item.proposal.hasPreview,
              item.proposal.hasApprovalRequest else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let proposal = item.proposal
        let intent = proposal.intent
        let preview = proposal.preview
        let approval = proposal.approvalRequest
        guard !intent.effectID.isEmpty, !intent.nodeID.isEmpty,
              !intent.connectorClass.isEmpty, !intent.action.isEmpty,
              !intent.accountBindingID.isEmpty, intent.destinationFingerprint.count == 64,
              intent.inputDigest.count == 64, proposal.intentDigest.count == 64,
              preview.previewDigest.count == 64,
              preview.destinationFingerprint == intent.destinationFingerprint,
              !intent.idempotencyKey.isEmpty, !approval.approvalID.isEmpty,
              approval.fingerprint.count == 32, approval.targetID == intent.effectID,
              approval.targetRevision == intent.revisionID,
              approval.expiresAtUnixMillis > item.proposedAtUnixMillis,
              [
                  "proposed", "authorized", "dispatching", "succeeded", "rejected", "not_sent",
                  "outcome_unknown", "reconciled_applied", "reconciled_not_applied",
              ].contains(item.status),
              item.proposedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let authorized = item.status != "proposed"
        guard authorized == item.hasAuthorization,
              authorized == (item.authorizedAtUnixMillis > 0),
              authorized == (item.authorizedStorePosition > 0) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        if authorized {
            let authorization = item.authorization
            guard authorization.effectID == intent.effectID,
                  authorization.intentDigest == proposal.intentDigest,
                  authorization.previewDigest == preview.previewDigest,
                  authorization.destinationFingerprint == intent.destinationFingerprint,
                  authorization.idempotencyKey == intent.idempotencyKey,
                  authorization.approvalFingerprint == approval.fingerprint,
                  authorization.hasResolution,
                  authorization.resolution.approvalID == approval.approvalID,
                  authorization.resolution.expectedFingerprint == approval.fingerprint,
                  authorization.resolution.decision == .approve,
                  !authorization.grantID.isEmpty,
                  !authorization.resolution.actorID.isEmpty,
                  !authorization.resolution.deviceID.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        }
        let dispatch = try effectDispatch(item, proposal: proposal)
        let reconciliation = try effectReconciliation(item, dispatch: dispatch)
        return DesktopWorkflowProjectedEffectAuthority(
            effectID: intent.effectID,
            nodeID: intent.nodeID,
            connectorClass: intent.connectorClass,
            action: intent.action,
            accountBindingID: intent.accountBindingID,
            destinationFingerprint: intent.destinationFingerprint,
            inputDigest: intent.inputDigest,
            intentDigest: proposal.intentDigest,
            previewDigest: preview.previewDigest,
            idempotencyKey: intent.idempotencyKey,
            approvalID: approval.approvalID,
            approvalFingerprint: approval.fingerprint,
            status: item.status,
            consequence: preview.consequence,
            reversible: preview.reversible,
            expiresAtUnixMillis: approval.expiresAtUnixMillis,
            grantID: authorized ? item.authorization.grantID : nil,
            actorID: authorized ? item.authorization.resolution.actorID : nil,
            deviceID: authorized ? item.authorization.resolution.deviceID : nil,
            proposedAtUnixMillis: item.proposedAtUnixMillis,
            authorizedAtUnixMillis: authorized ? item.authorizedAtUnixMillis : nil,
            proposedStorePosition: item.proposedStorePosition,
            authorizedStorePosition: authorized ? item.authorizedStorePosition : nil,
            dispatch: dispatch,
            reconciliation: reconciliation
        )
    }

    private static func effectDispatch(
        _ item: Kaname_V1_WorkflowProjectedEffectAuthority,
        proposal: Kaname_V1_WorkflowEffectProposed
    ) throws -> DesktopWorkflowProjectedEffectDispatch? {
        let requiresDispatch = !["proposed", "authorized"].contains(item.status)
        guard requiresDispatch == item.hasDispatchStarted,
              requiresDispatch == (item.dispatchStartedAtUnixMillis > 0),
              requiresDispatch == (item.dispatchStartedStorePosition > 0) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        guard requiresDispatch else {
            guard !item.hasDispatchSettled, !item.hasReconciliation,
                  item.dispatchSettledAtUnixMillis == 0, item.reconciledAtUnixMillis == 0,
                  item.dispatchSettledStorePosition == 0, item.reconciledStorePosition == 0,
                  item.reconciliationCount == 0 else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return nil
        }
        let intent = proposal.intent
        let authorization = item.authorization
        let started = item.dispatchStarted
        guard started.runID == intent.runID, started.runTokenID == intent.runTokenID,
              started.effectID == intent.effectID, !started.dispatchID.isEmpty,
              started.grantID == authorization.grantID,
              started.intentDigest == proposal.intentDigest,
              started.previewDigest == proposal.preview.previewDigest,
              started.destinationFingerprint == intent.destinationFingerprint,
              started.idempotencyKey == intent.idempotencyKey,
              started.deadlineUnixMillis > item.dispatchStartedAtUnixMillis,
              started.deadlineUnixMillis <= authorization.expiresAtUnixMillis,
              started.hasRegistration else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let registration = started.registration
        guard registration.connectorClass == intent.connectorClass,
              !registration.version.isEmpty, registration.packageDigest.count == 64,
              !registration.bindingID.isEmpty,
              registration.accountBindingID == intent.accountBindingID,
              !registration.allowedActions.isEmpty,
              registration.allowedActions == registration.allowedActions.sorted(),
              Set(registration.allowedActions).count == registration.allowedActions.count,
              registration.allowedActions.contains(intent.action),
              registration.idempotent, registration.supportsReconciliation,
              registration.registrationDigest.count == 64 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settledRequired = ["succeeded", "rejected", "not_sent"].contains(item.status)
        let settledAllowed = !["proposed", "authorized", "dispatching"].contains(item.status)
        guard !settledRequired || item.hasDispatchSettled,
              item.hasDispatchSettled == (item.dispatchSettledAtUnixMillis > 0),
              item.hasDispatchSettled == (item.dispatchSettledStorePosition > 0),
              !item.hasDispatchSettled || settledAllowed else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settled = item.hasDispatchSettled ? item.dispatchSettled : nil
        let receipt = try settled.map { value -> DesktopWorkflowProjectedEffectReceipt in
            guard value.runID == intent.runID, value.runTokenID == intent.runTokenID,
                  value.effectID == intent.effectID, value.dispatchID == started.dispatchID,
                  value.grantID == authorization.grantID,
                  value.idempotencyKey == intent.idempotencyKey, value.hasReceipt else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            let expected: Kaname_V1_WorkflowEffectReceiptOutcome
            switch value.outcome {
            case .succeeded:
                guard item.status == "succeeded", value.errorCode.isEmpty else {
                    throw DesktopWorkflowRunInspectionError.malformedResponse
                }
                expected = .applied
            case .rejected:
                guard item.status == "rejected", !value.errorCode.isEmpty else {
                    throw DesktopWorkflowRunInspectionError.malformedResponse
                }
                expected = .notApplied
            case .notSent:
                guard item.status == "not_sent", !value.errorCode.isEmpty else {
                    throw DesktopWorkflowRunInspectionError.malformedResponse
                }
                expected = .notApplied
            case .unknown:
                guard ["outcome_unknown", "reconciled_applied", "reconciled_not_applied"]
                    .contains(item.status), !value.errorCode.isEmpty else {
                    throw DesktopWorkflowRunInspectionError.malformedResponse
                }
                expected = .unknown
            default:
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return try effectReceipt(value.receipt, expected: expected)
        }
        return .init(
            dispatchID: started.dispatchID,
            registration: .init(
                connectorClass: registration.connectorClass,
                version: registration.version,
                packageDigest: registration.packageDigest,
                bindingID: registration.bindingID,
                accountBindingID: registration.accountBindingID,
                allowedActions: registration.allowedActions,
                registrationDigest: registration.registrationDigest
            ),
            deadlineUnixMillis: started.deadlineUnixMillis,
            outcome: settled.map { String(describing: $0.outcome) },
            errorCode: settled.flatMap { $0.errorCode.isEmpty ? nil : $0.errorCode },
            receipt: receipt,
            elapsedMilliseconds: settled?.elapsedMilliseconds,
            startedAtUnixMillis: item.dispatchStartedAtUnixMillis,
            settledAtUnixMillis: item.hasDispatchSettled ? item.dispatchSettledAtUnixMillis : nil,
            startedStorePosition: item.dispatchStartedStorePosition,
            settledStorePosition: item.hasDispatchSettled ? item.dispatchSettledStorePosition : nil
        )
    }

    private static func effectReconciliation(
        _ item: Kaname_V1_WorkflowProjectedEffectAuthority,
        dispatch: DesktopWorkflowProjectedEffectDispatch?
    ) throws -> DesktopWorkflowProjectedEffectReconciliation? {
        let hasReconciliation = item.hasReconciliation
        guard hasReconciliation == (item.reconciliationCount > 0),
              hasReconciliation == (item.reconciledAtUnixMillis > 0),
              hasReconciliation == (item.reconciledStorePosition > 0),
              ["reconciled_applied", "reconciled_not_applied"].contains(item.status)
                  ? hasReconciliation : true else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        guard hasReconciliation else { return nil }
        guard let dispatch else { throw DesktopWorkflowRunInspectionError.malformedResponse }
        let intent = item.proposal.intent
        let value = item.reconciliation
        guard value.runID == intent.runID, value.runTokenID == intent.runTokenID,
              value.effectID == intent.effectID, value.dispatchID == dispatch.dispatchID,
              !value.reconciliationID.isEmpty,
              value.idempotencyKey == intent.idempotencyKey, value.hasReceipt else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let expected: Kaname_V1_WorkflowEffectReceiptOutcome
        switch value.outcome {
        case .applied:
            guard item.status == "reconciled_applied", value.errorCode.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            expected = .applied
        case .notApplied:
            guard item.status == "reconciled_not_applied", !value.errorCode.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            expected = .notApplied
        case .stillUnknown:
            guard item.status == "outcome_unknown", !value.errorCode.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            expected = .unknown
        default:
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return .init(
            reconciliationID: value.reconciliationID,
            outcome: String(describing: value.outcome),
            errorCode: value.errorCode.isEmpty ? nil : value.errorCode,
            receipt: try effectReceipt(value.receipt, expected: expected),
            elapsedMilliseconds: value.elapsedMilliseconds,
            reconciledAtUnixMillis: item.reconciledAtUnixMillis,
            storePosition: item.reconciledStorePosition,
            observationCount: item.reconciliationCount
        )
    }

    private static func effectReceipt(
        _ value: Kaname_V1_WorkflowEffectReceipt,
        expected: Kaname_V1_WorkflowEffectReceiptOutcome
    ) throws -> DesktopWorkflowProjectedEffectReceipt {
        guard !value.receiptID.isEmpty, value.outcome == expected,
              value.evidenceDigest.count == 64 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return .init(
            receiptID: value.receiptID,
            providerReference: value.providerReference.isEmpty ? nil : value.providerReference,
            outcome: String(describing: value.outcome),
            evidenceDigest: value.evidenceDigest
        )
    }

    private static func purgePreview(
        _ preview: Kaname_V1_WorkflowRunPurgePreview
    ) throws -> DesktopWorkflowRunPurgePreview {
        guard preview.evidenceDigest.count == 64,
              preview.automaticEligibleAtUnixMillis >= 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return .init(
            manualEligible: preview.manualEligible,
            automaticEligible: preview.automaticEligible,
            protectedReason: preview.protectedReason.nilIfEmpty,
            automaticEligibleAtUnixMillis: preview.automaticEligibleAtUnixMillis > 0
                ? preview.automaticEligibleAtUnixMillis : nil,
            affectedAttemptIDs: preview.affectedAttemptIds,
            affectedValueIDs: preview.affectedValueIds,
            affectedFileHandleIDs: preview.affectedFileHandleIds,
            retainedPromotedHandleIDs: preview.retainedPromotedHandleIds,
            affectedValueBytes: preview.affectedValueBytes,
            affectedEffectIDs: preview.affectedEffectIds,
            evidenceDigest: preview.evidenceDigest
        )
    }

    private static func llmAttempt(
        _ item: Kaname_V1_WorkflowProjectedLlmAttempt
    ) throws -> DesktopWorkflowProjectedLlmAttempt {
        guard !item.invocationID.isEmpty, !item.attemptID.isEmpty,
              !item.executionTokenID.isEmpty, !item.nodeID.isEmpty,
              item.hasSettings, item.contextDigest.count == 64,
              !item.contextGroups.isEmpty, !item.messages.isEmpty,
              item.hasCompilationReport, !item.outputSchemaRef.isEmpty,
              item.outputSchemaDigest.count == 64, item.hasInput,
              ["running", "settled"].contains(item.status),
              item.timeoutMilliseconds > 0, item.deadlineUnixMillis >= 0,
              item.startedAtUnixMillis >= 0, item.startedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settings = item.settings
        guard !settings.modelClass.isEmpty, !settings.providerID.isEmpty,
              !settings.modelID.isEmpty, !settings.modelRevision.isEmpty,
              ["minimal", "low", "medium", "high"].contains(settings.reasoningEffort),
              settings.temperatureMilli <= 2_000,
              (256...49_152).contains(settings.maximumContextBytes),
              (1...65_536).contains(settings.maximumOutputTokens),
              ["job", "case"].contains(settings.conversationScope) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settled = item.status == "settled"
        guard settled == !item.outcome.isEmpty,
              settled == (item.settledStorePosition > 0),
              settled == (item.settledAtUnixMillis > 0),
              !settled || [
                "succeeded", "output_validation_failed", "timed_out", "cancelled",
                "malformed_result", "crashed",
              ].contains(item.outcome),
              !settled || item.idempotencyKey == item.invocationID else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        if item.outcome == "succeeded" {
            guard item.hasOutput, item.errorCode.isEmpty, !item.hasError,
                  !item.receiptID.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        } else if settled && item.outcome != "cancelled" {
            guard !item.hasOutput, !item.errorCode.isEmpty, item.hasError,
                  !item.receiptID.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        }
        let groups = try item.contextGroups.map { group in
            guard !group.groupID.isEmpty, !group.kind.isEmpty, !group.title.isEmpty,
                  !group.provenance.isEmpty, group.hasContent,
                  group.originalByteCount >= group.retainedByteCount,
                  group.content.byteCount == group.retainedByteCount else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedLlmContextGroup(
                groupID: group.groupID, kind: group.kind, title: group.title,
                provenance: group.provenance, content: try value(group.content),
                originalByteCount: group.originalByteCount,
                retainedByteCount: group.retainedByteCount,
                redactionCount: group.redactionCount, truncated: group.truncated,
                sourceEpisodeIDs: group.sourceEpisodeIds
            )
        }
        let groupIDs = Set(groups.map(\.groupID))
        let messages = try item.messages.enumerated().map { index, message in
            guard !message.messageID.isEmpty,
                  message.sequence == UInt32(index + 1),
                  ["system", "developer", "user", "assistant", "tool"].contains(message.role),
                  groupIDs.contains(message.contextGroupID), !message.summary.isEmpty,
                  message.hasContent else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedLlmMessage(
                messageID: message.messageID, sequence: message.sequence, role: message.role,
                contextGroupID: message.contextGroupID, summary: message.summary,
                content: try value(message.content), estimatedTokens: message.estimatedTokens,
                redactionCount: message.redactionCount, truncated: message.truncated
            )
        }
        let report = item.compilationReport
        guard report.retainedGroupCount == UInt32(groups.count),
              report.originalGroupCount >= report.retainedGroupCount,
              report.originalByteCount >= report.retainedByteCount,
              report.retainedByteCount <= settings.maximumContextBytes else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let toolDefinitions = try item.toolDefinitions.map { definition in
            guard !definition.toolID.isEmpty, !definition.version.isEmpty,
                  definition.packageDigest.count == 64, !definition.description_p.isEmpty,
                  !definition.inputSchemaRef.isEmpty, definition.inputSchemaDigest.count == 64,
                  !definition.outputSchemaRef.isEmpty,
                  definition.outputSchemaDigest.count == 64 else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedLlmToolDefinition(
                toolID: definition.toolID, version: definition.version,
                packageDigest: definition.packageDigest, description: definition.description_p,
                inputSchemaRef: definition.inputSchemaRef,
                inputSchemaDigest: definition.inputSchemaDigest,
                outputSchemaRef: definition.outputSchemaRef,
                outputSchemaDigest: definition.outputSchemaDigest
            )
        }
        let toolIDs = Set(toolDefinitions.map { $0.toolID })
        let toolCalls = try item.toolCalls.enumerated().map { index, call in
            guard !call.callID.isEmpty, call.sequence == UInt32(index + 1),
                  toolIDs.contains(call.toolID), ["succeeded", "failed"].contains(call.status),
                  call.hasInput,
                  (call.status == "succeeded") == call.hasOutput,
                  (call.status == "failed") == call.hasError else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedLlmToolCall(
                callID: call.callID, sequence: call.sequence, toolID: call.toolID,
                status: call.status, input: try value(call.input),
                output: try call.hasOutput ? value(call.output) : nil,
                errorCode: call.errorCode.nilIfEmpty,
                error: try call.hasError ? value(call.error) : nil,
                durationMilliseconds: call.durationMilliseconds
            )
        }
        let callIDs = Set(toolCalls.map { $0.callID })
        let responseMessages = try item.responseMessages.enumerated().map { index, message in
            guard !message.messageID.isEmpty, message.sequence == UInt32(index + 1),
                  ["assistant", "tool"].contains(message.role),
                  ["message", "analysis_summary", "tool_call", "tool_result", "final"]
                    .contains(message.kind),
                  !message.summary.isEmpty, message.hasContent,
                  message.toolCallID.isEmpty || callIDs.contains(message.toolCallID) else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedLlmResponseMessage(
                messageID: message.messageID, sequence: message.sequence,
                role: message.role, kind: message.kind, summary: message.summary,
                content: try value(message.content), toolCallID: message.toolCallID.nilIfEmpty
            )
        }
        let usage = item.hasUsage ? DesktopWorkflowProjectedLlmUsage(
            inputTokens: item.usage.inputTokens,
            cachedInputTokens: item.usage.cachedInputTokens,
            outputTokens: item.usage.outputTokens,
            reasoningTokens: item.usage.reasoningTokens,
            totalTokens: item.usage.totalTokens,
            toolCallCount: item.usage.toolCallCount,
            costCurrency: item.usage.costCurrency.nilIfEmpty,
            inputCostMicros: item.usage.inputCostMicros,
            outputCostMicros: item.usage.outputCostMicros,
            reasoningCostMicros: item.usage.reasoningCostMicros,
            toolCostMicros: item.usage.toolCostMicros,
            totalCostMicros: item.usage.totalCostMicros
        ) : nil
        let validation = item.hasValidation ? DesktopWorkflowProjectedLlmResponseValidation(
            status: item.validation.status, schemaRef: item.validation.schemaRef,
            schemaDigest: item.validation.schemaDigest,
            diagnostics: item.validation.diagnostics,
            diagnosticsTruncated: item.validation.diagnosticsTruncated
        ) : nil
        let providerReceipt = item.hasProviderReceipt
            ? DesktopWorkflowProjectedLlmProviderReceipt(
                requestID: item.providerReceipt.requestID,
                responseID: item.providerReceipt.responseID,
                receiptID: item.providerReceipt.receiptID,
                providerRunReference: item.providerReceipt.providerRunReference.nilIfEmpty,
                metadataDigest: item.providerReceipt.metadataDigest
            )
            : nil
        return DesktopWorkflowProjectedLlmAttempt(
            invocationID: item.invocationID, attemptID: item.attemptID,
            executionTokenID: item.executionTokenID, nodeID: item.nodeID,
            settings: DesktopWorkflowProjectedLlmSettings(
                modelClass: settings.modelClass, providerID: settings.providerID,
                modelID: settings.modelID, modelRevision: settings.modelRevision,
                reasoningEffort: settings.reasoningEffort,
                temperatureMilli: settings.temperatureMilli,
                maximumContextBytes: settings.maximumContextBytes,
                maximumOutputTokens: settings.maximumOutputTokens,
                conversationScope: settings.conversationScope
            ),
            contextDigest: item.contextDigest, contextGroups: groups, messages: messages,
            priorEpisodeIDs: item.priorEpisodeIds,
            attachments: try item.attachments.map(capabilityArtifact),
            compilationReport: DesktopWorkflowProjectedLlmCompilationReport(
                originalGroupCount: report.originalGroupCount,
                retainedGroupCount: report.retainedGroupCount,
                originalByteCount: report.originalByteCount,
                retainedByteCount: report.retainedByteCount,
                redactionCount: report.redactionCount,
                truncatedGroupIDs: report.truncatedGroupIds,
                droppedGroupIDs: report.droppedGroupIds,
                redactionReasons: report.redactionReasons
            ),
            outputSchemaRef: item.outputSchemaRef,
            outputSchemaDigest: item.outputSchemaDigest, input: try value(item.input),
            status: item.status, outcome: item.outcome.nilIfEmpty,
            output: try item.hasOutput ? value(item.output) : nil,
            errorCode: item.errorCode.nilIfEmpty,
            error: try item.hasError ? value(item.error) : nil,
            timeoutMilliseconds: item.timeoutMilliseconds,
            deadlineUnixMillis: item.deadlineUnixMillis,
            elapsedMilliseconds: settled ? item.elapsedMilliseconds : nil,
            receiptID: item.receiptID.nilIfEmpty,
            providerRunReference: item.providerRunReference.nilIfEmpty,
            idempotencyKey: item.idempotencyKey.nilIfEmpty,
            startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            startedStorePosition: item.startedStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil,
            toolDefinitions: toolDefinitions, toolCalls: toolCalls,
            responseMessages: responseMessages, usage: usage,
            validation: validation, providerReceipt: providerReceipt
        )
    }

    private static func capabilityAttempt(
        _ item: Kaname_V1_WorkflowProjectedCapabilityAttempt
    ) throws -> DesktopWorkflowProjectedCapabilityAttempt {
        guard !item.invocationID.isEmpty, !item.attemptID.isEmpty,
              !item.executionTokenID.isEmpty, !item.nodeID.isEmpty,
              !item.capabilityID.isEmpty, !item.version.isEmpty,
              item.packageDigest.count == 64,
              item.configurationContractDigest.count == 64,
              item.inputSchemaDigest.count == 64,
              item.outputSchemaDigest.count == 64,
              !item.outputSchemaRef.isEmpty,
              item.hasConfiguration, item.hasInput,
              ["running", "settled"].contains(item.status),
              item.timeoutMilliseconds > 0, item.deadlineUnixMillis >= 0,
              item.startedAtUnixMillis >= 0, item.startedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settled = item.status == "settled"
        guard settled == !item.outcome.isEmpty,
              settled == (item.settledStorePosition > 0),
              settled == (item.settledAtUnixMillis > 0),
              !settled || [
                "succeeded", "input_validation_failed", "output_validation_failed",
                "timed_out", "cancelled", "malformed_result", "crashed",
              ].contains(item.outcome),
              !settled || item.idempotencyKey == item.invocationID else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        if item.outcome == "succeeded" {
            guard item.hasOutput, item.errorCode.isEmpty, !item.hasError,
                  !item.receiptID.isEmpty else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        } else if settled && item.outcome != "cancelled" {
            guard !item.hasOutput, !item.errorCode.isEmpty, item.hasError else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        }
        let logs = try item.logs.enumerated().map { index, log in
            guard log.sequence == UInt32(index + 1),
                  ["debug", "info", "warning", "error"].contains(log.level),
                  !log.message.isEmpty,
                  log.offsetMilliseconds <= item.elapsedMilliseconds else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedCapabilityLog(
                sequence: log.sequence, level: log.level, message: log.message,
                offsetMilliseconds: log.offsetMilliseconds
            )
        }
        return DesktopWorkflowProjectedCapabilityAttempt(
            invocationID: item.invocationID,
            attemptID: item.attemptID,
            executionTokenID: item.executionTokenID,
            nodeID: item.nodeID,
            capabilityID: item.capabilityID,
            version: item.version,
            packageDigest: item.packageDigest,
            configurationContractDigest: item.configurationContractDigest,
            inputSchemaDigest: item.inputSchemaDigest,
            outputSchemaDigest: item.outputSchemaDigest,
            outputSchemaRef: item.outputSchemaRef,
            configuration: try value(item.configuration),
            input: try value(item.input),
            artifactInputs: try item.artifactInputs.map(capabilityArtifact),
            status: item.status,
            outcome: item.outcome.nilIfEmpty,
            output: try item.hasOutput ? value(item.output) : nil,
            artifactOutputs: try item.artifactOutputs.map(capabilityArtifact),
            errorCode: item.errorCode.nilIfEmpty,
            error: try item.hasError ? value(item.error) : nil,
            logs: logs,
            timeoutMilliseconds: item.timeoutMilliseconds,
            deadlineUnixMillis: item.deadlineUnixMillis,
            elapsedMilliseconds: settled ? item.elapsedMilliseconds : nil,
            receiptID: item.receiptID.nilIfEmpty,
            providerRunReference: item.providerRunReference.nilIfEmpty,
            idempotencyKey: item.idempotencyKey.nilIfEmpty,
            startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            startedStorePosition: item.startedStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil
        )
    }

    private static func capabilityArtifact(
        _ item: Kaname_V1_WorkflowProjectedCapabilityArtifactHandle
    ) throws -> DesktopWorkflowProjectedCapabilityArtifact {
        guard !item.handleID.isEmpty, !item.role.isEmpty, item.hasValue,
              item.value.storageReferenceID == item.handleID else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedCapabilityArtifact(
            handleID: item.handleID,
            role: item.role,
            value: try value(item.value)
        )
    }

    private static func subflow(
        _ item: Kaname_V1_WorkflowProjectedSubflow
    ) throws -> DesktopWorkflowProjectedSubflow {
        guard !item.invocationID.isEmpty, !item.attemptID.isEmpty,
              !item.executionTokenID.isEmpty, !item.nodeID.isEmpty,
              !item.childRunID.isEmpty, !item.childWorkflowID.isEmpty,
              !item.childRevisionID.isEmpty, !item.childPackageID.isEmpty,
              item.childPackageDigest.count == 64, !item.entrypoint.isEmpty,
              !item.childCommandID.isEmpty, item.calledAtUnixMillis >= 0,
              item.hasInput, ["called", "settled"].contains(item.status),
              item.calledStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let settled = item.status == "settled"
        guard settled == !item.outcome.isEmpty,
              settled == (item.settledStorePosition > 0),
              settled == (item.settledAtUnixMillis > 0),
              !settled || ["succeeded", "failed", "cancelled"].contains(item.outcome) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        if item.outcome == "succeeded" {
            guard item.hasOutput, item.errorCode.isEmpty, !item.hasError else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        } else if settled {
            guard !item.hasOutput, !item.errorCode.isEmpty, item.hasError else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
        } else if item.hasOutput || !item.errorCode.isEmpty || item.hasError
                    || !item.childFinalEmissionIds.isEmpty {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedSubflow(
            invocationID: item.invocationID,
            attemptID: item.attemptID,
            executionTokenID: item.executionTokenID,
            nodeID: item.nodeID,
            childRunID: item.childRunID,
            childWorkflowID: item.childWorkflowID,
            childRevisionID: item.childRevisionID,
            childPackageID: item.childPackageID,
            childPackageDigest: item.childPackageDigest,
            entrypoint: item.entrypoint,
            input: try value(item.input),
            status: item.status,
            outcome: item.outcome.nilIfEmpty,
            output: try item.hasOutput ? value(item.output) : nil,
            errorCode: item.errorCode.nilIfEmpty,
            error: try item.hasError ? value(item.error) : nil,
            childFinalEmissionIDs: item.childFinalEmissionIds,
            childCommandID: item.childCommandID,
            calledAtUnixMillis: item.calledAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            calledStorePosition: item.calledStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil
        )
    }

    private static func episode(
        _ item: Kaname_V1_WorkflowProjectedCaseEpisode
    ) throws -> DesktopWorkflowProjectedCaseEpisode {
        guard !item.installationID.isEmpty, !item.caseID.isEmpty,
              !item.episodeID.isEmpty, item.ordinal > 0,
              ["initial", "delivery", "correction", "redelivery"].contains(item.kind),
              !item.triggerKind.isEmpty, !item.inputs.isEmpty,
              item.hasCompiledContext, item.startedStorePosition > 0,
              item.sourceEpisodeIds.count + 1 == Int(item.ordinal),
              (item.ordinal == 1) == item.priorEpisodeID.isEmpty else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let inputs = try item.inputs.map { binding in
            guard !binding.portID.isEmpty, binding.hasValue else {
                throw DesktopWorkflowRunInspectionError.malformedResponse
            }
            return DesktopWorkflowProjectedInputBinding(
                portID: binding.portID,
                value: try value(binding.value)
            )
        }
        return DesktopWorkflowProjectedCaseEpisode(
            installationID: item.installationID,
            caseID: item.caseID,
            episodeID: item.episodeID,
            ordinal: item.ordinal,
            kind: item.kind,
            priorEpisodeID: item.priorEpisodeID.nilIfEmpty,
            triggerKind: item.triggerKind,
            triggerEventID: item.triggerEventID.nilIfEmpty,
            inputs: inputs,
            compiledContext: try value(item.compiledContext),
            sourceEpisodeIDs: item.sourceEpisodeIds,
            sourceEventIDs: item.sourceEventIds,
            startedStorePosition: item.startedStorePosition
        )
    }

    private static func value(_ value: Kaname_V1_WorkflowProjectedValue) throws -> DesktopWorkflowProjectedValue {
        guard !value.valueID.isEmpty,
              !value.contentType.isEmpty,
              value.sha256.count == 64,
              !value.availability.isEmpty else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedValue(
            id: value.valueID,
            contentType: value.contentType,
            byteCount: value.byteCount,
            sha256: value.sha256,
            inlineCanonicalJSON: value.inlineCanonicalJson.isEmpty ? nil : value.inlineCanonicalJson,
            storageReferenceID: value.storageReferenceID.nilIfEmpty,
            availability: value.availability,
            storage: try value.hasStorage ? storage(value.storage) : nil
        )
    }

    private static func storage(
        _ storage: Kaname_V1_WorkflowStorageValueMetadata
    ) throws -> DesktopWorkflowStorageValueMetadata {
        guard !storage.scope.isEmpty,
              !storage.logicalKey.isEmpty,
              !storage.result.isEmpty else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let summary = storage.result == "listed" || storage.result == "missing"
        guard summary || (!storage.handleID.isEmpty && !storage.versionID.isEmpty && storage.revision > 0) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowStorageValueMetadata(
            handleID: storage.handleID.nilIfEmpty,
            scope: storage.scope,
            logicalKey: storage.logicalKey,
            versionID: storage.versionID.nilIfEmpty,
            revision: storage.revision > 0 ? storage.revision : nil,
            previousVersionID: storage.previousVersionID.nilIfEmpty,
            sourceVersionID: storage.sourceVersionID.nilIfEmpty,
            byteCount: storage.byteCount,
            result: storage.result
        )
    }

    private static func attempt(_ item: Kaname_V1_WorkflowProjectedAttempt) throws -> DesktopWorkflowProjectedAttempt {
        guard !item.attemptID.isEmpty, !item.nodeID.isEmpty, item.attemptNumber > 0,
              !item.status.isEmpty, item.startedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedAttempt(
            id: item.attemptID, nodeID: item.nodeID, number: item.attemptNumber,
            status: item.status, outcome: item.outcome.nilIfEmpty,
            errorCode: item.errorCode.nilIfEmpty, error: try item.hasError ? value(item.error) : nil,
            emissionIDs: item.emissionIds, startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            startedStorePosition: item.startedStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil,
            executionTokenID: item.executionTokenID.nilIfEmpty
        )
    }

    private static func node(_ item: Kaname_V1_WorkflowProjectedNodeState) throws -> DesktopWorkflowProjectedNode {
        guard !item.nodeID.isEmpty, !item.status.isEmpty, !item.latestAttemptID.isEmpty,
              item.latestAttemptNumber > 0, item.lastStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedNode(
            nodeID: item.nodeID, status: item.status, latestAttemptID: item.latestAttemptID,
            latestAttemptNumber: item.latestAttemptNumber,
            startedAtUnixMillis: item.startedAtUnixMillis,
            settledAtUnixMillis: item.settledAtUnixMillis > 0 ? item.settledAtUnixMillis : nil,
            lastStorePosition: item.lastStorePosition
        )
    }

    private static func emission(_ item: Kaname_V1_WorkflowProjectedEmission) throws -> DesktopWorkflowProjectedEmission {
        guard !item.emissionID.isEmpty, !item.attemptID.isEmpty, !item.nodeID.isEmpty,
              !item.portID.isEmpty, item.hasValue, !item.eventID.isEmpty, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEmission(
            id: item.emissionID, attemptID: item.attemptID, nodeID: item.nodeID,
            portID: item.portID, value: try value(item.value), eventID: item.eventID,
            emittedAtUnixMillis: item.emittedAtUnixMillis, storePosition: item.storePosition,
            executionTokenID: item.executionTokenID.nilIfEmpty
        )
    }

    private static func edge(_ item: Kaname_V1_WorkflowProjectedEdgeCheckpoint) throws -> DesktopWorkflowProjectedEdge {
        guard !item.eventID.isEmpty, !item.edgeID.isEmpty, !item.emissionID.isEmpty,
              !item.targetNodeID.isEmpty, !item.targetPortID.isEmpty,
              !item.state.isEmpty, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEdge(
            eventID: item.eventID, edgeID: item.edgeID, emissionID: item.emissionID,
            targetNodeID: item.targetNodeID, targetPortID: item.targetPortID,
            state: item.state, checkpointedAtUnixMillis: item.checkpointedAtUnixMillis,
            storePosition: item.storePosition, executionTokenID: item.executionTokenID.nilIfEmpty
        )
    }

    private static func executionToken(
        _ item: Kaname_V1_WorkflowProjectedExecutionToken
    ) throws -> DesktopWorkflowProjectedExecutionToken {
        guard !item.executionTokenID.isEmpty, !item.status.isEmpty,
              item.createdStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedExecutionToken(
            executionTokenID: item.executionTokenID,
            parentExecutionTokenID: item.parentExecutionTokenID.nilIfEmpty,
            forkNodeID: item.forkNodeID.nilIfEmpty,
            branchID: item.branchID.nilIfEmpty,
            branchPortID: item.branchPortID.nilIfEmpty,
            joinNodeID: item.joinNodeID.nilIfEmpty,
            sourceEmissionID: item.sourceEmissionID.nilIfEmpty,
            status: item.status,
            outcome: item.outcome.nilIfEmpty,
            terminalNodeID: item.terminalNodeID.nilIfEmpty,
            errorCode: item.errorCode.nilIfEmpty,
            error: try item.hasError ? value(item.error) : nil,
            finalEmissionIDs: item.finalEmissionIds,
            createdStorePosition: item.createdStorePosition,
            settledStorePosition: item.settledStorePosition > 0 ? item.settledStorePosition : nil,
            iterationNodeID: item.iterationNodeID.nilIfEmpty,
            iterationIndex: item.iterationNodeID.isEmpty ? nil : item.iterationIndex,
            iterationCount: item.iterationNodeID.isEmpty ? nil : item.iterationCount,
            resumeNodeID: item.resumeNodeID.nilIfEmpty,
            resumeReason: item.resumeReason.nilIfEmpty
        )
    }

    private static func join(
        _ item: Kaname_V1_WorkflowProjectedJoinEvaluation
    ) throws -> DesktopWorkflowProjectedJoin {
        guard !item.joinNodeID.isEmpty, !item.forkNodeID.isEmpty,
              !item.resumedExecutionTokenID.isEmpty, !item.policy.isEmpty,
              item.threshold > 0, !item.decision.isEmpty, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedJoin(
            joinNodeID: item.joinNodeID,
            forkNodeID: item.forkNodeID,
            resumedExecutionTokenID: item.resumedExecutionTokenID,
            policy: item.policy,
            threshold: item.threshold,
            decision: item.decision,
            expectedExecutionTokenIDs: item.expectedExecutionTokenIds,
            arrivedExecutionTokenIDs: item.arrivedExecutionTokenIds,
            failedExecutionTokenIDs: item.failedExecutionTokenIds,
            pendingExecutionTokenIDs: item.pendingExecutionTokenIds,
            cancelRemaining: item.cancelRemaining,
            errorCode: item.errorCode.nilIfEmpty,
            storePosition: item.storePosition
        )
    }

    private static func iteration(
        _ item: Kaname_V1_WorkflowProjectedIteration
    ) throws -> DesktopWorkflowProjectedIteration {
        guard !item.iterationNodeID.isEmpty, !item.parentExecutionTokenID.isEmpty,
              !item.controllerAttemptID.isEmpty, !item.inputValueID.isEmpty,
              item.inputSha256.count == 64, item.maximumItems > 0,
              item.maximumConcurrency > 0,
              item.maximumConcurrency <= item.maximumItems,
              !item.failurePolicy.isEmpty, item.plannedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let evaluated = !item.decision.isEmpty
        guard !evaluated || (!item.resumedExecutionTokenID.isEmpty
            && item.hasOutput && item.evaluatedStorePosition > 0) else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedIteration(
            iterationNodeID: item.iterationNodeID,
            parentExecutionTokenID: item.parentExecutionTokenID,
            controllerAttemptID: item.controllerAttemptID,
            inputValueID: item.inputValueID,
            inputSHA256: item.inputSha256,
            itemCount: item.itemCount,
            maximumItems: item.maximumItems,
            maximumConcurrency: item.maximumConcurrency,
            failurePolicy: item.failurePolicy,
            decision: item.decision.nilIfEmpty,
            resumedExecutionTokenID: item.resumedExecutionTokenID.nilIfEmpty,
            expectedExecutionTokenIDs: item.expectedExecutionTokenIds,
            succeededExecutionTokenIDs: item.succeededExecutionTokenIds,
            failedExecutionTokenIDs: item.failedExecutionTokenIds,
            pendingExecutionTokenIDs: item.pendingExecutionTokenIds,
            errorCode: item.errorCode.nilIfEmpty,
            output: try item.hasOutput ? value(item.output) : nil,
            plannedStorePosition: item.plannedStorePosition,
            evaluatedStorePosition: item.evaluatedStorePosition > 0 ? item.evaluatedStorePosition : nil
        )
    }

    private static func retry(
        _ item: Kaname_V1_WorkflowProjectedRetryEvaluation
    ) throws -> DesktopWorkflowProjectedRetry {
        guard !item.retryNodeID.isEmpty, !item.executionTokenID.isEmpty,
              !item.controllerAttemptID.isEmpty, !item.failedAttemptID.isEmpty,
              !item.targetNodeID.isEmpty, !item.errorCode.isEmpty,
              !item.decision.isEmpty, item.nextAttemptNumber > 1,
              item.maximumAttempts > 0, item.hasRetryInput, item.hasError,
              item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedRetry(
            retryNodeID: item.retryNodeID,
            executionTokenID: item.executionTokenID,
            controllerAttemptID: item.controllerAttemptID,
            failedAttemptID: item.failedAttemptID,
            targetNodeID: item.targetNodeID,
            errorCode: item.errorCode,
            decision: item.decision,
            nextAttemptNumber: item.nextAttemptNumber,
            maximumAttempts: item.maximumAttempts,
            delayMilliseconds: item.delayMilliseconds,
            eligibleAtUnixMillis: item.eligibleAtUnixMillis > 0 ? item.eligibleAtUnixMillis : nil,
            retryInput: try value(item.retryInput),
            error: try value(item.error),
            storePosition: item.storePosition
        )
    }

    private static func wait(
        _ item: Kaname_V1_WorkflowProjectedWait
    ) throws -> DesktopWorkflowProjectedWait {
        guard !item.subscriptionID.isEmpty, !item.waitNodeID.isEmpty,
              !item.executionTokenID.isEmpty, !item.controllerAttemptID.isEmpty,
              !item.workflowID.isEmpty, !item.revisionID.isEmpty,
              item.packageDigest.count == 64,
              ["timer", "event", "reply"].contains(item.kind),
              ["case", "installation", "workflow"].contains(item.ownerKind),
              !item.ownerID.isEmpty, !item.correlation.isEmpty,
              !item.inputValueID.isEmpty, item.inputSha256.count == 64,
              ["waiting", "resumed", "expired", "cancelled"].contains(item.status),
              item.expiresAtUnixMillis > 0, item.subscribedStorePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        let resolved = item.status != "waiting"
        guard resolved == !item.decision.isEmpty,
              resolved == (item.resolvedStorePosition > 0),
              !resolved || item.decision == item.status else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedWait(
            subscriptionID: item.subscriptionID,
            waitNodeID: item.waitNodeID,
            executionTokenID: item.executionTokenID,
            controllerAttemptID: item.controllerAttemptID,
            workflowID: item.workflowID,
            revisionID: item.revisionID,
            packageDigest: item.packageDigest,
            kind: item.kind,
            ownerKind: item.ownerKind,
            ownerID: item.ownerID,
            correlation: try item.correlation.map(waitCorrelation),
            inputValueID: item.inputValueID,
            inputSHA256: item.inputSha256,
            status: item.status,
            decision: item.decision.nilIfEmpty,
            resolvingSignalID: item.resolvingSignalID.nilIfEmpty,
            output: try item.hasOutput ? value(item.output) : nil,
            reasonCode: item.reasonCode.nilIfEmpty,
            expiresAtUnixMillis: item.expiresAtUnixMillis,
            subscribedStorePosition: item.subscribedStorePosition,
            resolvedStorePosition: item.resolvedStorePosition > 0 ? item.resolvedStorePosition : nil
        )
    }

    private static func waitSignal(
        _ item: Kaname_V1_WorkflowProjectedWaitSignal
    ) throws -> DesktopWorkflowProjectedWaitSignal {
        guard !item.signalID.isEmpty, !item.signalCommandID.isEmpty,
              ["event", "reply"].contains(item.kind),
              ["case", "installation", "workflow"].contains(item.ownerKind),
              !item.ownerID.isEmpty, !item.correlation.isEmpty,
              item.hasValue, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedWaitSignal(
            signalID: item.signalID,
            signalCommandID: item.signalCommandID,
            kind: item.kind,
            ownerKind: item.ownerKind,
            ownerID: item.ownerID,
            correlation: try item.correlation.map(waitCorrelation),
            value: try value(item.value),
            recordedAtUnixMillis: item.recordedAtUnixMillis,
            storePosition: item.storePosition
        )
    }

    private static func waitCorrelation(
        _ item: Kaname_V1_WorkflowWaitCorrelation
    ) throws -> DesktopWorkflowWaitCorrelation {
        guard !item.key.isEmpty, item.sha256.count == 64 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowWaitCorrelation(key: item.key, sha256: item.sha256)
    }

    private static func matchTrace(_ item: Kaname_V1_WorkflowProjectedMatchTrace) throws -> DesktopWorkflowProjectedMatchTrace {
        guard !item.eventID.isEmpty, !item.attemptID.isEmpty, !item.nodeID.isEmpty,
              !item.inputValueID.isEmpty, item.hasTrace, item.storePosition > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedMatchTrace(
            eventID: item.eventID, attemptID: item.attemptID, nodeID: item.nodeID,
            inputValueID: item.inputValueID, evaluatedCaseIDs: item.evaluatedCaseIds,
            matchedCaseIDs: item.matchedCaseIds, emittedPortIDs: item.emittedPortIds,
            trace: try value(item.trace), recordedAtUnixMillis: item.recordedAtUnixMillis,
            storePosition: item.storePosition
        )
    }

    private static func event(_ item: Kaname_V1_WorkflowProjectedEventReference) throws -> DesktopWorkflowProjectedEvent {
        guard !item.eventID.isEmpty, !item.kind.isEmpty,
              item.storePosition > 0, item.streamSequence > 0 else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return DesktopWorkflowProjectedEvent(
            eventID: item.eventID, kind: item.kind, storePosition: item.storePosition,
            streamSequence: item.streamSequence, occurredAtUnixMillis: item.occurredAtUnixMillis
        )
    }
}

public struct DesktopWorkflowRunPurgeClient: Sendable {
    private let transport: any DesktopWorkflowRunPurgeTransport
    private let timeout: TimeInterval

    public init(
        transport: any DesktopWorkflowRunPurgeTransport,
        timeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func purge(
        _ run: DesktopDurableWorkflowRun,
        requestID: String,
        requestedAtUnixMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws -> Kaname_V1_WorkflowRunPurgeReceipt {
        guard !requestID.isEmpty,
              requestID.count <= 128,
              run.purgePreview.manualEligible,
              run.purgePreview.evidenceDigest.count == 64,
              requestedAtUnixMillis >= 0 else {
            throw DesktopWorkflowRunInspectionError.invalidRequest
        }
        var request = Kaname_V1_PurgeWorkflowRunRequest()
        request.schemaVersion.major = 1
        request.requestID = requestID
        request.runID = run.runID
        request.mode = .manual
        request.expectedPreviewEvidenceDigest = run.purgePreview.evidenceDigest
        request.requestedAtUnixMillis = requestedAtUnixMillis
        let response = try await transport.purgeWorkflowRun(request, timeout: timeout)
        guard response.schemaVersion.major == 1,
              response.requestID == requestID,
              response.hasReceipt,
              response.receipt.hasTombstone,
              response.receipt.tombstone.runID == run.runID,
              response.receipt.tombstone.previewEvidenceDigest == run.purgePreview.evidenceDigest,
              response.receipt.tombstone.affectedEffectAuthorityCount
                == UInt64(run.purgePreview.affectedEffectIDs.count),
              response.receipt.tombstone.historicalRevisionRetained,
              !response.receipt.purgeEventID.isEmpty,
              response.receipt.purgeStorePosition > run.lastStorePosition else {
            throw DesktopWorkflowRunInspectionError.malformedResponse
        }
        return response.receipt
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
