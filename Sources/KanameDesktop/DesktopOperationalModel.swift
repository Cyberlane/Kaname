import Foundation

public enum DesktopActionState: String, Codable, CaseIterable, Equatable, Sendable {
    case proposed
    case awaitingApproval
    case approved
    case rejected
    case running
    case completed
    case failed
    case interrupted
    case reconciled
    case cancelled

    public var label: String {
        switch self {
        case .proposed: "Proposed"
        case .awaitingApproval: "Awaiting approval"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .reconciled: "Reconciled"
        case .cancelled: "Cancelled"
        }
    }
}

public enum DesktopProviderEventKind: String, Codable, Equatable, Sendable {
    case status
    case assistantText
    case reasoning
    case tool
    case question
    case approval
    case diff
    case usage
    case error
    case native
}

public struct DesktopProviderEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var runID: String
    public var kind: DesktopProviderEventKind
    public var title: String
    public var detail: String
    public var nativeType: String
    public var nativeThreadID: String?
    public var nativeTurnID: String?
    public var approvalID: String?
    public var rawPayloadBase64: String?
    public var payloadWasTruncated: Bool
    public var createdAtUnixMillis: Int64

    public init(
        id: String,
        threadID: String,
        runID: String,
        kind: DesktopProviderEventKind,
        title: String,
        detail: String,
        nativeType: String,
        nativeThreadID: String?,
        nativeTurnID: String?,
        approvalID: String?,
        rawPayloadBase64: String?,
        payloadWasTruncated: Bool,
        createdAtUnixMillis: Int64
    ) {
        self.id = id
        self.threadID = threadID
        self.runID = runID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.nativeType = nativeType
        self.nativeThreadID = nativeThreadID
        self.nativeTurnID = nativeTurnID
        self.approvalID = approvalID
        self.rawPayloadBase64 = rawPayloadBase64
        self.payloadWasTruncated = payloadWasTruncated
        self.createdAtUnixMillis = createdAtUnixMillis
    }
}

public struct DesktopResearchSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var researchID: String
    public var title: String
    public var location: String
    public var publisher: String
    public var isPrimary: Bool
    public var retrievedAtUnixMillis: Int64
    public var note: String
}

public struct DesktopKnowledgeProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var knowledgeSourceID: String?
    public var title: String
    public var target: String
    public var summary: String
    public var proposedContent: String
    public var baseRevision: String
    public var state: DesktopActionState
    public var createdAtUnixMillis: Int64
}

public struct DesktopArtifactRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case file
        case diff
        case report
        case image
        case log

        public var label: String { rawValue.capitalized }
    }

    public let id: String
    public var threadID: String?
    public var name: String
    public var kind: Kind
    public var localPath: String
    public var digest: String
    public var provenance: String
    public var createdAtUnixMillis: Int64
}

public struct DesktopApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String?
    public var title: String
    public var exactTarget: String
    public var consequence: String
    public var dataLeavingDevice: String
    public var reversible: Bool
    public var state: DesktopActionState
    public var requestedAtUnixMillis: Int64
    public var expiresAtUnixMillis: Int64?
}

public struct DesktopGitStackLayer: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workspaceID: String
    public var title: String
    public var branch: String
    public var baseBranch: String
    public var pullRequestURL: String?
    public var checkSummary: String
    public var reviewSummary: String
    public var state: DesktopActionState
    public var dependsOnLayerID: String?
}

private struct DesktopProviderRunPayload: Decodable {
    let id: String
    let threadID: String?
    let sourceMessageID: String?
    let provider: String
    let model: String
    let reasoningEffort: String?
    let briefDigest: String
    let contextReferenceCount: Int
    let nativeThreadID: String?
    let nativeTurnID: String?
    let tokenUsage: Int?
    let costSummary: String
    let errorSummary: String?
    let state: DesktopActionState
    let startedAtUnixMillis: Int64
    let completedAtUnixMillis: Int64?
}

public struct DesktopProviderRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String?
    public var sourceMessageID: String?
    public var provider: String
    public var model: String
    public var reasoningEffort: String
    public var briefDigest: String
    public var contextReferenceCount: Int
    public var nativeThreadID: String?
    public var nativeTurnID: String?
    public var tokenUsage: Int?
    public var costSummary: String
    public var errorSummary: String?
    public var state: DesktopActionState
    public var startedAtUnixMillis: Int64
    public var completedAtUnixMillis: Int64?

    public init(
        id: String,
        threadID: String?,
        sourceMessageID: String? = nil,
        provider: String,
        model: String,
        reasoningEffort: String = "xhigh",
        briefDigest: String,
        contextReferenceCount: Int,
        nativeThreadID: String? = nil,
        nativeTurnID: String? = nil,
        tokenUsage: Int?,
        costSummary: String,
        errorSummary: String? = nil,
        state: DesktopActionState,
        startedAtUnixMillis: Int64,
        completedAtUnixMillis: Int64?
    ) {
        self.id = id
        self.threadID = threadID
        self.sourceMessageID = sourceMessageID
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.briefDigest = briefDigest
        self.contextReferenceCount = contextReferenceCount
        self.nativeThreadID = nativeThreadID
        self.nativeTurnID = nativeTurnID
        self.tokenUsage = tokenUsage
        self.costSummary = costSummary
        self.errorSummary = errorSummary
        self.state = state
        self.startedAtUnixMillis = startedAtUnixMillis
        self.completedAtUnixMillis = completedAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DesktopProviderRunPayload(from: decoder)
        id = payload.id
        threadID = payload.threadID
        sourceMessageID = payload.sourceMessageID
        provider = payload.provider
        model = payload.model
        reasoningEffort = payload.reasoningEffort ?? "xhigh"
        briefDigest = payload.briefDigest
        contextReferenceCount = payload.contextReferenceCount
        nativeThreadID = payload.nativeThreadID
        nativeTurnID = payload.nativeTurnID
        tokenUsage = payload.tokenUsage
        costSummary = payload.costSummary
        errorSummary = payload.errorSummary
        state = payload.state
        startedAtUnixMillis = payload.startedAtUnixMillis
        completedAtUnixMillis = payload.completedAtUnixMillis
    }
}

public struct DesktopComparisonRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var brief: String
    public var runIDs: [String]
    public var state: DesktopActionState
    public var createdAtUnixMillis: Int64
}

public struct DesktopAutomationRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var automationID: String
    public var scheduledAtUnixMillis: Int64
    public var startedAtUnixMillis: Int64?
    public var completedAtUnixMillis: Int64?
    public var state: DesktopActionState
    public var detail: String
    public var evidenceArtifactIDs: [String]
}

public struct DesktopAuditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var domain: String
    public var action: String
    public var target: String
    public var state: DesktopActionState
    public var detail: String
    public var recordedAtUnixMillis: Int64
}

public struct DesktopOperationalSnapshot: Codable, Equatable, Sendable {
    public var researchSources: [DesktopResearchSource]
    public var knowledgeProposals: [DesktopKnowledgeProposal]
    public var artifacts: [DesktopArtifactRecord]
    public var approvals: [DesktopApprovalRecord]
    public var gitStackLayers: [DesktopGitStackLayer]
    public var providerRuns: [DesktopProviderRunRecord]
    public var providerEvents: [DesktopProviderEventRecord]
    public var composerDrafts: [String: String]
    public var comparisons: [DesktopComparisonRecord]
    public var automationRuns: [DesktopAutomationRunRecord]
    public var audit: [DesktopAuditRecord]

    public static let empty = DesktopOperationalSnapshot(
        researchSources: [],
        knowledgeProposals: [],
        artifacts: [],
        approvals: [],
        gitStackLayers: [],
        providerRuns: [],
        providerEvents: [],
        composerDrafts: [:],
        comparisons: [],
        automationRuns: [],
        audit: []
    )

    private enum CodingKeys: String, CodingKey {
        case researchSources
        case knowledgeProposals
        case artifacts
        case approvals
        case gitStackLayers
        case providerRuns
        case providerEvents
        case composerDrafts
        case comparisons
        case automationRuns
        case audit
    }

    public init(
        researchSources: [DesktopResearchSource],
        knowledgeProposals: [DesktopKnowledgeProposal],
        artifacts: [DesktopArtifactRecord],
        approvals: [DesktopApprovalRecord],
        gitStackLayers: [DesktopGitStackLayer],
        providerRuns: [DesktopProviderRunRecord],
        providerEvents: [DesktopProviderEventRecord],
        composerDrafts: [String: String],
        comparisons: [DesktopComparisonRecord],
        automationRuns: [DesktopAutomationRunRecord],
        audit: [DesktopAuditRecord]
    ) {
        self.researchSources = researchSources
        self.knowledgeProposals = knowledgeProposals
        self.artifacts = artifacts
        self.approvals = approvals
        self.gitStackLayers = gitStackLayers
        self.providerRuns = providerRuns
        self.providerEvents = providerEvents
        self.composerDrafts = composerDrafts
        self.comparisons = comparisons
        self.automationRuns = automationRuns
        self.audit = audit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        researchSources = try container.decode([DesktopResearchSource].self, forKey: .researchSources)
        knowledgeProposals = try container.decode([DesktopKnowledgeProposal].self, forKey: .knowledgeProposals)
        artifacts = try container.decode([DesktopArtifactRecord].self, forKey: .artifacts)
        approvals = try container.decode([DesktopApprovalRecord].self, forKey: .approvals)
        gitStackLayers = try container.decode([DesktopGitStackLayer].self, forKey: .gitStackLayers)
        providerRuns = try container.decode([DesktopProviderRunRecord].self, forKey: .providerRuns)
        providerEvents = try container.decodeIfPresent([DesktopProviderEventRecord].self, forKey: .providerEvents) ?? []
        composerDrafts = try container.decodeIfPresent([String: String].self, forKey: .composerDrafts) ?? [:]
        comparisons = try container.decode([DesktopComparisonRecord].self, forKey: .comparisons)
        automationRuns = try container.decode([DesktopAutomationRunRecord].self, forKey: .automationRuns)
        audit = try container.decode([DesktopAuditRecord].self, forKey: .audit)
    }
}

public struct DesktopDiagnosticsReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAtUnixMillis: Int64
    public let projectCount: Int
    public let activeThreadCount: Int
    public let archivedThreadCount: Int
    public let unreadThreadCount: Int
    public let pendingApprovalCount: Int
    public let researchCount: Int
    public let emailDraftCount: Int
    public let calendarProposalCount: Int
    public let automationCount: Int
    public let artifactCount: Int
    public let auditRecordCount: Int
    public let safeMode: Bool
    public let persistenceHealthy: Bool
    public let relayState: String
    public let queueState: String
}
