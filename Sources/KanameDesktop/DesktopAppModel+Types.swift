import Combine
import CryptoKit
import Foundation
import KanameConnectivity
import KanameDomain
import KanameLocalCore
#if os(macOS)
import Darwin
#endif

public enum DesktopAttention: String, Codable, CaseIterable, Equatable, Sendable {
    case needsResponse
    case needsApproval
    case needsInput
    case running
    case queued
    case completed
    case failed
    case archived

    public var label: String {
        switch self {
        case .needsResponse: "Needs response"
        case .needsApproval: "Needs approval"
        case .needsInput: "Waiting for input"
        case .running: "Running"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        case .archived: "Archived"
        }
    }
}

public enum DesktopWorkKind: String, Codable, CaseIterable, Equatable, Sendable {
    case coding
    case research
    case planning
    case personal

    public var label: String { rawValue.capitalized }

    public var newConversationTitle: String {
        "New \(rawValue) conversation"
    }
}

public enum DesktopMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
}

public enum DesktopConversationTitleSource: String, Codable, Equatable, Sendable {
    case placeholder
    case provisional
    case providerGenerated
    case providerFallback
    case manual
}

private struct DesktopThreadPayload: Decodable {
    let id: String
    let projectID: String?
    let title: String
    let summary: String
    let kind: DesktopWorkKind
    let attention: DesktopAttention
    let provider: String
    let model: String
    let reasoningEffort: String?
    let runtimeMode: ConversationRuntimeMode?
    let networkAccess: Bool?
    let titleSource: DesktopConversationTitleSource?
    let createdAtUnixMillis: Int64?
    let updatedAtUnixMillis: Int64
    let unread: Bool
    let messages: [DesktopMessage]
    let plan: [DesktopPlanItem]
    let evidence: [DesktopEvidence]
}

public struct DesktopMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let turnID: String?
    public let role: DesktopMessageRole
    public let body: String
    public let attachments: [ConversationImageAttachment]
    public let createdAtUnixMillis: Int64

    public init(
        id: String = UUID().uuidString.lowercased(),
        turnID: String? = nil,
        role: DesktopMessageRole,
        body: String,
        attachments: [ConversationImageAttachment] = [],
        createdAtUnixMillis: Int64
    ) {
        self.id = id
        self.turnID = turnID ?? (role == .user ? id : nil)
        self.role = role
        self.body = body
        self.attachments = attachments
        self.createdAtUnixMillis = createdAtUnixMillis
    }

    private enum CodingKeys: String, CodingKey {
        case id, turnID, role, body, attachments, createdAtUnixMillis
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(DesktopMessageRole.self, forKey: .role)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            ?? (role == .user ? id : nil)
        body = try container.decode(String.self, forKey: .body)
        attachments = try container.decodeIfPresent([ConversationImageAttachment].self, forKey: .attachments) ?? []
        createdAtUnixMillis = try container.decode(Int64.self, forKey: .createdAtUnixMillis)
    }
}

public struct DesktopPlanItem: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case pending
        case inProgress
        case complete
    }

    public let id: String
    public var title: String
    public var state: State

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        state: State
    ) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public struct DesktopEvidence: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case passed
        case pending
        case notRun
        case failed
    }

    public let id: String
    public var label: String
    public var detail: String
    public var state: State

    public init(
        id: String = UUID().uuidString.lowercased(),
        label: String,
        detail: String,
        state: State
    ) {
        (self.id, self.label, self.detail, self.state) = (id, label, detail, state)
    }
}

/// One thing the provider learned while investigating or debugging: what it
/// checked, what it observed, what it concluded. Parsed from a `## Findings`
/// section in the provider's reply; later fed by a Kaname Bridge tool.
public struct DesktopFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var detail: String
    public var runID: String?
    public var createdAtUnixMillis: Int64

    public init(id: String, title: String, detail: String, runID: String?, createdAtUnixMillis: Int64) {
        (self.id, self.title, self.detail, self.runID, self.createdAtUnixMillis) = (id, title, detail, runID, createdAtUnixMillis)
    }
}

public struct DesktopThreadCompaction: Codable, Equatable, Sendable {
    public var summary: String
    public var throughMessageID: String
    public var messageCount: Int
    public var createdAtUnixMillis: Int64

    public init(summary: String, throughMessageID: String, messageCount: Int, createdAtUnixMillis: Int64) {
        self.summary = summary
        self.throughMessageID = throughMessageID
        self.messageCount = messageCount
        self.createdAtUnixMillis = createdAtUnixMillis
    }
}

public struct DesktopThread: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var projectID: String?
    public var title: String
    public var summary: String
    public var kind: DesktopWorkKind
    public var attention: DesktopAttention
    public var provider: String
    public var model: String
    public var reasoningEffort: String
    public var runtimeMode: ConversationRuntimeMode
    public var networkAccess: Bool
    public var titleSource: DesktopConversationTitleSource
    public var createdAtUnixMillis: Int64
    public var updatedAtUnixMillis: Int64
    public var unread: Bool
    public var messages: [DesktopMessage]
    public var plan: [DesktopPlanItem]
    public var planBody: String?
    public var findings: [DesktopFinding]?
    public var evidence: [DesktopEvidence]
    /// Set when the user compacted this thread: earlier messages stay stored but
    /// providers start a fresh native session seeded with this digest.
    public var compaction: DesktopThreadCompaction?

    public init(
        id: String = UUID().uuidString.lowercased(),
        projectID: String? = nil,
        title: String,
        summary: String,
        kind: DesktopWorkKind,
        attention: DesktopAttention,
        provider: String = "Local",
        model: String = "No provider selected",
        reasoningEffort: String = "xhigh",
        runtimeMode: ConversationRuntimeMode = .approvalRequired,
        networkAccess: Bool = false,
        titleSource: DesktopConversationTitleSource = .manual,
        createdAtUnixMillis: Int64? = nil,
        updatedAtUnixMillis: Int64,
        unread: Bool = false,
        messages: [DesktopMessage] = [],
        plan: [DesktopPlanItem] = [],
        planBody: String? = nil,
        evidence: [DesktopEvidence] = [],
        compaction: DesktopThreadCompaction? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.summary = summary
        self.kind = kind
        self.attention = attention
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.runtimeMode = runtimeMode
        self.networkAccess = networkAccess
        self.titleSource = titleSource
        self.createdAtUnixMillis = createdAtUnixMillis ?? updatedAtUnixMillis
        self.updatedAtUnixMillis = updatedAtUnixMillis
        self.unread = unread
        self.messages = messages
        self.plan = plan
        self.planBody = planBody
        self.evidence = evidence
        self.compaction = compaction
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DesktopThreadPayload(from: decoder)
        let persistedModel: String
        if payload.provider.caseInsensitiveCompare("Codex") == .orderedSame,
           payload.model == "Local development session" {
            persistedModel = "Use provider default"
        } else {
            persistedModel = payload.model
        }
        self.init(
            id: payload.id,
            projectID: payload.projectID,
            title: payload.title,
            summary: payload.summary,
            kind: payload.kind,
            attention: payload.attention,
            provider: payload.provider,
            model: persistedModel,
            reasoningEffort: payload.reasoningEffort ?? "xhigh",
            runtimeMode: payload.runtimeMode ?? .approvalRequired,
            networkAccess: payload.networkAccess ?? false,
            titleSource: payload.titleSource ?? .manual,
            createdAtUnixMillis: payload.createdAtUnixMillis
                ?? payload.messages.map(\.createdAtUnixMillis).min()
                ?? payload.updatedAtUnixMillis,
            updatedAtUnixMillis: payload.updatedAtUnixMillis,
            unread: payload.unread,
            messages: payload.messages,
            plan: payload.plan,
            evidence: payload.evidence
        )
    }
}

public struct DesktopProjectContext: Codable, Equatable, Sendable {
    public var instructionReferences: [String]
    public var knowledgeSourceIDs: [String]
    public var skillIDs: [String]
    /// Explicitly permits accepted, shared knowledge from other projects to
    /// enter this project's Bridge history context.
    public var allowsCrossProjectRecall: Bool
    public var defaultKind: DesktopWorkKind
    public var defaultProvider: String
    public var defaultModel: String

    public init(
        instructionReferences: [String] = [],
        knowledgeSourceIDs: [String] = [],
        skillIDs: [String] = [],
        allowsCrossProjectRecall: Bool = false,
        defaultKind: DesktopWorkKind = .coding,
        defaultProvider: String = "Codex",
        defaultModel: String = "Use provider default"
    ) {
        self.instructionReferences = instructionReferences
        self.knowledgeSourceIDs = knowledgeSourceIDs
        self.skillIDs = skillIDs
        self.allowsCrossProjectRecall = allowsCrossProjectRecall
        self.defaultKind = defaultKind
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
    }

    private enum CodingKeys: String, CodingKey {
        case instructionReferences
        case knowledgeSourceIDs
        case skillIDs
        case allowsCrossProjectRecall
        case defaultKind
        case defaultProvider
        case defaultModel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            instructionReferences: try container.decodeIfPresent([String].self, forKey: .instructionReferences) ?? [],
            knowledgeSourceIDs: try container.decodeIfPresent([String].self, forKey: .knowledgeSourceIDs) ?? [],
            skillIDs: try container.decodeIfPresent([String].self, forKey: .skillIDs) ?? [],
            allowsCrossProjectRecall: try container.decodeIfPresent(Bool.self, forKey: .allowsCrossProjectRecall) ?? false,
            defaultKind: try container.decodeIfPresent(DesktopWorkKind.self, forKey: .defaultKind) ?? .coding,
            defaultProvider: try container.decodeIfPresent(String.self, forKey: .defaultProvider) ?? "Codex",
            defaultModel: try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? "Use provider default"
        )
    }

    public static let empty = DesktopProjectContext()
}

private struct DesktopProjectPayload: Decodable {
    let id: String
    let name: String
    let path: String?
    let summary: String
    let accent: String?
    let context: DesktopProjectContext?
    let archivedAtUnixMillis: Int64?
    let createdAtUnixMillis: Int64
}

public struct DesktopProject: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var path: String?
    public var summary: String
    public var accent: String
    public var context: DesktopProjectContext
    public var archivedAtUnixMillis: Int64?
    public var createdAtUnixMillis: Int64

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        path: String? = nil,
        summary: String,
        accent: String = "frost",
        context: DesktopProjectContext = .empty,
        archivedAtUnixMillis: Int64? = nil,
        createdAtUnixMillis: Int64
    ) {
        (self.id, self.name, self.path) = (id, name, path)
        (self.summary, self.accent, self.context) = (summary, accent, context)
        (self.archivedAtUnixMillis, self.createdAtUnixMillis) = (archivedAtUnixMillis, createdAtUnixMillis)
    }

    public init(from decoder: any Decoder) throws {
        let payload = try DesktopProjectPayload(from: decoder)
        self.init(
            id: payload.id,
            name: payload.name,
            path: payload.path,
            summary: payload.summary,
            accent: payload.accent ?? "frost",
            context: payload.context ?? .empty,
            archivedAtUnixMillis: payload.archivedAtUnixMillis,
            createdAtUnixMillis: payload.createdAtUnixMillis
        )
    }
}

public struct DesktopRemoteEvent: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case passed
        case ready
        case notRun
        case deferred
    }

    public let id: String
    public var title: String
    public var detail: String
    public var state: State
}

public struct DesktopRemoteStatus: Codable, Equatable, Sendable {
    public var relayStatus: String
    public var enrollmentStatus: String
    public var notificationStatus: String
    public var queueStatus: String
    public var lastVerifiedAtUnixMillis: Int64
    public var events: [DesktopRemoteEvent]

    /// Fresh workspaces contain the remote foundation, not evidence that this
    /// build has exercised it. Operational probes replace these values after
    /// they produce evidence; persisted snapshots keep their recorded state.
    public static func unverifiedFoundation() -> DesktopRemoteStatus {
        DesktopRemoteStatus(
            relayStatus: "Not checked in this workspace",
            enrollmentStatus: "Foundation available · qualification not run",
            notificationStatus: "Contract available · delivery not run",
            queueStatus: "Recovery foundation available · not run",
            lastVerifiedAtUnixMillis: 0,
            events: [
                DesktopRemoteEvent(
                    id: "remote-relay-rehearsal",
                    title: "Encrypted relay foundation",
                    detail: "Rehearsal has not run in this workspace; no relay result or cleanup receipt is recorded.",
                    state: .notRun
                ),
                DesktopRemoteEvent(
                    id: "remote-restart-recovery",
                    title: "Restart recovery foundation",
                    detail: "Recovery has not run in this workspace; behavior and pending state are unknown.",
                    state: .notRun
                ),
                DesktopRemoteEvent(
                    id: "remote-apns-contract",
                    title: "APNs privacy contract",
                    detail: "The foundation defines a content-free hint, but delivery and payload inspection have not run.",
                    state: .notRun
                ),
                DesktopRemoteEvent(
                    id: "remote-physical-iphone",
                    title: "Physical iPhone qualification",
                    detail: "Not run; deferred until an iPhone is explicitly designated.",
                    state: .deferred
                ),
            ]
        )
    }
}

public struct DesktopPreferences: Codable, Equatable, Sendable {
    public enum PreviewPrivacy: String, Codable, CaseIterable, Equatable, Sendable {
        case hidden
        case safeSummary

        public var label: String {
            switch self {
            case .hidden: "Hidden"
            case .safeSummary: "Safe summary"
            }
        }
    }

    public var showTechnicalDetails = false
    public var compactRows = false
    public var previewPrivacy: PreviewPrivacy = .hidden
    public var confirmBeforeArchiving = true
    public var safeMode = false
    public var auditRetentionDays = 90
    public var defaultScheduleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier

    private enum CodingKeys: String, CodingKey {
        case showTechnicalDetails
        case compactRows
        case previewPrivacy
        case confirmBeforeArchiving
        case safeMode
        case auditRetentionDays
        case defaultScheduleTimeZoneIdentifier
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showTechnicalDetails = try container.decodeIfPresent(Bool.self, forKey: .showTechnicalDetails) ?? false
        compactRows = try container.decodeIfPresent(Bool.self, forKey: .compactRows) ?? false
        previewPrivacy = try container.decodeIfPresent(PreviewPrivacy.self, forKey: .previewPrivacy) ?? .hidden
        confirmBeforeArchiving = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeArchiving) ?? true
        safeMode = try container.decodeIfPresent(Bool.self, forKey: .safeMode) ?? false
        auditRetentionDays = try container.decodeIfPresent(Int.self, forKey: .auditRetentionDays) ?? 90
        let storedTimeZone = try container.decodeIfPresent(String.self, forKey: .defaultScheduleTimeZoneIdentifier)
        defaultScheduleTimeZoneIdentifier = storedTimeZone.flatMap(TimeZone.init(identifier:))?.identifier
            ?? TimeZone.autoupdatingCurrent.identifier
    }
}

public protocol DesktopStateStoring: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public protocol DesktopRecoveryStateStoring: DesktopStateStoring {
    func loadRecovery() throws -> Data?
    func saveRecovered(_ data: Data) throws
}

public enum DesktopRecoveryReason: String, Codable, Equatable, Sendable {
    case unreadableState
    case unsupportedStateVersion
    case migrationFailed
    case initialPersistenceFailed
    case runtimeRollbackUnverified
}

public struct DesktopRecoveryStatus: Equatable, Sendable {
    public let reason: DesktopRecoveryReason
    public let detectedStateSchemaVersion: Int?
    public let quarantineCreated: Bool
    public let previousWorkspaceAvailable: Bool

    public init(
        reason: DesktopRecoveryReason,
        detectedStateSchemaVersion: Int?,
        quarantineCreated: Bool,
        previousWorkspaceAvailable: Bool
    ) {
        self.reason = reason
        self.detectedStateSchemaVersion = detectedStateSchemaVersion
        self.quarantineCreated = quarantineCreated
        self.previousWorkspaceAvailable = previousWorkspaceAvailable
    }
}

public enum DesktopModelRecoveryError: Error, Equatable, LocalizedError {
    case recoveryNotRequired
    case recoveryUnavailable
    case previousWorkspaceUnavailable
    case restoreArtifactInvalid
    case persistenceVerificationFailed
    case activeRuntimeWork
    case recoveryRollbackFailed

    public var errorDescription: String? {
        switch self {
        case .recoveryNotRequired: "The workspace is not in recovery mode."
        case .recoveryUnavailable: "Managed desktop recovery is unavailable for this state store."
        case .previousWorkspaceUnavailable: "No previous private workspace is available to restore."
        case .restoreArtifactInvalid: "The verified recovery artifact is not a supported workspace state."
        case .persistenceVerificationFailed: "Kaname could not verify the persisted recovery state."
        case .activeRuntimeWork: "Wait for the active provider worker to stop before resetting or restoring Kaname."
        case .recoveryRollbackFailed: "Kaname could not prove that workspace and runtime recovery rolled back together. It remains locked in read-only recovery."
        }
    }
}

public struct DesktopRuntimeArchiveMove: Equatable, Sendable {
    public let source: URL
    public let archive: URL

    public init(source: URL, archive: URL) {
        self.source = source
        self.archive = archive
    }
}

public struct DesktopRuntimeRestoreTransaction: Sendable {
    public let originalMoves: [DesktopRuntimeArchiveMove]
    public let activatedRoots: [URL]
    public let failedRestoreDirectory: URL
}
