import Foundation

public enum DesktopProviderSessionState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case running
    case recoverable
    case interrupted
    case unsupported

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .running: "Running"
        case .recoverable: "Recoverable"
        case .interrupted: "Interrupted"
        case .unsupported: "Unsupported"
        }
    }
}

public struct DesktopProviderSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var provider: String
    public var nativeSessionID: String
    public var source: String
    public var capabilities: [String]
    public var limitations: [String]
    public var state: DesktopProviderSessionState
    public var lastReconciledAtUnixMillis: Int64

    public func supports(capability: String) -> Bool {
        capabilities.contains { $0.caseInsensitiveCompare(capability) == .orderedSame }
    }

    public func capabilityStatus(for capability: String) -> String {
        if supports(capability: capability) {
            return state == .unsupported
                ? "Declared by \(provider), but the current session is unsupported."
                : "Available in this \(provider) session."
        }
        if let limitation = limitations.first(where: {
            $0.localizedCaseInsensitiveContains(capability)
        }) {
            return limitation
        }
        return "\(provider) did not declare \(capability) for this reconciled session."
    }

}

public enum DesktopWorktreeState: String, Codable, CaseIterable, Equatable, Sendable {
    case proposed
    case preparing
    case ready
    case dirty
    case review
    case accepted
    case cleanupPending
    case removed
    case failed

    public var label: String { rawValue.capitalized }
}

public struct DesktopWorktreeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var projectID: String
    public var threadID: String
    public var rootWorkspacePath: String
    public var worktreePath: String
    public var branch: String
    public var baseRevision: String
    public var headRevision: String?
    public var changedFileCount: Int
    public var diffSummary: String
    public var testCommand: String
    public var testSummary: String
    public var diagnosticSummary: String
    public var state: DesktopWorktreeState
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
}

public enum DesktopSubagentState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case waiting
    case completed
    case failed
    case interrupted

    public var label: String { rawValue.capitalized }
}

public struct DesktopSubagentRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var runID: String
    public var parentID: String?
    public var provider: String
    public var title: String
    public var detail: String
    public var state: DesktopSubagentState
    public var startedAtUnixMillis: Int64
    public var completedAtUnixMillis: Int64?
}

public struct DesktopComparisonDecisionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var comparisonID: String
    public var frozenContextDigest: String
    public var selectedRunID: String?
    public var continuedThreadID: String?
    public var decidedAtUnixMillis: Int64?
}

public struct DesktopPullRequestRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var workspaceID: String
    public var repository: String
    public var number: Int
    public var title: String
    public var url: String
    public var headBranch: String
    public var baseBranch: String
    public var checkSummary: String
    public var reviewSummary: String
    public var mergeAfterIDs: [String]
    public var state: DesktopActionState
    public var lastReconciledAtUnixMillis: Int64

}

public typealias DesktopPullRequestReconciliation = (
    repository: String,
    number: Int,
    title: String,
    url: String,
    headBranch: String,
    baseBranch: String,
    checkSummary: String,
    reviewSummary: String,
    mergeAfterIDs: [String],
    state: DesktopActionState,
    reconciledAtUnixMillis: Int64
)

public enum DesktopQualityGateKind: String, Codable, CaseIterable, Equatable, Sendable {
    case tests
    case diagnostics
    case mori
    case lode
    case context
    case knowledge

    public var label: String { rawValue.capitalized }
}

public struct DesktopQualityGateRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var threadID: String
    public var worktreeID: String?
    public var kind: DesktopQualityGateKind
    public var command: String
    public var summary: String
    public var state: DesktopActionState
    public var artifactIDs: [String]
    public var recordedAtUnixMillis: Int64
}
