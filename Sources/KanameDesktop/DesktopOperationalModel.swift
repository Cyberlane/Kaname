import Foundation
import KanameDomain

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

public struct DesktopVaultScopeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sourceID: String?
    public var path: String
    public var canRead: Bool
    public var canWrite: Bool
    public var lastReconciledAtUnixMillis: Int64?
}

public struct DesktopKnowledgeDocumentRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, CaseIterable, Equatable, Sendable {
        case projectMemory
        case decision
        case sourceInbox
        case research

        public var label: String {
            switch self {
            case .projectMemory: "Project memory"
            case .decision: "Decision"
            case .sourceInbox: "Source inbox"
            case .research: "Research"
            }
        }
    }

    public var id: String { path }
    public var projectID: String?
    public var path: String
    public var title: String
    public var digest: String
    public var role: Role?
    public var provenance: String
    public var sourceURLs: [String]
    public var wikilinks: [String]
    public var backlinks: [String]
    public var attachments: [String]
    public var properties: [String: String]
    public var lastReadAtUnixMillis: Int64
    public var conflictDigest: String?

    public init(path: String, title: String, digest: String, provenance: String, lastReadAtUnixMillis: Int64) {
        (self.path, self.title, self.digest) = (path, title, digest)
        (self.provenance, self.lastReadAtUnixMillis) = (provenance, lastReadAtUnixMillis)
        projectID = nil
        role = nil
        sourceURLs = []
        wikilinks = []
        backlinks = []
        attachments = []
        properties = [:]
        conflictDigest = nil
    }

    public mutating func replaceContext(
        projectID: String?,
        role: Role?,
        sourceURLs: [String],
        wikilinks: [String],
        backlinks: [String],
        attachments: [String],
        properties: [String: String],
        conflictDigest: String?
    ) {
        (self.projectID, self.role, self.conflictDigest) = (projectID, role, conflictDigest)
        self.sourceURLs = sourceURLs
        self.wikilinks = wikilinks
        self.backlinks = backlinks
        self.attachments = attachments
        self.properties = properties
    }
}

public struct DesktopKnowledgeWriteRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var proposalID: String
    public var approvalID: String?
    public var targetPath: String
    public var baseDigest: String
    public var proposedDigest: String
    public var diffSummary: String
    public var unifiedDiff: String
    public var state: DesktopActionState
    public var currentDigest: String?
    public var createdAtUnixMillis: Int64
    public var reconciledAtUnixMillis: Int64?
}

public struct DesktopCapabilityUpdateRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var capabilityID: String
    public var source: String
    public var previousRevision: String
    public var proposedRevision: String
    public var changeSummary: String
    public var state: DesktopActionState
    public var reviewedAtUnixMillis: Int64?
}

public struct DesktopMailActionRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case archive
        case trash
        case labels
        case createDraft
        case send

        public var label: String {
            switch self {
            case .archive: "Archive"
            case .trash: "Move to Trash"
            case .labels: "Change labels"
            case .createDraft: "Create Gmail draft"
            case .send: "Send email"
            }
        }
    }

    public let id: String
    public var accountID: String
    public var accountIdentity: String
    public var threadID: String?
    public var kind: Kind
    public var preview: String
    public var exactTarget: String
    public var approvalID: String?
    public var standingRuleID: String?
    public var state: DesktopActionState
    public var remoteReceipt: String?
    public var createdAtUnixMillis: Int64
    public var reconciledAtUnixMillis: Int64?
}

public struct DesktopMailStandingRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var accountID: String
    public var accountIdentity: String
    public var name: String
    public var query: String
    public var action: DesktopMailActionRecord.Kind
    public var enabled: Bool
    public var createdAtUnixMillis: Int64
}

public struct DesktopMailAttentionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(accountID):\(threadID)" }
    public var accountID: String
    public var threadID: String
    public var accountIdentity: String
    public var sender: String
    public var subject: String
    public var unread: Bool
    public var updatedAtUnixMillis: Int64
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

public enum DesktopProviderRunPurpose: String, Codable, Equatable, Sendable {
    case conversation
    case codingPlan
    case codingImplementation
}

private struct DesktopProviderRunPayload: Decodable {
    let id: String
    let threadID: String?
    let sourceMessageID: String?
    let provider: String
    let model: String
    let reasoningEffort: String?
    let runtimeMode: ConversationRuntimeMode?
    let networkAccess: Bool?
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
    let usesProjectContext: Bool?
    let workspacePathOverride: String?
    let purpose: DesktopProviderRunPurpose?
}

public struct DesktopProviderRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String?
    public var sourceMessageID: String?
    public var provider: String
    public var model: String
    public var reasoningEffort: String
    public var runtimeMode: ConversationRuntimeMode
    public var networkAccess: Bool
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
    public var usesProjectContext: Bool? = nil
    public var workspacePathOverride: String? = nil
    public var purpose: DesktopProviderRunPurpose = .conversation

    public init(
        id: String,
        threadID: String?,
        sourceMessageID: String? = nil,
        provider: String,
        model: String,
        reasoningEffort: String = "xhigh",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false,
        briefDigest: String,
        contextReferenceCount: Int,
        nativeThreadID: String? = nil,
        nativeTurnID: String? = nil,
        tokenUsage: Int?,
        costSummary: String,
        errorSummary: String? = nil,
        state: DesktopActionState,
        startedAtUnixMillis: Int64,
        completedAtUnixMillis: Int64?,
        usesProjectContext: Bool? = nil,
        workspacePathOverride: String? = nil,
        purpose: DesktopProviderRunPurpose = .conversation
    ) {
        self.id = id
        self.threadID = threadID
        self.sourceMessageID = sourceMessageID
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.runtimeMode = runtimeMode
        self.networkAccess = networkAccess
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
        self.usesProjectContext = usesProjectContext
        self.workspacePathOverride = workspacePathOverride
        self.purpose = purpose
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DesktopProviderRunPayload(from: decoder)
        id = payload.id
        threadID = payload.threadID
        sourceMessageID = payload.sourceMessageID
        provider = payload.provider
        model = payload.model
        reasoningEffort = payload.reasoningEffort ?? "xhigh"
        runtimeMode = payload.runtimeMode ?? .approvalRequired
        networkAccess = payload.networkAccess ?? false
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
        usesProjectContext = payload.usesProjectContext
        workspacePathOverride = payload.workspacePathOverride
        purpose = payload.purpose ?? .conversation
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
    public var deduplicationKey: String? = nil
    public var ownerID: String? = nil
    public var wasMissed: Bool? = nil
    public var approvalID: String? = nil
    public var threadID: String? = nil
    public var providerRunID: String? = nil
    public var notificationState: String? = nil
    public var contractTarget: String? = nil
    public var exactTarget: String? = nil
    public var workspacePath: String? = nil
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
    public var composerAttachmentDrafts: [String: [ConversationImageAttachment]]
    public var comparisons: [DesktopComparisonRecord]
    public var automationRuns: [DesktopAutomationRunRecord]
    public var providerSessions: [DesktopProviderSessionRecord]
    public var worktrees: [DesktopWorktreeRecord]
    public var subagents: [DesktopSubagentRecord]
    public var comparisonDecisions: [DesktopComparisonDecisionRecord]
    public var pullRequests: [DesktopPullRequestRecord]
    public var qualityGates: [DesktopQualityGateRecord]
    public var vaultScopes: [DesktopVaultScopeRecord]
    public var knowledgeDocuments: [DesktopKnowledgeDocumentRecord]
    public var knowledgeWrites: [DesktopKnowledgeWriteRecord]
    public var capabilityUpdates: [DesktopCapabilityUpdateRecord]
    public var mailActions: [DesktopMailActionRecord]
    public var mailStandingRules: [DesktopMailStandingRule]
    public var mailAttention: [DesktopMailAttentionRecord]
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
        composerAttachmentDrafts: [:],
        comparisons: [],
        automationRuns: [],
        providerSessions: [],
        worktrees: [],
        subagents: [],
        comparisonDecisions: [],
        pullRequests: [],
        qualityGates: [],
        vaultScopes: [],
        knowledgeDocuments: [],
        knowledgeWrites: [],
        capabilityUpdates: [],
        mailActions: [],
        mailStandingRules: [],
        mailAttention: [],
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
        case composerAttachmentDrafts
        case comparisons
        case automationRuns
        case providerSessions
        case worktrees
        case subagents
        case comparisonDecisions
        case pullRequests
        case qualityGates
        case vaultScopes
        case knowledgeDocuments
        case knowledgeWrites
        case capabilityUpdates
        case mailActions
        case mailStandingRules
        case mailAttention
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
        composerAttachmentDrafts: [String: [ConversationImageAttachment]] = [:],
        comparisons: [DesktopComparisonRecord],
        automationRuns: [DesktopAutomationRunRecord],
        providerSessions: [DesktopProviderSessionRecord],
        worktrees: [DesktopWorktreeRecord],
        subagents: [DesktopSubagentRecord],
        comparisonDecisions: [DesktopComparisonDecisionRecord],
        pullRequests: [DesktopPullRequestRecord],
        qualityGates: [DesktopQualityGateRecord],
        vaultScopes: [DesktopVaultScopeRecord] = [],
        knowledgeDocuments: [DesktopKnowledgeDocumentRecord] = [],
        knowledgeWrites: [DesktopKnowledgeWriteRecord] = [],
        capabilityUpdates: [DesktopCapabilityUpdateRecord] = [],
        mailActions: [DesktopMailActionRecord] = [],
        mailStandingRules: [DesktopMailStandingRule] = [],
        mailAttention: [DesktopMailAttentionRecord] = [],
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
        self.composerAttachmentDrafts = composerAttachmentDrafts
        self.comparisons = comparisons
        self.automationRuns = automationRuns
        self.providerSessions = providerSessions
        self.worktrees = worktrees
        self.subagents = subagents
        self.comparisonDecisions = comparisonDecisions
        self.pullRequests = pullRequests
        self.qualityGates = qualityGates
        self.vaultScopes = vaultScopes
        self.knowledgeDocuments = knowledgeDocuments
        self.knowledgeWrites = knowledgeWrites
        self.capabilityUpdates = capabilityUpdates
        self.mailActions = mailActions
        self.mailStandingRules = mailStandingRules
        self.mailAttention = mailAttention
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
        composerAttachmentDrafts = try container.decodeIfPresent(
            [String: [ConversationImageAttachment]].self,
            forKey: .composerAttachmentDrafts
        ) ?? [:]
        comparisons = try container.decode([DesktopComparisonRecord].self, forKey: .comparisons)
        automationRuns = try container.decode([DesktopAutomationRunRecord].self, forKey: .automationRuns)
        providerSessions = try container.decodeIfPresent([DesktopProviderSessionRecord].self, forKey: .providerSessions) ?? []
        worktrees = try container.decodeIfPresent([DesktopWorktreeRecord].self, forKey: .worktrees) ?? []
        subagents = try container.decodeIfPresent([DesktopSubagentRecord].self, forKey: .subagents) ?? []
        comparisonDecisions = try container.decodeIfPresent([DesktopComparisonDecisionRecord].self, forKey: .comparisonDecisions) ?? []
        pullRequests = try container.decodeIfPresent([DesktopPullRequestRecord].self, forKey: .pullRequests) ?? []
        qualityGates = try container.decodeIfPresent([DesktopQualityGateRecord].self, forKey: .qualityGates) ?? []
        vaultScopes = try container.decodeIfPresent([DesktopVaultScopeRecord].self, forKey: .vaultScopes) ?? []
        knowledgeDocuments = try container.decodeIfPresent([DesktopKnowledgeDocumentRecord].self, forKey: .knowledgeDocuments) ?? []
        knowledgeWrites = try container.decodeIfPresent([DesktopKnowledgeWriteRecord].self, forKey: .knowledgeWrites) ?? []
        capabilityUpdates = try container.decodeIfPresent([DesktopCapabilityUpdateRecord].self, forKey: .capabilityUpdates) ?? []
        mailActions = try container.decodeIfPresent([DesktopMailActionRecord].self, forKey: .mailActions) ?? []
        mailStandingRules = try container.decodeIfPresent([DesktopMailStandingRule].self, forKey: .mailStandingRules) ?? []
        mailAttention = try container.decodeIfPresent([DesktopMailAttentionRecord].self, forKey: .mailAttention) ?? []
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
