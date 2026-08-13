import CryptoKit
import Foundation

public enum DesktopWorkflowTriggerKind: String, Codable, CaseIterable, Equatable, Sendable {
    case manual
    case email
    case schedule
    case calendar

    public var label: String { rawValue.capitalized }
}

public enum DesktopWorkflowStepKind: String, Codable, CaseIterable, Equatable, Sendable {
    case classifyEvent
    case correlateWork
    case compileContext
    case structuredModel
    case invokeTool
    case registerArtifact
    case validate
    case branch
    case agent
    case effect
    case humanReview
    case requestApproval
    case createEmailDraft
    case sendEmail
    case waitForEmail
    case complete

    public var label: String {
        switch self {
        case .classifyEvent: "Classify event"
        case .correlateWork: "Correlate work"
        case .compileContext: "Compile context"
        case .structuredModel: "Structured model"
        case .invokeTool: "Invoke tool"
        case .registerArtifact: "Register artifact"
        case .validate: "Validate"
        case .branch: "Decision branch"
        case .agent: "Bounded agent"
        case .effect: "Connector effect"
        case .humanReview: "Human review"
        case .requestApproval: "Request approval"
        case .createEmailDraft: "Create email draft"
        case .sendEmail: "Send email"
        case .waitForEmail: "Wait for email"
        case .complete: "Complete"
        }
    }
}

public enum DesktopWorkflowPermission: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case emailRead
    case emailDraft
    case emailSend
    case emailLabels
    case fileRead
    case fileWrite
    case modelEgress
    case network
    case externalEffects

    public var label: String {
        switch self {
        case .emailRead: "Read selected email accounts"
        case .emailDraft: "Create email drafts"
        case .emailSend: "Send email"
        case .emailLabels: "Change email labels"
        case .fileRead: "Read selected folders"
        case .fileWrite: "Write selected folders"
        case .modelEgress: "Send declared data to a model provider"
        case .network: "Use declared network destinations"
        case .externalEffects: "Propose effects through trusted connectors"
        }
    }
}

public struct DesktopWorkflowStepDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var kind: DesktopWorkflowStepKind
    public var capabilityID: String?
    public var inputSchemaReference: String?
    public var outputSchemaReference: String?
    public var retryLimit: Int
    public var isIdempotent: Bool
    public var blocking: Bool
    public var artifactInputs: [DesktopWorkflowArtifactInputDefinition]?
    public var stateInputs: [DesktopWorkflowStateInputDefinition]?
    public var transitions: [DesktopWorkflowTransitionDefinition]?
    public var reviewContract: DesktopWorkflowReviewContract?
    public var waitContract: DesktopWorkflowWaitContract?
    public var executionPolicy: DesktopWorkflowExecutionPolicy?
    public var agentPolicy: DesktopWorkflowAgentPolicy?

    public init(
        id: String,
        name: String,
        kind: DesktopWorkflowStepKind,
        capabilityID: String? = nil,
        inputSchemaReference: String? = nil,
        outputSchemaReference: String? = nil,
        retryLimit: Int = 0,
        isIdempotent: Bool = true,
        blocking: Bool = true,
        artifactInputs: [DesktopWorkflowArtifactInputDefinition]? = nil,
        stateInputs: [DesktopWorkflowStateInputDefinition]? = nil,
        transitions: [DesktopWorkflowTransitionDefinition]? = nil,
        reviewContract: DesktopWorkflowReviewContract? = nil,
        waitContract: DesktopWorkflowWaitContract? = nil,
        executionPolicy: DesktopWorkflowExecutionPolicy? = nil,
        agentPolicy: DesktopWorkflowAgentPolicy? = nil
    ) {
        (self.id, self.name, self.kind) = (id, name, kind)
        (self.capabilityID, self.inputSchemaReference, self.outputSchemaReference) = (
            capabilityID, inputSchemaReference, outputSchemaReference
        )
        (self.retryLimit, self.isIdempotent, self.blocking) = (retryLimit, isIdempotent, blocking)
        self.artifactInputs = artifactInputs
        self.stateInputs = stateInputs
        self.transitions = transitions
        self.reviewContract = reviewContract
        self.waitContract = waitContract
        self.executionPolicy = executionPolicy
        self.agentPolicy = agentPolicy
    }
}

public struct DesktopWorkflowPermissionEnvelope: Codable, Equatable, Sendable {
    public var permissions: [DesktopWorkflowPermission]
    public var accountIDs: [String]
    public var filesystemScopes: [String]
    public var capabilityIDs: [String]
    public var networkDestinations: [String]
    public var dataClassesLeavingDevice: [String]

    public init(
        permissions: [DesktopWorkflowPermission] = [],
        accountIDs: [String] = [],
        filesystemScopes: [String] = [],
        capabilityIDs: [String] = [],
        networkDestinations: [String] = [],
        dataClassesLeavingDevice: [String] = []
    ) {
        self.permissions = Array(Set(permissions)).sorted { $0.rawValue < $1.rawValue }
        self.accountIDs = Array(Set(accountIDs)).sorted()
        self.filesystemScopes = Array(Set(filesystemScopes)).sorted()
        self.capabilityIDs = Array(Set(capabilityIDs)).sorted()
        self.networkDestinations = Array(Set(networkDestinations)).sorted()
        self.dataClassesLeavingDevice = Array(Set(dataClassesLeavingDevice)).sorted()
    }

    public func broadens(_ prior: Self) -> Bool {
        !Set(permissions).isSubset(of: Set(prior.permissions))
            || !Set(accountIDs).isSubset(of: Set(prior.accountIDs))
            || !Set(filesystemScopes).isSubset(of: Set(prior.filesystemScopes))
            || !Set(capabilityIDs).isSubset(of: Set(prior.capabilityIDs))
            || !Set(networkDestinations).isSubset(of: Set(prior.networkDestinations))
            || !Set(dataClassesLeavingDevice).isSubset(of: Set(prior.dataClassesLeavingDevice))
    }
}

public struct DesktopWorkflowDefinitionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var icon: String
    public var source: String
    public var license: String
    public var currentRevisionID: String
    public var enabled: Bool
    public var triggerKinds: [DesktopWorkflowTriggerKind]
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public struct DesktopWorkflowRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var version: String
    public var schemaVersion: Int
    public var manifestDigest: String
    public var steps: [DesktopWorkflowStepDefinition]
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var correlationSummary: String
    public var contextSummary: String
    public var completionSummary: String
    public var datasetDefinitions: [DesktopWorkflowDatasetDefinition]? = nil
    public var configurationSchema: String? = nil
    public var configurationSchemaVersion: Int? = nil
    public var manualRunInputSchema: String? = nil
    public var bindingSlots: [DesktopWorkflowBindingSlotDefinition]? = nil
    public var providerFeatures: [DesktopWorkflowProviderFeatureRequirement]? = nil
    public var hostCompatibility: DesktopWorkflowHostCompatibility? = nil
    public var dependencies: [DesktopWorkflowDependencyConstraint]? = nil
    public var publisher: DesktopWorkflowPublisher? = nil
    public var provenance: DesktopWorkflowPackageProvenance? = nil
    public var uiHints: [DesktopWorkflowUIHint]? = nil
    public var configurationMigrations: [DesktopWorkflowConfigurationMigration]? = nil
    public var installedAtUnixMillis: Int64
}

/// An explicit, revocable scope connecting an installed workflow to one event
/// source. Definitions never observe accounts merely because they are enabled.
public struct DesktopWorkflowTriggerBindingRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var trigger: DesktopWorkflowTriggerKind
    public var source: String
    public var accountIDs: [String]
    public var sourceFilter: String
    public var enabled: Bool
    public var lastCursor: String?
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopWorkflowWorkState: String, Codable, CaseIterable, Equatable, Sendable {
    case open
    case preparing
    case running
    case needsAttention
    case readyForEffect
    case waitingExternal
    case accepted
    case operationallyClosed
    case failed
    case cancelled
    case superseded

    public var label: String {
        switch self {
        case .open: "Open"
        case .preparing: "Preparing"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .readyForEffect: "Ready for effect"
        case .waitingExternal: "Waiting for reply"
        case .accepted: "Accepted"
        case .operationallyClosed: "Operationally closed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .superseded: "Superseded"
        }
    }

    public var needsAttention: Bool {
        self == .needsAttention || self == .failed
    }

    public var isHistorical: Bool {
        [.accepted, .operationallyClosed, .cancelled, .superseded].contains(self)
    }
}

public struct DesktopWorkflowWorkItemRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workflowID: String
    public var title: String
    public var goal: String
    public var state: DesktopWorkflowWorkState
    public var currentEpisodeID: String?
    public var nextAction: String
    public var explicitAcceptance: Bool
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
    public var closedAtUnixMillis: Int64?
    public var installationID: String? = nil
}

public enum DesktopWorkflowConversationRelationship: String, Codable, CaseIterable, Equatable, Sendable {
    case primary
    case continuation
    case evidenceOnly
    case detached

    public var label: String {
        switch self {
        case .primary: "Primary"
        case .continuation: "Continuation"
        case .evidenceOnly: "Evidence only"
        case .detached: "Detached"
        }
    }
}

public struct DesktopWorkflowConversationBindingRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var source: String
    public var accountID: String
    public var conversationID: String
    public var relationship: DesktopWorkflowConversationRelationship
    public var correlationReason: String
    public var confidence: Double
    public var requiresReview: Bool
    public var firstMessageID: String?
    public var latestMessageID: String?
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowEpisodeIntent: String, Codable, CaseIterable, Equatable, Sendable {
    case request
    case correction
    case clarification
    case newInput
    case approval
    case rejection
    case acceptance
    case continuation

    public var label: String {
        switch self {
        case .request: "Request"
        case .correction: "Correction"
        case .clarification: "Clarification"
        case .newInput: "New input"
        case .approval: "Approval"
        case .rejection: "Rejection"
        case .acceptance: "Acceptance"
        case .continuation: "Continuation"
        }
    }
}

public struct DesktopWorkflowEpisodeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var ordinal: Int
    public var intent: DesktopWorkflowEpisodeIntent
    public var sourceEventID: String
    public var sourceMessageID: String?
    public var summary: String
    public var deltaSummary: String
    public var state: DesktopWorkflowWorkState
    public var workflowRevisionID: String
    public var supersedesEpisodeID: String?
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowRunState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case waiting
    case completed
    case failed
    case cancelled

    public var label: String { rawValue.capitalized }
}

public enum DesktopWorkflowRetryMode: String, Codable, CaseIterable, Equatable, Sendable {
    case initial
    case exactReplay
    case failedStep
    case currentRevision

    public var label: String {
        switch self {
        case .initial: "Initial run"
        case .exactReplay: "Retry original revision and inputs"
        case .failedStep: "Retry failed step"
        case .currentRevision: "Reprocess with current revision"
        }
    }
}

public struct DesktopWorkflowRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var episodeID: String
    public var workflowRevisionID: String
    public var retryMode: DesktopWorkflowRetryMode
    public var priorRunID: String?
    public var contextSnapshotID: String?
    public var state: DesktopWorkflowRunState
    public var currentStepID: String?
    public var traceID: String
    public var startedAtUnixMillis: Int64?
    public var completedAtUnixMillis: Int64?
}

public struct DesktopWorkflowStepAttemptRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var stepID: String
    public var attempt: Int
    public var state: DesktopWorkflowRunState
    public var inputDigest: String
    public var outputDigest: String?
    public var providerRunID: String?
    public var artifactIDs: [String]
    public var errorSummary: String?
    public var spanID: String
    public var parentSpanID: String?
    public var startedAtUnixMillis: Int64
    public var completedAtUnixMillis: Int64?
}

public enum DesktopWorkflowFactState: String, Codable, CaseIterable, Equatable, Sendable {
    case proposed
    case verified
    case rejected
    case superseded
    case expired

    public var label: String { rawValue.capitalized }
}

public struct DesktopWorkflowFactRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var key: String
    public var value: String
    public var state: DesktopWorkflowFactState
    public var sourceReferenceIDs: [String]
    public var verifiedBy: String?
    public var episodeID: String
    public var supersededByFactID: String?
    public var createdAtUnixMillis: Int64
    public var scope: DesktopWorkflowDataScope? = nil
    public var workflowID: String? = nil
    public var expiresAtUnixMillis: Int64? = nil
    public var proposedSupersedesFactID: String? = nil
    public var scopeID: String? = nil
}

public struct DesktopWorkflowContextReference: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: String
    public var label: String
    public var sourceID: String
    public var digest: String
    public var included: Bool
    public var reason: String
    public var estimatedTokens: Int
    /// Bounded, immutable source text selected by the context compiler. Binary
    /// artifacts remain digest references and are never coerced into prompt text.
    public var content: String? = nil

    public static func reference(
        id: String,
        kind: String,
        label: String,
        sourceID: String,
        digest: String,
        included: Bool,
        reason: String,
        estimatedTokens: Int,
        content: String? = nil
    ) -> Self {
        let boundedTokenEstimate = max(0, estimatedTokens)
        let explanation = reason.isEmpty ? "No selection explanation supplied." : reason
        return Self(
            id: id, kind: kind, label: label, sourceID: sourceID, digest: digest,
            included: included, reason: explanation, estimatedTokens: boundedTokenEstimate,
            content: content
        )
    }
}

public struct DesktopWorkflowContextKnowledge: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var value: String
    public var scope: DesktopWorkflowDataScope
    public var sourceReferenceIDs: [String]
}

public struct DesktopWorkflowContextSnapshotRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var episodeID: String
    public var compilerVersion: Int
    public var currentRequest: String
    public var openQuestions: [String]
    public var negativeConstraints: [String]
    public var references: [DesktopWorkflowContextReference]
    public var authoritySummary: String
    public var dataEgressSummary: String
    public var estimatedTokens: Int
    public var digest: String
    public var createdAtUnixMillis: Int64
    public var knowledge: [DesktopWorkflowContextKnowledge]? = nil
}

public enum DesktopWorkflowValidationSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case blocking
    case warning
    case informational

    public var label: String { rawValue.capitalized }
}

public enum DesktopWorkflowValidationOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case passed
    case failed
    case error
    case notRun

    public var label: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .error: "Error"
        case .notRun: "Not run"
        }
    }
}

public struct DesktopWorkflowValidationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var episodeID: String
    public var runID: String
    public var validatorID: String
    public var validatorRevision: String
    public var targetID: String
    public var severity: DesktopWorkflowValidationSeverity
    public var outcome: DesktopWorkflowValidationOutcome
    public var summary: String
    public var evidenceArtifactIDs: [String]
    public var waiverDecisionID: String?
    public var createdAtUnixMillis: Int64
}

public enum DesktopWorkflowEffectState: String, Codable, CaseIterable, Equatable, Sendable {
    case proposed
    case awaitingApproval
    case approved
    case executing
    case reconciled
    case failed
    case outcomeUnknown
    case cancelled

    public var label: String {
        switch self {
        case .proposed: "Proposed"
        case .awaitingApproval: "Awaiting approval"
        case .approved: "Approved"
        case .executing: "Executing"
        case .reconciled: "Reconciled"
        case .failed: "Failed"
        case .outcomeUnknown: "Outcome unknown"
        case .cancelled: "Cancelled"
        }
    }
}

public struct DesktopWorkflowEffectRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workItemID: String
    public var episodeID: String
    public var runID: String
    public var stepID: String
    public var kind: String
    public var accountID: String?
    public var exactTarget: String
    public var contentDigest: String
    public var attachmentDigests: [String]
    public var approvalID: String?
    public var idempotencyKey: String
    public var state: DesktopWorkflowEffectState
    public var remoteReceipt: String?
    public var createdAtUnixMillis: Int64
    public var reconciledAtUnixMillis: Int64?
}

public struct DesktopWorkflowExternalEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var source: String
    public var accountID: String
    public var conversationID: String?
    public var messageID: String?
    public var cursor: String?
    public var payloadDigest: String
    public var deduplicationKey: String
    public var observedAtUnixMillis: Int64
}

public struct DesktopWorkflowArtifactEdgeRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case derivedFrom
        case supersedes
        case validatedBy
        case attachedToMessage
        case sentByEffect
        case reusedFromPriorEpisode

        public var label: String {
            switch self {
            case .derivedFrom: "Derived from"
            case .supersedes: "Supersedes"
            case .validatedBy: "Validated by"
            case .attachedToMessage: "Attached to message"
            case .sentByEffect: "Sent by effect"
            case .reusedFromPriorEpisode: "Reused from prior episode"
            }
        }
    }

    public let id: String
    public var fromArtifactID: String
    public var toID: String
    public var kind: Kind
    public var createdAtUnixMillis: Int64
}

public struct DesktopWorkflowPlatformState: Codable, Equatable, Sendable {
    public var definitions: [DesktopWorkflowDefinitionRecord]
    public var revisions: [DesktopWorkflowRevisionRecord]
    public var triggerBindings: [DesktopWorkflowTriggerBindingRecord]
    public var workItems: [DesktopWorkflowWorkItemRecord]
    public var conversationBindings: [DesktopWorkflowConversationBindingRecord]
    public var episodes: [DesktopWorkflowEpisodeRecord]
    public var runs: [DesktopWorkflowRunRecord]
    public var stepAttempts: [DesktopWorkflowStepAttemptRecord]
    public var facts: [DesktopWorkflowFactRecord]
    public var contextSnapshots: [DesktopWorkflowContextSnapshotRecord]
    public var validations: [DesktopWorkflowValidationRecord]
    public var effects: [DesktopWorkflowEffectRecord]
    public var externalEvents: [DesktopWorkflowExternalEventRecord]
    public var artifactEdges: [DesktopWorkflowArtifactEdgeRecord]
    public var stateRecords: [DesktopWorkflowStateRecord]
    public var artifactRoles: [DesktopWorkflowArtifactRoleRecord]
    public var capabilityInstallations: [DesktopWorkflowCapabilityInstallationRecord]
    public var runtimeClaims: [DesktopWorkflowRuntimeClaimRecord]
    public var transitionRecords: [DesktopWorkflowTransitionRecord]
    public var reviewRequests: [DesktopWorkflowReviewRequestRecord]
    public var waitSubscriptions: [DesktopWorkflowWaitSubscriptionRecord]
    public var datasetRows: [DesktopWorkflowDatasetRowRecord]
    public var validatorReports: [DesktopWorkflowValidatorReportRecord]
    public var executionReceipts: [DesktopWorkflowExecutionReceiptRecord]
    public var authorityGrants: [DesktopWorkflowAuthorityGrantRecord]
    public var effectPreviews: [DesktopWorkflowEffectPreviewRecord]
    public var triggerHealth: [DesktopWorkflowTriggerHealthRecord]
    public var ownershipPolicies: [DesktopWorkflowOwnershipPolicyRecord]
    public var ownershipClaims: [DesktopWorkflowOwnershipClaimRecord]
    public var connectorInstallations: [DesktopWorkflowConnectorInstallationRecord]
    public var connectorBindings: [DesktopWorkflowConnectorBindingRecord]
    public var qualificationRuns: [DesktopWorkflowQualificationRunRecord]
    public var rendererInstallations: [DesktopWorkflowRendererInstallationRecord]
    public var renderReceipts: [DesktopWorkflowRenderReceiptRecord]
    public var subflows: [DesktopWorkflowSubflowRecord]
    public var studioDrafts: [DesktopWorkflowStudioDraftRecord]
    public var scheduleBindings: [DesktopWorkflowScheduleBindingRecord]
    public var migrationAssessments: [DesktopWorkflowMigrationAssessmentRecord]
    public var installations: [DesktopWorkflowInstallationRecord]
    public var configurationRevisions: [DesktopWorkflowConfigurationRevisionRecord]
    public var bindingRevisions: [DesktopWorkflowBindingRevisionRecord]
    public var dependencyLockRevisions: [DesktopWorkflowDependencyLockRevisionRecord]
    public var capturePolicyRevisions: [DesktopWorkflowCapturePolicyRevisionRecord]
    public var retentionPolicyRevisions: [DesktopWorkflowRetentionPolicyRevisionRecord]

    public static let empty = Self(
        definitions: [], revisions: [], triggerBindings: [], workItems: [], conversationBindings: [], episodes: [], runs: [],
        stepAttempts: [], facts: [], contextSnapshots: [], validations: [], effects: [], externalEvents: [], artifactEdges: [],
        stateRecords: [], artifactRoles: [],
        capabilityInstallations: DesktopWorkflowBuiltinCapabilities.installations(at: 0), runtimeClaims: [],
        transitionRecords: [], reviewRequests: [], waitSubscriptions: [], datasetRows: [], validatorReports: [],
        executionReceipts: [], authorityGrants: [], effectPreviews: [], triggerHealth: [], ownershipPolicies: [],
        ownershipClaims: [], connectorInstallations: [], connectorBindings: [], qualificationRuns: [],
        rendererInstallations: [], renderReceipts: [], subflows: [], studioDrafts: [], scheduleBindings: [],
        migrationAssessments: [], installations: [], configurationRevisions: [], bindingRevisions: [],
        dependencyLockRevisions: [], capturePolicyRevisions: [], retentionPolicyRevisions: []
    )

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case definitions, revisions, triggerBindings, workItems, conversationBindings, episodes, runs, stepAttempts, facts
        case contextSnapshots, validations, effects, externalEvents, artifactEdges, stateRecords, artifactRoles
        case capabilityInstallations, runtimeClaims, transitionRecords, reviewRequests, waitSubscriptions, datasetRows
        case validatorReports, executionReceipts, authorityGrants, effectPreviews, triggerHealth, ownershipPolicies
        case ownershipClaims, connectorInstallations, connectorBindings, qualificationRuns, rendererInstallations
        case renderReceipts, subflows, studioDrafts, scheduleBindings, migrationAssessments
        case installations, configurationRevisions, bindingRevisions, dependencyLockRevisions
        case capturePolicyRevisions, retentionPolicyRevisions
    }

}

extension DesktopWorkflowPlatformState {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try Self.decodeArray([DesktopWorkflowDefinitionRecord].self, key: .definitions, from: container)
        revisions = try Self.decodeArray([DesktopWorkflowRevisionRecord].self, key: .revisions, from: container)
        triggerBindings = try Self.decodeArray([DesktopWorkflowTriggerBindingRecord].self, key: .triggerBindings, from: container)
        workItems = try Self.decodeArray([DesktopWorkflowWorkItemRecord].self, key: .workItems, from: container)
        conversationBindings = try Self.decodeArray([DesktopWorkflowConversationBindingRecord].self, key: .conversationBindings, from: container)
        episodes = try Self.decodeArray([DesktopWorkflowEpisodeRecord].self, key: .episodes, from: container)
        runs = try Self.decodeArray([DesktopWorkflowRunRecord].self, key: .runs, from: container)
        stepAttempts = try Self.decodeArray([DesktopWorkflowStepAttemptRecord].self, key: .stepAttempts, from: container)
        facts = try Self.decodeArray([DesktopWorkflowFactRecord].self, key: .facts, from: container)
        contextSnapshots = try Self.decodeArray([DesktopWorkflowContextSnapshotRecord].self, key: .contextSnapshots, from: container)
        validations = try Self.decodeArray([DesktopWorkflowValidationRecord].self, key: .validations, from: container)
        effects = try Self.decodeArray([DesktopWorkflowEffectRecord].self, key: .effects, from: container)
        externalEvents = try Self.decodeArray([DesktopWorkflowExternalEventRecord].self, key: .externalEvents, from: container)
        artifactEdges = try Self.decodeArray([DesktopWorkflowArtifactEdgeRecord].self, key: .artifactEdges, from: container)
        stateRecords = try Self.decodeArray([DesktopWorkflowStateRecord].self, key: .stateRecords, from: container)
        artifactRoles = try Self.decodeArray([DesktopWorkflowArtifactRoleRecord].self, key: .artifactRoles, from: container)
        capabilityInstallations = try Self.decodeArray(
            [DesktopWorkflowCapabilityInstallationRecord].self, key: .capabilityInstallations, from: container
        )
        runtimeClaims = try Self.decodeArray([DesktopWorkflowRuntimeClaimRecord].self, key: .runtimeClaims, from: container)
        transitionRecords = try Self.decodeArray([DesktopWorkflowTransitionRecord].self, key: .transitionRecords, from: container)
        reviewRequests = try Self.decodeArray([DesktopWorkflowReviewRequestRecord].self, key: .reviewRequests, from: container)
        waitSubscriptions = try Self.decodeArray([DesktopWorkflowWaitSubscriptionRecord].self, key: .waitSubscriptions, from: container)
        datasetRows = try Self.decodeArray([DesktopWorkflowDatasetRowRecord].self, key: .datasetRows, from: container)
        validatorReports = try Self.decodeArray([DesktopWorkflowValidatorReportRecord].self, key: .validatorReports, from: container)
        executionReceipts = try Self.decodeArray([DesktopWorkflowExecutionReceiptRecord].self, key: .executionReceipts, from: container)
        authorityGrants = try Self.decodeArray([DesktopWorkflowAuthorityGrantRecord].self, key: .authorityGrants, from: container)
        effectPreviews = try Self.decodeArray([DesktopWorkflowEffectPreviewRecord].self, key: .effectPreviews, from: container)
        triggerHealth = try Self.decodeArray([DesktopWorkflowTriggerHealthRecord].self, key: .triggerHealth, from: container)
        ownershipPolicies = try Self.decodeArray([DesktopWorkflowOwnershipPolicyRecord].self, key: .ownershipPolicies, from: container)
        ownershipClaims = try Self.decodeArray([DesktopWorkflowOwnershipClaimRecord].self, key: .ownershipClaims, from: container)
        connectorInstallations = try Self.decodeArray([DesktopWorkflowConnectorInstallationRecord].self, key: .connectorInstallations, from: container)
        connectorBindings = try Self.decodeArray([DesktopWorkflowConnectorBindingRecord].self, key: .connectorBindings, from: container)
        qualificationRuns = try Self.decodeArray([DesktopWorkflowQualificationRunRecord].self, key: .qualificationRuns, from: container)
        rendererInstallations = try Self.decodeArray([DesktopWorkflowRendererInstallationRecord].self, key: .rendererInstallations, from: container)
        renderReceipts = try Self.decodeArray([DesktopWorkflowRenderReceiptRecord].self, key: .renderReceipts, from: container)
        subflows = try Self.decodeArray([DesktopWorkflowSubflowRecord].self, key: .subflows, from: container)
        studioDrafts = try Self.decodeArray([DesktopWorkflowStudioDraftRecord].self, key: .studioDrafts, from: container)
        scheduleBindings = try Self.decodeArray([DesktopWorkflowScheduleBindingRecord].self, key: .scheduleBindings, from: container)
        migrationAssessments = try Self.decodeArray([DesktopWorkflowMigrationAssessmentRecord].self, key: .migrationAssessments, from: container)
        installations = try Self.decodeArray([DesktopWorkflowInstallationRecord].self, key: .installations, from: container)
        configurationRevisions = try Self.decodeArray([DesktopWorkflowConfigurationRevisionRecord].self, key: .configurationRevisions, from: container)
        bindingRevisions = try Self.decodeArray([DesktopWorkflowBindingRevisionRecord].self, key: .bindingRevisions, from: container)
        dependencyLockRevisions = try Self.decodeArray([DesktopWorkflowDependencyLockRevisionRecord].self, key: .dependencyLockRevisions, from: container)
        capturePolicyRevisions = try Self.decodeArray([DesktopWorkflowCapturePolicyRevisionRecord].self, key: .capturePolicyRevisions, from: container)
        retentionPolicyRevisions = try Self.decodeArray([DesktopWorkflowRetentionPolicyRevisionRecord].self, key: .retentionPolicyRevisions, from: container)
    }

    private static func decodeArray<Element: Decodable>(
        _ type: [Element].Type,
        key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [Element] {
        try container.decodeIfPresent(type, forKey: key) ?? []
    }
}

public struct DesktopWorkflowPackageManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let summary: String
    public let icon: String
    public let version: String
    public let source: String
    public let license: String
    public let triggers: [DesktopWorkflowTriggerKind]
    public let steps: [DesktopWorkflowStepDefinition]
    public let permissions: DesktopWorkflowPermissionEnvelope
    public let correlationSummary: String
    public let contextSummary: String
    public let completionSummary: String
    public var datasets: [DesktopWorkflowDatasetDefinition]? = nil
    public var configurationSchema: String? = nil
    public var configurationSchemaVersion: Int? = nil
    public var manualRunInputSchema: String? = nil
    public var bindingSlots: [DesktopWorkflowBindingSlotDefinition]? = nil
    public var providerFeatures: [DesktopWorkflowProviderFeatureRequirement]? = nil
    public var hostCompatibility: DesktopWorkflowHostCompatibility? = nil
    public var dependencies: [DesktopWorkflowDependencyConstraint]? = nil
    public var publisher: DesktopWorkflowPublisher? = nil
    public var provenance: DesktopWorkflowPackageProvenance? = nil
    public var uiHints: [DesktopWorkflowUIHint]? = nil
    public var configurationMigrations: [DesktopWorkflowConfigurationMigration]? = nil

}

public enum DesktopWorkflowPackageError: Error, Equatable, LocalizedError {
    case oversized
    case invalidSchema
    case invalidIdentifier
    case invalidText
    case invalidSteps
    case duplicateStep
    case unsafeCapability
    case invalidPermission
    case permissionBroadening
    case invalidContract(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .oversized: "The workflow manifest exceeds the 256 KiB limit."
        case .invalidSchema: "The workflow manifest schema is not supported."
        case .invalidIdentifier: "The workflow or step identifier is invalid."
        case .invalidText: "The workflow manifest contains missing or oversized text."
        case .invalidSteps: "The workflow must contain between one and sixty-four ordered steps."
        case .duplicateStep: "Every workflow step must have a unique identifier."
        case .unsafeCapability: "The workflow refers to an unregistered or unsafe capability identifier."
        case .invalidPermission: "The workflow requests a permission that its steps do not justify."
        case .permissionBroadening: "This revision broadens authority and must be reviewed before enablement."
        case let .invalidContract(path, message): "The workflow contract is invalid at \(path.isEmpty ? "/" : path): \(message)"
        }
    }
}

public enum DesktopWorkflowPackageCodec {
    public static let maximumManifestBytes = 256 * 1_024

    public static func decode(_ data: Data, registeredCapabilityIDs: Set<String>) throws -> DesktopWorkflowPackageManifest {
        guard data.count <= maximumManifestBytes else { throw DesktopWorkflowPackageError.oversized }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let manifest = try decoder.decode(DesktopWorkflowPackageManifest.self, from: data)
        try validate(manifest, registeredCapabilityIDs: registeredCapabilityIDs)
        return manifest
    }

    public static func canonicalData(_ manifest: DesktopWorkflowPackageManifest) throws -> Data {
        try DesktopWorkflowCanonicalJSON.encode(manifest)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(
        _ manifest: DesktopWorkflowPackageManifest,
        registeredCapabilityIDs: Set<String>
    ) throws {
        guard (1...3).contains(manifest.schemaVersion) else {
            throw DesktopWorkflowPackageError.invalidSchema
        }
        guard validIdentifier(manifest.id), validVersion(manifest.version) else { throw DesktopWorkflowPackageError.invalidIdentifier }
        let text = [manifest.name, manifest.summary, manifest.source, manifest.license,
                    manifest.correlationSummary, manifest.contextSummary, manifest.completionSummary]
        guard text.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_192 }),
              manifest.icon.utf8.count <= 128 else { throw DesktopWorkflowPackageError.invalidText }
        guard (1...64).contains(manifest.steps.count) else { throw DesktopWorkflowPackageError.invalidSteps }
        let ids = manifest.steps.map(\.id)
        guard ids.allSatisfy(validIdentifier), Set(ids).count == ids.count else { throw DesktopWorkflowPackageError.duplicateStep }
        let capabilityIDs = manifest.steps.compactMap(\.capabilityID)
        guard capabilityIDs.allSatisfy({ validIdentifier($0) && registeredCapabilityIDs.contains($0) }) else {
            throw DesktopWorkflowPackageError.unsafeCapability
        }
        guard manifest.permissions.capabilityIDs.allSatisfy(registeredCapabilityIDs.contains) else {
            throw DesktopWorkflowPackageError.unsafeCapability
        }
        guard manifest.steps.allSatisfy({ step in
            guard let agent = step.agentPolicy else { return step.kind != .agent }
            let allowed = Set(agent.allowedCapabilityIDs)
            return step.kind == .agent && allowed.isSubset(of: registeredCapabilityIDs)
                && allowed.isSubset(of: Set(manifest.permissions.capabilityIDs))
        }) else {
            throw DesktopWorkflowPackageError.unsafeCapability
        }
        if manifest.steps.contains(where: { $0.kind == .sendEmail }),
           !manifest.permissions.permissions.contains(.emailSend) {
            throw DesktopWorkflowPackageError.invalidPermission
        }
        if manifest.steps.contains(where: { $0.kind == .createEmailDraft }),
           !manifest.permissions.permissions.contains(.emailDraft) {
            throw DesktopWorkflowPackageError.invalidPermission
        }
        if manifest.steps.contains(where: { $0.kind == .effect }),
           !manifest.permissions.permissions.contains(.externalEffects) {
            throw DesktopWorkflowPackageError.invalidPermission
        }
        guard manifest.steps.allSatisfy({ (0...5).contains($0.retryLimit) && ($0.isIdempotent || $0.retryLimit == 0) }) else {
            throw DesktopWorkflowPackageError.invalidSteps
        }
        guard manifest.steps.allSatisfy({ step in
            let artifactRoles = step.artifactInputs?.map(\.role) ?? []
            let stateKeys = step.stateInputs?.map { "\($0.namespace):\($0.key)" } ?? []
            return artifactRoles.allSatisfy(validIdentifier) && Set(artifactRoles).count == artifactRoles.count
                && (step.stateInputs ?? []).allSatisfy {
                    validIdentifier($0.namespace) && validIdentifier($0.key)
                }
                && Set(stateKeys).count == stateKeys.count
        }) else { throw DesktopWorkflowPackageError.invalidSteps }
        let stepIDs = Set(ids)
        do {
            try manifest.steps.forEach { try DesktopWorkflowHostContractValidation.validate(step: $0, stepIDs: stepIDs) }
            try (manifest.datasets ?? []).forEach(DesktopWorkflowHostContractValidation.validate)
        } catch {
            throw DesktopWorkflowPackageError.invalidSteps
        }
        guard Set((manifest.datasets ?? []).map(\.id)).count == (manifest.datasets ?? []).count else {
            throw DesktopWorkflowPackageError.invalidSteps
        }
        if manifest.schemaVersion == 2 {
            do { try DesktopWorkflowHostContractValidation.validateGraph(manifest.steps) }
            catch { throw DesktopWorkflowPackageError.invalidSteps }
        }
        if manifest.schemaVersion == 3 {
            do { try DesktopWorkflowHostContractValidation.validateGraph(manifest.steps) }
            catch { throw DesktopWorkflowPackageError.invalidSteps }
            try validateV3(manifest)
        }
    }

    private static func validateV3(_ manifest: DesktopWorkflowPackageManifest) throws {
        guard let compatibility = manifest.hostCompatibility,
              compatibility.minimumWorkspaceSchema > 0,
              compatibility.maximumWorkspaceSchema.map({ $0 >= compatibility.minimumWorkspaceSchema }) ?? true,
              let publisher = manifest.publisher,
              validIdentifier(publisher.identifier),
              !publisher.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.provenance != nil else {
            throw DesktopWorkflowPackageError.invalidContract(
                path: "/hostCompatibility", message: "Manifest v3 requires compatible host bounds, publisher identity, and provenance."
            )
        }
        if let schema = manifest.configurationSchema {
            guard let version = manifest.configurationSchemaVersion, version > 0 else {
                throw DesktopWorkflowPackageError.invalidContract(
                    path: "/configurationSchemaVersion", message: "A positive configuration schema version is required."
                )
            }
            try validateDeclaredSchema(schema, path: "/configurationSchema")
            if let secretPath = firstSecretConfigurationPath(schema) {
                throw DesktopWorkflowPackageError.invalidContract(
                    path: "/configurationSchema" + secretPath,
                    message: "Secret values must use a secret-reference binding slot, not configuration."
                )
            }
        } else if manifest.configurationSchemaVersion != nil {
            throw DesktopWorkflowPackageError.invalidContract(
                path: "/configurationSchema", message: "Configuration schema text is missing."
            )
        }
        if let manual = manifest.manualRunInputSchema {
            try validateDeclaredSchema(manual, path: "/manualRunInputSchema")
        }
        let slots = manifest.bindingSlots ?? []
        guard Set(slots.map(\.id)).count == slots.count,
              slots.allSatisfy({
                  validIdentifier($0.id) && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/bindingSlots", message: "Binding slots must have unique valid identifiers and user-facing text.")
        }
        let features = manifest.providerFeatures ?? []
        guard Set(features.map(\.id)).count == features.count,
              features.allSatisfy({ validIdentifier($0.id) && validIdentifier($0.providerKind) && validIdentifier($0.feature) }),
              slots.compactMap(\.providerFeatureID).allSatisfy(Set(features.map(\.id)).contains) else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/providerFeatures", message: "Provider feature declarations or slot references are invalid.")
        }
        let dependencies = manifest.dependencies ?? []
        guard Set(dependencies.map { "\($0.kind.rawValue):\($0.id)" }).count == dependencies.count,
              dependencies.allSatisfy({ validIdentifier($0.id) && validVersionRequirement($0.versionRequirement) }) else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/dependencies", message: "Dependency identifiers and version constraints must be unique and bounded.")
        }
        guard (manifest.uiHints ?? []).allSatisfy({ $0.pointer.hasPrefix("/") && $0.pointer.utf8.count <= 512 }),
              Set((manifest.uiHints ?? []).map(\.pointer)).count == (manifest.uiHints ?? []).count else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/uiHints", message: "UI hints must use unique JSON Pointer paths.")
        }
        let migrations = manifest.configurationMigrations ?? []
        guard migrations.allSatisfy({ migration in
            migration.fromVersion > 0 && migration.toVersion == migration.fromVersion + 1
                && !migration.operations.isEmpty
                && migration.operations.allSatisfy { operation in
                    operation.pointer.hasPrefix("/")
                        && (operation.kind != .rename || operation.destinationPointer?.hasPrefix("/") == true)
                        && (operation.kind != .setDefault || operation.value != nil)
                }
        }), Set(migrations.map(\.id)).count == migrations.count else {
            throw DesktopWorkflowPackageError.invalidContract(path: "/configurationMigrations", message: "Configuration migrations must advance one version using bounded pointer operations.")
        }
    }

    private static func validateDeclaredSchema(_ schema: String, path: String) throws {
        guard let data = schema.data(using: .utf8) else {
            throw DesktopWorkflowPackageError.invalidContract(path: path, message: "Schema is not UTF-8.")
        }
        if let issue = DesktopWorkflowJSONSchemaValidator.schemaDiagnostics(data, requireDeclaredDialect: true).first {
            throw DesktopWorkflowPackageError.invalidContract(path: path + issue.path, message: issue.message)
        }
    }

    private static func firstSecretConfigurationPath(_ schema: String) -> String? {
        guard let data = schema.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let forbidden = Set([
            "secret", "password", "token", "apikey", "api_key", "apitoken", "api_token",
            "accesstoken", "access_token", "credential", "clientsecret", "client_secret",
        ])
        func inspect(_ node: Any, path: String) -> String? {
            guard let object = node as? [String: Any] else { return nil }
            if let properties = object["properties"] as? [String: Any] {
                for (key, child) in properties.sorted(by: { $0.key < $1.key }) {
                    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                    if forbidden.contains(normalized) { return path + "/properties/" + key }
                    if let nested = inspect(child, path: path + "/properties/" + key) { return nested }
                }
            }
            if let definitions = object["$defs"] as? [String: Any] {
                for (key, child) in definitions.sorted(by: { $0.key < $1.key }) {
                    if let nested = inspect(child, path: path + "/$defs/" + key) { return nested }
                }
            }
            return nil
        }
        return inspect(root, path: "")
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
    }

    private static func validVersionRequirement(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.range(of: #"^[0-9A-Za-z.*+<>=~^|, -]+$"#, options: .regularExpression) != nil
    }
}

public enum DesktopWorkflowContextCompiler {
    public static func compile(
        workItem: DesktopWorkflowWorkItemRecord,
        episode: DesktopWorkflowEpisodeRecord,
        facts: [DesktopWorkflowFactRecord],
        references: [DesktopWorkflowContextReference],
        request: String,
        openQuestions: [String],
        negativeConstraints: [String],
        authority: DesktopWorkflowPermissionEnvelope,
        accountIDs: Set<String> = [],
        createdAtUnixMillis: Int64,
        tokenBudget: Int = 32_000
    ) -> DesktopWorkflowContextSnapshotRecord? {
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRequest.isEmpty else { return nil }
        let activeFacts = facts.filter {
            ($0.workItemID == workItem.id
                || ($0.scope == .installation && $0.workflowID == workItem.workflowID)
                || ($0.scope == .accountBinding && $0.workflowID == workItem.workflowID
                    && $0.scopeID.map(accountIDs.contains) == true))
                && $0.state == .verified
                && ($0.expiresAtUnixMillis == nil || $0.expiresAtUnixMillis! > createdAtUnixMillis)
        }
            .sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
        let factText = activeFacts.map {
            "\($0.key)=\($0.value) [verified; scope=\(($0.scope ?? .workItem).rawValue); sources=\($0.sourceReferenceIDs.sorted().joined(separator: ","))]"
        }.joined(separator: "\n")
        let normalizedReferences = references.map { reference -> DesktopWorkflowContextReference in
            var normalized = reference
            if let content = normalized.content {
                normalized.content = boundedUTF8(content, maximumBytes: 64_000)
                normalized.estimatedTokens = max(normalized.estimatedTokens, normalized.content!.utf8.count / 4)
            }
            return normalized
        }
        let prioritized = normalizedReferences.sorted {
            if $0.included != $1.included { return $0.included && !$1.included }
            return ($0.kind, $0.label, $0.id) < ($1.kind, $1.label, $1.id)
        }
        let fixedTokens = max(1, cleanRequest.utf8.count / 4)
            + max(1, factText.utf8.count / 4)
            + openQuestions.reduce(0) { $0 + max(1, $1.utf8.count / 4) }
            + negativeConstraints.reduce(0) { $0 + max(1, $1.utf8.count / 4) }
        var remaining = max(0, tokenBudget - fixedTokens)
        let boundedReferences = prioritized.map { reference -> DesktopWorkflowContextReference in
            var selected = reference
            if selected.included && selected.estimatedTokens > remaining {
                selected.included = false
                selected.reason = "Excluded because the declared context budget was exhausted."
            }
            if selected.included { remaining -= selected.estimatedTokens }
            return selected
        }
        let includedTokens = boundedReferences.filter(\.included).reduce(0) { $0 + $1.estimatedTokens }
        let superseded = facts.filter {
            ($0.workItemID == workItem.id
                || ($0.scope == .installation && $0.workflowID == workItem.workflowID)
                || ($0.scope == .accountBinding && $0.workflowID == workItem.workflowID
                    && $0.scopeID.map(accountIDs.contains) == true))
                && [.rejected, .superseded, .expired].contains($0.state)
        }
            .sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
            .map { "Do not use inactive knowledge \($0.key)=\($0.value)." }
        let compiledNegativeConstraints = Array(Set(negativeConstraints + superseded)).sorted()
        let authoritySummary = authority.permissions.map(\.label).joined(separator: ", ")
        let egressSummary = authority.dataClassesLeavingDevice.isEmpty
            ? "No declared data leaves the device."
            : authority.dataClassesLeavingDevice.joined(separator: ", ")
        struct DigestPayload: Encodable {
            let workItemID: String
            let episodeID: String
            let request: String
            let facts: String
            let references: [DesktopWorkflowContextReference]
            let openQuestions: [String]
            let negativeConstraints: [String]
            let authority: String
            let egress: String
        }
        let payload = DigestPayload(
            workItemID: workItem.id, episodeID: episode.id, request: cleanRequest, facts: factText,
            references: boundedReferences, openQuestions: openQuestions, negativeConstraints: compiledNegativeConstraints,
            authority: authoritySummary, egress: egressSummary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return DesktopWorkflowContextSnapshotRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItem.id, episodeID: episode.id,
            compilerVersion: 3, currentRequest: cleanRequest, openQuestions: openQuestions,
            negativeConstraints: compiledNegativeConstraints, references: boundedReferences,
            authoritySummary: authoritySummary.isEmpty ? "Read-only local workflow" : authoritySummary,
            dataEgressSummary: egressSummary,
            estimatedTokens: includedTokens + max(1, cleanRequest.utf8.count / 4) + max(1, factText.utf8.count / 4),
            digest: DesktopWorkflowPackageCodec.digest(data), createdAtUnixMillis: createdAtUnixMillis,
            knowledge: activeFacts.map {
                DesktopWorkflowContextKnowledge(
                    id: $0.id, key: $0.key, value: $0.value, scope: $0.scope ?? .workItem,
                    sourceReferenceIDs: $0.sourceReferenceIDs.sorted()
                )
            }
        )
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var usedBytes = 0
        return String(value.prefix { character in
            let characterBytes = String(character).utf8.count
            guard usedBytes + characterBytes <= maximumBytes else { return false }
            usedBytes += characterBytes
            return true
        })
    }
}
