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

    public init(
        id: String,
        name: String,
        kind: DesktopWorkflowStepKind,
        capabilityID: String? = nil,
        inputSchemaReference: String? = nil,
        outputSchemaReference: String? = nil,
        retryLimit: Int = 0,
        isIdempotent: Bool = true,
        blocking: Bool = true
    ) {
        (self.id, self.name, self.kind) = (id, name, kind)
        (self.capabilityID, self.inputSchemaReference, self.outputSchemaReference) = (
            capabilityID, inputSchemaReference, outputSchemaReference
        )
        (self.retryLimit, self.isIdempotent, self.blocking) = (retryLimit, isIdempotent, blocking)
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

    public static func reference(
        id: String,
        kind: String,
        label: String,
        sourceID: String,
        digest: String,
        included: Bool,
        reason: String,
        estimatedTokens: Int
    ) -> Self {
        let boundedTokenEstimate = max(0, estimatedTokens)
        let explanation = reason.isEmpty ? "No selection explanation supplied." : reason
        return Self(
            id: id, kind: kind, label: label, sourceID: sourceID, digest: digest,
            included: included, reason: explanation, estimatedTokens: boundedTokenEstimate
        )
    }
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

    public static let empty = Self(
        definitions: [], revisions: [], triggerBindings: [], workItems: [], conversationBindings: [], episodes: [], runs: [],
        stepAttempts: [], facts: [], contextSnapshots: [], validations: [], effects: [], externalEvents: [], artifactEdges: []
    )

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case definitions, revisions, triggerBindings, workItems, conversationBindings, episodes, runs, stepAttempts, facts
        case contextSnapshots, validations, effects, externalEvents, artifactEdges
    }

    public init(
        definitions: [DesktopWorkflowDefinitionRecord], revisions: [DesktopWorkflowRevisionRecord],
        triggerBindings: [DesktopWorkflowTriggerBindingRecord],
        workItems: [DesktopWorkflowWorkItemRecord], conversationBindings: [DesktopWorkflowConversationBindingRecord],
        episodes: [DesktopWorkflowEpisodeRecord], runs: [DesktopWorkflowRunRecord],
        stepAttempts: [DesktopWorkflowStepAttemptRecord], facts: [DesktopWorkflowFactRecord],
        contextSnapshots: [DesktopWorkflowContextSnapshotRecord], validations: [DesktopWorkflowValidationRecord],
        effects: [DesktopWorkflowEffectRecord], externalEvents: [DesktopWorkflowExternalEventRecord],
        artifactEdges: [DesktopWorkflowArtifactEdgeRecord]
    ) {
        (self.definitions, self.revisions, self.triggerBindings) = (definitions, revisions, triggerBindings)
        (self.workItems, self.conversationBindings, self.episodes) = (workItems, conversationBindings, episodes)
        (self.runs, self.stepAttempts, self.facts) = (runs, stepAttempts, facts)
        (self.contextSnapshots, self.validations, self.effects) = (contextSnapshots, validations, effects)
        (self.externalEvents, self.artifactEdges) = (externalEvents, artifactEdges)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try container.decodeIfPresent([DesktopWorkflowDefinitionRecord].self, forKey: .definitions) ?? []
        revisions = try container.decodeIfPresent([DesktopWorkflowRevisionRecord].self, forKey: .revisions) ?? []
        triggerBindings = try container.decodeIfPresent([DesktopWorkflowTriggerBindingRecord].self, forKey: .triggerBindings) ?? []
        workItems = try container.decodeIfPresent([DesktopWorkflowWorkItemRecord].self, forKey: .workItems) ?? []
        conversationBindings = try container.decodeIfPresent([DesktopWorkflowConversationBindingRecord].self, forKey: .conversationBindings) ?? []
        episodes = try container.decodeIfPresent([DesktopWorkflowEpisodeRecord].self, forKey: .episodes) ?? []
        runs = try container.decodeIfPresent([DesktopWorkflowRunRecord].self, forKey: .runs) ?? []
        stepAttempts = try container.decodeIfPresent([DesktopWorkflowStepAttemptRecord].self, forKey: .stepAttempts) ?? []
        facts = try container.decodeIfPresent([DesktopWorkflowFactRecord].self, forKey: .facts) ?? []
        contextSnapshots = try container.decodeIfPresent([DesktopWorkflowContextSnapshotRecord].self, forKey: .contextSnapshots) ?? []
        validations = try container.decodeIfPresent([DesktopWorkflowValidationRecord].self, forKey: .validations) ?? []
        effects = try container.decodeIfPresent([DesktopWorkflowEffectRecord].self, forKey: .effects) ?? []
        externalEvents = try container.decodeIfPresent([DesktopWorkflowExternalEventRecord].self, forKey: .externalEvents) ?? []
        artifactEdges = try container.decodeIfPresent([DesktopWorkflowArtifactEdgeRecord].self, forKey: .artifactEdges) ?? []
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(
        _ manifest: DesktopWorkflowPackageManifest,
        registeredCapabilityIDs: Set<String>
    ) throws {
        guard manifest.schemaVersion == 1 else { throw DesktopWorkflowPackageError.invalidSchema }
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
        if manifest.steps.contains(where: { $0.kind == .sendEmail }),
           !manifest.permissions.permissions.contains(.emailSend) {
            throw DesktopWorkflowPackageError.invalidPermission
        }
        if manifest.steps.contains(where: { $0.kind == .createEmailDraft }),
           !manifest.permissions.permissions.contains(.emailDraft) {
            throw DesktopWorkflowPackageError.invalidPermission
        }
        guard manifest.steps.allSatisfy({ (0...5).contains($0.retryLimit) && ($0.isIdempotent || $0.retryLimit == 0) }) else {
            throw DesktopWorkflowPackageError.invalidSteps
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil
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
        createdAtUnixMillis: Int64,
        tokenBudget: Int = 32_000
    ) -> DesktopWorkflowContextSnapshotRecord? {
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRequest.isEmpty else { return nil }
        let activeFacts = facts.filter { $0.workItemID == workItem.id && ($0.state == .verified || $0.state == .proposed) }
            .sorted { ($0.key, $0.createdAtUnixMillis, $0.id) < ($1.key, $1.createdAtUnixMillis, $1.id) }
        let prioritized = references.sorted {
            if $0.included != $1.included { return $0.included && !$1.included }
            return ($0.kind, $0.label, $0.id) < ($1.kind, $1.label, $1.id)
        }
        var remaining = max(0, tokenBudget - max(1, cleanRequest.utf8.count / 4))
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
        let factText = activeFacts.map { "\($0.key)=\($0.value) [\($0.state.rawValue)]" }.joined(separator: "\n")
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
            references: boundedReferences, openQuestions: openQuestions, negativeConstraints: negativeConstraints,
            authority: authoritySummary, egress: egressSummary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        return DesktopWorkflowContextSnapshotRecord(
            id: UUID().uuidString.lowercased(), workItemID: workItem.id, episodeID: episode.id,
            compilerVersion: 1, currentRequest: cleanRequest, openQuestions: openQuestions,
            negativeConstraints: negativeConstraints, references: boundedReferences,
            authoritySummary: authoritySummary.isEmpty ? "Read-only local workflow" : authoritySummary,
            dataEgressSummary: egressSummary,
            estimatedTokens: includedTokens + max(1, cleanRequest.utf8.count / 4) + max(1, factText.utf8.count / 4),
            digest: DesktopWorkflowPackageCodec.digest(data), createdAtUnixMillis: createdAtUnixMillis
        )
    }
}
