import Foundation

public struct Thread: Codable, Equatable, Sendable {
    public let id: KanameID
    public let title: String
    public let workspaceKind: WorkspaceKind

    public init(id: KanameID, title: String, workspaceKind: WorkspaceKind) {
        self.id = id
        self.title = title
        self.workspaceKind = workspaceKind
    }
}

public enum WorkspaceKind: String, CaseIterable, Codable, Sendable {
    case coding
    case research
    case knowledge
    case email
    case calendar
}

public enum TaskState: String, CaseIterable, Codable, Sendable {
    case notStarted
    case queued
    case starting
    case running
    case waitingForUser
    case completed
    case accepted
    case failed
    case cancelled
    case interrupted
}

public enum AttentionState: String, CaseIterable, Codable, Sendable {
    case none
    case queued
    case running
    case needsResponse
    case needsReview
    case failed
    case interrupted
}

public enum ApprovalAction: String, CaseIterable, Codable, Sendable {
    case codeChange
    case sendEmail
    case modifyCalendar
}

public enum ApprovalStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case approved
    case rejected
    case expired
}

public struct Approval: Codable, Equatable, Sendable {
    public let id: KanameID
    public let action: ApprovalAction
    public let status: ApprovalStatus
    public let target: String
    public let consequence: String
    public let expiresAt: Date?

    public init(
        id: KanameID,
        action: ApprovalAction,
        status: ApprovalStatus,
        target: String,
        consequence: String,
        expiresAt: Date?
    ) {
        self.id = id
        self.action = action
        self.status = status
        self.target = target
        self.consequence = consequence
        self.expiresAt = expiresAt
    }
}
