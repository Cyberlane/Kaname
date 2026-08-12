import Foundation

/// The durable macOS workspace schema shared by persistence and update
/// compatibility checks. Keeping this in KanameDomain prevents an updater from
/// duplicating a security-sensitive version number owned by the desktop model.
public enum KanameDesktopStateSchema {
    public static let currentVersion = 19
}

/// A provider-neutral description of how much autonomy one conversation has.
/// Adapters translate these stable product modes into their native permission
/// and sandbox controls rather than leaking one provider's flags into storage.
public enum ConversationRuntimeMode: String, Codable, CaseIterable, Equatable, Sendable {
    case approvalRequired
    case autoAcceptEdits
    case auto
    case fullAccess
}

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

public struct Task: Codable, Equatable, Sendable {
    public let id: KanameID
    public let threadID: KanameID
    public let title: String

    public init(id: KanameID, threadID: KanameID, title: String) {
        self.id = id
        self.threadID = threadID
        self.title = title
    }
}

public struct ProviderSession: Codable, Equatable, Sendable {
    public let id: KanameID
    public let provider: String
    public let nativeSessionID: String?

    public init(id: KanameID, provider: String, nativeSessionID: String? = nil) {
        self.id = id
        self.provider = provider
        self.nativeSessionID = nativeSessionID
    }
}

public struct Run: Codable, Equatable, Sendable {
    public let id: KanameID
    public let taskID: KanameID
    public let providerSessionID: KanameID

    public init(id: KanameID, taskID: KanameID, providerSessionID: KanameID) {
        self.id = id
        self.taskID = taskID
        self.providerSessionID = providerSessionID
    }
}

public struct QueueItem: Codable, Equatable, Sendable {
    public let id: KanameID
    public let threadID: KanameID
    public let position: UInt64
    public let body: String
    public let createdAt: Date

    public init(
        id: KanameID,
        threadID: KanameID,
        position: UInt64,
        body: String,
        createdAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.position = position
        self.body = body
        self.createdAt = createdAt
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
