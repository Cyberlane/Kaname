import Foundation

public enum DesktopActionState: String, Codable, CaseIterable, Equatable, Sendable {
    case proposed
    case awaitingApproval
    case approved
    case rejected
    case running
    case completed
    case failed
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
        case .reconciled: "Reconciled"
        case .cancelled: "Cancelled"
        }
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

public struct DesktopProviderRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String?
    public var provider: String
    public var model: String
    public var briefDigest: String
    public var contextReferenceCount: Int
    public var tokenUsage: Int?
    public var costSummary: String
    public var state: DesktopActionState
    public var startedAtUnixMillis: Int64
    public var completedAtUnixMillis: Int64?
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
        comparisons: [],
        automationRuns: [],
        audit: []
    )
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
